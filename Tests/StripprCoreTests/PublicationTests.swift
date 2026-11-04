import XCTest
import Foundation
import Darwin
@testable import StripprCore

final class PublicationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("STRiPPR-publication-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testDirectoryInodeCanonicalizationGateRequiresKnownNonpersistentSMBIDs() throws {
        let persistent = UInt32(VOL_CAP_FMT_PERSISTENTOBJECTIDS)
        XCTAssertTrue(FilesystemPublicationCapabilities.allowsDirectoryInodeCanonicalization(
            fileSystemName: "smbfs", formatCapabilities: 0, formatValid: persistent))
        XCTAssertFalse(FilesystemPublicationCapabilities.allowsDirectoryInodeCanonicalization(
            fileSystemName: "smbfs", formatCapabilities: persistent, formatValid: persistent))
        XCTAssertFalse(FilesystemPublicationCapabilities.allowsDirectoryInodeCanonicalization(
            fileSystemName: "smbfs", formatCapabilities: 0, formatValid: 0), "An unknown capability must remain fail-closed")
        XCTAssertFalse(FilesystemPublicationCapabilities.allowsDirectoryInodeCanonicalization(
            fileSystemName: "smbfs", formatCapabilities: persistent, formatValid: 0))
        for other in ["apfs", "hfs", "nfs", "SMBFS", ""] {
            XCTAssertFalse(FilesystemPublicationCapabilities.allowsDirectoryInodeCanonicalization(
                fileSystemName: other, formatCapabilities: 0, formatValid: persistent), other)
        }
        XCTAssertFalse(FilesystemPublicationCapabilities.allowsDirectoryInodeCanonicalization(descriptor: -1))
        let source = try fixture("capability-file.mp4")
        let descriptor = source.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw publicationPOSIXFailure() }
        defer { close(descriptor) }
        XCTAssertFalse(FilesystemPublicationCapabilities.allowsDirectoryInodeCanonicalization(descriptor: descriptor),
                       "A regular file descriptor can never establish directory-volume eligibility")
    }

    func testUnsupportedHardLinkPublishesVerifiedFileInsideAtomicOutputFolder() throws {
        let source = try fixture("copy.mp4")
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source)
        let backend = PublicationFaultBackend(root: directory, fileError: ENOTSUP)
        let result = try clean(scan, backend: backend)
        assertFallback(result, source: source, original: original, scan: scan)
        XCTAssertEqual(backend.hardLinkCalls, 1)
        XCTAssertEqual(backend.swapCalls, 0)
        XCTAssertEqual(backend.directoryCalls, 1)
        XCTAssertNil(backend.injectionError)
    }

    func testUnsupportedSwapSavesVerifiedCopyAndHonestlyRetainsOriginal() throws {
        let source = try fixture("replacement.mp4")
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source)
        let backend = PublicationFaultBackend(root: directory, fileError: ENOTSUP)
        let result = try clean(scan, replaceOriginal: true, backend: backend)
        assertFallback(result, source: source, original: original, scan: scan)
        XCTAssertTrue(result.warnings.contains { $0.localizedCaseInsensitiveContains("original was not replaced") })
        XCTAssertEqual(backend.swapCalls, 1)
        XCTAssertEqual(backend.hardLinkCalls, 0)
        XCTAssertEqual(backend.directoryCalls, 1)
    }

    func testPermissionDenialNeverTriggersPublicationFallback() throws {
        for replacing in [false, true] {
            let source = try fixture("denied-\(replacing).mp4")
            let original = try Data(contentsOf: source)
            let backend = PublicationFaultBackend(root: directory, fileError: EACCES)
            XCTAssertThrowsError(try clean(MediaScanner.scan(url: source), replaceOriginal: replacing, backend: backend))
            XCTAssertEqual(backend.directoryCalls, 0)
            XCTAssertEqual(try Data(contentsOf: source), original)
            assertNoStaging()
        }
    }

    func testDirectoryFallbackNeverOverwritesExistingFileSymlinkOrNonemptyDirectory() throws {
        for kind in [PublicationCollision.file, .symlink, .nonemptyDirectory] {
            let source = try fixture("collision-\(kind).mp4")
            let original = try Data(contentsOf: source)
            let backend = PublicationFaultBackend(root: directory, fileError: ENOTSUP, collision: kind)
            let result = try clean(MediaScanner.scan(url: source), backend: backend)
            let collision = try XCTUnwrap(backend.collisionURL)
            XCTAssertNotEqual(result.outputURL.deletingLastPathComponent(), collision)
            switch kind {
            case .file: XCTAssertEqual(try Data(contentsOf: collision), backend.sentinel)
            case .symlink:
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: collision.path), try XCTUnwrap(backend.symlinkTarget).path)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backend.symlinkTarget)), backend.sentinel)
            case .nonemptyDirectory: XCTAssertEqual(try Data(contentsOf: collision.appendingPathComponent("valuable.dat")), backend.sentinel)
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertGreaterThanOrEqual(backend.directoryCalls, 2)
            XCTAssertNil(backend.injectionError)
            assertNoStaging()
        }
    }

    func testSourceChangedAfterUnsupportedFileOperationCannotReachDirectoryFallback() throws {
        for replacing in [false, true] {
            let root = directory.appendingPathComponent("source-race-\(replacing)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let source = try fixture("source-race-\(replacing)/source.mp4")
            let scan = try MediaScanner.scan(url: source)
            let changed = Data("An external source revision must survive".utf8)
            var retainedPayload: URL?, retainedBytes: Data?, recovery: URL?
            let backend = PublicationFaultBackend(root: root, fileError: ENOTSUP)
            backend.beforeFileOperation = {
                retainedPayload = try XCTUnwrap(stagedMediaForTests(in: root))
                retainedBytes = try Data(contentsOf: XCTUnwrap(retainedPayload))
                try changed.write(to: source, options: .atomic)
            }
            XCTAssertThrowsError(try clean(scan, replaceOriginal: replacing, backend: backend)) { error in
                if replacing {
                    guard case StripprError.replacementUncertain(let path, _) = error else {
                        return XCTFail("Changed replacement outcome must retain recovery data, received \(error)")
                    }
                    recovery = URL(fileURLWithPath: path)
                } else {
                    guard case StripprError.sourceChanged = error else {
                        return XCTFail("The proven uncommitted copy must fail its source guard, received \(error)")
                    }
                }
            }
            XCTAssertEqual(backend.directoryCalls, 0)
            XCTAssertEqual(try Data(contentsOf: source), changed)
            XCTAssertNil(backend.injectionError)
            if replacing {
                let payload = try XCTUnwrap(retainedPayload), retained = try XCTUnwrap(recovery)
                XCTAssertEqual(try Data(contentsOf: payload), try XCTUnwrap(retainedBytes))
                XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
                assertRecoveryContains(payload: payload, recovery: retained)
            } else {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
            }
        }
    }

    func testPayloadChangedAfterUnsupportedFileOperationCannotReachDirectoryFallback() throws {
        for replacing in [false, true] {
            let root = directory.appendingPathComponent("payload-race-\(replacing)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let source = try fixture("payload-race-\(replacing)/source.mp4")
            let original = try Data(contentsOf: source)
            let payload = try XCTUnwrap(original.range(of: Data("mdat".utf8)))
            var retainedPayload: URL?, tamperedBytes: Data?, recovery: URL?
            let backend = PublicationFaultBackend(root: root, fileError: ENOTSUP)
            backend.beforeFileOperation = {
                let stage = try XCTUnwrap(stagedMediaForTests(in: root))
                let handle = try FileHandle(forWritingTo: stage)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(payload.upperBound + 2))
                try handle.write(contentsOf: Data([0xfe]))
                retainedPayload = stage
                tamperedBytes = try Data(contentsOf: stage)
            }
            XCTAssertThrowsError(try clean(MediaScanner.scan(url: source), replaceOriginal: replacing, backend: backend)) { error in
                guard case StripprError.replacementUncertain(let path, _) = error else {
                    return XCTFail("An unprovable publication outcome must retain its staging data, received \(error)")
                }
                recovery = URL(fileURLWithPath: path)
            }
            XCTAssertEqual(backend.directoryCalls, 0)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertNil(backend.injectionError)
            let retained = try XCTUnwrap(recovery), staged = try XCTUnwrap(retainedPayload)
            XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
            assertRecoveryContains(payload: staged, recovery: retained)
            XCTAssertEqual(try Data(contentsOf: staged), try XCTUnwrap(tamperedBytes), "Uncertain recovery data must not be removed or rewritten")
            XCTAssertEqual(try XCTUnwrap(tamperedBytes)[payload.upperBound + 2], 0xfe, "The payload attack must actually execute")
        }
    }

    func testReplacedStagingDirectoryIsRejectedAndForeignFilesAreNeverCleanedUp() throws {
        let source = try fixture("directory-race.mp4")
        let original = try Data(contentsOf: source)
        let root = directory!
        let saved = root.appendingPathComponent("retained-owned-stage", isDirectory: true)
        var foreign: URL?
        let sentinel = Data("Foreign replacement must not be removed".utf8)
        let backend = PublicationFaultBackend(root: root, fileError: ENOTSUP)
        backend.beforeFileOperation = {
            let payload = try XCTUnwrap(stagedMediaForTests(in: root))
            let stage = payload.deletingLastPathComponent()
            try FileManager.default.moveItem(at: stage, to: saved)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            foreign = stage.appendingPathComponent("foreign.dat")
            try sentinel.write(to: XCTUnwrap(foreign))
        }
        XCTAssertThrowsError(try clean(MediaScanner.scan(url: source), backend: backend))
        XCTAssertEqual(backend.directoryCalls, 0)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(foreign)), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "An unknown renamed stage must be retained rather than deleting by a stale path")
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNil(backend.injectionError)
    }

    func testReplacedStagedPayloadIsRejectedAndForeignPayloadIsRetained() throws {
        let source = try fixture("inode-race.mp4")
        let original = try Data(contentsOf: source)
        let root = directory!
        let sentinel = Data("Foreign staged inode must survive cleanup".utf8)
        var foreign: URL?
        let backend = PublicationFaultBackend(root: root, fileError: ENOTSUP)
        backend.beforeFileOperation = {
            let stage = try XCTUnwrap(stagedMediaForTests(in: root))
            try FileManager.default.moveItem(at: stage, to: stage.appendingPathExtension("retained"))
            try sentinel.write(to: stage)
            foreign = stage
        }
        XCTAssertThrowsError(try clean(MediaScanner.scan(url: source), backend: backend))
        XCTAssertEqual(backend.directoryCalls, 0)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(foreign)), sentinel)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNil(backend.injectionError)
    }

    func testCancellationAfterUnsupportedOperationStopsBeforeDirectoryCommit() throws {
        for replacing in [false, true] {
            let source = try fixture("cancel-folder-\(replacing).mp4")
            let original = try Data(contentsOf: source)
            let token = CancellationToken()
            let backend = PublicationFaultBackend(root: directory, fileError: ENOTSUP)
            backend.beforeFileOperation = { token.cancel() }
            XCTAssertThrowsError(try clean(MediaScanner.scan(url: source), replaceOriginal: replacing, cancellation: token, backend: backend)) { error in
                guard case StripprError.cancelled = error else { return XCTFail("Expected cancellation, received \(error)") }
            }
            XCTAssertEqual(backend.directoryCalls, 0)
            XCTAssertEqual(try Data(contentsOf: source), original)
            assertNoStaging()
        }
    }

    func testCancellationAfterSuccessfulDirectoryCommitReportsSavedVerifiedCopy() throws {
        let source = try fixture("commit-cancel.mp4")
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source)
        let token = CancellationToken()
        let backend = PublicationFaultBackend(root: directory, fileError: ENOTSUP)
        backend.afterDirectoryRename = { _ in token.cancel() }
        let result = try clean(scan, cancellation: token, backend: backend)
        XCTAssertTrue(token.isCancelled)
        assertFallback(result, source: source, original: original, scan: scan)
    }

    func testDirectoryRenameFailurePreservesOriginalAndCleansOnlyOwnedStage() throws {
        let source = try fixture("rename-denied.mp4")
        let original = try Data(contentsOf: source)
        let backend = PublicationFaultBackend(root: directory, fileError: ENOTSUP, directoryError: EACCES)
        XCTAssertThrowsError(try clean(MediaScanner.scan(url: source), backend: backend))
        XCTAssertEqual(backend.directoryCalls, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        assertNoStaging()
    }

    func testPostCommitPayloadReplacementFailsVerificationAndRetainsForeignRecoveryFolder() throws {
        let source = try fixture("post-commit.mp4")
        let original = try Data(contentsOf: source)
        let sentinel = Data("Post-commit concurrent file must not be deleted".utf8)
        var foreign: URL?
        let backend = PublicationFaultBackend(root: directory, fileError: ENOTSUP)
        backend.afterDirectoryRename = { folder in
            let child = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
            try sentinel.write(to: child, options: .atomic)
            foreign = child
        }
        XCTAssertThrowsError(try clean(MediaScanner.scan(url: source), backend: backend))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(foreign)), sentinel)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNil(backend.injectionError)
    }

    func testSwapThatCommitsThenReturnsIOErrorRetainsOriginalForRecoveryAndReportsUncertainty() throws {
        let source = try fixture("ambiguous-swap.mp4")
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source)
        let backend = PublicationFaultBackend(root: directory, fileError: EIO, commitFileOperationBeforeError: true)
        var recovery: URL?
        XCTAssertThrowsError(try clean(scan, replaceOriginal: true, backend: backend)) { error in
            guard case StripprError.replacementUncertain(let path, _) = error else {
                return XCTFail("A completed swap with a reported I/O error must be uncertain, received \(error)")
            }
            recovery = URL(fileURLWithPath: path)
            XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("original was not replaced"))
            XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("original was retained"))
        }
        XCTAssertEqual(backend.committedFileOperations, 1, "The test must perform a real swap before reporting EIO")
        XCTAssertEqual(backend.swapCalls, 1)
        XCTAssertEqual(backend.directoryCalls, 0)
        XCTAssertNil(backend.injectionError)
        let retainedOriginal = try XCTUnwrap(backend.stagedPayloadAtFileOperation)
        XCTAssertEqual(try Data(contentsOf: retainedOriginal), original, "The old original must never be deleted after an ambiguous swap")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(recovery).path))
        XCTAssertNotEqual(try Data(contentsOf: source), original, "The backend really installed the cleaned inode")
        XCTAssertFalse(try MediaScanner.scan(url: source).canClean)
        let cleaned = try Data(contentsOf: source)
        XCTAssertEqual(cleaned.count, original.count)
        if cleaned.count == original.count {
            for offset in original.indices where !scan.edits.contains(where: { UInt64(offset) >= $0.offset && UInt64(offset) < $0.offset + $0.length }) {
                XCTAssertEqual(cleaned[offset], original[offset])
            }
        }
    }

    func testHardLinkThatCommitsThenReturnsIOErrorRetainsBothAliasesAndReportsCandidate() throws {
        let source = try fixture("ambiguous-link.mp4")
        let original = try Data(contentsOf: source)
        let backend = PublicationFaultBackend(root: directory, fileError: EIO, commitFileOperationBeforeError: true)
        var reportedError: Error?
        XCTAssertThrowsError(try clean(MediaScanner.scan(url: source), backend: backend)) { error in
            reportedError = error
            guard case StripprError.replacementUncertain(let path, _) = error else {
                return XCTFail("A possible published alias must be reported as uncertain, received \(error)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("no file was published"))
        }
        XCTAssertEqual(backend.committedFileOperations, 1, "The test must actually create a hard link before reporting EIO")
        XCTAssertEqual(backend.hardLinkCalls, 1)
        XCTAssertEqual(backend.directoryCalls, 0)
        XCTAssertNil(backend.injectionError)
        let candidate = try XCTUnwrap(backend.fileOperationDestination)
        let stage = try XCTUnwrap(backend.stagedPayloadAtFileOperation)
        XCTAssertTrue(try XCTUnwrap(reportedError).localizedDescription.contains(candidate.path), "Recovery instructions must identify the possible published candidate")
        XCTAssertEqual(try Data(contentsOf: stage), try Data(contentsOf: candidate))
        let candidateIdentity = try SourceIdentity.read(candidate), stagedIdentity = try SourceIdentity.read(stage)
        XCTAssertTrue(candidateIdentity.isSameObject(as: stagedIdentity))
        XCTAssertEqual(candidateIdentity.linkCount, 2, "Uncertain publication must retain the possible alias and owned recovery link")
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(try MediaScanner.scan(url: candidate).canClean)
    }

    func testDirectoryRenameThatCommitsThenReturnsIOErrorRetainsVisibleRecoveryFolder() throws {
        let source = try fixture("ambiguous-directory.mp4")
        let original = try Data(contentsOf: source)
        let backend = PublicationFaultBackend(root: directory, fileError: ENOTSUP, directoryError: EIO,
                                              commitDirectoryOperationBeforeError: true)
        var recovery: URL?
        XCTAssertThrowsError(try clean(MediaScanner.scan(url: source), backend: backend)) { error in
            guard case StripprError.replacementUncertain(let path, _) = error else {
                return XCTFail("A completed directory rename must retain recovery information, received \(error)")
            }
            recovery = URL(fileURLWithPath: path, isDirectory: true)
        }
        XCTAssertEqual(backend.committedDirectoryOperations, 1)
        XCTAssertEqual(backend.directoryCalls, 1)
        XCTAssertNil(backend.injectionError)
        let folder = try XCTUnwrap(recovery)
        let payload = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        XCTAssertFalse(try MediaScanner.scan(url: payload).canClean)
        XCTAssertEqual(try Data(contentsOf: source), original)
        assertNoStaging()
    }

    func testDirectoryCommitClosesEveryPayloadDescriptorAndVerifiesFreshAttributesDespiteLateCancellation() throws {
        for replacing in [false, true] {
            for cancel in [false, true] {
                let source = try fixture("closed-before-rename-\(replacing)-\(cancel).mp4")
                let required = Data([0, 255, 5, 0, 128])
                try publicationAttribute(source, set: required)
                let original = try Data(contentsOf: source), scan = try MediaScanner.scan(url: source)
                let token = CancellationToken()
                let metadata = CommittedMetadataAuditBackend(cancellation: token)
                let backend = PublicationFaultBackend(root: directory, fileError: ENOTSUP)
                var audits = 0
                backend.beforeDirectoryRename = { folder, _ in
                    let payload = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
                    let descriptors = try publicationPayloadDescriptors(payload)
                    audits += 1
                    XCTAssertTrue(descriptors.isEmpty, "Even read-only payload handles must close before a NAS directory rename")
                }
                backend.afterDirectoryRename = { _ in if cancel { token.cancel() } }
                let result = try clean(scan, replaceOriginal: replacing, cancellation: token, filesystem: metadata, backend: backend)
                XCTAssertEqual(audits, 1)
                XCTAssertNil(backend.injectionError)
                XCTAssertEqual(try publicationAttribute(result.outputURL), required)
                assertFreshCommittedSnapshots(metadata)
                assertFallback(result, source: source, original: original, scan: scan)
            }
        }
    }

    func testDirectoryCommitAttributeLossReportsUncertaintyAndRetainsOutputWithOrWithoutLateCancellation() throws {
        for replacing in [false, true] {
            for cancel in [false, true] {
                let source = try fixture("directory-attribute-loss-\(replacing)-\(cancel).mp4")
                let required = Data([9, 0, 250])
                try publicationAttribute(source, set: required)
                let original = try Data(contentsOf: source), scan = try MediaScanner.scan(url: source)
                let token = CancellationToken()
                let metadata = CommittedMetadataAuditBackend(cancellation: token)
                let backend = PublicationFaultBackend(root: directory, fileError: ENOTSUP)
                var output: URL?, recovery: URL?
                backend.afterDirectoryRename = { folder in
                    let payload = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
                    try publicationRemoveAttribute(payload)
                    output = payload
                    if cancel { token.cancel() }
                }
                XCTAssertThrowsError(try clean(scan, replaceOriginal: replacing, cancellation: token, filesystem: metadata, backend: backend)) { error in
                    recovery = assertCommittedUncertainty(error)
                }
                let retained = try XCTUnwrap(output)
                XCTAssertNil(try publicationAttribute(retained))
                XCTAssertEqual(try publicationAttribute(source), required)
                XCTAssertEqual(try Data(contentsOf: source), original)
                XCTAssertFalse(try MediaScanner.scan(url: retained).canClean)
                assertRecoveryContains(payload: retained, recovery: try XCTUnwrap(recovery))
                // A real removal can change ctime and be rejected by the earlier
                // exact identity guard. Fresh snapshot acceptance is tested below.
                XCTAssertNil(backend.injectionError)
            }
        }
    }

    func testIdentityStableCommittedAttributeLossIsRejectedByFreshMetadataCheckDespiteLateCancellation() throws {
        let source = try fixture("identity-stable-attribute-loss.mp4")
        let required = Data([10, 0, 251])
        try publicationAttribute(source, set: required)
        let original = try Data(contentsOf: source), scan = try MediaScanner.scan(url: source)
        let token = CancellationToken()
        // Model a NAS returning a missing attribute without changing inode,
        // timestamps, flags, or file bytes. Only the committed snapshot differs.
        let metadata = CommittedMetadataAuditBackend(cancellation: token, hideRequiredAttributeWhenCommitted: true)
        let backend = PublicationFaultBackend(root: directory, fileError: ENOTSUP)
        var output: URL?, recovery: URL?
        backend.afterDirectoryRename = { folder in
            output = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
            token.cancel()
        }
        XCTAssertThrowsError(try clean(scan, cancellation: token, filesystem: metadata, backend: backend)) { error in
            recovery = assertCommittedUncertainty(error)
        }
        let retained = try XCTUnwrap(output)
        XCTAssertEqual(try publicationAttribute(retained), required, "This injection changes only the returned committed snapshot")
        XCTAssertEqual(try Data(contentsOf: source), original)
        assertRecoveryContains(payload: retained, recovery: try XCTUnwrap(recovery))
        assertFreshCommittedSnapshots(metadata)
        XCTAssertNil(backend.injectionError)
    }

    func testFlatCopyAttributeLossRetainsPossibleAliasAndReportsUncertaintyAfterCommit() throws {
        for cancel in [false, true] {
            let source = try fixture("flat-attribute-loss-\(cancel).mp4")
            let required = Data([8, 0, 249])
            try publicationAttribute(source, set: required)
            let original = try Data(contentsOf: source), scan = try MediaScanner.scan(url: source)
            let token = CancellationToken()
            let metadata = CommittedMetadataAuditBackend(cancellation: token)
            let backend = PublicationFaultBackend(root: directory, fileError: 0)
            var output: URL?, recovery: URL?, marked = 0
            backend.afterSuccessfulFileOperation = { candidate in
                output = candidate
                try publicationRemoveAttribute(candidate)
                marked = try markExistingPayloadDescriptors(candidate)
                if cancel { token.cancel() }
            }
            XCTAssertThrowsError(try clean(scan, cancellation: token, filesystem: metadata, backend: backend)) { error in
                recovery = assertCommittedUncertainty(error)
            }
            let candidate = try XCTUnwrap(output)
            XCTAssertGreaterThan(marked, 0, "The fresh-descriptor sentinel must mark a real retained handle")
            XCTAssertNil(try publicationAttribute(candidate))
            XCTAssertEqual(try publicationAttribute(source), required)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try SourceIdentity.read(candidate).linkCount, 2, "A potentially published alias and its recovery alias must both remain")
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(recovery).path))
            assertFreshCommittedSnapshots(metadata)
            XCTAssertNil(backend.injectionError)
        }
    }

    func testSwapAttributeLossIsDetectedBeforeDeletingDisplacedOriginalEvenWithLateCancellation() throws {
        for cancel in [false, true] {
            let root = directory.appendingPathComponent("swap-attribute-loss-\(cancel)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let source = try fixture("swap-attribute-loss-\(cancel)/source.mp4")
            let required = Data([7, 0, 248])
            try publicationAttribute(source, set: required)
            let original = try Data(contentsOf: source), scan = try MediaScanner.scan(url: source)
            let token = CancellationToken()
            let metadata = CommittedMetadataAuditBackend(cancellation: token)
            let backend = PublicationFaultBackend(root: root, fileError: 0)
            var backup: URL?, recovery: URL?, marked = 0
            backend.beforeFileOperation = { backup = try XCTUnwrap(stagedMediaForTests(in: root)) }
            backend.afterSuccessfulFileOperation = { installed in
                try publicationRemoveAttribute(installed)
                marked = try markExistingPayloadDescriptors(installed)
                if cancel { token.cancel() }
            }
            XCTAssertThrowsError(try clean(scan, replaceOriginal: true, cancellation: token, filesystem: metadata, backend: backend)) { error in
                recovery = assertCommittedUncertainty(error)
            }
            let retained = try XCTUnwrap(backup)
            XCTAssertGreaterThan(marked, 0)
            XCTAssertEqual(try Data(contentsOf: retained), original, "The displaced original must survive failed committed metadata verification")
            XCTAssertEqual(try publicationAttribute(retained), required)
            XCTAssertNil(try publicationAttribute(source))
            assertRecoveryContains(payload: retained, recovery: try XCTUnwrap(recovery))
            assertFreshCommittedSnapshots(metadata)
            XCTAssertNil(backend.injectionError)
        }
    }

    func testFlatCopyAndSwapUseFreshUncancelledCommittedSnapshotsBeforeCleanup() throws {
        for replacing in [false, true] {
            let source = try fixture("late-cancel-committed-\(replacing).mp4")
            let required = Data([6, 0, 247])
            try publicationAttribute(source, set: required)
            let original = try Data(contentsOf: source), scan = try MediaScanner.scan(url: source)
            let token = CancellationToken()
            let metadata = CommittedMetadataAuditBackend(cancellation: token)
            let backend = PublicationFaultBackend(root: directory, fileError: 0)
            var marked = 0
            backend.afterSuccessfulFileOperation = { installed in
                marked = try markExistingPayloadDescriptors(installed)
                token.cancel()
            }
            let result = try clean(scan, replaceOriginal: replacing, cancellation: token, filesystem: metadata, backend: backend)
            XCTAssertTrue(token.isCancelled)
            XCTAssertGreaterThan(marked, 0)
            XCTAssertEqual(result.didReplaceOriginal, replacing)
            XCTAssertEqual(try publicationAttribute(result.outputURL), required)
            XCTAssertFalse(try MediaScanner.scan(url: result.outputURL).canClean)
            if !replacing { XCTAssertEqual(try Data(contentsOf: source), original) }
            assertFreshCommittedSnapshots(metadata)
            assertNoStaging()
            XCTAssertNil(backend.injectionError)
        }
    }

    private func clean(_ scan: ScanResult, replaceOriginal: Bool = false,
                       cancellation: CancellationToken = CancellationToken(),
                       filesystem: (any FilesystemMetadataBackend)? = nil,
                       backend: PublicationFaultBackend) throws -> CleanResult {
        try MediaCleaner.clean(scan, replaceOriginal: replaceOriginal, cancellation: cancellation,
                               filesystem: filesystem ?? DarwinFilesystemMetadataBackend(cancellation: cancellation), publication: backend)
    }

    private func assertFreshCommittedSnapshots(_ metadata: CommittedMetadataAuditBackend,
                                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(metadata.destinationSnapshots.isEmpty, "The published payload must receive committed metadata verification", file: file, line: line)
        for snapshot in metadata.destinationSnapshots {
            XCTAssertEqual(snapshot.accessMode, O_RDONLY, file: file, line: line)
            XCTAssertNotEqual(snapshot.descriptorFlags & FD_CLOEXEC, 0,
                              "Committed verification must open a fresh descriptor, not reuse a marked retained handle", file: file, line: line)
        }
    }

    private func assertCommittedUncertainty(_ error: Error, file: StaticString = #filePath, line: UInt = #line) -> URL? {
        guard case StripprError.replacementUncertain(let path, _) = error else {
            XCTFail("Post-commit metadata failure must retain recovery data and report uncertainty, received \(error)", file: file, line: line)
            return nil
        }
        XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("no file was published"), file: file, line: line)
        XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("cancelled"), file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), file: file, line: line)
        return URL(fileURLWithPath: path)
    }

    private func assertFallback(_ result: CleanResult, source: URL, original: Data, scan: ScanResult,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.didReplaceOriginal, file: file, line: line)
        XCTAssertEqual(result.outputURL.deletingLastPathComponent().deletingLastPathComponent(), directory, file: file, line: line)
        XCTAssertFalse(result.outputURL.deletingLastPathComponent().lastPathComponent.hasPrefix("."), file: file, line: line)
        XCTAssertNotEqual(result.outputURL, source, file: file, line: line)
        XCTAssertTrue(result.warnings.contains { $0.localizedCaseInsensitiveContains("output folder") }, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: source), original, file: file, line: line)
        guard let output = try? Data(contentsOf: result.outputURL) else { return XCTFail("Verified output is missing", file: file, line: line) }
        XCTAssertEqual(output.count, original.count, file: file, line: line)
        if output.count == original.count {
            for offset in original.indices where !scan.edits.contains(where: { UInt64(offset) >= $0.offset && UInt64(offset) < $0.offset + $0.length }) {
                XCTAssertEqual(output[offset], original[offset], file: file, line: line)
            }
        }
        XCTAssertFalse((try? MediaScanner.scan(url: result.outputURL).canClean) ?? true, file: file, line: line)
        assertNoStaging(file: file, line: line)
    }

    private func assertRecoveryContains(payload: URL, recovery: URL, file: StaticString = #filePath, line: UInt = #line) {
        let actual = payload.resolvingSymlinksInPath().standardizedFileURL
        let reported = recovery.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertTrue(actual.path == reported.path || actual.deletingLastPathComponent().path == reported.path,
                      "Reported recovery \(reported.path) does not contain retained payload \(actual.path)", file: file, line: line)
    }

    private func assertNoStaging(file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(names.contains { $0.hasPrefix(".strippr-") }, "Owned staging directory was left behind", file: file, line: line)
    }

    private func fixture(_ name: String) throws -> URL {
        let field = atom(Data([0xa9, 0x6e, 0x61, 0x6d]), atom("data", be32(1) + be32(0) + Data("Fixture Title".utf8)))
        let data = atom("ftyp", Data("isom0000isom".utf8)) + atom("mdat", Data("Retained compressed payload".utf8))
            + atom("moov", atom("udta", atom("meta", be32(0) + atom("ilst", field))))
        let source = directory.appendingPathComponent(name)
        try data.write(to: source)
        return source
    }
    private func atom(_ name: String, _ data: Data) -> Data { atom(Data(name.utf8), data) }
    private func atom(_ name: Data, _ data: Data) -> Data { be32(UInt32(data.count + 8)) + name + data }
    private func be32(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
}

