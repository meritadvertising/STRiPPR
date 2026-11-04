import Foundation
import Darwin

/// Every method returns a captured errno, or zero on success. This avoids reading
/// ambient errno after a test seam or another library operation has run.
protocol FilesystemPublicationBackend {
    func hardLink(sourceDirectory: Int32, sourceName: String, destinationDirectory: Int32, destinationName: String) -> Int32
    func swap(sourceDirectory: Int32, sourceName: String, destinationDirectory: Int32, destinationName: String) -> Int32
    func renameDirectory(sourceDirectory: Int32, sourceName: String, destinationDirectory: Int32, destinationName: String) -> Int32
}

struct DarwinFilesystemPublicationBackend: FilesystemPublicationBackend {
    func hardLink(sourceDirectory: Int32, sourceName: String, destinationDirectory: Int32, destinationName: String) -> Int32 {
        let result = sourceName.withCString { source in destinationName.withCString { destination in
            linkat(sourceDirectory, source, destinationDirectory, destination, 0)
        } }
        return result == 0 ? 0 : errno
    }

    func swap(sourceDirectory: Int32, sourceName: String, destinationDirectory: Int32, destinationName: String) -> Int32 {
        let result = sourceName.withCString { source in destinationName.withCString { destination in
            renameatx_np(sourceDirectory, source, destinationDirectory, destination, UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY))
        } }
        return result == 0 ? 0 : errno
    }

    func renameDirectory(sourceDirectory: Int32, sourceName: String, destinationDirectory: Int32, destinationName: String) -> Int32 {
        let result = sourceName.withCString { source in destinationName.withCString { destination in
            renameat(sourceDirectory, source, destinationDirectory, destination)
        } }
        return result == 0 ? 0 : errno
    }
}

struct FilesystemPublicationResult {
    let outputURL: URL
    let warnings: [String]
    let usedDirectory: Bool
}

enum FilesystemPublication {
    static func publishCopy(stage: StagedFile, sourceURL: URL, directory: URL,
                            verifiedStageIdentity: SourceIdentity,
                            backend: any FilesystemPublicationBackend,
                            validate: () throws -> Void) throws -> FilesystemPublicationResult {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        for number in 0..<10_000 {
            try validate()
            let suffix = number == 0 ? ".stripped" : ".stripped-\(number)"
            let name = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            let code = backend.hardLink(sourceDirectory: stage.directoryDescriptor, sourceName: stage.name,
                destinationDirectory: stage.parentDirectoryDescriptor, destinationName: name)
            if code == 0 {
                return FilesystemPublicationResult(outputURL: directory.appendingPathComponent(name), warnings: [], usedDirectory: false)
            }
            // A server may commit a link and then report an I/O error. Inspect
            // both aliases without cancellation before treating any error as a
            // failed operation or attempting another publication method.
            var candidate = stat()
            let inspected = name.withCString {
                fstatat(stage.parentDirectoryDescriptor, $0, &candidate, AT_SYMLINK_NOFOLLOW)
            }
            let inspectionError = inspected == 0 ? 0 : errno
            let candidateIsOtherObject = inspected == 0
                && (UInt64(candidate.st_ino) != verifiedStageIdentity.inode
                    || Int64(candidate.st_dev) != verifiedStageIdentity.device)
            let candidateKnownNotLinked = candidateIsOtherObject || (inspected != 0 && inspectionError == ENOENT)
            guard candidateKnownNotLinked,
                  (try? stage.assertStillOwned(expected: verifiedStageIdentity)) != nil else {
                stage.shouldClean = false
                throw StripprError.replacementUncertain(recoveryPath: stage.directoryURL.path,
                    detail: "The volume reported a copy-publication error. The output may be present at \(directory.appendingPathComponent(name).path). The staging folder was retained; inspect both locations")
            }
            if code == EEXIST { continue }
            if code == ENOTSUP {
                return try publishDirectory(stage: stage, sourceURL: sourceURL, directory: directory,
                    requestedReplacement: false, verifiedStageIdentity: verifiedStageIdentity,
                    backend: backend, validate: validate)
            }
            throw failure("Could not publish the verified copy", code: code)
        }
        throw StripprError.io("Too many existing cleaned copies. Choose another output directory.")
    }

