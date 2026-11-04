import XCTest
import Foundation
import Darwin
@testable import StripprCore

/// Replacement tests operate exclusively on fresh temporary fixtures created here.
final class CleaningOptionsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("STRiPPR-options-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testDefaultsKeepOriginalAndEncoderInformation() throws {
        let source = try write("defaults.mp4", mp4())
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source)
        XCTAssertTrue(scan.keepEncoderInfo)
        XCTAssertTrue(scan.tags.contains { $0.value == "Keep Encoder" && !$0.removable })
        let result = try MediaCleaner.clean(scan)
        XCTAssertFalse(result.didReplaceOriginal)
        XCTAssertNotEqual(result.outputURL, source)
        XCTAssertNil(result.recoveryURL)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let output = try Data(contentsOf: result.outputURL)
        XCTAssertNotNil(output.range(of: Data("Keep Encoder".utf8)))
        XCTAssertNil(output.range(of: Data("Remove Title".utf8)))
        assertOnlyPlannedEdits(original: original, output: output, scan: scan)
    }

    func testEncoderRemovalIsOptInAndOnlyTouchesKnownMP4Metadata() throws {
        let values = item("©nam", "Remove Title") + item("©too", "Remove Encoder")
            + item("©swr", "Remove Software") + item("©enc", "Remove Encoding App")
            + item("pgap", "Keep gapless") + item("covr", "Keep artwork")
        let source = try write("encoder.mp4", mp4(items: values))
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source, keepEncoderInfo: false)
        XCTAssertFalse(scan.keepEncoderInfo)
        for value in ["Remove Encoder", "Remove Software", "Remove Encoding App"] {
            XCTAssertTrue(scan.tags.contains { $0.value == value && $0.removable })
        }
        let result = try MediaCleaner.clean(scan)
        let output = try Data(contentsOf: result.outputURL)
        for value in ["Remove Title", "Remove Encoder", "Remove Software", "Remove Encoding App"] {
            XCTAssertNil(output.range(of: Data(value.utf8)))
        }
        XCTAssertNotNil(output.range(of: Data("Keep gapless".utf8)))
        XCTAssertNotNil(output.range(of: Data("Keep artwork".utf8)))
        XCTAssertNotNil(output.range(of: Data("Unchanged stream encoder marker".utf8)))
        XCTAssertEqual(try Data(contentsOf: source), original)
        assertOnlyPlannedEdits(original: original, output: output, scan: scan)
    }

    func testEncoderOnlyFileBecomesCleanableOnlyWhenEncoderRetentionIsOff() throws {
        let source = try write("encoder-only.mp4", mp4(items: item("©too", "Remove Encoder")))
        XCTAssertFalse(try MediaScanner.scan(url: source).canClean)
        let scan = try MediaScanner.scan(url: source, keepEncoderInfo: false)
        XCTAssertTrue(scan.canClean)
        let result = try MediaCleaner.clean(scan)
        XCTAssertFalse(try MediaScanner.scan(url: result.outputURL, keepEncoderInfo: false).canClean)
    }

    func testMdtaEncoderRemovalPreservesStructuralAndUnknownKeys() throws {
        let names = ["title", "encoder", "encoding_tool", "com.apple.quicktime.software", "com.apple.quicktime.video-orientation", "color_primaries", "private.encoder.config"]
        let strings = ["Remove Title", "Remove Encoder", "Remove Encoding Tool", "Remove Software", "Keep orientation", "Keep color", "Keep unknown config"]
        let entries = names.map { be32(UInt32($0.utf8.count + 8)) + Data("mdta".utf8) + Data($0.utf8) }.reduce(Data(), +)
        let keys = atom("keys", be32(0) + be32(UInt32(names.count)) + entries)
        let items = strings.enumerated().map { index, value in item(be32(UInt32(index + 1)), value) }.reduce(Data(), +)
        let source = try write("encoder-mdta.mp4", mp4(items: items, keys: keys))
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source, keepEncoderInfo: false)
        let result = try MediaCleaner.clean(scan)
        let output = try Data(contentsOf: result.outputURL)
        for value in strings.prefix(4) { XCTAssertNil(output.range(of: Data(value.utf8))) }
        for value in strings.suffix(3) { XCTAssertNotNil(output.range(of: Data(value.utf8))) }
        assertOnlyPlannedEdits(original: original, output: output, scan: scan)
    }

    func testAVIEncoderRemovalTouchesINFOOnly() throws {
        let fields = riffChunk("INAM", Data("Remove Title\0".utf8)) + riffChunk("ISFT", Data("Remove Encoder\0".utf8))
        let media = Data("Keep ISFT inside media stream".utf8)
        let body = Data("AVI ".utf8) + riffChunk("LIST", Data("INFO".utf8) + fields) + riffChunk("LIST", Data("movi".utf8) + riffChunk("00dc", media))
        let source = try write("encoder.avi", Data("RIFF".utf8) + le32(UInt32(body.count)) + body)
        let original = try Data(contentsOf: source)
        let retained = try MediaScanner.scan(url: source)
        XCTAssertTrue(retained.tags.contains { $0.value == "Remove Encoder" && !$0.removable })
        let scan = try MediaScanner.scan(url: source, keepEncoderInfo: false)
        let result = try MediaCleaner.clean(scan)
        let output = try Data(contentsOf: result.outputURL)
        XCTAssertNil(output.range(of: Data("Remove Encoder".utf8)))
        XCTAssertNotNil(output.range(of: media))
        assertOnlyPlannedEdits(original: original, output: output, scan: scan)
    }

    func testAtomicReplacementKeepsPathPermissionsAndEveryUneditedByte() throws {
        let source = try write("replace.mp4", mp4())
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o640)], ofItemAtPath: source.path)
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source)
        let visibility = SourceVisibility(source: source)
        let result = try MediaCleaner.clean(scan, replaceOriginal: true) { _, _ in visibility.check() }
        XCTAssertTrue(result.didReplaceOriginal)
        XCTAssertEqual(result.outputURL, source)
        XCTAssertNil(result.recoveryURL)
        XCTAssertFalse(visibility.observedMissingSource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let output = try Data(contentsOf: source)
        XCTAssertNil(output.range(of: Data("Remove Title".utf8)))
        XCTAssertNotNil(output.range(of: Data("Keep Encoder".utf8)))
        assertOnlyPlannedEdits(original: original, output: output, scan: scan)
        let mode = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o640)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
    }

    func testReplacementCancellationAtEveryPrecommitStageLeavesOriginalAndNoTemporaryFiles() throws {
        let source = try write("cancel-replace.mp4", mp4())
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source)
        for threshold in [0.0, 0.40, 0.80, 0.99] {
            let cancellation = CancellationToken()
            XCTAssertThrowsError(try MediaCleaner.clean(scan, replaceOriginal: true, cancellation: cancellation) { value, _ in
                if value >= threshold { cancellation.cancel() }
            }) { error in
                guard case StripprError.cancelled = error else { return XCTFail("Expected cancellation before replacement, got \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
        }
    }

    func testChangedSourceBeforeReplacementIsNeverOverwritten() throws {
        let source = try write("changed-replace.mp4", mp4())
        let scan = try MediaScanner.scan(url: source)
        let changed = mp4(items: item("©nam", "New original must survive") + item("©too", "New Encoder"))
        try changed.write(to: source, options: .atomic)
        XCTAssertThrowsError(try MediaCleaner.clean(scan, replaceOriginal: true))
        XCTAssertEqual(try Data(contentsOf: source), changed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
    }

    func testSourceChangedImmediatelyBeforeCommitIsNotOverwritten() throws {
        let source = try write("late-change.mp4", mp4())
        let scan = try MediaScanner.scan(url: source)
        let changed = mp4(items: item("©nam", "Externally changed original must survive"))
        let mutation = OneTimeSourceReplacement(source: source, bytes: changed)
        XCTAssertThrowsError(try MediaCleaner.clean(scan, replaceOriginal: true) { value, _ in
            if value >= 0.99 { mutation.replace() }
        })
        XCTAssertTrue(mutation.didReplace)
        XCTAssertEqual(try Data(contentsOf: source), changed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
    }

    func testTamperedVerifiedStagingFileCannotBePublishedOrReplaceOriginal() throws {
        let source = try write("tampered-stage.mp4", mp4())
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source)
        for replaceOriginal in [false, true] {
            let mutation = OneTimeStageTampering(directory: directory)
            XCTAssertThrowsError(try MediaCleaner.clean(scan, replaceOriginal: replaceOriginal) { value, _ in
                if value >= 0.99 { mutation.appendToStage() }
            })
            XCTAssertTrue(mutation.didTamper)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
        }
    }

    func testPayloadTamperedAtFinalVerificationCallbackCannotBeBlessedByLaterSnapshot() throws {
        let source = try write("late-payload-tamper.mp4", mp4())
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source)
        let payload = try XCTUnwrap(original.range(of: Data("mdat".utf8)))
        for replaceOriginal in [false, true] {
            let mutation = OneTimeStagePayloadMutation(directory: directory, offset: UInt64(payload.upperBound + 3))
            XCTAssertThrowsError(try MediaCleaner.clean(scan, replaceOriginal: replaceOriginal) { value, _ in
                if value >= 0.97 { mutation.overwritePayloadByte() }
            })
            XCTAssertTrue(mutation.didTamper)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
        }
    }

    func testReplacementRejectsSymbolicLinkWithoutTouchingItsTarget() throws {
        let target = try write("target.mp4", mp4())
        let original = try Data(contentsOf: target)
        let link = directory.appendingPathComponent("alias.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try MediaScanner.scan(url: link))
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testReplacementRejectsHardLinkedSourceAndPreservesBothNames() throws {
        let source = try write("hardlinked.mp4", mp4())
        let alias = directory.appendingPathComponent("hardlink.mp4")
        try FileManager.default.linkItem(at: source, to: alias)
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source)
        XCTAssertThrowsError(try MediaCleaner.clean(scan, replaceOriginal: true))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: alias), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["hardlink.mp4", "hardlinked.mp4"])
    }

    func testReplacementRejectsReadOnlyOriginalWithoutErasingIt() throws {
        let source = try write("read-only.mp4", mp4())
        let original = try Data(contentsOf: source)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o444)], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: source.path) }
        let scan = try MediaScanner.scan(url: source)
        XCTAssertThrowsError(try MediaCleaner.clean(scan, replaceOriginal: true))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
    }

    func testBusyLockedOriginalCannotBeReplaced() throws {
        let source = try write("locked.mp4", mp4())
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source)
        let descriptor = source.path.withCString { Darwin.open($0, O_RDONLY) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { _ = stripprFileLock(descriptor, LOCK_UN); _ = Darwin.close(descriptor) }
        XCTAssertEqual(stripprFileLock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try MediaCleaner.clean(scan, replaceOriginal: true))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
    }

    func testFailureToStageReplacementLeavesOriginalAtItsPath() throws {
        let source = try write("stage-failure.mp4", mp4())
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try MediaCleaner.clean(scan, replaceOriginal: true))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
    }

    func testUnsupportedReadOnlyContainerCannotBeReplaced() throws {
        let bytes = Data([0, 0, 1, 0xba, 0x21, 0, 1, 0, 1, 0, 0, 1, 0xb9])
        let source = try write("read-only.mpg", bytes)
        let scan = try MediaScanner.scan(url: source, keepEncoderInfo: false)
        XCTAssertFalse(scan.canClean)
        XCTAssertThrowsError(try MediaCleaner.clean(scan, replaceOriginal: true))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
    }

    private func assertOnlyPlannedEdits(original: Data, output: Data, scan: ScanResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(output.count, original.count, file: file, line: line)
        guard output.count == original.count else { return }
        for index in original.indices where !scan.edits.contains(where: { UInt64(index) >= $0.offset && UInt64(index) < $0.offset + $0.length }) {
            XCTAssertEqual(output[index], original[index], "Unapproved byte changed at \(index)", file: file, line: line)
        }
    }
    private func write(_ name: String, _ bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
    private func mp4(items: Data? = nil, keys: Data = Data()) -> Data {
        let fields = items ?? (item("©nam", "Remove Title") + item("©too", "Keep Encoder"))
        let payload = Data("Unchanged stream encoder marker".utf8) + Data((0..<1024).map { UInt8($0 % 251) })
        return atom("ftyp", Data("isom0000isom".utf8)) + atom("mdat", payload)
            + atom("moov", atom("trak", atom("tkhd", Data("timing orientation color configuration".utf8)))
                + atom("udta", atom("meta", be32(0) + keys + atom("ilst", fields))))
    }
    private func item(_ name: String, _ value: String) -> Data { item(Data(name.data(using: .isoLatin1)!), value) }
    private func item(_ name: Data, _ value: String) -> Data { atom(name, atom("data", be32(1) + be32(0) + Data(value.utf8))) }
    private func atom(_ name: String, _ payload: Data) -> Data { atom(Data(name.utf8), payload) }
    private func atom(_ name: Data, _ payload: Data) -> Data { be32(UInt32(payload.count + 8)) + name + payload }
    private func riffChunk(_ name: String, _ value: Data) -> Data { Data(name.utf8) + le32(UInt32(value.count)) + value + (value.count % 2 == 1 ? Data([0]) : Data()) }
    private func be32(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    private func le32(_ value: UInt32) -> Data { Data([UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255), UInt8((value >> 24) & 255)]) }
}