private enum PublicationCollision { case file, symlink, nonemptyDirectory }

private final class PublicationFaultBackend: FilesystemPublicationBackend, @unchecked Sendable {
    private let native = DarwinFilesystemPublicationBackend()
    private let root: URL
    private let fileError: Int32
    private let directoryError: Int32
    private let collision: PublicationCollision?
    private let commitFileOperationBeforeError: Bool
    private let commitDirectoryOperationBeforeError: Bool
    let sentinel = Data("Existing target must be retained".utf8)
    var beforeFileOperation: (() throws -> Void)?
    var beforeDirectoryRename: ((URL, URL) throws -> Void)?
    var afterSuccessfulFileOperation: ((URL) throws -> Void)?
    var afterDirectoryRename: ((URL) throws -> Void)?
    private(set) var hardLinkCalls = 0
    private(set) var swapCalls = 0
    private(set) var directoryCalls = 0
    private(set) var collisionURL: URL?
    private(set) var symlinkTarget: URL?
    private(set) var injectionError: String?
    private(set) var committedFileOperations = 0
    private(set) var committedDirectoryOperations = 0
    private(set) var fileOperationDestination: URL?
    private(set) var stagedPayloadAtFileOperation: URL?

    init(root: URL, fileError: Int32, directoryError: Int32 = 0, collision: PublicationCollision? = nil,
         commitFileOperationBeforeError: Bool = false, commitDirectoryOperationBeforeError: Bool = false) {
        self.root = root; self.fileError = fileError; self.directoryError = directoryError; self.collision = collision
        self.commitFileOperationBeforeError = commitFileOperationBeforeError
        self.commitDirectoryOperationBeforeError = commitDirectoryOperationBeforeError
    }

