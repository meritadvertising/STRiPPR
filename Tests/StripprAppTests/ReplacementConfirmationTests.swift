import XCTest
import Foundation
@testable import STRiPPR

final class ReplacementConfirmationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("STRiPPR-confirmation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let directory { try FileManager.default.removeItem(at: directory) } }

    @MainActor
    func testOptionsDefaultToKeepingOriginalsAndEncoderAndEmptyQueueCannotArmReplacement() {
        let store = BatchStore()
        XCTAssertTrue(store.keepOriginals)
        XCTAssertTrue(store.keepEncoderInfo)
        store.setKeepOriginals(false)
        store.clean()
        XCTAssertNil(store.replacementRequest)
        XCTAssertFalse(store.isBusy)
    }

    @MainActor
    func testReplacementRequiresConfirmationAndExplicitCancellationDoesNoIO() async throws {
        let source = try fixture("review-before-replace.mp4")
        let original = try Data(contentsOf: source)
        let store = BatchStore()
        store.add([source]); try await waitUntilIdle(store)
        store.setKeepOriginals(false)
        XCTAssertEqual(try Data(contentsOf: source), original)
        store.clean()
        let request = try XCTUnwrap(store.replacementRequest)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.items[0].phase, .ready)
        XCTAssertTrue(request.message.contains(source.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
        store.cancelReplacement()
        XCTAssertNil(store.replacementRequest)
        store.confirmReplacement(request)
        XCTAssertFalse(store.isBusy, "A cancelled confirmation must not be reusable")
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNil(store.items[0].output)
    }

    @MainActor
    func testValidCapturedConfirmationWorksAfterAlertBindingClearsAndCannotBeReplayed() async throws {
        let source = try fixture("confirmed.mp4")
        let store = BatchStore()
        store.add([source]); try await waitUntilIdle(store)
        store.setKeepOriginals(false)
        store.clean()
        let request = try XCTUnwrap(store.replacementRequest)
        // SwiftUI clears an item's alert binding before its captured action runs.
        store.replacementRequest = nil
        store.confirmReplacement(request)
        XCTAssertTrue(store.isBusy)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.items[0].phase, .verified)
        XCTAssertTrue(store.items[0].didReplaceOriginal)
        XCTAssertEqual(store.items[0].output, source)
        let cleaned = try Data(contentsOf: source)
        XCTAssertNil(cleaned.range(of: Data("Remove Title".utf8)))
        XCTAssertNotNil(cleaned.range(of: Data("Keep Encoder".utf8)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
        store.confirmReplacement(request)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(try Data(contentsOf: source), cleaned)
    }

    @MainActor
    func testAddingFileInvalidatesPreviouslyReviewedReplacementSet() async throws {
        let first = try fixture("first.mp4")
        let second = try fixture("second.mp4")
        let original = try Data(contentsOf: first)
        let store = BatchStore()
        store.add([first]); try await waitUntilIdle(store)
        store.setKeepOriginals(false); store.clean()
        let request = try XCTUnwrap(store.replacementRequest)
        store.add([second]); try await waitUntilIdle(store)
        XCTAssertNil(store.replacementRequest)
        store.confirmReplacement(request)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.readyCount, 2)
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: second), original)
    }

    @MainActor
    func testReturningToKeepOriginalsInvalidatesReplacementAndCreatesCopy() async throws {
        let source = try fixture("keep-original-again.mp4")
        let original = try Data(contentsOf: source)
        let store = BatchStore()
        store.add([source]); try await waitUntilIdle(store)
        store.setKeepOriginals(false); store.clean()
        let request = try XCTUnwrap(store.replacementRequest)
        store.setKeepOriginals(true)
        store.confirmReplacement(request)
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.replacementRequest)
        XCTAssertEqual(try Data(contentsOf: source), original)
        store.clean(); try await waitUntilIdle(store)
        XCTAssertEqual(store.items[0].phase, .verified)
        XCTAssertFalse(store.items[0].didReplaceOriginal)
        XCTAssertNotEqual(store.items[0].output, source)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor
    func testChangingEncoderPolicyRescansAndInvalidatesEarlierConfirmation() async throws {
        let source = try fixture("encoder-policy.mp4")
        let original = try Data(contentsOf: source)
        let store = BatchStore()
        store.add([source]); try await waitUntilIdle(store)
        store.setKeepOriginals(false); store.clean()
        let old = try XCTUnwrap(store.replacementRequest)
        store.setKeepEncoderInfo(false)
        XCTAssertTrue(store.isScanning)
        XCTAssertNil(store.replacementRequest)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.items[0].scan?.keepEncoderInfo, false)
        XCTAssertTrue(store.items[0].scan?.tags.contains { $0.value == "Keep Encoder" && $0.removable } == true)
        store.confirmReplacement(old)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(try Data(contentsOf: source), original)
        store.clean()
        let current = try XCTUnwrap(store.replacementRequest)
        XCTAssertFalse(current.keepEncoderInfo)
        XCTAssertNotEqual(current.id, old.id)
        store.confirmReplacement(current); try await waitUntilIdle(store)
        XCTAssertEqual(store.items[0].phase, .verified)
        XCTAssertTrue(store.items[0].didReplaceOriginal)
        let output = try Data(contentsOf: source)
        XCTAssertNil(output.range(of: Data("Remove Title".utf8)))
        XCTAssertNil(output.range(of: Data("Keep Encoder".utf8)))
    }

    @MainActor
    func testUnarmedRequestCannotAuthorizeReplacement() async throws {
        let source = try fixture("unarmed.mp4")
        let original = try Data(contentsOf: source)
        let store = BatchStore()
        store.add([source]); try await waitUntilIdle(store)
        store.setKeepOriginals(false)
        let unarmed = ReplacementRequest(files: store.items, keepEncoderInfo: store.keepEncoderInfo)
        store.confirmReplacement(unarmed)
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.replacementRequest)
        XCTAssertEqual(store.items[0].phase, .ready)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNil(store.items[0].output)
    }

    @MainActor
    private func waitUntilIdle(_ store: BatchStore) async throws {
        let deadline = Date().addingTimeInterval(10)
        while store.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(store.isBusy, "Timed out waiting for the batch task")
        if store.isBusy { throw NSError(domain: "ReplacementConfirmationTests", code: 1) }
    }
    private func fixture(_ name: String) throws -> URL {
        let fields = item([0xa9, 0x6e, 0x61, 0x6d], "Remove Title") + item([0xa9, 0x74, 0x6f, 0x6f], "Keep Encoder")
        let bytes = atom("ftyp", Data("isom0000isom".utf8)) + atom("mdat", Data("Payload must survive".utf8))
            + atom("moov", atom("udta", atom("meta", be32(0) + atom("ilst", fields))))
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
    private func item(_ name: [UInt8], _ value: String) -> Data {
        let child = atom("data", be32(1) + be32(0) + Data(value.utf8))
        return be32(UInt32(child.count + 8)) + Data(name) + child
    }
    private func atom(_ name: String, _ payload: Data) -> Data { be32(UInt32(payload.count + 8)) + Data(name.utf8) + payload }
    private func be32(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
}
