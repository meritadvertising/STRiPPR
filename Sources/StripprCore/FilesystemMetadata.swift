import Foundation
import Darwin
import CryptoKit

struct FilesystemAttributeFingerprint: Equatable, Sendable {
    let length: UInt64
    let digest: Data
}

struct FilesystemMetadataSnapshot: Equatable, Sendable {
    let permissions: UInt16
    let owner: UInt32
    let group: UInt32
    let flags: UInt32
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let acl: Data
    let attributes: [String: FilesystemAttributeFingerprint]
}

struct FilesystemMetadataReport {
    let warnings: [String]
    let toleratedAttributes: Set<String>
}

/// The seam deliberately leaves policy and independent verification in the real helper.
/// A backend returning success cannot conceal a rejected attribute callback or a bad snapshot.
protocol FilesystemMetadataBackend {
    func snapshot(descriptor: Int32) throws -> FilesystemMetadataSnapshot
    /// A publication has already committed; cancellation must not obscure its outcome.
    func snapshotCommitted(descriptor: Int32) throws -> FilesystemMetadataSnapshot
    func copy(source: Int32, destination: Int32,
              onAttributeError: @escaping (String?, Int32) -> Bool) throws
}

extension FilesystemMetadataBackend {
    func snapshotCommitted(descriptor: Int32) throws -> FilesystemMetadataSnapshot {
        try snapshot(descriptor: descriptor)
    }
}

enum FilesystemMetadata {
    static let provenance = "com.apple.provenance"

    static func preserve(source: Int32, destination: Int32,
                         expected: FilesystemMetadataSnapshot,
                         backend: any FilesystemMetadataBackend) throws -> FilesystemMetadataReport {
        var failures: [(String?, Int32)] = []
        do {
            try backend.copy(source: source, destination: destination) { name, code in
                failures.append((name, code))
                return tolerates(name: name, error: code)
            }
        } catch {
            if let failure = failures.first(where: { !tolerates(name: $0.0, error: $0.1) }) {
                throw attributeError(failure.0, failure.1)
            }
            throw error
        }
        if let failure = failures.first(where: { !tolerates(name: $0.0, error: $0.1) }) {
            throw attributeError(failure.0, failure.1)
        }
        let tolerated = Set(failures.compactMap { $0.0 })
        let report = try verify(source: source, destination: destination, expected: expected,
                                toleratedAttributes: tolerated, backend: backend)
        return FilesystemMetadataReport(warnings: unique(report.warnings + (tolerated.isEmpty ? [] : [provenanceWarning])),
                                        toleratedAttributes: tolerated)
    }

    static func verify(source: Int32, destination: Int32,
                       expected: FilesystemMetadataSnapshot,
                       toleratedAttributes: Set<String>,
                       backend: any FilesystemMetadataBackend,
                       committed: Bool = false) throws -> FilesystemMetadataReport {
        let original: FilesystemMetadataSnapshot
        let actual: FilesystemMetadataSnapshot
        if committed {
            original = try backend.snapshotCommitted(descriptor: source)
            actual = try backend.snapshotCommitted(descriptor: destination)
        } else {
            original = try backend.snapshot(descriptor: source)
            actual = try backend.snapshot(descriptor: destination)
        }
        guard original == expected else { throw StripprError.sourceChanged }
        func mismatch(_ reason: String) -> StripprError {
            committed ? .io("Published filesystem metadata verification failed: \(reason).") : .verification(reason)
        }
        guard actual.permissions == expected.permissions, actual.owner == expected.owner,
              actual.group == expected.group, actual.flags == expected.flags else {
            throw mismatch("Original filesystem permissions, ownership, or flags could not be preserved")
        }
        guard actual.modifiedSeconds == expected.modifiedSeconds,
              actual.modifiedNanoseconds == expected.modifiedNanoseconds else {
            throw mismatch("Original filesystem modification time could not be preserved")
        }
        guard actual.acl == expected.acl else {
            throw mismatch("Original filesystem access control list could not be preserved")
        }
        var warnings: [String] = []
        for name in Set(expected.attributes.keys).union(actual.attributes.keys).sorted() {
            guard expected.attributes[name] != actual.attributes[name] else { continue }
            if name == provenance, toleratedAttributes.contains(provenance) {
                warnings.append(provenanceWarning)
            } else if name == provenance, expected.attributes[name] == nil {
                // The OS can attach provenance to a newly created inode. Do not remove it.
                warnings.append("macOS added filesystem attribute com.apple.provenance to the cleaned file. Its value was not copied from the original.")
            } else {
                throw mismatch("Filesystem attribute could not be preserved: \(name)")
            }
        }
        return FilesystemMetadataReport(warnings: unique(warnings), toleratedAttributes: toleratedAttributes)
    }

