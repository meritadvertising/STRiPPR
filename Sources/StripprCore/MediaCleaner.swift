import Foundation
import Darwin

// The macOS 27 Swift SDK imports both the BSD function and the fcntl `struct flock`
// under one name, hiding the callable Darwin.flock overload. Use its stable C ABI
// (sys/fcntl.h: int flock(int, int)) with an unambiguous Swift name.
@_silgen_name("flock")
func stripprFileLock(_ descriptor: Int32, _ operation: Int32) -> Int32

public enum MediaCleaner {
    /// Changes only approved fixed-size metadata ranges in a staged file and verifies every byte.
    /// Replacement is opt-in. Cancellation is honored until the atomic publication/swap starts.
    public static func clean(_ scan: ScanResult,
                             outputDirectory: URL? = nil,
                             replaceOriginal: Bool = false,
                             cancellation: CancellationToken = CancellationToken(),
                             progress: @Sendable (Double, String) -> Void = { _, _ in }) throws -> CleanResult {
        try cancellation.check()
        guard scan.canClean else { throw StripprError.unsupported("No safely removable supported metadata was found.") }
        guard try SourceIdentity.read(scan.url) == scan.identity else { throw StripprError.sourceChanged }
        try validate(scan)
        let directory = (replaceOriginal ? scan.url.deletingLastPathComponent() : (outputDirectory ?? scan.url.deletingLastPathComponent())).standardizedFileURL
        let directoryDescriptor = directory.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard directoryDescriptor >= 0 else { throw posixError("Could not open the output directory") }
        defer { Darwin.close(directoryDescriptor) }
        let sourceDescriptor = scan.url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard sourceDescriptor >= 0 else { throw posixError("Could not open the original without following symbolic links") }
        let source = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        defer { if replaceOriginal { _ = stripprFileLock(sourceDescriptor, LOCK_UN) }; try? source.close() }
        guard try SourceIdentity.read(descriptor: sourceDescriptor) == scan.identity else { throw StripprError.sourceChanged }
        if replaceOriginal {
            try assertReplaceable(scan.identity, sourceURL: scan.url)
            guard stripprFileLock(sourceDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw posixError("The original is busy or locked; it was not replaced")
            }
        }
        let stage = try StagedFile(directory: directory, directoryDescriptor: directoryDescriptor)
        let temporary = stage.url
        let writer = stage.writer
        defer { try? writer.close() }
        do {
            let chunkSize = 1_048_576
            var copied: UInt64 = 0
            progress(0, "Copying original")
            while copied < scan.fileSize {
                try cancellation.check()
                let bytes = try source.read(upToCount: Int(min(UInt64(chunkSize), scan.fileSize - copied))) ?? Data()
                guard !bytes.isEmpty else { throw StripprError.sourceChanged }
                try writer.write(contentsOf: bytes)
                copied += UInt64(bytes.count)
                progress(Double(copied) / Double(scan.fileSize) * 0.45, "Copying original")
            }
            guard (try source.read(upToCount: 1) ?? Data()).isEmpty else { throw StripprError.sourceChanged }
            let zeros = Data(repeating: 0, count: chunkSize)
            for (index, edit) in scan.edits.enumerated() {
                try cancellation.check()
                try writer.seek(toOffset: edit.offset)
                try writer.write(contentsOf: edit.replacementHeader)
                var remaining = edit.length - UInt64(edit.replacementHeader.count)
                while remaining > 0 {
                    try cancellation.check()
                    let count = Int(min(UInt64(chunkSize), remaining))
                    try writer.write(contentsOf: zeros.prefix(count)); remaining -= UInt64(count)
                }
                progress(0.45 + 0.05 * Double(index + 1) / Double(scan.edits.count), "Removing supported tags")
            }
            if replaceOriginal {
                guard fcopyfile(source.fileDescriptor, writer.fileDescriptor, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                    throw posixError("Could not preserve original permissions, ACLs, and extended attributes")
                }
                let preserved = try SourceIdentity.read(descriptor: writer.fileDescriptor)
                guard preserved.permissions == scan.identity.permissions, preserved.owner == scan.identity.owner,
                      preserved.group == scan.identity.group else {
                    throw StripprError.verification("Original permissions or ownership could not be preserved")
                }
            }
            try writer.synchronize()
            // Pin the identity BEFORE comparing bytes. A verification progress callback must
            // never be able to change already-compared bytes and create a new trusted baseline.
            let verifiedStageIdentity = try SourceIdentity.read(descriptor: writer.fileDescriptor)
            try stage.assertStillOwned(expected: verifiedStageIdentity)
            let cleaned = try FileHandle(forReadingFrom: temporary)
            defer { try? cleaned.close() }
            try source.seek(toOffset: 0)
            var verified: UInt64 = 0
            var firstEdit = 0
            while verified < scan.fileSize {
                try cancellation.check()
                let count = Int(min(UInt64(chunkSize), scan.fileSize - verified))
                var expected = try source.read(upToCount: count) ?? Data()
                let actual = try cleaned.read(upToCount: count) ?? Data()
                guard expected.count == count, actual.count == count else { throw StripprError.verification("File length changed") }
                let chunkEnd = verified + UInt64(count)
                while firstEdit < scan.edits.count && scan.edits[firstEdit].offset + scan.edits[firstEdit].length <= verified { firstEdit += 1 }
                var editIndex = firstEdit
                while editIndex < scan.edits.count && scan.edits[editIndex].offset < chunkEnd {
                    let edit = scan.edits[editIndex]
                    let overlapStart = max(verified, edit.offset)
                    let overlapEnd = min(chunkEnd, edit.offset + edit.length)
                    let localStart = Int(overlapStart - verified)
                    let localEnd = Int(overlapEnd - verified)
                    expected.replaceSubrange(localStart..<localEnd, with: Data(repeating: 0, count: localEnd - localStart))
                    let headerEnd = min(overlapEnd, edit.offset + UInt64(edit.replacementHeader.count))
                    if headerEnd > overlapStart {
                        let hStart = Int(overlapStart - edit.offset)
                        let hEnd = Int(headerEnd - edit.offset)
                        expected.replaceSubrange(localStart..<localStart + hEnd - hStart, with: edit.replacementHeader.subdata(in: hStart..<hEnd))
                    }
                    editIndex += 1
                }
                guard expected == actual else { throw StripprError.verification("Bytes outside approved metadata edits differ") }
                verified += UInt64(count)
                progress(0.50 + Double(verified) / Double(scan.fileSize) * 0.47, "Verifying every byte")
            }
            guard (try cleaned.read(upToCount: 1) ?? Data()).isEmpty else { throw StripprError.verification("Unexpected trailing data") }
            try stage.assertStillOwned(expected: verifiedStageIdentity)
            try assertStableSource(scan, source: source, directoryDescriptor: directoryDescriptor, replacing: replaceOriginal)
            let outputScan = try MediaScanner.scan(url: temporary, cancellation: cancellation, keepEncoderInfo: scan.keepEncoderInfo)
            guard outputScan.edits.isEmpty else { throw StripprError.verification("A supported descriptive tag remains") }
            guard outputScan.fileSize == scan.fileSize else { throw StripprError.verification("File size differs") }
            try stage.assertStillOwned(expected: verifiedStageIdentity)
            try cancellation.check()
            progress(0.99, replaceOriginal ? "Replacing original with verified file" : "Publishing verified copy")
            try cancellation.check()
            try assertStableSource(scan, source: source, directoryDescriptor: directoryDescriptor, replacing: replaceOriginal)
            let result: CleanResult
            if replaceOriginal {
                try assertReplaceable(scan.identity, sourceURL: scan.url)
                try assertStableSource(scan, source: source, directoryDescriptor: directoryDescriptor, replacing: true)
                try stage.assertStillOwned(expected: verifiedStageIdentity)
                try cancellation.check()
                // From this point cancellation is intentionally deferred: the swap and outcome check
                // form a commit. A cancellation after commit reports the committed result honestly.
                result = try replace(scan: scan, stage: stage, source: source, directoryDescriptor: directoryDescriptor, verifiedBytes: verified, verifiedStageIdentity: verifiedStageIdentity)
            } else {
                try stage.assertStillOwned(expected: verifiedStageIdentity)
                try cancellation.check()
                let outputURL = try publish(stage: stage, sourceURL: scan.url, directory: directory, verifiedStageIdentity: verifiedStageIdentity)
                let removedTemporary = stage.cleanup(canResetMetadata: false)
                stage.shouldClean = false
                result = CleanResult(outputURL: outputURL, removedTagCount: scan.removableTagCount, verifiedBytes: verified,
                                     didReplaceOriginal: false,
                                     warnings: scan.warnings + (removedTemporary ? [] : ["Verified copy saved, but a temporary hard link remains at \(temporary.path)."]),
                                     recoveryURL: removedTemporary ? nil : temporary)
            }
            progress(1, result.didReplaceOriginal ? "Original replaced with verified file" : "Verified copy saved")
            return result
        } catch {
            if stage.shouldClean {
                let cleaned = stage.cleanup(canResetMetadata: true)
                stage.shouldClean = false
                if !cleaned {
                    throw StripprError.io("\(error.localizedDescription) An unpublished temporary file remains at \(temporary.path). The original was not replaced.")
                }
            }
            throw error
        }
    }