    /// A nonempty directory can be renamed to a fresh name without ever replacing
    /// a file, symlink, or nonempty directory. We precheck all collisions, including
    /// empty directories, and choose a new 128-bit UUID name. An uncoordinated actor
    /// can still race an empty-directory insertion; no existing file data is replaced.
    static func publishDirectory(stage: StagedFile, sourceURL: URL, directory: URL,
                                 requestedReplacement: Bool, verifiedStageIdentity: SourceIdentity,
                                 backend: any FilesystemPublicationBackend,
                                 validate: () throws -> Void) throws -> FilesystemPublicationResult {
        for _ in 0..<32 {
            try validate()
            let name = limitedName(sourceURL.deletingPathExtension().lastPathComponent, maximumBytes: 96)
                + ".stripped-" + UUID().uuidString
            var existing = stat()
            let inspected = name.withCString { fstatat(stage.parentDirectoryDescriptor, $0, &existing, AT_SYMLINK_NOFOLLOW) }
            if inspected == 0 { continue }
            let inspectionError = errno
            guard inspectionError == ENOENT else { throw failure("Could not inspect the output folder", code: inspectionError) }
            // The backend may have returned unsupported after a concurrent change.
            // Recheck the source, verified file, and owned directory before committing.
            try validate()
            let oldName = stage.directoryName
            // This SMB server can make named attributes transiently unavailable
            // when a payload handle spans a parent-directory rename. Pin identity,
            // close all payload handles, and reopen only after the operation.
            try stage.closePayloadForDirectoryCommit(expected: verifiedStageIdentity)
            let code = backend.renameDirectory(sourceDirectory: stage.parentDirectoryDescriptor, sourceName: oldName,
                destinationDirectory: stage.parentDirectoryDescriptor, destinationName: name)
            if code == 0 {
                stage.markDirectoryPublished(name, nativeRenameSucceeded: true)
                do {
                    try stage.reopenPayloadAfterDirectoryOperation(expected: verifiedStageIdentity)
                    try stage.assertPublished(expected: verifiedStageIdentity)
                }
                catch {
                    throw StripprError.replacementUncertain(recoveryPath: stage.directoryURL.path,
                        detail: "The original was retained, but the published output folder could not be verified: \(committedDiagnostic(error)). No automatic cleanup was attempted")
                }
                let notice = requestedReplacement
                    ? "Original was not replaced: this volume does not support guarded atomic replacement. A verified cleaned copy was saved in an output folder; the original is retained."
                    : "This volume does not support single-file atomic publication. A verified cleaned copy was saved in an output folder; the original is retained."
                return FilesystemPublicationResult(outputURL: stage.url, warnings: [notice], usedDirectory: true)
            }
            // A network error can leave the server's result uncertain. Preserve any
            // owned output directory already visible at the candidate name.
            if stage.directoryExistsAtParent(name) {
                stage.markDirectoryPublished(name)
                throw StripprError.replacementUncertain(recoveryPath: stage.directoryURL.path,
                    detail: "The original was retained. The server reported an output-folder publication error; inspect this recovery folder")
            }
            var candidate = stat()
            let inspectedAfterError = name.withCString {
                fstatat(stage.parentDirectoryDescriptor, $0, &candidate, AT_SYMLINK_NOFOLLOW)
            }
            let inspectionErrorAfterCommit = inspectedAfterError == 0 ? 0 : errno
            guard (inspectedAfterError == 0 || inspectionErrorAfterCommit == ENOENT),
                  (try? stage.assertClosedPayloadStillOwned(expected: verifiedStageIdentity)) != nil else {
                stage.shouldClean = false
                throw StripprError.replacementUncertain(recoveryPath: stage.directoryURL.path,
                    detail: "The original was retained. The output-folder operation could not be checked after the server reported an error. Inspect the staging folder and possible output folder at \(directory.appendingPathComponent(name).path)")
            }
            do { try stage.reopenPayloadAfterDirectoryOperation(expected: verifiedStageIdentity) }
            catch {
                stage.shouldClean = false
                throw StripprError.replacementUncertain(recoveryPath: stage.directoryURL.path,
                    detail: "The original was retained, but the unchanged staging payload could not be reopened after the output-folder operation: \(committedDiagnostic(error))")
            }
            if [EEXIST, ENOTEMPTY, ENOTDIR, EISDIR].contains(code) { continue }
            throw failure("Could not publish the verified output folder; the original was retained", code: code)
        }
        throw StripprError.io("Could not choose an unused output-folder name. The original was retained.")
    }