    static func tolerates(name: String?, error: Int32) -> Bool {
        name == provenance && [EACCES, EPERM, ENOTSUP].contains(error)
    }

    static let provenanceWarning = "Filesystem attribute not preserved: com.apple.provenance. The destination refused to copy this Apple provenance information; it may affect system security tracking. Media bytes and required filesystem attributes were verified."

    static func unique(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { seen.insert($0).inserted }
    }

    private static func attributeError(_ name: String?, _ code: Int32) -> StripprError {
        .io("Could not preserve filesystem attribute \(name ?? "(unidentified)"): \(String(cString: strerror(code))). The original was not replaced.")
    }
}

struct DarwinFilesystemMetadataBackend: FilesystemMetadataBackend {
    let cancellation: CancellationToken
    init(cancellation: CancellationToken = CancellationToken()) { self.cancellation = cancellation }

    func snapshotCommitted(descriptor: Int32) throws -> FilesystemMetadataSnapshot {
        try DarwinFilesystemMetadataBackend(cancellation: CancellationToken()).snapshot(descriptor: descriptor)
    }

    func snapshot(descriptor: Int32) throws -> FilesystemMetadataSnapshot {
        try cancellation.check()
        let before = try SourceIdentity.read(descriptor: descriptor)
        let acl = try readACL(descriptor)
        let names = try attributeNames(descriptor)
        var attributes: [String: FilesystemAttributeFingerprint] = [:]
        for name in names { attributes[name] = try fingerprint(descriptor, name: name) }
        guard try SourceIdentity.read(descriptor: descriptor) == before else { throw StripprError.sourceChanged }
        return FilesystemMetadataSnapshot(permissions: before.permissions, owner: before.owner,
            group: before.group, flags: before.flags, modifiedSeconds: before.modifiedSeconds,
            modifiedNanoseconds: before.modifiedNanoseconds, acl: acl, attributes: attributes)
    }

