import XCTest
import Foundation
import StripprCore
@testable import STRiPPR

final class BatchStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("STRiPPR-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    func testRecursiveScanDeduplicatesAndSkipsSymlinksAndGeneratedCopies() async throws {
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let source = try fixture("clip.mp4")
        let sameName = try fixture("nested/clip.mp4")
        let legitimate = try fixture("clip.stripped-original.mp4")
        _ = try fixture("clip.stripped.mp4")
        _ = try fixture("clip.stripped-2.mp4")
        _ = try fixture(".hidden.mp4")
        try Data("text".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("cycle"), withDestinationURL: directory)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias.mp4"), withDestinationURL: source)
        let store = BatchStore()
        store.add([directory, source, nested])
        try await waitUntilIdle(store)
        XCTAssertEqual(Set(store.items.map { $0.url.path }), Set([source.path, sameName.path, legitimate.path]))
        XCTAssertEqual(store.readyCount, 3)
        XCTAssertGreaterThanOrEqual(store.skipped, 4)
        store.add([source, sameName, directory])
        try await waitUntilIdle(store)
        XCTAssertEqual(store.items.count, 3, "Repeated drops and overlapping folders must preserve one row per path")
    }

    @MainActor
    func testChangedSourceFailsCleaningThenRetryRescansBeforeCleaning() async throws {
        let source = try fixture("changed.mp4", title: "Old title")
        let store = BatchStore()
        store.add([source])
        try await waitUntilIdle(store)
        let id = try XCTUnwrap(store.items.first?.id)
        XCTAssertEqual(store.items[0].phase, .ready)
        _ = try fixture("changed.mp4", title: "New longer title")
        let updatedOriginal = try Data(contentsOf: source)
        store.clean()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.items[0].phase, .failed)
        XCTAssertNil(store.items[0].output)
        XCTAssertTrue(store.items[0].detail.contains("original changed"))
        store.retry(id)
        XCTAssertTrue(store.isScanning)
        XCTAssertNil(store.items[0].scan, "Retry must clear the obsolete scan immediately")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.items[0].phase, .ready)
        XCTAssertTrue(store.items[0].scan?.tags.contains { $0.value == "New longer title" } == true)
        store.clean()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.items[0].phase, .verified)
        XCTAssertEqual(store.verifiedCount, 1)
        let output = try XCTUnwrap(store.items[0].output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: source), updatedOriginal)
        XCTAssertNil(try Data(contentsOf: output).range(of: Data("New longer title".utf8)))
    }

    @MainActor
    func testRetryOfCancelledInitialScanWithNilScanReadsTheFile() async throws {
        let source = try fixture("cancelled.mp4")
        let row = FileItem(id: UUID(), url: source, scan: nil, phase: .cancelled, detail: "Scan cancelled")
        let store = BatchStore()
        store.items = [row]
        store.retry(row.id)
        XCTAssertTrue(store.isBusy)
        XCTAssertEqual(store.items[0].phase, .scanning)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.items[0].phase, .ready)
        XCTAssertNotNil(store.items[0].scan)
        XCTAssertEqual(store.readyCount, 1)
        XCTAssertTrue(store.items[0].scan?.tags.contains { $0.value == "Fixture Title" } == true)
    }

    @MainActor
    func testRetryOfFailedInitialScanWorksAfterFileIsRepaired() async throws {
        let source = directory.appendingPathComponent("repaired.mp4")
        try Data([0, 1, 2]).write(to: source)
        let store = BatchStore()
        store.add([source])
        try await waitUntilIdle(store)
        XCTAssertEqual(store.items[0].phase, .failed)
        XCTAssertNil(store.items[0].scan)
        _ = try fixture("repaired.mp4")
        store.retry(store.items[0].id)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.items[0].phase, .ready)
        XCTAssertEqual(store.readyCount, 1)
    }

    @MainActor
    func testCancelledBatchRetainsMeasuredProgressAndRemainingQueue() async throws {
        let first = try fixture("first.mp4", payloadSize: 32 * 1024 * 1024)
        let second = try fixture("second.mp4")
        let store = BatchStore()
        store.add([first, second])
        try await waitUntilIdle(store)
        XCTAssertEqual(store.readyCount, 2)
        store.clean()
        let deadline = Date().addingTimeInterval(5)
        while store.isBusy && store.items[0].progress == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000)
        }
        XCTAssertTrue(store.isBusy, "Large copy must still be active when cancellation is requested")
        XCTAssertGreaterThan(store.items[0].progress, 0)
        XCTAssertLessThan(store.items[0].progress, 0.5, "Cancel during the original-copy phase")
        let observed = store.overallProgress
        store.cancel()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.items[0].phase, .cancelled)
        XCTAssertEqual(store.items[1].phase, .ready)
        XCTAssertGreaterThanOrEqual(store.overallProgress, observed)
        XCTAssertLessThan(store.overallProgress, 0.5, "A cancelled file must not count as a completed file")
        XCTAssertEqual(store.overallProgress, store.items[0].progress / 2, accuracy: 0.000001)
        XCTAssertNil(store.items[0].output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["first.mp4", "second.mp4"])
    }

    @MainActor
    private func waitUntilIdle(_ store: BatchStore, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(store.isBusy, "Timed out waiting for the batch task to finish")
        if store.isBusy { throw NSError(domain: "BatchStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Batch task timed out"]) }
    }

    /// Sparse synthetic media keeps the cancellation case large enough to observe
    /// without allocating its payload in memory or depending on external codecs.
    private func fixture(_ name: String, title: String = "Fixture Title", payloadSize: Int = 256) throws -> URL {
        let ilst = atom("ilst", metadata([0xa9, 0x6e, 0x61, 0x6d], title) + metadata([0xa9, 0x74, 0x6f, 0x6f], "Keep Encoder"))
        let movie = atom("moov", atom("udta", atom("meta", be32(0) + ilst)))
        let url = directory.appendingPathComponent(name)
        var prefix = atom("ftyp", Data("isom0000isom".utf8))
        prefix.append(be32(UInt32(payloadSize + 8))); prefix.append(Data("mdat".utf8))
        try prefix.write(to: url)
        let file = try FileHandle(forWritingTo: url)
        try file.seek(toOffset: UInt64(prefix.count + payloadSize))
        try file.write(contentsOf: movie)
        try file.close()
        return url
    }

    private func metadata(_ type: [UInt8], _ value: String) -> Data {
        be32(UInt32(value.utf8.count + 24)) + Data(type) + atom("data", be32(1) + be32(0) + Data(value.utf8))
    }
    private func atom(_ type: String, _ payload: Data) -> Data { be32(UInt32(payload.count + 8)) + Data(type.utf8) + payload }
    private func be32(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
}
