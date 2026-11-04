import Foundation
import Darwin

public enum StripprError: Error, LocalizedError, Sendable {
    case cancelled
    case invalidFile(String)
    case unsupported(String)
    case sourceChanged
    case verification(String)
    case io(String)
    case replacementUncertain(recoveryPath: String, detail: String)
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled before publishing or replacing this file."
        case .invalidFile(let reason): return "Invalid or unsupported media structure: \(reason)"
        case .unsupported(let reason): return reason
        case .sourceChanged: return "The original changed since scanning. Rescan it before cleaning."
        case .verification(let reason): return "Verification failed: \(reason). No file was published or replaced."
        case .io(let reason): return reason
        case .replacementUncertain(let path, let detail): return "File operation needs attention: \(detail). Recovery location: \(path). Keep any recovery data until the result is checked."
        }
    }
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func check() throws { if isCancelled { throw StripprError.cancelled } }
}

public struct MetadataTag: Identifiable, Hashable, Sendable {
    public let id: String
    public let key: String
    public let value: String
    public let removable: Bool
    public let reason: String
    public init(id: String, key: String, value: String, removable: Bool, reason: String) {
        self.id = id; self.key = key; self.value = value; self.removable = removable; self.reason = reason
    }
}

public struct MetadataEdit: Sendable {
    public let offset: UInt64
    public let length: UInt64
    /// Header includes the original width/size and a neutral padding atom/chunk type.
    public let replacementHeader: Data
}

struct SourceIdentity: Equatable, Sendable {
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let inode: UInt64
    let device: Int64
    let linkCount: UInt64
    let permissions: UInt16
    let owner: UInt32
    let group: UInt32
    let flags: UInt32

    private init(_ info: stat) throws {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0 else {
            throw StripprError.invalidFile("Expected a regular local file; symbolic links are not accepted.")
        }
        size = UInt64(info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        inode = UInt64(info.st_ino); device = Int64(info.st_dev)
        linkCount = UInt64(info.st_nlink); permissions = UInt16(info.st_mode & 0o7777)
        owner = info.st_uid; group = info.st_gid; flags = info.st_flags
    }

    static func read(_ url: URL) throws -> SourceIdentity {
        var info = stat()
        let result = url.path.withCString { Darwin.lstat($0, &info) }
        guard result == 0 else { throw StripprError.io("Could not inspect file: \(String(cString: strerror(errno)))") }
        return try SourceIdentity(info)
    }

    static func read(descriptor: Int32) throws -> SourceIdentity {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw StripprError.io("Could not inspect open file: \(String(cString: strerror(errno)))") }
        return try SourceIdentity(info)
    }

    static func read(directoryDescriptor: Int32, name: String) throws -> SourceIdentity {
        var info = stat()
        let result = name.withCString { Darwin.fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else { throw StripprError.io("Could not inspect source directory entry: \(String(cString: strerror(errno)))") }
        return try SourceIdentity(info)
    }

    func isSameObject(as other: SourceIdentity) -> Bool { inode == other.inode && device == other.device }

    /// Rename/swap may change ctime, but must not change bytes, permissions, links, or ownership.
    func matchesAfterRename(_ other: SourceIdentity) -> Bool {
        size == other.size && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
            && isSameObject(as: other) && linkCount == other.linkCount && permissions == other.permissions
            && owner == other.owner && group == other.group && flags == other.flags
    }
}

public struct ScanResult: Sendable {
    public let url: URL
    public let format: String
    public let fileSize: UInt64
    public let tags: [MetadataTag]
    public let edits: [MetadataEdit]
    public let warnings: [String]
    public let keepEncoderInfo: Bool
    let identity: SourceIdentity
    public var canClean: Bool { !edits.isEmpty }
    public var removableTagCount: Int { tags.filter(\.removable).count }
}

public struct CleanResult: Sendable {
    public let outputURL: URL
    public let removedTagCount: Int
    public let verifiedBytes: UInt64
    public let didReplaceOriginal: Bool
    public let warnings: [String]
    /// A retained original/recovery file after a committed replacement cleanup problem.
    public let recoveryURL: URL?
}

extension Data {
    func uint32BE(_ start: Int = 0) -> UInt32 {
        self[start..<start+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    func uint64BE(_ start: Int = 0) -> UInt64 {
        self[start..<start+8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    func uint32LE(_ start: Int = 0) -> UInt32 {
        self[start..<start+4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