    static func limitedName(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        var bytes = 0
        for scalar in value.unicodeScalars {
            let size = String(scalar).utf8.count
            if bytes + size > maximumBytes { break }
            result.unicodeScalars.append(scalar); bytes += size
        }
        return result.isEmpty ? "video" : result
    }

    private static func failure(_ operation: String, code: Int32) -> StripprError {
        .io("\(operation): \(String(cString: strerror(code)))")
    }

    static func committedDiagnostic(_ error: Error) -> String {
        // Pre-commit verification errors carry a blanket no-publication suffix.
        // Preserve their concrete reason without repeating that after a commit.
        if case StripprError.verification(let reason) = error { return reason }
        return error.localizedDescription
    }
}

private struct StagingDirectoryIdentity: Equatable {
    let inode: UInt64
    let device: Int64
    let owner: UInt32
    let group: UInt32
    let permissions: UInt16
    let flags: UInt32

    init(_ info: stat) throws {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw StripprError.verification("The staging directory was replaced")
        }
        inode = UInt64(info.st_ino); device = Int64(info.st_dev)
        owner = info.st_uid; group = info.st_gid
        permissions = UInt16(info.st_mode & 0o7777); flags = info.st_flags
    }

    static func read(_ descriptor: Int32) throws -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw StripprError.io("Could not inspect the staging directory descriptor: \(String(cString: strerror(errno)))")
        }
        return try Self(info)
    }

    static func read(parent: Int32, name: String) throws -> Self {
        var info = stat()
        guard name.withCString({ fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw StripprError.verification("Could not inspect the staging directory path: \(String(cString: strerror(errno)))")
        }
        return try Self(info)
    }

    func isSameObject(as other: Self) -> Bool {
        inode == other.inode && device == other.device
    }

    /// Capture stable metadata without changing the directory object pinned at
    /// creation. SMB may canonicalize a directory after its first child or rename.
    static func stableMetadata(descriptor: Int32, parent: Int32, name: String,
                               created: Self, allowingInodeCanonicalization: Bool = false) throws -> Self {
        var mismatch = ""
        for _ in 0..<3 {
            let opened = try read(descriptor)
            let atName = try read(parent: parent, name: name)
            let openedAgain = try read(descriptor)
            let atNameAgain = try read(parent: parent, name: name)
            guard [opened, atName, openedAgain, atNameAgain].allSatisfy({
                $0.isSameObject(as: created) || (allowingInodeCanonicalization && $0.device == created.device)
            }) else {
                throw StripprError.verification("The staging directory object changed: descriptor \(opened.inode)/\(opened.device), path \(atName.inode)/\(atName.device), expected \(created.inode)/\(created.device)")
            }
            if opened == atName, atName == openedAgain, openedAgain == atNameAgain {
                return openedAgain
            }
            mismatch = "descriptor/path: \(opened.differences(from: atName)); repeated descriptor/path: \(openedAgain.differences(from: atNameAgain))"
        }
        throw StripprError.verification("The staging directory metadata did not stabilize: \(mismatch)")
    }

    func matchesAfterHiddenNameRename(_ other: Self, allowingInodeCanonicalization: Bool = false) -> Bool {
        // SMB derives UF_HIDDEN from a dot-prefixed name. Publishing the folder
        // visibly may clear only that presentation flag; all access/identity
        // metadata remains guarded, and the post-rename baseline is then pinned.
        let hidden = UInt32(UF_HIDDEN)
        return (isSameObject(as: other) || (allowingInodeCanonicalization && device == other.device))
            && owner == other.owner && group == other.group
            && permissions == other.permissions && (flags == other.flags || flags == (other.flags & ~hidden))
    }

    func differences(from other: Self) -> String {
        var fields: [String] = []
        if inode != other.inode { fields.append("inode \(inode) vs \(other.inode)") }
        if device != other.device { fields.append("device \(device) vs \(other.device)") }
        if owner != other.owner { fields.append("owner \(owner) vs \(other.owner)") }
        if group != other.group { fields.append("group \(group) vs \(other.group)") }
        if permissions != other.permissions { fields.append("mode \(permissions) vs \(other.permissions)") }
        if flags != other.flags { fields.append("flags \(flags) vs \(other.flags)") }
        return fields.isEmpty ? "none" : fields.joined(separator: ", ")
    }
}