    func hardLink(sourceDirectory: Int32, sourceName: String, destinationDirectory: Int32, destinationName: String) -> Int32 {
        hardLinkCalls += 1
        do { try beforeFileOperation?() } catch { injectionError = String(describing: error) }
        if commitFileOperationBeforeError {
            do { stagedPayloadAtFileOperation = try stagedMediaForTests(in: root) } catch { injectionError = String(describing: error) }
            fileOperationDestination = root.appendingPathComponent(destinationName)
            let actual = native.hardLink(sourceDirectory: sourceDirectory, sourceName: sourceName,
                                         destinationDirectory: destinationDirectory, destinationName: destinationName)
            if actual == 0 {
                committedFileOperations += 1
                do { try afterSuccessfulFileOperation?(root.appendingPathComponent(destinationName)) } catch { injectionError = String(describing: error) }
                return fileError
            }
            injectionError = "Native hard-link injection failed with errno \(actual)"
            return actual
        }
        if fileError != 0 { return fileError }
        let result = native.hardLink(sourceDirectory: sourceDirectory, sourceName: sourceName,
                                     destinationDirectory: destinationDirectory, destinationName: destinationName)
        if result == 0 {
            do { try afterSuccessfulFileOperation?(root.appendingPathComponent(destinationName)) } catch { injectionError = String(describing: error) }
        }
        return result
    }