private final class SourceVisibility: @unchecked Sendable {
    let source: URL
    private let lock = NSLock()
    private(set) var observedMissingSource = false
    init(source: URL) { self.source = source }
    func check() {
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: source.path) { observedMissingSource = true }
    }
}

private final class OneTimeSourceReplacement: @unchecked Sendable {
    let source: URL
    let bytes: Data
    private let lock = NSLock()
    private(set) var didReplace = false
    init(source: URL, bytes: Data) { self.source = source; self.bytes = bytes }
    func replace() {
        lock.lock(); defer { lock.unlock() }
        guard !didReplace else { return }
        do { try bytes.write(to: source, options: .atomic); didReplace = true } catch {}
    }
}

private final class OneTimeStageTampering: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private(set) var didTamper = false
    init(directory: URL) { self.directory = directory }
    func appendToStage() {
        lock.lock(); defer { lock.unlock() }
        guard !didTamper else { return }
        do {
            guard let stage = try stagedMediaForTests(in: directory) else { return }
            let writer = try FileHandle(forWritingTo: stage)
            try writer.seekToEnd(); try writer.write(contentsOf: Data([0])); try writer.close()
            didTamper = true
        } catch {}
    }
}

private final class OneTimeStagePayloadMutation: @unchecked Sendable {
    let directory: URL
    let offset: UInt64
    private let lock = NSLock()
    private(set) var didTamper = false
    init(directory: URL, offset: UInt64) { self.directory = directory; self.offset = offset }
    func overwritePayloadByte() {
        lock.lock(); defer { lock.unlock() }
        guard !didTamper else { return }
        do {
            guard let stage = try stagedMediaForTests(in: directory) else { return }
            let writer = try FileHandle(forWritingTo: stage)
            try writer.seek(toOffset: offset)
            try writer.write(contentsOf: Data([0xfe])); try writer.close()
            didTamper = true
        } catch {}
    }
}

/// Locate the real staged payload in a disposable test directory. Support both
/// earlier flat stages and owned staging directories; never follow symlinks.
func stagedMediaForTests(in directory: URL) throws -> URL? {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    for candidate in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        where candidate.lastPathComponent.hasPrefix(".strippr-") {
        let values = try candidate.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { continue }
        if values.isRegularFile == true && candidate.pathExtension == "tmp" { return candidate }
        if values.isDirectory == true {
            for payload in try FileManager.default.contentsOfDirectory(at: candidate, includingPropertiesForKeys: Array(keys)) {
                let attributes = try payload.resourceValues(forKeys: keys)
                if attributes.isRegularFile == true && attributes.isSymbolicLink != true { return payload }
            }
        }
    }
    return nil
}