    private static func validate(_ scan: ScanResult) throws {
        var end: UInt64 = 0
        for edit in scan.edits {
            guard edit.offset >= end, edit.length >= UInt64(edit.replacementHeader.count),
                  edit.offset <= scan.fileSize, edit.length <= scan.fileSize - edit.offset,
                  edit.replacementHeader.count >= 8 else { throw StripprError.verification("Invalid edit plan") }
            end = edit.offset + edit.length
        }
    }

    private static func assertStableSource(_ scan: ScanResult, source: FileHandle, directoryDescriptor: Int32, replacing: Bool) throws {
        guard try SourceIdentity.read(scan.url) == scan.identity,
              try SourceIdentity.read(descriptor: source.fileDescriptor) == scan.identity else { throw StripprError.sourceChanged }
        if replacing {
            guard try SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: scan.url.lastPathComponent) == scan.identity else {
                throw StripprError.sourceChanged
            }
        }
    }

    private static func assertReplaceable(_ identity: SourceIdentity, sourceURL: URL) throws {
        guard identity.linkCount == 1 else { throw StripprError.unsupported("Original replacement is unavailable for files with multiple hard links. Keep originals enabled.") }
        guard identity.owner == geteuid() else { throw StripprError.unsupported("Original replacement requires a file owned by the current user. Keep originals enabled.") }
        let immutableFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
        guard identity.flags & immutableFlags == 0 else { throw StripprError.unsupported("The original is locked or append-only; it was not replaced.") }
        guard identity.permissions & 0o200 != 0, identity.permissions & 0o6000 == 0,
              sourceURL.path.withCString({ Darwin.access($0, W_OK) }) == 0 else {
            throw StripprError.unsupported("The original is read-only or has special permissions; it was not replaced.")
        }
    }

    private static func replace(scan: ScanResult, stage: StagedFile, source: FileHandle, directoryDescriptor: Int32, verifiedBytes: UInt64, verifiedStageIdentity: SourceIdentity) throws -> CleanResult {
        try stage.assertStillOwned(expected: verifiedStageIdentity)
        let newIdentity = verifiedStageIdentity
        let sourceName = scan.url.lastPathComponent
        let swap = stage.name.withCString { temporary in sourceName.withCString { original in
            renameatx_np(directoryDescriptor, temporary, directoryDescriptor, original, UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY))
        } }
        guard swap == 0 else { throw posixError("Atomic original replacement failed; the original was not replaced") }
        // The temporary path now holds the old file. Never let ordinary stage cleanup remove it
        // until its identity is proven and the installed result is also still our verified inode.
        stage.shouldClean = false
        let displaced = try? SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: stage.name)
        let installed = try? SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: sourceName)
        let openedOriginal = try? SourceIdentity.read(descriptor: source.fileDescriptor)
        if let displaced, let installed, let openedOriginal,
           displaced.matchesAfterRename(scan.identity), openedOriginal.matchesAfterRename(scan.identity),
           installed.matchesAfterRename(newIdentity) {
            let removedBackup = stage.name.withCString { unlinkat(directoryDescriptor, $0, 0) } == 0
            return CleanResult(outputURL: scan.url, removedTagCount: scan.removableTagCount, verifiedBytes: verifiedBytes,
                               didReplaceOriginal: true,
                               warnings: scan.warnings + (removedBackup ? [] : ["Original replaced successfully, but the former original remains at \(stage.url.path)."]),
                               recoveryURL: removedBackup ? nil : stage.url)
        }
        // A source-path/content race was detected after the atomic swap. Swap back only while
        // both directory entries still refer to the exact inodes observed after our commit.
        if let displaced, let installed, installed.matchesAfterRename(newIdentity),
           let currentDisplaced = try? SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: stage.name),
           let currentInstalled = try? SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: sourceName),
           currentDisplaced == displaced, currentInstalled == installed {
            let rollback = stage.name.withCString { temporary in sourceName.withCString { original in
                renameatx_np(directoryDescriptor, temporary, directoryDescriptor, original, UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY))
            } }
            if rollback == 0,
               let restored = try? SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: sourceName),
               let staged = try? SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: stage.name),
               restored.matchesAfterRename(displaced), staged.matchesAfterRename(newIdentity) {
                stage.shouldClean = true
                throw StripprError.sourceChanged
            }
        }
        throw StripprError.replacementUncertain(recoveryPath: stage.url.path,
            detail: "A concurrent source change prevented a safe outcome check or rollback")
    }

    private static func publish(stage: StagedFile, sourceURL: URL, directory: URL, verifiedStageIdentity: SourceIdentity) throws -> URL {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        for number in 0..<10_000 {
            try stage.assertStillOwned(expected: verifiedStageIdentity)
            let suffix = number == 0 ? ".stripped" : ".stripped-\(number)"
            let name = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            let result = stage.name.withCString { from in name.withCString { to in
                linkat(stage.directoryDescriptor, from, stage.directoryDescriptor, to, 0)
            } }
            if result == 0 { return directory.appendingPathComponent(name) }
            if errno == EEXIST { continue }
            throw posixError("Could not publish the verified copy (output volume must support hard links)")
        }
        throw StripprError.io("Too many existing cleaned copies. Choose another output directory.")
    }

    private static func posixError(_ operation: String) -> StripprError {
        .io("\(operation): \(String(cString: strerror(errno)))")
    }
}