    func swap(sourceDirectory: Int32, sourceName: String, destinationDirectory: Int32, destinationName: String) -> Int32 {
        swapCalls += 1
        do { try beforeFileOperation?() } catch { injectionError = String(describing: error) }
        if commitFileOperationBeforeError {
            do { stagedPayloadAtFileOperation = try stagedMediaForTests(in: root) } catch { injectionError = String(describing: error) }
            fileOperationDestination = root.appendingPathComponent(destinationName)
            let actual = native.swap(sourceDirectory: sourceDirectory, sourceName: sourceName,
                                     destinationDirectory: destinationDirectory, destinationName: destinationName)
            if actual == 0 {
                committedFileOperations += 1
                do { try afterSuccessfulFileOperation?(root.appendingPathComponent(destinationName)) } catch { injectionError = String(describing: error) }
                return fileError
            }
            injectionError = "Native swap injection failed with errno \(actual)"
            return actual
        }
        if fileError != 0 { return fileError }
        let result = native.swap(sourceDirectory: sourceDirectory, sourceName: sourceName,
                                 destinationDirectory: destinationDirectory, destinationName: destinationName)
        if result == 0 {
            do { try afterSuccessfulFileOperation?(root.appendingPathComponent(destinationName)) } catch { injectionError = String(describing: error) }
        }
        return result
    }