    func copy(source: Int32, destination: Int32,
              onAttributeError: @escaping (String?, Int32) -> Bool) throws {
        try cancellation.check()
        let sourceIdentity = try SourceIdentity.read(descriptor: source)
        guard let state = copyfile_state_alloc() else { throw failure("Could not allocate filesystem metadata copy state") }
        defer { copyfile_state_free(state) }
        let context = FilesystemCopyContext(cancellation: cancellation, onAttributeError: onAttributeError)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), pointer) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(filesystemCopyCallback, to: UnsafeRawPointer.self)) == 0 else {
            throw failure("Could not configure filesystem metadata copy")
        }
        let result = withExtendedLifetime(context) {
            fcopyfile(source, destination, state, copyfile_flags_t(COPYFILE_SECURITY))
        }
        let code = errno
        try cancellation.check()
        guard result == 0 else { throw failure("Could not preserve original filesystem metadata", code: code) }
        // Even COPYFILE_SECURITY can normalize quarantine via libquarantine. Preserve each
        // source attribute afterward as opaque, unchanged bytes through ordinary authorized
        // APIs. Never interpret security flags, remove an OS-created attribute, or override
        // a denied write. Independent fingerprints below remain the acceptance criterion.
        for name in try attributeNames(source) {
            try copyAttribute(source: source, destination: destination, name: name,
                              onAttributeError: onAttributeError)
        }
        // Resource-fork writes may update mtime. A second copyfile call would normalize
        // quarantine again, so restore just the original modification time through its
        // public descriptor API, with normal OS authorization and nanosecond precision.
        let destinationIdentity = try SourceIdentity.read(descriptor: destination)
        if destinationIdentity.modifiedSeconds != sourceIdentity.modifiedSeconds ||
            destinationIdentity.modifiedNanoseconds != sourceIdentity.modifiedNanoseconds {
            var attributes = attrlist()
            attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = attrgroup_t(ATTR_CMN_MODTIME)
            var modified = timespec(tv_sec: time_t(sourceIdentity.modifiedSeconds),
                                    tv_nsec: Int(sourceIdentity.modifiedNanoseconds))
            guard fsetattrlist(destination, &attributes, &modified, MemoryLayout<timespec>.size, 0) == 0 else {
                throw failure("Could not preserve original filesystem modification time")
            }
        }
        try cancellation.check()
    }

    private func copyAttribute(source: Int32, destination: Int32, name: String,
                               onAttributeError: (String?, Int32) -> Bool) throws {
        try cancellation.check()
        let size = name.withCString { fgetxattr(source, $0, nil, 0, 0, 0) }
        guard size >= 0 else { throw failure("Could not read filesystem attribute \(name)") }
        let resourceFork = name == "com.apple.ResourceFork"
        guard (resourceFork && UInt64(size) <= UInt64(UInt32.max)) || size <= 67_108_864 else {
            throw StripprError.io("Filesystem attribute \(name) is too large to preserve safely.")
        }
        var position = 0
        repeat {
            try cancellation.check()
            let count = resourceFork ? min(1_048_576, size - position) : size
            var bytes = Data(count: count)
            let read = bytes.withUnsafeMutableBytes { buffer in name.withCString {
                fgetxattr(source, $0, buffer.baseAddress, buffer.count, UInt32(position), 0)
            } }
            guard read >= 0 else { throw failure("Could not read filesystem attribute \(name)") }
            guard read == count else { throw StripprError.sourceChanged }
            let written = bytes.withUnsafeBytes { buffer in name.withCString {
                fsetxattr(destination, $0, buffer.baseAddress, buffer.count, UInt32(position), 0)
            } }
            let code = errno
            if written != 0 {
                // The shared helper records this event and independently enforces the
                // exact-name/errno exception. No other rejected attribute is discarded.
                if onAttributeError(name, code) { return }
                throw failure("Could not preserve filesystem attribute \(name)", code: code)
            }
            position += count
        } while resourceFork && position < size
    }

    private func readACL(_ descriptor: Int32) throws -> Data {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return Data() }
            throw failure("Could not inspect original filesystem access control list")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        // Some filesystems do not implement acl_valid_fd_np. Validate a duplicate:
        // acl_valid may reorder entries, while the original serialization must retain order.
        guard let validationCopy = acl_dup(acl) else { throw failure("Could not duplicate filesystem access control list") }
        defer { acl_free(UnsafeMutableRawPointer(validationCopy)) }
        guard acl_valid(validationCopy) == 0 else {
            throw failure("Could not validate filesystem access control list")
        }
        let data = try externalACL(acl)
        var entry: acl_entry_t?
        errno = 0
        if acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0 {
            guard errno == EINVAL || errno == ENOENT || errno == 0 else {
                throw failure("Could not inspect filesystem access control entries")
            }
            // An empty ACL can still carry inheritance flags. Normalize only the
            // exact unflagged empty representation, retaining all other ACL bytes.
            guard let empty = acl_init(0) else { throw failure("Could not inspect empty filesystem ACL") }
            defer { acl_free(UnsafeMutableRawPointer(empty)) }
            if data == (try externalACL(empty)) { return Data() }
        }
        return data
    }

    private func externalACL(_ acl: acl_t) throws -> Data {
        let size = acl_size(acl)
        guard size > 0, size <= 1_048_576 else { throw StripprError.io("Filesystem access control list has an unsupported size.") }
        var data = Data(count: size)
        let written = data.withUnsafeMutableBytes { acl_copy_ext($0.baseAddress!, acl, size) }
        guard written >= 0 else { throw failure("Could not fingerprint filesystem access control list") }
        data.count = written
        return data
    }

    private func attributeNames(_ descriptor: Int32) throws -> [String] {
        let size = flistxattr(descriptor, nil, 0, 0)
        guard size >= 0 else { throw failure("Could not enumerate filesystem attributes") }
        guard size <= 1_048_576 else { throw StripprError.io("Filesystem attribute list is too large to verify safely.") }
        if size == 0 { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let count = flistxattr(descriptor, &buffer, buffer.count, 0)
        guard count >= 0 else { throw failure("Could not read filesystem attribute names") }
        guard count > 0, count <= size, buffer[count - 1] == 0 else { throw StripprError.sourceChanged }
        return buffer.prefix(count).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
    }

    private func fingerprint(_ descriptor: Int32, name: String) throws -> FilesystemAttributeFingerprint {
        try cancellation.check()
        let size = name.withCString { fgetxattr(descriptor, $0, nil, 0, 0, 0) }
        guard size >= 0 else { throw failure("Could not inspect filesystem attribute \(name)") }
        let resourceFork = name == "com.apple.ResourceFork"
        guard (resourceFork && UInt64(size) <= UInt64(UInt32.max)) || size <= 67_108_864 else {
            throw StripprError.io("Filesystem attribute \(name) is too large to verify safely.")
        }
        var hash = SHA256()
        if resourceFork {
            var position = 0
            while position < size {
                try cancellation.check()
                var bytes = Data(count: min(1_048_576, size - position))
                let count = bytes.withUnsafeMutableBytes { buffer in name.withCString {
                    fgetxattr(descriptor, $0, buffer.baseAddress, buffer.count, UInt32(position), 0)
                } }
                guard count >= 0 else { throw failure("Could not verify filesystem attribute \(name)") }
                guard count == bytes.count else { throw StripprError.sourceChanged }
                hash.update(data: bytes); position += count
            }
        } else {
            var bytes = Data(count: size)
            let count = bytes.withUnsafeMutableBytes { buffer in name.withCString {
                fgetxattr(descriptor, $0, buffer.baseAddress, buffer.count, 0, 0)
            } }
            guard count >= 0 else { throw failure("Could not verify filesystem attribute \(name)") }
            guard count == size else { throw StripprError.sourceChanged }
            hash.update(data: bytes)
        }
        return FilesystemAttributeFingerprint(length: UInt64(size), digest: Data(hash.finalize()))
    }

    private func failure(_ operation: String, code: Int32 = errno) -> StripprError {
        .io("\(operation): \(String(cString: strerror(code))).")
    }
}