private final class StagedFile {
    let name: String
    let url: URL
    let directoryDescriptor: Int32
    let writer: FileHandle
    let identity: SourceIdentity
    var shouldClean = true

    init(directory: URL, directoryDescriptor: Int32) throws {
        name = ".strippr-\(UUID().uuidString).tmp"
        url = directory.appendingPathComponent(name)
        self.directoryDescriptor = directoryDescriptor
        let descriptor = name.withCString { openat(directoryDescriptor, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw StripprError.io("Could not create a temporary cleaned file: \(String(cString: strerror(errno)))") }
        writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { identity = try SourceIdentity.read(descriptor: descriptor) }
        catch { try? writer.close(); _ = name.withCString { unlinkat(directoryDescriptor, $0, 0) }; throw error }
    }

    func assertStillOwned(expected: SourceIdentity) throws {
        let current = try SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: name)
        guard current.isSameObject(as: identity), current.linkCount == 1, current == expected,
              try SourceIdentity.read(descriptor: writer.fileDescriptor) == expected else {
            throw StripprError.verification("The verified temporary file changed before publication")
        }
    }

    /// Remove only our staged inode. A swapped-out original is intentionally excluded.
    func cleanup(canResetMetadata: Bool) -> Bool {
        var info = stat()
        let inspected = name.withCString { fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if inspected != 0 { return errno == ENOENT }
        guard UInt64(info.st_ino) == identity.inode, Int64(info.st_dev) == identity.device,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return false }
        if name.withCString({ unlinkat(directoryDescriptor, $0, 0) }) == 0 { return true }
        // A copied ACL/flag can impede deletion of our unpublished temporary file. Reset only
        // that single-link staging inode, never a published copy or a displaced original.
        guard canResetMetadata, info.st_nlink == 1 else { return false }
        _ = fchflags(writer.fileDescriptor, 0)
        _ = fchmod(writer.fileDescriptor, S_IRUSR | S_IWUSR)
        if let emptyACL = acl_init(0) { _ = acl_set_fd(writer.fileDescriptor, emptyACL); acl_free(UnsafeMutableRawPointer(emptyACL)) }
        return name.withCString { unlinkat(directoryDescriptor, $0, 0) } == 0
    }
}