/// The payload starts inside an exclusively created hidden directory. The same
/// verified file can be linked/swapped on supporting volumes or published with
/// its whole directory on a volume that rejects those file-level operations.
final class StagedFile {
    let name: String
    let parentDirectory: URL
    let parentDirectoryDescriptor: Int32
    let directoryDescriptor: Int32
    private(set) var writer: FileHandle
    let identity: SourceIdentity
    private var directoryIdentity: StagingDirectoryIdentity
    private var publishedDirectoryPinned = false
    private var payloadClosedForDirectoryCommit = false
    private var previousDirectoryName: String?
    private var nativeDirectoryRenameSucceeded = false
    private(set) var directoryName: String
    private(set) var directoryPublished = false
    var shouldClean = true

    var directoryURL: URL { parentDirectory.appendingPathComponent(directoryName, isDirectory: true) }
    var url: URL { directoryURL.appendingPathComponent(name) }

    init(directory: URL, directoryDescriptor parent: Int32, sourceURL: URL) throws {
        let folderName = ".strippr-\(UUID().uuidString)"
        let stem = FilesystemPublication.limitedName(sourceURL.deletingPathExtension().lastPathComponent, maximumBytes: 160)
        let ext = FilesystemPublication.limitedName(sourceURL.pathExtension, maximumBytes: 16)
        let fileName = stem + ".stripped" + (sourceURL.pathExtension.isEmpty ? "" : "." + ext)
        guard !fileName.contains("/"), !fileName.contains("\0") else { throw StripprError.io("Unsupported output filename") }
        guard folderName.withCString({ mkdirat(parent, $0, S_IRWXU) }) == 0 else {
            throw StripprError.io("Could not create an owned hidden staging directory: \(String(cString: strerror(errno)))")
        }
        let child = folderName.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard child >= 0 else {
            _ = folderName.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
            throw StripprError.io("Could not open the owned hidden staging directory")
        }
        let createdDirectory: StagingDirectoryIdentity
        do {
            createdDirectory = try StagingDirectoryIdentity.read(child)
            guard createdDirectory == (try StagingDirectoryIdentity.read(parent: parent, name: folderName)) else {
                throw StripprError.verification("The staging directory changed during creation")
            }
        } catch { close(child); throw error }
        let descriptor = fileName.withCString { openat(child, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else {
            if (try? StagingDirectoryIdentity.read(parent: parent, name: folderName)) == createdDirectory {
                _ = folderName.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
            }
            close(child)
            throw StripprError.io("Could not create a temporary cleaned file: \(String(cString: strerror(errno)))")
        }
        let fileWriter = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let fileIdentity: SourceIdentity
        let ownedDirectory: StagingDirectoryIdentity
        do {
            fileIdentity = try SourceIdentity.read(descriptor: descriptor)
            ownedDirectory = try StagingDirectoryIdentity.stableMetadata(descriptor: child,
                parent: parent, name: folderName, created: createdDirectory)
        } catch {
            // All cleanup uses the descriptors and directory identity we created.
            // Never recurse through a substituted path or delete an existing entry.
            if let atDirectory = try? StagingDirectoryIdentity.read(parent: parent, name: folderName),
               atDirectory.isSameObject(as: createdDirectory),
               let openedDirectory = try? StagingDirectoryIdentity.read(child),
               openedDirectory.isSameObject(as: createdDirectory),
               let opened = try? SourceIdentity.read(descriptor: descriptor),
               let atName = try? SourceIdentity.read(directoryDescriptor: child, name: fileName),
               opened.isSameObject(as: atName) {
                _ = fileName.withCString { unlinkat(child, $0, 0) }
                _ = folderName.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
            }
            try? fileWriter.close(); close(child)
            throw error
        }
        // Assign only after all throwing setup, so error cleanup cannot race a
        // partially initialized object's deinit and close a descriptor twice.
        parentDirectory = directory
        parentDirectoryDescriptor = parent
        directoryName = folderName
        name = fileName
        directoryDescriptor = child
        writer = fileWriter
        identity = fileIdentity
        directoryIdentity = ownedDirectory
    }

    deinit { close(directoryDescriptor) }

    /// SMB may defer a data writer's final modification time until close. Close
    /// the data-writing descriptor before final metadata restoration and retain
    /// an anchored read-only descriptor for all subsequent verification/commit.
    func finalizeDataWriter() throws -> FileHandle {
        let beforeClose = try SourceIdentity.read(descriptor: writer.fileDescriptor)
        try assertStillOwned(expected: beforeClose)
        try writer.synchronize()
        try writer.close()
        let descriptor = name.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw StripprError.io("Could not reopen the staged file for final verification: \(String(cString: strerror(errno)))")
        }
        let finalHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try assertDirectoryOwned()
            let reopened = try SourceIdentity.read(descriptor: descriptor)
            let atName = try SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: name)
            guard reopened.isSameObject(as: identity), reopened.linkCount == 1,
                  reopened.size == beforeClose.size, reopened == atName else {
                throw StripprError.verification("The staged file changed while closing its data writer")
            }
        } catch { try? finalHandle.close(); throw error }
        writer = finalHandle
        return finalHandle
    }

    /// Metadata changes on an SMB read-only handle may remain pending until its
    /// close. Rotate that setter handle to a separate verifier before publication.
    func finalizeMetadataHandle() throws -> FileHandle {
        try finalizeDataWriter()
    }

    func closePayloadForDirectoryCommit(expected: SourceIdentity) throws {
        try assertStillOwned(expected: expected)
        try writer.close()
        payloadClosedForDirectoryCommit = true
        try assertClosedPayloadStillOwned(expected: expected)
    }

    func assertClosedPayloadStillOwned(expected: SourceIdentity) throws {
        guard payloadClosedForDirectoryCommit else { throw StripprError.io("The directory-publication payload was not closed") }
        try assertDirectoryOwned()
        let atName = try SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: name)
        guard atName == expected, atName.isSameObject(as: identity), atName.linkCount == 1,
              try entries() == [name] else {
            throw StripprError.verification("The closed directory-publication payload changed: \(payloadDifferences(atName, expected))")
        }
    }

    func reopenPayloadAfterDirectoryOperation(expected: SourceIdentity) throws {
        guard payloadClosedForDirectoryCommit else { throw StripprError.io("Unexpected open payload during directory publication") }
        let descriptor = name.withCString { openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw StripprError.io("Could not reopen the directory-publication payload: \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let opened = try SourceIdentity.read(descriptor: descriptor)
            let atName = try SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: name)
            guard opened == expected, opened == atName, opened.isSameObject(as: identity), opened.linkCount == 1 else {
                throw StripprError.verification("The directory-publication payload changed while its handles were closed: \(payloadDifferences(opened, expected)); ctime \(opened.changedSeconds).\(opened.changedNanoseconds) vs \(expected.changedSeconds).\(expected.changedNanoseconds)")
            }
        } catch { try? handle.close(); throw error }
        writer = handle
        payloadClosedForDirectoryCommit = false
    }

    func openPublishedPayload(at output: URL, expected: SourceIdentity, linkCount: UInt64) throws -> FileHandle {
        let container: Int32
        let closeContainer: Bool
        let publishedName: String
        if directoryPublished {
            guard output.deletingLastPathComponent().standardizedFileURL == directoryURL.standardizedFileURL,
                  output.lastPathComponent == name else {
                throw StripprError.io("Unexpected published output location")
            }
            container = directoryName.withCString {
                openat(parentDirectoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard container >= 0 else { throw StripprError.io("Could not reopen the published output folder: \(String(cString: strerror(errno)))") }
            closeContainer = true
            publishedName = name
        } else {
            guard output.deletingLastPathComponent().standardizedFileURL == parentDirectory.standardizedFileURL else {
                throw StripprError.io("Unexpected published output directory")
            }
            container = parentDirectoryDescriptor
            closeContainer = false
            publishedName = output.lastPathComponent
        }
        defer { if closeContainer { close(container) } }
        if directoryPublished {
            let freshDirectory = try StagingDirectoryIdentity.read(container)
            guard freshDirectory == directoryIdentity else {
                throw StripprError.io("The freshly opened published folder changed: \(freshDirectory.differences(from: directoryIdentity))")
            }
        }
        let descriptor = publishedName.withCString { openat(container, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw StripprError.io("Could not reopen the published file: \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let fresh = try SourceIdentity.read(descriptor: descriptor)
            let atName = try SourceIdentity.read(directoryDescriptor: container, name: publishedName)
            let retained = try SourceIdentity.read(descriptor: writer.fileDescriptor)
            guard fresh == atName, fresh.matchesAfterRename(retained),
                  fresh.isSameObject(as: expected), fresh.linkCount == linkCount,
                  fresh.size == expected.size, fresh.modifiedSeconds == expected.modifiedSeconds,
                  fresh.modifiedNanoseconds == expected.modifiedNanoseconds,
                  fresh.permissions == expected.permissions, fresh.owner == expected.owner,
                  fresh.group == expected.group, fresh.flags == expected.flags else {
                throw StripprError.io("The freshly opened published payload differs from the verified file: \(payloadDifferences(fresh, expected)); expected links \(linkCount)")
            }
        } catch { try? handle.close(); throw error }
        return handle
    }

    func assertStillOwned(expected: SourceIdentity) throws {
        try assertDirectoryOwned()
        let current = try SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: name)
        guard current.isSameObject(as: identity), current.linkCount == 1, current == expected,
              try SourceIdentity.read(descriptor: writer.fileDescriptor) == expected else {
            throw StripprError.verification("The verified temporary file changed before publication")
        }
        guard try entries() == [name] else { throw StripprError.verification("The staging directory contains unexpected entries") }
    }

    func assertPublished(expected: SourceIdentity) throws {
        if !publishedDirectoryPinned {
            let descriptorIdentity = try StagingDirectoryIdentity.read(directoryDescriptor)
            let canonicalizingInode = !descriptorIdentity.isSameObject(as: directoryIdentity)
                && nativeDirectoryRenameSucceeded
                && FilesystemPublicationCapabilities.allowsDirectoryInodeCanonicalization(descriptor: directoryDescriptor)
            let published = try StagingDirectoryIdentity.stableMetadata(descriptor: directoryDescriptor,
                parent: parentDirectoryDescriptor, name: directoryName, created: directoryIdentity,
                allowingInodeCanonicalization: canonicalizingInode)
            guard published.matchesAfterHiddenNameRename(directoryIdentity,
                    allowingInodeCanonicalization: canonicalizingInode) else {
                throw StripprError.verification("The published directory metadata changed unexpectedly: \(published.differences(from: directoryIdentity))")
            }
            if canonicalizingInode { try assertDirectoryInodeCanonicalization(published) }
            directoryIdentity = published
            publishedDirectoryPinned = true
        }
        try assertDirectoryOwned()
        let current = try SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: name)
        let opened = try SourceIdentity.read(descriptor: writer.fileDescriptor)
        guard current.isSameObject(as: identity) else {
            throw StripprError.verification("The published payload object changed: inode/device \(current.inode)/\(current.device), expected \(identity.inode)/\(identity.device)")
        }
        guard current.matchesAfterRename(expected) else {
            throw StripprError.verification("The published payload path differs from its verified identity: \(payloadDifferences(current, expected))")
        }
        guard opened.matchesAfterRename(expected) else {
            throw StripprError.verification("The open published payload differs from its verified identity: \(payloadDifferences(opened, expected))")
        }
        let contents = try entries()
        guard contents == [name] else {
            throw StripprError.verification("The published folder contains unexpected entries: \(contents.joined(separator: ", "))")
        }
    }

    func markDirectoryPublished(_ name: String, nativeRenameSucceeded: Bool = false) {
        previousDirectoryName = directoryName
        nativeDirectoryRenameSucceeded = nativeRenameSucceeded
        directoryName = name; directoryPublished = true; shouldClean = false
    }

    func directoryExistsAtParent(_ name: String) -> Bool {
        guard let candidate = try? StagingDirectoryIdentity.read(parent: parentDirectoryDescriptor, name: name) else { return false }
        return candidate.isSameObject(as: directoryIdentity)
    }

    /// Never recurse: foreign or unexpected entries and replaced directory paths
    /// are retained for recovery instead of being deleted.
    func cleanup(canResetMetadata: Bool) -> Bool {
        guard !directoryPublished, (try? assertDirectoryOwned()) != nil else { return false }
        var info = stat()
        let inspected = name.withCString { fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if inspected == 0 {
            guard UInt64(info.st_ino) == identity.inode, Int64(info.st_dev) == identity.device,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return false }
            if name.withCString({ unlinkat(directoryDescriptor, $0, 0) }) != 0 {
                guard canResetMetadata, info.st_nlink == 1 else { return false }
                _ = fchflags(writer.fileDescriptor, 0)
                _ = fchmod(writer.fileDescriptor, S_IRUSR | S_IWUSR)
                if let acl = acl_init(0) { _ = acl_set_fd(writer.fileDescriptor, acl); acl_free(UnsafeMutableRawPointer(acl)) }
                guard name.withCString({ unlinkat(directoryDescriptor, $0, 0) }) == 0 else { return false }
            }
        } else if errno != ENOENT { return false }
        return removeDirectoryIfEmpty()
    }

    func removeDirectoryIfEmpty() -> Bool {
        guard !directoryPublished, (try? assertDirectoryOwned()) != nil,
              let contents = try? entries(), contents.isEmpty else { return false }
        return directoryName.withCString { unlinkat(parentDirectoryDescriptor, $0, AT_REMOVEDIR) } == 0
    }

    private func assertDirectoryOwned() throws {
        let opened = try StagingDirectoryIdentity.read(directoryDescriptor)
        guard opened == directoryIdentity else {
            throw StripprError.verification("The owned staging directory descriptor changed: \(opened.differences(from: directoryIdentity))")
        }
        let atName = try StagingDirectoryIdentity.read(parent: parentDirectoryDescriptor, name: directoryName)
        guard atName == directoryIdentity else {
            throw StripprError.verification("The owned staging directory path changed: \(atName.differences(from: directoryIdentity))")
        }
    }

    /// Apple's SMB client hashes parent/name into n_ino on servers without
    /// persistent file IDs, and recomputes it on the same vnode after rename.
    /// The continuously held directory FD remains our anchor; qualify a new
    /// reported inode only on that known filesystem capability and native success.
    private func assertDirectoryInodeCanonicalization(_ published: StagingDirectoryIdentity) throws {
        guard nativeDirectoryRenameSucceeded, let oldName = previousDirectoryName else {
            throw StripprError.io("Directory identity canonicalization requires a successful native rename")
        }
        var oldEntry = stat()
        let oldExists = oldName.withCString { fstatat(parentDirectoryDescriptor, $0, &oldEntry, AT_SYMLINK_NOFOLLOW) }
        let oldError = oldExists == 0 ? 0 : errno
        guard oldExists != 0, oldError == ENOENT else {
            throw StripprError.io("The old staging directory name is not confirmed absent after publication")
        }
        let anchoredParent = try descriptorDirectoryURL(parentDirectoryDescriptor)
        let anchoredPublished = try descriptorDirectoryURL(directoryDescriptor)
        guard anchoredPublished.path == anchoredParent.appendingPathComponent(directoryName, isDirectory: true).standardizedFileURL.path else {
            throw StripprError.io("The held directory descriptor does not resolve to the published folder")
        }
        let fresh = directoryName.withCString {
            openat(parentDirectoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fresh >= 0 else {
            throw StripprError.io("Could not reopen the canonical published folder: \(String(cString: strerror(errno)))")
        }
        defer { close(fresh) }
        let reopened = try StagingDirectoryIdentity.read(fresh)
        let stillHeld = try StagingDirectoryIdentity.read(directoryDescriptor)
        let atName = try StagingDirectoryIdentity.read(parent: parentDirectoryDescriptor, name: directoryName)
        guard reopened == published, stillHeld == published, atName == published else {
            throw StripprError.io("The held and freshly opened published-folder identities disagree")
        }
    }

    private func descriptorDirectoryURL(_ descriptor: Int32) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            fcntl(descriptor, F_GETPATH, pointer.baseAddress!)
        }
        guard result == 0 else {
            throw StripprError.io("Could not resolve a pinned directory descriptor: \(String(cString: strerror(errno)))")
        }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true).standardizedFileURL
    }

    private func payloadDifferences(_ actual: SourceIdentity, _ expected: SourceIdentity) -> String {
        var fields: [String] = []
        if actual.inode != expected.inode { fields.append("inode \(actual.inode) vs \(expected.inode)") }
        if actual.device != expected.device { fields.append("device \(actual.device) vs \(expected.device)") }
        if actual.size != expected.size { fields.append("size \(actual.size) vs \(expected.size)") }
        if actual.modifiedSeconds != expected.modifiedSeconds || actual.modifiedNanoseconds != expected.modifiedNanoseconds {
            fields.append("mtime \(actual.modifiedSeconds).\(actual.modifiedNanoseconds) vs \(expected.modifiedSeconds).\(expected.modifiedNanoseconds)")
        }
        if actual.linkCount != expected.linkCount { fields.append("links \(actual.linkCount) vs \(expected.linkCount)") }
        if actual.permissions != expected.permissions { fields.append("mode \(actual.permissions) vs \(expected.permissions)") }
        if actual.owner != expected.owner { fields.append("owner \(actual.owner) vs \(expected.owner)") }
        if actual.group != expected.group { fields.append("group \(actual.group) vs \(expected.group)") }
        if actual.flags != expected.flags { fields.append("flags \(actual.flags) vs \(expected.flags)") }
        return fields.isEmpty ? "none" : fields.joined(separator: ", ")
    }

    private func entries() throws -> [String] {
        let fd = openat(directoryDescriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StripprError.io("Could not inspect staging-directory entries through openat: \(String(cString: strerror(errno)))") }
        guard let stream = fdopendir(fd) else {
            let code = errno; close(fd)
            throw StripprError.io("Could not read staging-directory entries: \(String(cString: strerror(code)))")
        }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw StripprError.io("Could not finish staging-directory inspection") }
                break
            }
            let value = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if value != "." && value != ".." { result.append(value) }
        }
        return result.sorted()
    }
}