final class FilesystemCopyContext {
    let cancellation: CancellationToken
    let onAttributeError: (String?, Int32) -> Bool
    init(cancellation: CancellationToken, onAttributeError: @escaping (String?, Int32) -> Bool) {
        self.cancellation = cancellation; self.onAttributeError = onAttributeError
    }
}

let filesystemCopyCallback: copyfile_callback_t = { what, stage, state, _, _, pointer in
    let savedError = errno
    guard let pointer else { return Int32(COPYFILE_QUIT) }
    let context = Unmanaged<FilesystemCopyContext>.fromOpaque(pointer).takeUnretainedValue()
    if context.cancellation.isCancelled { return Int32(COPYFILE_QUIT) }
    guard stage == COPYFILE_ERR else { return Int32(COPYFILE_CONTINUE) }
    guard what == COPYFILE_COPY_XATTR else {
        _ = context.onAttributeError(nil, savedError)
        return Int32(COPYFILE_QUIT)
    }
    var name: UnsafeMutablePointer<CChar>?
    if let state { _ = copyfile_state_get(state, UInt32(COPYFILE_STATE_XATTRNAME), &name) }
    return context.onAttributeError(name.map { String(cString: $0) }, savedError)
        ? Int32(COPYFILE_SKIP) : Int32(COPYFILE_QUIT)
}
