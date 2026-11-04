import XCTest
import Foundation
import Darwin
@testable import StripprCore

final class FilesystemMetadataTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("STRiPPR-filesystem-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testNativeCopiesAndReplacementsPreserveOpaqueAttributesACLModeAndOwnership() throws {
        for replaceOriginal in [false, true] {
            let source = try fixture("native-\(replaceOriginal).mp4")
            let opaque = Data([0, 255, 1, 0, 128, 42, 0])
            let quarantine = Data("0083;00000000;STRiPPR Tests;00000000-0000-0000-0000-000000000000".utf8)
            try setAttribute(source, name: "com.example.strippr.opaque", data: opaque)
            try setAttribute(source, name: "com.apple.quarantine", data: quarantine)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o640)], ofItemAtPath: source.path)
            try addACL(to: source)
            let original = try Data(contentsOf: source)
            let expected = try snapshot(source)
            XCTAssertFalse(expected.acl.isEmpty, "The ACL preservation case must actually contain an ACL")
            let scan = try MediaScanner.scan(url: source)
            let result = try MediaCleaner.clean(scan, replaceOriginal: replaceOriginal)
            let actual = try snapshot(result.outputURL)
            XCTAssertEqual(actual.permissions, expected.permissions)
            XCTAssertEqual(actual.owner, expected.owner)
            XCTAssertEqual(actual.group, expected.group)
            XCTAssertEqual(actual.flags, expected.flags)
            XCTAssertEqual(actual.modifiedSeconds, expected.modifiedSeconds)
            XCTAssertEqual(actual.modifiedNanoseconds, expected.modifiedNanoseconds)
            XCTAssertEqual(actual.acl, expected.acl)
            XCTAssertEqual(try attribute(result.outputURL, name: "com.example.strippr.opaque"), opaque)
            XCTAssertEqual(try attribute(result.outputURL, name: "com.apple.quarantine"), quarantine)
            XCTAssertEqual(Set(actual.attributes.keys), Set(expected.attributes.keys))
            for (name, fingerprint) in expected.attributes {
                XCTAssertEqual(actual.attributes[name]?.length, fingerprint.length, name)
                XCTAssertEqual(actual.attributes[name]?.digest, fingerprint.digest, name)
            }
            assertOnlyEdits(original, try Data(contentsOf: result.outputURL), scan)
            if !replaceOriginal { XCTAssertEqual(try Data(contentsOf: source), original) }
            XCTAssertEqual(result.didReplaceOriginal, replaceOriginal)
        }
    }

    func testAllDataWritersCloseBeforeFinalMetadataIsAppliedThroughReadOnlyDescriptor() throws {
        for replaceOriginal in [false, true] {
            let source = try fixture("closed-writer-\(replaceOriginal).mp4")
            let original = try Data(contentsOf: source)
            let expected = try snapshot(source)
            let backend = WriterFinalizationAuditBackend()
            let scan = try MediaScanner.scan(url: source)
            let result = try MediaCleaner.clean(scan, replaceOriginal: replaceOriginal, filesystem: backend)
            let preflight = try XCTUnwrap(backend.observations.first)
            XCTAssertEqual(preflight.size, 0)
            XCTAssertEqual(preflight.accessMode, O_RDWR)
            XCTAssertGreaterThanOrEqual(preflight.writableDescriptors.count, 2,
                                        "The descriptor audit must detect both the data writer and a temporary duplicate")
            let finalPasses = backend.observations.filter { $0.size > 0 }
            XCTAssertFalse(finalPasses.isEmpty, "The metadata backend must run again after payload edits")
            for pass in finalPasses {
                XCTAssertEqual(pass.size, Int64(original.count))
                XCTAssertEqual(pass.accessMode, O_RDONLY,
                               "A metadata-only O_RDWR descriptor can still change NAS timestamps on close")
                XCTAssertTrue(pass.writableDescriptors.isEmpty,
                              "Every data-writing handle to the staged inode must close before final metadata restoration")
            }
            assertOnlyEdits(original, try Data(contentsOf: result.outputURL), scan)
            let actual = try snapshot(result.outputURL)
            XCTAssertEqual(actual.modifiedSeconds, expected.modifiedSeconds)
            XCTAssertEqual(actual.modifiedNanoseconds, expected.modifiedNanoseconds)
            if !replaceOriginal { XCTAssertEqual(try Data(contentsOf: source), original) }
        }
    }

    func testOnlyExactProvenancePermissionOrUnsupportedFailuresWarnAndProceed() throws {
        for replaceOriginal in [false, true] {
            for code in [EACCES, EPERM, ENOTSUP] {
                let source = try fixture("provenance-\(replaceOriginal)-\(code).mp4")
                let original = try Data(contentsOf: source)
                let bytes = Data([0, 254, 0, 253])
                try setAttribute(source, name: "com.example.strippr.retained", data: bytes)
                let scan = try MediaScanner.scan(url: source)
                let backend = MetadataFaultBackend(.callback("com.apple.provenance", code))
                let result = try MediaCleaner.clean(scan, replaceOriginal: replaceOriginal, filesystem: backend)
                XCTAssertFalse(backend.callbackDecisions.isEmpty)
                XCTAssertTrue(backend.callbackDecisions.allSatisfy { $0 })
                XCTAssertEqual(backend.stageLengths.first, 0, "Metadata compatibility is checked before payload copying")
                XCTAssertTrue(result.warnings.contains { $0.contains("com.apple.provenance") })
                XCTAssertEqual(try attribute(result.outputURL, name: "com.example.strippr.retained"), bytes)
                assertOnlyEdits(original, try Data(contentsOf: result.outputURL), scan)
                if !replaceOriginal { XCTAssertEqual(try Data(contentsOf: source), original) }
            }
        }
    }

    func testMissingProvenanceRequiresARecordedToleratedFailure() throws {
        for reportFailure in [false, true] {
            let source = try fixture("missing-provenance-\(reportFailure).mp4")
            let original = try Data(contentsOf: source)
            let backend = MetadataFaultBackend(.sourceProvenance(reportFailure: reportFailure))
            let scan = try MediaScanner.scan(url: source)
            if reportFailure {
                let result = try MediaCleaner.clean(scan, filesystem: backend)
                XCTAssertTrue(result.warnings.contains { $0.contains("com.apple.provenance") })
                XCTAssertEqual(backend.callbackDecisions, Array(repeating: true, count: backend.stageLengths.count))
                try FileManager.default.removeItem(at: result.outputURL)
            } else {
                XCTAssertThrowsError(try MediaCleaner.clean(scan, filesystem: backend))
                XCTAssertTrue(backend.callbackDecisions.isEmpty)
                XCTAssertEqual(backend.stageLengths, [0])
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
            assertNoGeneratedFiles()
        }
    }

    func testNativeSnapshotNormalizesEmptyACLAndFingerprintsEmptyAndStreamingResourceForkAttributes() throws {
        let source = try fixture("resource-fork.mp4")
        let removeACL = Process()
        removeACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
        removeACL.arguments = ["-N", source.path]
        try removeACL.run()
        removeACL.waitUntilExit()
        XCTAssertEqual(removeACL.terminationStatus, 0)
        let resource = Data((0..<(2 * 1_048_576 + 17)).map { UInt8($0 % 251) })
        try setAttribute(source, name: "com.example.strippr.empty", data: Data())
        try setAttribute(source, name: "com.apple.ResourceFork", data: resource)
        let before = try snapshot(source)
        XCTAssertTrue(before.acl.isEmpty)
        XCTAssertEqual(before.attributes["com.example.strippr.empty"]?.length, 0)
        XCTAssertEqual(before.attributes["com.apple.ResourceFork"]?.length, UInt64(resource.count))
        let result = try MediaCleaner.clean(MediaScanner.scan(url: source))
        let after = try snapshot(result.outputURL)
        XCTAssertTrue(after.acl.isEmpty)
        XCTAssertEqual(after.attributes, before.attributes)
        XCTAssertEqual(try attribute(result.outputURL, name: "com.example.strippr.empty"), Data())
        XCTAssertEqual(try attribute(result.outputURL, name: "com.apple.ResourceFork"), resource)
    }

    func testNativeCopyfileAdapterCallsErrorHandlerOnlyForERRAndCapturesErrno() throws {
        let observation = FilesystemCallbackObservation()
        let context = FilesystemCopyContext(cancellation: CancellationToken()) { name, code in
            observation.append(name, code)
            errno = EIO // The callback must already have captured the original error.
            return false
        }
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        let state = try XCTUnwrap(copyfile_state_alloc())
        defer { copyfile_state_free(state) }
        withExtendedLifetime(context) {
            for stage in [COPYFILE_START, COPYFILE_FINISH, COPYFILE_PROGRESS] {
                errno = EACCES
                XCTAssertEqual(filesystemCopyCallback(COPYFILE_COPY_XATTR, stage, state, nil, nil, pointer), COPYFILE_CONTINUE)
            }
            XCTAssertTrue(observation.errors.isEmpty)
            errno = EPERM
            XCTAssertEqual(filesystemCopyCallback(COPYFILE_COPY_XATTR, COPYFILE_ERR, state, nil, nil, pointer), COPYFILE_QUIT)
            XCTAssertEqual(observation.errors.count, 1)
            XCTAssertNil(observation.errors.first?.0)
            XCTAssertEqual(observation.errors.first?.1, EPERM)
            errno = EACCES
            XCTAssertEqual(filesystemCopyCallback(COPYFILE_COPY_DATA, COPYFILE_ERR, state, nil, nil, pointer), COPYFILE_QUIT)
            XCTAssertEqual(observation.errors.count, 2, "Unidentified error types must also be recorded and fail closed")
            XCTAssertEqual(observation.errors.last?.1, EACCES)
        }
        let permitted = FilesystemCopyContext(cancellation: CancellationToken()) { _, _ in true }
        withExtendedLifetime(permitted) {
            errno = EACCES
            XCTAssertEqual(filesystemCopyCallback(COPYFILE_COPY_XATTR, COPYFILE_ERR, state, nil, nil,
                                                 Unmanaged.passUnretained(permitted).toOpaque()), COPYFILE_SKIP,
                           "A permitted refusal skips that attribute; CONTINUE would request a retry")
        }
        XCTAssertEqual(filesystemCopyCallback(COPYFILE_COPY_XATTR, COPYFILE_ERR, nil, nil, nil, nil), COPYFILE_QUIT)
    }

    func testEmptyACLWithNoInheritFlagIsNotNormalizedAwayWhenFilesystemStoresIt() throws {
        let source = try fixture("flagged-empty-acl.mp4")
        try withDescriptor(source) { descriptor in
            let acl = try XCTUnwrap(acl_init(0))
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var flags: acl_flagset_t?
            guard acl_get_flagset_np(UnsafeMutableRawPointer(acl), &flags) == 0,
                  let flags, acl_add_flag_np(flags, ACL_FLAG_NO_INHERIT) == 0,
                  acl_set_flagset_np(UnsafeMutableRawPointer(acl), flags) == 0 else { throw posixFailure() }
            guard acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0 else {
                if errno == ENOTSUP { throw XCTSkip("The temporary filesystem does not support flagged empty ACLs") }
                throw posixFailure()
            }
            errno = 0
            guard let stored = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
                if errno == ENOENT { throw XCTSkip("The temporary filesystem discarded the flagged empty ACL") }
                throw posixFailure()
            }
            defer { acl_free(UnsafeMutableRawPointer(stored)) }
            var storedFlags: acl_flagset_t?
            guard acl_get_flagset_np(UnsafeMutableRawPointer(stored), &storedFlags) == 0, let storedFlags else { throw posixFailure() }
            guard acl_get_flag_np(storedFlags, ACL_FLAG_NO_INHERIT) == 1 else {
                throw XCTSkip("The temporary filesystem normalized away the empty ACL flag")
            }
            XCTAssertFalse(try DarwinFilesystemMetadataBackend().snapshot(descriptor: descriptor).acl.isEmpty,
                           "Zero entries must not erase stored ACL inheritance flags")
        }
    }

    func testProtectedUnknownAndUnnamedCallbackErrorsAbortBeforePayloadEvenIfBackendReturnsSuccess() throws {
        let names: [String?] = ["com.apple.quarantine", "com.apple.macl", "com.example.strippr.unknown", nil]
        for replaceOriginal in [false, true] {
            for (number, name) in names.enumerated() {
                let source = try fixture("protected-\(replaceOriginal)-\(number).mp4")
                let original = try Data(contentsOf: source)
                let scan = try MediaScanner.scan(url: source)
                let backend = MetadataFaultBackend(.callback(name, EACCES))
                XCTAssertThrowsError(try MediaCleaner.clean(scan, replaceOriginal: replaceOriginal, filesystem: backend))
                XCTAssertEqual(backend.callbackDecisions, [false], "A COPYFILE_ERR must never become a false success")
                XCTAssertEqual(backend.stageLengths, [0], "A failed preflight must not write payload or run a later metadata copy")
                XCTAssertEqual(try Data(contentsOf: source), original)
                assertNoGeneratedFiles()
            }
        }
    }

    func testProvenanceExceptionDoesNotAcceptOtherNamesOrUnexpectedErrors() throws {
        let failures: [(String, Int32)] = [
            ("com.apple.provenance.extra", EACCES), ("com.apple.Provenance", EPERM),
            ("com.apple.provenance", EIO), ("com.apple.provenance", ENOSPC)
        ]
        for (number, failure) in failures.enumerated() {
            let source = try fixture("strict-\(number).mp4")
            let original = try Data(contentsOf: source)
            let backend = MetadataFaultBackend(.callback(failure.0, failure.1))
            XCTAssertThrowsError(try MediaCleaner.clean(MediaScanner.scan(url: source), filesystem: backend))
            XCTAssertEqual(backend.callbackDecisions, [false])
            XCTAssertEqual(backend.stageLengths, [0])
            XCTAssertEqual(try Data(contentsOf: source), original)
            assertNoGeneratedFiles()
        }
    }

    func testUnknownAttributeLossOrSameLengthCorruptionIsDetectedBeforePayload() throws {
        for replaceOriginal in [false, true] {
            for remove in [false, true] {
                let source = try fixture("attribute-\(replaceOriginal)-\(remove).mp4")
                let name = "com.example.strippr.binary"
                let retained = Data([1, 0, 255, 2])
                try setAttribute(source, name: name, data: retained)
                let original = try Data(contentsOf: source)
                let fault: MetadataFault = remove ? .removeAttribute(name) : .attribute(name, Data([2, 0, 255, 1]))
                let backend = MetadataFaultBackend(fault)
                XCTAssertThrowsError(try MediaCleaner.clean(MediaScanner.scan(url: source), replaceOriginal: replaceOriginal, filesystem: backend))
                XCTAssertEqual(backend.stageLengths, [0])
                XCTAssertEqual(try attribute(source, name: name), retained)
                XCTAssertEqual(try Data(contentsOf: source), original)
                assertNoGeneratedFiles()
            }
        }
    }

    func testUnexpectedDestinationAttributeCannotBeSilentlyAdded() throws {
        let source = try fixture("extra-attribute.mp4")
        let original = try Data(contentsOf: source)
        let backend = MetadataFaultBackend(.attribute("com.example.strippr.unexpected", Data([1])))
        XCTAssertThrowsError(try MediaCleaner.clean(MediaScanner.scan(url: source), filesystem: backend))
        XCTAssertEqual(backend.stageLengths, [0])
        XCTAssertEqual(try Data(contentsOf: source), original)
        assertNoGeneratedFiles()
    }

    func testModeOwnershipGroupAndACLVerificationFailuresAbortPreflight() throws {
        let faults: [MetadataFault] = [.mode(0o600), .snapshotOwner, .snapshotGroup, .snapshotACL]
        for replaceOriginal in [false, true] {
            for (number, fault) in faults.enumerated() {
                let source = try fixture("security-\(replaceOriginal)-\(number).mp4")
                try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o640)], ofItemAtPath: source.path)
                let original = try Data(contentsOf: source)
                let expected = try snapshot(source)
                let backend = MetadataFaultBackend(fault)
                XCTAssertThrowsError(try MediaCleaner.clean(MediaScanner.scan(url: source), replaceOriginal: replaceOriginal, filesystem: backend))
                XCTAssertEqual(backend.stageLengths, [0])
                let actual = try snapshot(source)
                XCTAssertEqual(actual.permissions, expected.permissions)
                XCTAssertEqual(actual.owner, expected.owner)
                XCTAssertEqual(actual.group, expected.group)
                XCTAssertEqual(actual.acl, expected.acl)
                XCTAssertEqual(try Data(contentsOf: source), original)
                assertNoGeneratedFiles()
            }
        }
    }

    func testMetadataCopyThrowsAbortBeforePayloadAndPreserveOriginal() throws {
        for label in ["ACL", "ownership", "permissions", "attribute enumeration"] {
            let source = try fixture("throw-\(label).mp4")
            let original = try Data(contentsOf: source)
            let backend = MetadataFaultBackend(.failure(label))
            XCTAssertThrowsError(try MediaCleaner.clean(MediaScanner.scan(url: source), replaceOriginal: true, filesystem: backend))
            XCTAssertEqual(backend.stageLengths, [0])
            XCTAssertEqual(try Data(contentsOf: source), original)
            assertNoGeneratedFiles()
        }
    }

    func testToleratedProvenanceWarningDoesNotBypassCancellation() throws {
        for replaceOriginal in [false, true] {
            for threshold in [0.0, 0.99] {
                let source = try fixture("cancel-\(replaceOriginal)-\(threshold).mp4")
                let original = try Data(contentsOf: source)
                let token = CancellationToken()
                let backend = MetadataFaultBackend(.callback("com.apple.provenance", EPERM))
                XCTAssertThrowsError(try MediaCleaner.clean(MediaScanner.scan(url: source), replaceOriginal: replaceOriginal, cancellation: token, filesystem: backend) { value, _ in
                    if value >= threshold { token.cancel() }
                }) { error in
                    guard case StripprError.cancelled = error else { return XCTFail("Expected cancellation, received \(error)") }
                }
                XCTAssertEqual(try Data(contentsOf: source), original)
                assertNoGeneratedFiles()
            }
        }
    }

    func testToleratedProvenanceWarningDoesNotBypassSourceChangeGuard() throws {
        for replaceOriginal in [false, true] {
            let source = try fixture("changed-\(replaceOriginal).mp4")
            let scan = try MediaScanner.scan(url: source)
            let replacement = Data("External owner change must survive".utf8)
            let mutation = FilesystemTestMutation {
                try replacement.write(to: source, options: .atomic)
            }
            let backend = MetadataFaultBackend(.callback("com.apple.provenance", EACCES))
            XCTAssertThrowsError(try MediaCleaner.clean(scan, replaceOriginal: replaceOriginal, filesystem: backend) { value, _ in
                if value >= 0.99 { mutation.perform() }
            })
            XCTAssertTrue(mutation.completed)
            XCTAssertEqual(try Data(contentsOf: source), replacement)
            assertNoGeneratedFiles()
        }
    }

    func testToleratedProvenanceWarningDoesNotBypassVerifiedStageTamperingGuard() throws {
        for replaceOriginal in [false, true] {
            let source = try fixture("tamper-\(replaceOriginal).mp4")
            let original = try Data(contentsOf: source)
            let payload = try XCTUnwrap(original.range(of: Data("mdat".utf8)))
            let root = directory!
            let mutation = FilesystemTestMutation {
                let stage = try XCTUnwrap(stagedMediaForTests(in: root))
                let writer = try FileHandle(forWritingTo: stage)
                defer { try? writer.close() }
                try writer.seek(toOffset: UInt64(payload.upperBound + 2))
                try writer.write(contentsOf: Data([0xfe]))
            }
            let backend = MetadataFaultBackend(.callback("com.apple.provenance", ENOTSUP))
            XCTAssertThrowsError(try MediaCleaner.clean(MediaScanner.scan(url: source), replaceOriginal: replaceOriginal, filesystem: backend) { value, _ in
                if value >= 0.97 { mutation.perform() }
            })
            XCTAssertTrue(mutation.completed)
            XCTAssertEqual(try Data(contentsOf: source), original)
            assertNoGeneratedFiles()
        }
    }

    private func snapshot(_ url: URL) throws -> FilesystemMetadataSnapshot {
        try withDescriptor(url) { try DarwinFilesystemMetadataBackend().snapshot(descriptor: $0) }
    }

    private func setAttribute(_ url: URL, name: String, data: Data) throws {
        try withDescriptor(url) { try writeAttribute($0, name: name, data: data) }
    }

    private func attribute(_ url: URL, name: String) throws -> Data {
        try withDescriptor(url) { descriptor in
            let length = name.withCString { fgetxattr(descriptor, $0, nil, 0, 0, 0) }
            guard length >= 0 else { throw posixFailure() }
            var data = Data(count: length)
            let actual = data.withUnsafeMutableBytes { bytes in
                name.withCString { fgetxattr(descriptor, $0, bytes.baseAddress, length, 0, 0) }
            }
            guard actual == length else { throw posixFailure() }
            return data
        }
    }

    private func withDescriptor<T>(_ url: URL, _ body: (Int32) throws -> T) throws -> T {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw posixFailure() }
        defer { Darwin.close(descriptor) }
        return try body(descriptor)
    }

    private func addACL(to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "user:\(NSUserName()) allow read,write,readattr,writeattr,readextattr,writeextattr,readsecurity", url.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "FilesystemMetadataTests.ACL", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
        }
    }

    private func assertNoGeneratedFiles(file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(names.contains { $0.hasPrefix(".strippr-") || $0.contains(".stripped") }, "Failed operation left a temporary or published result", file: file, line: line)
    }

    private func assertOnlyEdits(_ before: Data, _ after: Data, _ scan: ScanResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(after.count, before.count, file: file, line: line)
        guard after.count == before.count else { return }
        for offset in before.indices where !scan.edits.contains(where: { UInt64(offset) >= $0.offset && UInt64(offset) < $0.offset + $0.length }) {
            XCTAssertEqual(after[offset], before[offset], "Unexpected change outside metadata at \(offset)", file: file, line: line)
        }
    }

    private func fixture(_ name: String) throws -> URL {
        let fields = atom(Data([0xa9, 0x6e, 0x61, 0x6d]), atom("data", be32(1) + be32(0) + Data("Fixture Title".utf8)))
            + atom(Data([0xa9, 0x74, 0x6f, 0x6f]), atom("data", be32(1) + be32(0) + Data("Keep Encoder".utf8)))
        let bytes = atom("ftyp", Data("isom0000isom".utf8)) + atom("mdat", Data("Stream payload must remain identical".utf8))
            + atom("moov", atom("udta", atom("meta", be32(0) + atom("ilst", fields))))
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func atom(_ name: String, _ data: Data) -> Data { atom(Data(name.utf8), data) }
    private func atom(_ name: Data, _ data: Data) -> Data { be32(UInt32(data.count + 8)) + name + data }
    private func be32(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
}

private enum MetadataFault {
    case callback(String?, Int32)
    case sourceProvenance(reportFailure: Bool)
    case attribute(String, Data)
    case removeAttribute(String)
    case mode(mode_t)
    case snapshotOwner, snapshotGroup, snapshotACL
    case failure(String)
}

/// Delegate the real native operations, then inject a failure at their boundary.
/// Callback failures deliberately ignore the returned policy decision so the real
/// preservation helper must record and enforce errors even if copying returns.
private final class MetadataFaultBackend: FilesystemMetadataBackend, @unchecked Sendable {
    private let native = DarwinFilesystemMetadataBackend()
    private let fault: MetadataFault
    private var destination: Int32?
    private(set) var callbackDecisions: [Bool] = []
    private(set) var stageLengths: [Int64] = []

    init(_ fault: MetadataFault) { self.fault = fault }

    func snapshot(descriptor: Int32) throws -> FilesystemMetadataSnapshot {
        let value = try native.snapshot(descriptor: descriptor)
        if case .sourceProvenance = fault, descriptor != destination {
            var attributes = value.attributes
            attributes["com.apple.provenance"] = FilesystemAttributeFingerprint(length: 3, digest: Data(repeating: 0x5a, count: 32))
            return FilesystemMetadataSnapshot(permissions: value.permissions, owner: value.owner, group: value.group, flags: value.flags,
                                              modifiedSeconds: value.modifiedSeconds, modifiedNanoseconds: value.modifiedNanoseconds,
                                              acl: value.acl, attributes: attributes)
        }
        guard descriptor == destination else { return value }
        var owner = value.owner, group = value.group, acl = value.acl
        switch fault {
        case .snapshotOwner: owner = value.owner &+ 1
        case .snapshotGroup: group = value.group &+ 1
        case .snapshotACL: acl = value.acl + Data([0xfe])
        default: return value
        }
        return FilesystemMetadataSnapshot(permissions: value.permissions, owner: owner, group: group, flags: value.flags,
                                          modifiedSeconds: value.modifiedSeconds, modifiedNanoseconds: value.modifiedNanoseconds,
                                          acl: acl, attributes: value.attributes)
    }

    func copy(source: Int32, destination: Int32, onAttributeError: @escaping (String?, Int32) -> Bool) throws {
        self.destination = destination
        var info = stat()
        guard fstat(destination, &info) == 0 else { throw posixFailure() }
        stageLengths.append(info.st_size)
        if case .failure(let label) = fault { throw StripprError.io("Injected \(label) metadata failure") }
        try native.copy(source: source, destination: destination, onAttributeError: onAttributeError)
        switch fault {
        case .callback(let name, let code): callbackDecisions.append(onAttributeError(name, code))
        case .sourceProvenance(let reportFailure):
            if reportFailure { callbackDecisions.append(onAttributeError("com.apple.provenance", EACCES)) }
        case .attribute(let name, let bytes): try writeAttribute(destination, name: name, data: bytes)
        case .removeAttribute(let name):
            guard name.withCString({ fremovexattr(destination, $0, 0) }) == 0 else { throw posixFailure() }
        case .mode(let value):
            guard fchmod(destination, value) == 0 else { throw posixFailure() }
        default: break
        }
    }
}

private final class FilesystemCallbackObservation {
    private(set) var errors: [(String?, Int32)] = []
    func append(_ name: String?, _ code: Int32) { errors.append((name, code)) }
}

private struct WriterFinalizationObservation {
    let size: Int64
    let accessMode: Int32
    let writableDescriptors: [Int32]
}

/// Inspect real descriptor access modes while delegating metadata preservation to
/// the native backend. A preflight duplicate verifies that the audit can observe
/// all current writers, rather than only checking the descriptor handed to copy.
private final class WriterFinalizationAuditBackend: FilesystemMetadataBackend {
    private let native = DarwinFilesystemMetadataBackend()
    private(set) var observations: [WriterFinalizationObservation] = []

    func snapshot(descriptor: Int32) throws -> FilesystemMetadataSnapshot {
        try native.snapshot(descriptor: descriptor)
    }

    func copy(source: Int32, destination: Int32, onAttributeError: @escaping (String?, Int32) -> Bool) throws {
        var info = stat()
        guard fstat(destination, &info) == 0 else { throw posixFailure() }
        let flags = fcntl(destination, F_GETFL)
        guard flags >= 0 else { throw posixFailure() }
        let duplicate = info.st_size == 0 ? Darwin.dup(destination) : -1
        if info.st_size == 0 && duplicate < 0 { throw posixFailure() }
        defer { if duplicate >= 0 { Darwin.close(duplicate) } }
        let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap { Int32($0) }
        var writers: [Int32] = []
        for descriptor in descriptors {
            let currentFlags = fcntl(descriptor, F_GETFL)
            guard currentFlags >= 0, currentFlags & O_ACCMODE != O_RDONLY else { continue }
            var current = stat()
            if fstat(descriptor, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino {
                writers.append(descriptor)
            }
        }
        observations.append(WriterFinalizationObservation(size: info.st_size, accessMode: flags & O_ACCMODE,
                                                          writableDescriptors: writers.sorted()))
        try native.copy(source: source, destination: destination, onAttributeError: onAttributeError)
    }
}

private final class FilesystemTestMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: () throws -> Void
    private(set) var completed = false
    init(_ operation: @escaping () throws -> Void) { self.operation = operation }
    func perform() {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return }
        do { try operation(); completed = true } catch { XCTFail("Could not inject the intended mutation: \(error)") }
    }
}

private func writeAttribute(_ descriptor: Int32, name: String, data: Data) throws {
    let result = data.withUnsafeBytes { bytes in
        name.withCString { fsetxattr(descriptor, $0, bytes.baseAddress, data.count, 0, 0) }
    }
    guard result == 0 else { throw posixFailure() }
}

private func posixFailure() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
