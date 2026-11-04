import XCTest
import Foundation
@testable import StripprCore

final class MetadataSafetyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("STRiPPR-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testDescriptiveFieldsRemovedEncoderAndEveryOtherBytePreserved() throws {
        let source = try fixture()
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        XCTAssertTrue(scan.canClean)
        XCTAssertEqual(scan.removableTagCount, 2)
        XCTAssertTrue(scan.tags.contains { $0.value.contains("Fixture Title") && $0.removable })
        XCTAssertTrue(scan.tags.contains { $0.value.contains("Fixture Artist") && $0.removable })
        let result = try MediaCleaner.clean(scan, cancellation: CancellationToken())
        XCTAssertEqual(result.removedTagCount, 2)
        XCTAssertEqual(try Data(contentsOf: source), original, "Source must remain byte-identical")
        let clean = try Data(contentsOf: result.outputURL)
        XCTAssertEqual(clean.count, original.count)
        XCTAssertNil(clean.range(of: Data("Fixture Title".utf8)))
        XCTAssertNil(clean.range(of: Data("Fixture Artist".utf8)))
        XCTAssertNotNil(clean.range(of: Data("Keep Encoder".utf8)))
        for offset in original.indices where !scan.edits.contains(where: { UInt64(offset) >= $0.offset && UInt64(offset) < $0.offset + $0.length }) {
            XCTAssertEqual(clean[offset], original[offset], "Byte outside supported metadata changed at \(offset)")
        }
        let rescanned = try MediaScanner.scan(url: result.outputURL, cancellation: CancellationToken())
        XCTAssertFalse(rescanned.canClean)
        XCTAssertTrue(rescanned.tags.contains { $0.value.contains("Keep Encoder") && !$0.removable })
    }

    func testOutputCollisionNeverOverwrites() throws {
        let source = try fixture()
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        let first = try MediaCleaner.clean(scan, cancellation: CancellationToken())
        let saved = try Data(contentsOf: first.outputURL)
        let second = try MediaCleaner.clean(scan, cancellation: CancellationToken())
        XCTAssertNotEqual(first.outputURL, second.outputURL)
        XCTAssertEqual(try Data(contentsOf: first.outputURL), saved)
        XCTAssertEqual(try Data(contentsOf: second.outputURL), saved)
    }

    func testOutputNameSymlinkCannotOverwriteItsTarget() throws {
        let source = try fixture()
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        let first = try MediaCleaner.clean(scan, cancellation: CancellationToken())
        try FileManager.default.removeItem(at: first.outputURL)
        let target = directory.appendingPathComponent("valuable.txt")
        let sentinel = Data("do not overwrite".utf8)
        try sentinel.write(to: target)
        try FileManager.default.createSymbolicLink(at: first.outputURL, withDestinationURL: target)
        let second = try MediaCleaner.clean(scan, cancellation: CancellationToken())
        XCTAssertNotEqual(first.outputURL, second.outputURL)
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: first.outputURL.path), target.path)
    }

    func testCancellationDuringCopyLeavesNoPublishedOrTemporaryFile() throws {
        let source = try fixture(payloadSize: 4 * 1024 * 1024)
        let original = try Data(contentsOf: source)
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        let token = CancellationToken()
        XCTAssertThrowsError(try MediaCleaner.clean(scan, cancellation: token) { value, _ in
            if value > 0 { token.cancel() }
        }) { error in
            guard case StripprError.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
    }

    func testCancellationDuringVerificationAndBeforePublicationLeavesNoCopy() throws {
        let source = try fixture(payloadSize: 2 * 1024 * 1024)
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        for threshold in [0.80, 0.99] {
            let token = CancellationToken()
            XCTAssertThrowsError(try MediaCleaner.clean(scan, cancellation: token) { value, _ in
                if value >= threshold { token.cancel() }
            }) { error in
                guard case StripprError.cancelled = error else { return XCTFail("Expected cancellation at \(threshold), got \(error)") }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
        }
    }

    func testMetadataEditCrossingVerificationChunkBoundary() throws {
        let source = try fixture(payloadSize: 1_048_576 - 80)
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        XCTAssertTrue(scan.edits.contains { $0.offset < 1_048_576 && $0.offset + $0.length > 1_048_576 })
        let result = try MediaCleaner.clean(scan, cancellation: CancellationToken())
        XCTAssertEqual(result.verifiedBytes, scan.fileSize)
        let cleaned = try Data(contentsOf: result.outputURL)
        XCTAssertNil(cleaned.range(of: Data("Fixture Title".utf8)))
        XCTAssertNotNil(cleaned.range(of: Data("Keep Encoder".utf8)))
    }

    func testExtendedAndTerminalZeroSizeMetadataAtoms() throws {
        let data = atom("data", be32(1) + be32(0) + Data("Fixture Title".utf8))
        let extended = be32(1) + Data([0xa9, 0x6e, 0x61, 0x6d]) + be64(UInt64(data.count + 16)) + data
        let terminal = be32(0) + Data([0xa9, 0x41, 0x52, 0x54]) + atom("data", be32(1) + be32(0) + Data("Fixture Artist".utf8))
        let bytes = atom("ftyp", Data("isom0000isom".utf8)) + atom("moov", atom("udta", atom("meta", be32(0) + atom("ilst", extended + terminal))))
        let source = directory.appendingPathComponent("sized.mp4")
        try bytes.write(to: source)
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        XCTAssertEqual(scan.removableTagCount, 2)
        let result = try MediaCleaner.clean(scan, cancellation: CancellationToken())
        XCTAssertEqual(try Data(contentsOf: result.outputURL).count, bytes.count)
        XCTAssertFalse(try MediaScanner.scan(url: result.outputURL, cancellation: CancellationToken()).canClean)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testMetadataFourCCInsideMediaPayloadIsNeverInventoried() throws {
        let decoy = metadata([0xa9, 0x6e, 0x61, 0x6d], "media payload title")
        let bytes = atom("ftyp", Data("isom0000isom".utf8)) + atom("mdat", decoy) + atom("moov", Data())
        let source = directory.appendingPathComponent("decoy.mp4")
        try bytes.write(to: source)
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        XCTAssertFalse(scan.canClean)
        XCTAssertFalse(scan.tags.contains { $0.value.contains("media payload title") })
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testSourceChangedDuringCopyRefusesPublication() throws {
        let source = try fixture(payloadSize: 4 * 1024 * 1024)
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        let mutation = OneTimeMutation(source: source)
        XCTAssertThrowsError(try MediaCleaner.clean(scan, cancellation: CancellationToken()) { value, _ in
            if value > 0 { mutation.appendByte() }
        })
        XCTAssertTrue(mutation.didMutate)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
    }

    func testAlreadyCleanFileDoesNotProduceCopy() throws {
        let source = try fixture()
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        let first = try MediaCleaner.clean(scan, cancellation: CancellationToken())
        let rescanned = try MediaScanner.scan(url: first.outputURL, cancellation: CancellationToken())
        XCTAssertFalse(rescanned.canClean)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertThrowsError(try MediaCleaner.clean(rescanned, cancellation: CancellationToken()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
    }

    func testCancelledScanStopsBeforeReading() throws {
        let source = try fixture()
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try MediaScanner.scan(url: source, cancellation: token)) { error in
            guard case StripprError.cancelled = error else { return XCTFail("Expected cancellation") }
        }
    }

    func testSourceChangedAfterScanRefusesPublication() throws {
        let source = try fixture()
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        XCTAssertThrowsError(try MediaCleaner.clean(scan, cancellation: CancellationToken()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
    }

    func testNumericMdtaKeysRemoveValuesWithoutShiftingIndices() throws {
        let names = ["com.apple.quicktime.title", "artist", "encoder"]
        let entries = names.map { be32(UInt32($0.utf8.count + 8)) + Data("mdta".utf8) + Data($0.utf8) }.reduce(Data(), +)
        let keys = atom("keys", be32(0) + be32(UInt32(names.count)) + entries)
        let items = atom(be32(1), atom("data", be32(1) + be32(0) + Data("Fixture Title".utf8)))
            + atom(be32(2), atom("data", be32(1) + be32(0) + Data("Fixture Artist".utf8)))
            + atom(be32(3), atom("data", be32(1) + be32(0) + Data("Keep Encoder".utf8)))
        let bytes = atom("ftyp", Data("isom0000isom".utf8)) + atom("moov", atom("meta", be32(0) + keys + atom("ilst", items)))
        let source = directory.appendingPathComponent("keyed.mp4")
        try bytes.write(to: source)
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        XCTAssertEqual(scan.removableTagCount, 2)
        let cleaned = try MediaCleaner.clean(scan, cancellation: CancellationToken())
        let rescanned = try MediaScanner.scan(url: cleaned.outputURL, cancellation: CancellationToken())
        XCTAssertEqual(rescanned.removableTagCount, 0)
        XCTAssertTrue(rescanned.tags.contains { $0.value == "Keep Encoder" && !$0.removable })
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testAVIInfoFieldsRemovedSoftwarePreserved() throws {
        let fields = riffChunk("INAM", Data("Fixture Title\0".utf8))
            + riffChunk("IART", Data("Fixture Artist\0".utf8))
            + riffChunk("ISFT", Data("Keep Encoder\0".utf8))
        let body = Data("AVI ".utf8) + riffChunk("LIST", Data("INFO".utf8) + fields)
        let bytes = Data("RIFF".utf8) + le32(UInt32(body.count)) + body
        let source = directory.appendingPathComponent("info.avi")
        try bytes.write(to: source)
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        XCTAssertEqual(scan.removableTagCount, 2)
        let cleaned = try MediaCleaner.clean(scan, cancellation: CancellationToken())
        let output = try Data(contentsOf: cleaned.outputURL)
        XCTAssertEqual(output.count, bytes.count)
        XCTAssertNil(output.range(of: Data("Fixture Title".utf8)))
        XCTAssertNil(output.range(of: Data("Fixture Artist".utf8)))
        XCTAssertNotNil(output.range(of: Data("Keep Encoder".utf8)))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testMalformedAtomFailsClosed() throws {
        let source = directory.appendingPathComponent("truncated.mp4")
        var data = atom("ftyp", Data("isom0000".utf8))
        data.append(be32(4096)); data.append(Data("moov".utf8)); data.append(Data([1, 2, 3]))
        try data.write(to: source)
        XCTAssertThrowsError(try MediaScanner.scan(url: source, cancellation: CancellationToken()))
        XCTAssertEqual(try Data(contentsOf: source), data)
    }

    func testInvalidOutputDirectoryLeavesSourceAlone() throws {
        let source = try fixture()
        let original = try Data(contentsOf: source)
        let blockedDirectory = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blockedDirectory)
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        XCTAssertThrowsError(try MediaCleaner.clean(scan, outputDirectory: blockedDirectory, cancellation: CancellationToken()))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testArtworkMetadataIsPreservedAsPotentialAttachedImageStream() throws {
        let cover = metadata([0x63, 0x6f, 0x76, 0x72], "embedded-artwork-placeholder")
        let source = try fixture(extra: cover)
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        XCTAssertEqual(scan.removableTagCount, 2)
        XCTAssertTrue(scan.tags.contains { $0.key.lowercased().contains("artwork") && !$0.removable })
        let result = try MediaCleaner.clean(scan, cancellation: CancellationToken())
        XCTAssertNotNil(try Data(contentsOf: result.outputURL).range(of: Data("embedded-artwork-placeholder".utf8)))
    }

    func testUnknownMetadataIsReportedAndPreserved() throws {
        let source = try fixture(extra: atom("----", atom("name", Data([0,0,0,0]) + Data("private-field".utf8)) + atom("data", Data(repeating: 0, count: 8) + Data("untouched-secret".utf8))))
        let scan = try MediaScanner.scan(url: source, cancellation: CancellationToken())
        let result = try MediaCleaner.clean(scan, cancellation: CancellationToken())
        let output = try Data(contentsOf: result.outputURL)
        XCTAssertNotNil(output.range(of: Data("untouched-secret".utf8)))
        XCTAssertTrue(scan.tags.contains { !$0.removable } || !scan.warnings.isEmpty)
    }

    // This fixture deliberately includes recognizable nonmetadata bytes. The engine
    // must leave them unchanged without knowing a codec or rewriting a container.
    private func fixture(payloadSize: Int = 256, extra: Data = Data()) throws -> URL {
        let title = metadata([0xa9, 0x6e, 0x61, 0x6d], "Fixture Title")
        let artist = metadata([0xa9, 0x41, 0x52, 0x54], "Fixture Artist")
        let encoder = metadata([0xa9, 0x74, 0x6f, 0x6f], "Keep Encoder")
        let ilst = atom("ilst", title + artist + encoder + extra)
        let meta = atom("meta", Data(repeating: 0, count: 4) + ilst)
        let movie = atom("moov", atom("udta", meta))
        var bytes = atom("ftyp", Data("isom0000isom".utf8))
        bytes.append(atom("mdat", Data((0..<payloadSize).map { UInt8($0 % 251) })))
        bytes.append(movie)
        let url = directory.appendingPathComponent("input ünicode.mp4")
        try bytes.write(to: url)
        return url
    }

    private func metadata(_ fourcc: [UInt8], _ value: String) -> Data {
        atom(Data(fourcc), atom("data", be32(1) + be32(0) + Data(value.utf8)))
    }
    private func atom(_ type: String, _ payload: Data) -> Data { atom(Data(type.utf8), payload) }
    private func atom(_ type: Data, _ payload: Data) -> Data { be32(UInt32(payload.count + 8)) + type + payload }
    private func riffChunk(_ name: String, _ value: Data) -> Data {
        Data(name.utf8) + le32(UInt32(value.count)) + value + (value.count % 2 == 1 ? Data([0]) : Data())
    }
    private func be64(_ value: UInt64) -> Data {
        be32(UInt32(value >> 32)) + be32(UInt32(value & 0xffff_ffff))
    }
    private func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255), UInt8((value >> 24) & 255)])
    }
    private func be32(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
}

private final class OneTimeMutation: @unchecked Sendable {
    let source: URL
    private let lock = NSLock()
    private(set) var didMutate = false
    init(source: URL) { self.source = source }
    func appendByte() {
        lock.lock(); defer { lock.unlock() }
        guard !didMutate else { return }
        do {
            let handle = try FileHandle(forWritingTo: source)
            try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
            didMutate = true
        } catch {}
    }
}