    func renameDirectory(sourceDirectory: Int32, sourceName: String, destinationDirectory: Int32, destinationName: String) -> Int32 {
        directoryCalls += 1
        let target = root.appendingPathComponent(destinationName)
        if let collision, collisionURL == nil {
            do {
                switch collision {
                case .file: try sentinel.write(to: target)
                case .symlink:
                    let retained = root.appendingPathComponent("valuable-link-target.dat")
                    try sentinel.write(to: retained)
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: retained)
                    symlinkTarget = retained
                case .nonemptyDirectory:
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                    try sentinel.write(to: target.appendingPathComponent("valuable.dat"))
                }
                collisionURL = target
            } catch { injectionError = String(describing: error) }
        }
        if directoryError != 0 && !commitDirectoryOperationBeforeError { return directoryError }
        do { try beforeDirectoryRename?(root.appendingPathComponent(sourceName), target) } catch { injectionError = String(describing: error) }
        let result = native.renameDirectory(sourceDirectory: sourceDirectory, sourceName: sourceName,
                                            destinationDirectory: destinationDirectory, destinationName: destinationName)
        if result == 0 {
            committedDirectoryOperations += 1
            do { try afterDirectoryRename?(target) } catch { injectionError = String(describing: error) }
            if commitDirectoryOperationBeforeError { return directoryError }
        }
        return result
    }
}

