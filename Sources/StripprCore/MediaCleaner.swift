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
        try clean(scan, outputDirectory: outputDirectory, replaceOriginal: replaceOriginal,
                  cancellation: cancellation, filesystem: DarwinFilesystemMetadataBackend(cancellation: cancellation), progress: progress)
    }

    static func clean(_ scan: ScanResult,
                      outputDirectory: URL? = nil,
                      replaceOriginal: Bool = false,
                      cancellation: CancellationToken = CancellationToken(),
                      filesystem: any FilesystemMetadataBackend,
                      publication: any FilesystemPublicationBackend = DarwinFilesystemPublicationBackend(),
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
        let stage = try StagedFile(directory: directory, directoryDescriptor: directoryDescriptor, sourceURL: scan.url)
        let temporary = stage.url
        var writer = stage.writer
        defer { try? stage.writer.close() }
        do {
            // Fail before copying a large payload if required attributes cannot be preserved.
            // Every reported attribute error remains fatal except the explicitly disclosed,
            // narrowly permitted refusal to copy Apple's provenance attribute.
            progress(0, "Checking filesystem attributes")
            let expectedMetadata = try filesystem.snapshot(descriptor: sourceDescriptor)
            var metadataReport = try FilesystemMetadata.preserve(source: sourceDescriptor,
                destination: writer.fileDescriptor, expected: expectedMetadata, backend: filesystem)
            try assertStableSource(scan, source: source, directoryDescriptor: directoryDescriptor, replacing: replaceOriginal)
            try cancellation.check()
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
            // A network filesystem can defer its data-write timestamp until the
            // writing descriptor closes. Finalize that descriptor before restoring
            // metadata, then verify and publish using an anchored read-only handle.
            writer = try stage.finalizeDataWriter()
            // Payload writes can change timestamps and OS-created attributes. Reapply and
            // independently verify after closing the data writer; copyfile success alone is insufficient.
            let reapplied = try FilesystemMetadata.preserve(source: sourceDescriptor,
                destination: writer.fileDescriptor, expected: expectedMetadata, backend: filesystem)
            metadataReport = FilesystemMetadataReport(
                warnings: FilesystemMetadata.unique(metadataReport.warnings + reapplied.warnings),
                toleratedAttributes: metadataReport.toleratedAttributes.union(reapplied.toleratedAttributes))
            // Finish metadata-setting handles before renaming their parent. SMB
            // can otherwise make named attributes transiently unavailable on close.
            writer = try stage.finalizeMetadataHandle()
            let settledMetadata = try FilesystemMetadata.verify(source: sourceDescriptor,
                destination: writer.fileDescriptor, expected: expectedMetadata,
                toleratedAttributes: metadataReport.toleratedAttributes, backend: filesystem)
            metadataReport = FilesystemMetadataReport(
                warnings: FilesystemMetadata.unique(metadataReport.warnings + settledMetadata.warnings),
                toleratedAttributes: metadataReport.toleratedAttributes)
            // Pin the identity BEFORE comparing bytes. A verification progress callback must
            // never be able to change already-compared bytes and create a new trusted baseline.
            let verifiedStageIdentity = try SourceIdentity.read(descriptor: writer.fileDescriptor)
            try stage.assertStillOwned(expected: verifiedStageIdentity)
            let cleaned = try FileHandle(forReadingFrom: temporary)
            defer { try? cleaned.close() }
            let verified = try verifyPayload(scan: scan, source: source, cleaned: cleaned,
                cancellation: cancellation, progress: { verified in
                    progress(0.50 + Double(verified) / Double(scan.fileSize) * 0.47, "Verifying every byte")
                })
            // No payload reader may remain open across the NAS directory rename.
            try cleaned.close()
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
            let finalMetadata = try FilesystemMetadata.verify(source: sourceDescriptor,
                destination: writer.fileDescriptor, expected: expectedMetadata,
                toleratedAttributes: metadataReport.toleratedAttributes, backend: filesystem)
            let resultWarnings = FilesystemMetadata.unique(scan.warnings + metadataReport.warnings + finalMetadata.warnings)
            let toleratedAttributes = metadataReport.toleratedAttributes
            let validatePublication: () throws -> Void = {
                try cancellation.check()
                try assertStableSource(scan, source: source, directoryDescriptor: directoryDescriptor, replacing: replaceOriginal)
                _ = try FilesystemMetadata.verify(source: sourceDescriptor, destination: stage.writer.fileDescriptor,
                    expected: expectedMetadata, toleratedAttributes: toleratedAttributes, backend: filesystem)
                try stage.assertStillOwned(expected: verifiedStageIdentity)
            }
            let verifyCommittedPublication: (URL, UInt64) throws -> [String] = { output, links in
                do {
                    let published = try stage.openPublishedPayload(at: output, expected: verifiedStageIdentity, linkCount: links)
                    defer { try? published.close() }
                    let metadata = try FilesystemMetadata.verify(source: sourceDescriptor, destination: published.fileDescriptor,
                        expected: expectedMetadata, toleratedAttributes: toleratedAttributes, backend: filesystem, committed: true)
                    let originalBeforeRead = try SourceIdentity.read(descriptor: sourceDescriptor)
                    let publishedBeforeRead = try SourceIdentity.read(descriptor: published.fileDescriptor)
                    _ = try verifyPayload(scan: scan, source: source, cleaned: published, cancellation: nil)
                    guard try SourceIdentity.read(descriptor: sourceDescriptor) == originalBeforeRead,
                          try SourceIdentity.read(descriptor: published.fileDescriptor) == publishedBeforeRead else {
                        throw StripprError.io("The original or published payload changed during the final byte comparison")
                    }
                    if replaceOriginal && !stage.directoryPublished && output.standardizedFileURL == scan.url.standardizedFileURL {
                        let original = try SourceIdentity.read(descriptor: sourceDescriptor)
                        let backup = try SourceIdentity.read(directoryDescriptor: stage.directoryDescriptor, name: stage.name)
                        guard original.matchesAfterRename(scan.identity), backup.matchesAfterRename(scan.identity) else {
                            throw StripprError.io("The displaced original changed during final payload verification")
                        }
                    } else {
                        try assertStableSource(scan, source: source, directoryDescriptor: directoryDescriptor, replacing: false)
                    }
                    // Reopen the final name again after reading every byte, so a
                    // concurrent path/metadata change cannot pass an earlier check.
                    let finalPayload = try stage.openPublishedPayload(at: output, expected: verifiedStageIdentity, linkCount: links)
                    defer { try? finalPayload.close() }
                    guard try SourceIdentity.read(descriptor: published.fileDescriptor)
                            == SourceIdentity.read(descriptor: finalPayload.fileDescriptor) else {
                        throw StripprError.io("The published payload changed during final verification")
                    }
                    let final = try FilesystemMetadata.verify(source: sourceDescriptor, destination: finalPayload.fileDescriptor,
                        expected: expectedMetadata, toleratedAttributes: toleratedAttributes, backend: filesystem, committed: true)
                    return FilesystemMetadata.unique(metadata.warnings + final.warnings)
                } catch {
                    stage.shouldClean = false
                    throw StripprError.replacementUncertain(recoveryPath: stage.directoryURL.path,
                        detail: "The file operation committed at \(output.path), but fresh final-path verification failed: \(FilesystemPublication.committedDiagnostic(error)). Recovery data was retained and no automatic cleanup was attempted")
                }
            }
            let result: CleanResult
            if replaceOriginal {
                try assertReplaceable(scan.identity, sourceURL: scan.url)
                try assertStableSource(scan, source: source, directoryDescriptor: directoryDescriptor, replacing: true)
                try stage.assertStillOwned(expected: verifiedStageIdentity)
                try cancellation.check()
                // From this point cancellation is intentionally deferred: the swap and outcome check
                // form a commit. A cancellation after commit reports the committed result honestly.
                result = try replace(scan: scan, stage: stage, source: source, directoryDescriptor: directoryDescriptor,
                                     verifiedBytes: verified, verifiedStageIdentity: verifiedStageIdentity, warnings: resultWarnings,
                                     publication: publication, validatePublication: validatePublication,
                                     verifyCommittedPublication: verifyCommittedPublication)
            } else {
                try stage.assertStillOwned(expected: verifiedStageIdentity)
                try cancellation.check()
                let published = try FilesystemPublication.publishCopy(stage: stage, sourceURL: scan.url,
                    directory: directory, verifiedStageIdentity: verifiedStageIdentity, backend: publication,
                    validate: validatePublication)
                stage.shouldClean = false
                let committedWarnings = try verifyCommittedPublication(published.outputURL, published.usedDirectory ? 1 : 2)
                let removedTemporary = published.usedDirectory || stage.cleanup(canResetMetadata: false)
                stage.shouldClean = false
                result = CleanResult(outputURL: published.outputURL, removedTagCount: scan.removableTagCount, verifiedBytes: verified,
                                     didReplaceOriginal: false,
                                     warnings: resultWarnings + published.warnings + committedWarnings + (removedTemporary ? [] : ["Verified copy saved, but a staging folder remains at \(stage.directoryURL.path)."]),
                                     recoveryURL: removedTemporary ? nil : stage.directoryURL)
            }
            progress(1, result.didReplaceOriginal ? "Original replaced with verified file" : "Verified copy saved")
            return result
        } catch {
            if stage.shouldClean {
                let cleaned = stage.cleanup(canResetMetadata: true)
                stage.shouldClean = false
                if !cleaned {
                    throw StripprError.io("\(error.localizedDescription) Staging cleanup could not be verified. Inspect \(stage.directoryURL.path); the original was not replaced.")
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

    private static func verifyPayload(scan: ScanResult, source: FileHandle, cleaned: FileHandle,
                                      cancellation: CancellationToken?,
                                      progress: (UInt64) -> Void = { _ in }) throws -> UInt64 {
        let chunkSize = 1_048_576
        try source.seek(toOffset: 0)
        try cleaned.seek(toOffset: 0)
        var verified: UInt64 = 0
        var firstEdit = 0
        while verified < scan.fileSize {
            try cancellation?.check()
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
                    expected.replaceSubrange(localStart..<localStart + hEnd - hStart,
                        with: edit.replacementHeader.subdata(in: hStart..<hEnd))
                }
                editIndex += 1
            }
            guard expected == actual else { throw StripprError.verification("Bytes outside approved metadata edits differ") }
            verified += UInt64(count)
            progress(verified)
        }
        guard (try cleaned.read(upToCount: 1) ?? Data()).isEmpty else { throw StripprError.verification("Unexpected trailing data") }
        return verified
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

    private static func replace(scan: ScanResult, stage: StagedFile, source: FileHandle, directoryDescriptor: Int32,
                                verifiedBytes: UInt64, verifiedStageIdentity: SourceIdentity, warnings: [String],
                                publication: any FilesystemPublicationBackend,
                                validatePublication: () throws -> Void,
                                verifyCommittedPublication: (URL, UInt64) throws -> [String]) throws -> CleanResult {
        try stage.assertStillOwned(expected: verifiedStageIdentity)
        let newIdentity = verifiedStageIdentity
        let sourceName = scan.url.lastPathComponent
        let code = publication.swap(sourceDirectory: stage.directoryDescriptor, sourceName: stage.name,
            destinationDirectory: directoryDescriptor, destinationName: sourceName)
        if code != 0 {
            // A failed response does not prove the server did not commit. Only
            // unchanged source entries, the opened original, and owned staging
            // payload permit ordinary failure cleanup or an unsupported fallback.
            // These checks deliberately defer cancellation after the operation.
            let sourceAtName = try? SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: sourceName)
            let openedOriginal = try? SourceIdentity.read(descriptor: source.fileDescriptor)
            guard sourceAtName == scan.identity, openedOriginal == scan.identity,
                  (try? stage.assertStillOwned(expected: verifiedStageIdentity)) != nil else {
                stage.shouldClean = false
                throw StripprError.replacementUncertain(recoveryPath: stage.directoryURL.path,
                    detail: "The volume reported an original-replacement error, but an unchanged outcome could not be verified. Inspect the original path at \(scan.url.path) and the retained staging folder before continuing")
            }
        }
        if code == ENOTSUP {
            let published = try FilesystemPublication.publishDirectory(stage: stage, sourceURL: scan.url,
                directory: scan.url.deletingLastPathComponent(), requestedReplacement: true,
                verifiedStageIdentity: verifiedStageIdentity, backend: publication, validate: validatePublication)
            let committedWarnings = try verifyCommittedPublication(published.outputURL, 1)
            return CleanResult(outputURL: published.outputURL, removedTagCount: scan.removableTagCount,
                verifiedBytes: verifiedBytes, didReplaceOriginal: false,
                warnings: warnings + published.warnings + committedWarnings, recoveryURL: nil)
        }
        guard code == 0 else {
            throw StripprError.io("Atomic original replacement failed; the original was not replaced: \(String(cString: strerror(code)))")
        }
        // The temporary path now holds the old file. Never let ordinary stage cleanup remove it
        // until its identity is proven and the installed result is also still our verified inode.
        stage.shouldClean = false
        let displaced = try? SourceIdentity.read(directoryDescriptor: stage.directoryDescriptor, name: stage.name)
        let installed = try? SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: sourceName)
        let openedOriginal = try? SourceIdentity.read(descriptor: source.fileDescriptor)
        if let displaced, let installed, let openedOriginal,
           displaced.matchesAfterRename(scan.identity), openedOriginal.matchesAfterRename(scan.identity),
           installed.matchesAfterRename(newIdentity) {
            let committedWarnings = try verifyCommittedPublication(scan.url, 1)
            let removedBackup = stage.name.withCString { unlinkat(stage.directoryDescriptor, $0, 0) } == 0
            let removedFolder = removedBackup && stage.removeDirectoryIfEmpty()
            let recovery = removedBackup ? stage.directoryURL : stage.url
            return CleanResult(outputURL: scan.url, removedTagCount: scan.removableTagCount, verifiedBytes: verifiedBytes,
                               didReplaceOriginal: true,
                               warnings: warnings + committedWarnings + (removedFolder ? [] : ["Original replaced successfully, but a recovery staging folder remains at \(stage.directoryURL.path)."]),
                               recoveryURL: removedFolder ? nil : recovery)
        }
        // A source-path/content race was detected after the atomic swap. Swap back only while
        // both directory entries still refer to the exact inodes observed after our commit.
        if let displaced, let installed, installed.matchesAfterRename(newIdentity),
           let currentDisplaced = try? SourceIdentity.read(directoryDescriptor: stage.directoryDescriptor, name: stage.name),
           let currentInstalled = try? SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: sourceName),
           currentDisplaced == displaced, currentInstalled == installed {
            let rollback = publication.swap(sourceDirectory: stage.directoryDescriptor, sourceName: stage.name,
                destinationDirectory: directoryDescriptor, destinationName: sourceName)
            if rollback == 0,
               let restored = try? SourceIdentity.read(directoryDescriptor: directoryDescriptor, name: sourceName),
               let staged = try? SourceIdentity.read(directoryDescriptor: stage.directoryDescriptor, name: stage.name),
               restored.matchesAfterRename(displaced), staged.matchesAfterRename(newIdentity) {
                stage.shouldClean = true
                throw StripprError.sourceChanged
            }
        }
        throw StripprError.replacementUncertain(recoveryPath: stage.url.path,
            detail: "A concurrent source change prevented a safe outcome check or rollback")
    }

    private static func posixError(_ operation: String) -> StripprError {
        .io("\(operation): \(String(cString: strerror(errno)))")
    }
}