private struct CommittedDescriptorObservation {
    let accessMode: Int32
    let descriptorFlags: Int32
}

/// Use the real native snapshots, including its uncancelled committed operation.
/// The inode identifies the cleaned payload even after its name or role changes.
private final class CommittedMetadataAuditBackend: FilesystemMetadataBackend {
    private let native: DarwinFilesystemMetadataBackend
    private let hideRequiredAttributeWhenCommitted: Bool
    private var payload: SourceIdentity?
    private(set) var destinationSnapshots: [CommittedDescriptorObservation] = []

    init(cancellation: CancellationToken, hideRequiredAttributeWhenCommitted: Bool = false) {
        native = DarwinFilesystemMetadataBackend(cancellation: cancellation)
        self.hideRequiredAttributeWhenCommitted = hideRequiredAttributeWhenCommitted
    }

    func snapshot(descriptor: Int32) throws -> FilesystemMetadataSnapshot {
        try native.snapshot(descriptor: descriptor)
    }

    func snapshotCommitted(descriptor: Int32) throws -> FilesystemMetadataSnapshot {
        let actual = try SourceIdentity.read(descriptor: descriptor)
        let isPayload = payload.map { actual.isSameObject(as: $0) } ?? false
        if isPayload {
            let access = fcntl(descriptor, F_GETFL), flags = fcntl(descriptor, F_GETFD)
            guard access >= 0, flags >= 0 else { throw publicationPOSIXFailure() }
            destinationSnapshots.append(CommittedDescriptorObservation(accessMode: access & O_ACCMODE, descriptorFlags: flags))
        }
        let snapshot = try native.snapshotCommitted(descriptor: descriptor)
        if isPayload && hideRequiredAttributeWhenCommitted {
            var attributes = snapshot.attributes
            attributes.removeValue(forKey: publicationRequiredAttribute)
            return FilesystemMetadataSnapshot(permissions: snapshot.permissions, owner: snapshot.owner, group: snapshot.group,
                flags: snapshot.flags, modifiedSeconds: snapshot.modifiedSeconds, modifiedNanoseconds: snapshot.modifiedNanoseconds,
                acl: snapshot.acl, attributes: attributes)
        }
        return snapshot
    }

    func copy(source: Int32, destination: Int32, onAttributeError: @escaping (String?, Int32) -> Bool) throws {
        payload = try SourceIdentity.read(descriptor: destination)
        try native.copy(source: source, destination: destination, onAttributeError: onAttributeError)
    }
}

private let publicationRequiredAttribute = "com.example.strippr.required"

@discardableResult
private func publicationAttribute(_ url: URL, set value: Data? = nil) throws -> Data? {
    let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else { throw publicationPOSIXFailure() }
    defer { close(descriptor) }
    if let value {
        let result = value.withUnsafeBytes { bytes in publicationRequiredAttribute.withCString {
            fsetxattr(descriptor, $0, bytes.baseAddress, value.count, 0, 0)
        } }
        guard result == 0 else { throw publicationPOSIXFailure() }
    }
    let count = publicationRequiredAttribute.withCString { fgetxattr(descriptor, $0, nil, 0, 0, 0) }
    if count < 0 && errno == ENOATTR { return nil }
    guard count >= 0 else { throw publicationPOSIXFailure() }
    var data = Data(count: count)
    let actual = data.withUnsafeMutableBytes { bytes in publicationRequiredAttribute.withCString {
        fgetxattr(descriptor, $0, bytes.baseAddress, count, 0, 0)
    } }
    guard actual == count else { throw publicationPOSIXFailure() }
    return data
}

private func publicationRemoveAttribute(_ url: URL) throws {
    let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else { throw publicationPOSIXFailure() }
    defer { close(descriptor) }
    guard publicationRequiredAttribute.withCString({ fremovexattr(descriptor, $0, 0) }) == 0 else {
        throw publicationPOSIXFailure()
    }
}

private func publicationPayloadDescriptors(_ url: URL) throws -> [Int32] {
    let expected = try SourceIdentity.read(url)
    let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap { Int32($0) }
    return descriptors.filter { descriptor in
        guard let identity = try? SourceIdentity.read(descriptor: descriptor) else { return false }
        return identity.isSameObject(as: expected)
    }
}

/// A descriptor-local sentinel: existing handles lose CLOEXEC; a freshly opened
/// O_CLOEXEC verifier has it. No subprocess is launched while these marks exist.
private func markExistingPayloadDescriptors(_ url: URL) throws -> Int {
    let descriptors = try publicationPayloadDescriptors(url)
    for descriptor in descriptors {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags & ~FD_CLOEXEC) == 0 else { throw publicationPOSIXFailure() }
    }
    return descriptors.count
}

private func publicationPOSIXFailure() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
