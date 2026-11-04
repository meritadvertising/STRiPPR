import XCTest
import Foundation
import StripprCore
@testable import STRiPPR

final class QueuePresentationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("STRiPPR-queue-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    func testDefaultsNaturalNameSortingAndStableDuplicateNameTies() throws {
        let store = BatchStore()
        let urls = ["z/clip 2.mp4", "clip 10.mp4", "a/clip 2.mp4", "clip 1.mp4"].map { directory.appendingPathComponent($0) }
        let rows = urls.map { FileItem(id: UUID(), url: $0) }
        store.items = rows
        XCTAssertEqual(store.fileFilter, .both)
        XCTAssertEqual(store.fileSort, .name)
        XCTAssertTrue(store.sortAscending)
        XCTAssertEqual(store.visibleItems.map(\.url), [urls[3], urls[2], urls[0], urls[1]])
        XCTAssertEqual(store.unknownTagsCount, 4)
        store.sortAscending = false
        XCTAssertEqual(store.visibleItems.map(\.url), [urls[1], urls[0], urls[2], urls[3]])
        store.items.reverse()
        XCTAssertEqual(store.visibleItems.map(\.url), [urls[1], urls[0], urls[2], urls[3]], "Presentation order must not depend on mutable backing indices")
        for row in rows { XCTAssertEqual(store.items[try XCTUnwrap(store.index(for: row.id))].url, row.url) }
    }

    @MainActor
    func testUnknownReadOnlyAndFailedRowsAreNeverCalledWithoutRemovableTags() throws {
        let tagged = try scanFixture("tagged.mp4", title: "Found")
        let clean = try scanFixture("clean.mp4")
        let mpegURL = directory.appendingPathComponent("limited.mpg")
        try Data([0, 0, 1, 0xba, 0x44, 0, 4, 0, 4, 1, 0x89, 0xc3, 0xf8]).write(to: mpegURL)
        let limited = try MediaScanner.scan(url: mpegURL)
        let rows = [
            FileItem(id: UUID(), url: tagged.url, scan: tagged, phase: .ready),
            FileItem(id: UUID(), url: clean.url, scan: clean, phase: .inspected),
            FileItem(id: UUID(), url: directory.appendingPathComponent("unscanned.mp4")),
            FileItem(id: UUID(), url: mpegURL, scan: limited, phase: .readOnly),
            FileItem(id: UUID(), url: directory.appendingPathComponent("bad.mp4"), phase: .failed),
            FileItem(id: UUID(), url: clean.url, scan: clean, phase: .failed),
            FileItem(id: UUID(), url: tagged.url, scan: tagged, phase: .failed),
            FileItem(id: UUID(), url: clean.url, scan: clean, phase: .cancelled)
        ]
        let store = BatchStore()
        store.items = rows
        XCTAssertEqual(store.withTagsCount, 2, "A failed cleaning attempt may still show positive evidence from its last valid scan")
        XCTAssertEqual(store.withoutTagsCount, 1)
        XCTAssertEqual(store.unknownTagsCount, 5)
        store.fileFilter = .withoutTags
        XCTAssertEqual(store.visibleItemIDs, [rows[1].id])
        store.fileFilter = .withTags
        XCTAssertEqual(Set(store.visibleItemIDs), Set([rows[0].id, rows[6].id]))
        store.fileFilter = .both
        XCTAssertEqual(store.filteredCount, rows.count)
    }

    @MainActor
    func testNumericSortingUsesCountsAndSizesAndKeepsUnknownValuesLast() throws {
        let one = try scanFixture("one.mp4", title: "a")
        let two = try scanFixture("two.mp4", title: "A much longer title", artist: "Artist")
        let clean = try scanFixture("zero.mp4")
        let known = [one, two, clean].map { FileItem(id: UUID(), url: $0.url, scan: $0, phase: $0.canClean ? .ready : .inspected) }
        let unknown = FileItem(id: UUID(), url: directory.appendingPathComponent("a unknown.mp4"), phase: .failed)
        let store = BatchStore()
        store.items = known + [unknown]
        store.fileSort = .removableTags
        XCTAssertEqual(store.visibleItemIDs, [known[2].id, known[0].id, known[1].id, unknown.id])
        store.sortAscending = false
        XCTAssertEqual(store.visibleItemIDs, [known[1].id, known[0].id, known[2].id, unknown.id])
        store.fileSort = .size
        XCTAssertEqual(store.visibleItems.dropLast().compactMap { $0.scan?.fileSize }, known.compactMap { $0.scan?.fileSize }.sorted(by: >))
        XCTAssertEqual(store.visibleItemIDs.last, unknown.id)
        store.sortAscending = true
        XCTAssertEqual(store.visibleItems.dropLast().compactMap { $0.scan?.fileSize }, known.compactMap { $0.scan?.fileSize }.sorted())
        XCTAssertEqual(store.visibleItemIDs.last, unknown.id)
        store.fileSort = .status
        XCTAssertEqual(store.visibleItems.map(\.phase), [.failed, .inspected, .ready, .ready])
    }

    @MainActor
    func testFilterSortDuringWorkAndExpansionUseStableIDsWithoutResortingProgress() throws {
        let first = try scanFixture("clip 2.mp4", title: "Keep this row")
        let second = try scanFixture("clip 1.mp4")
        let store = BatchStore()
        store.items = [FileItem(id: UUID(), url: first.url, scan: first, phase: .cleaning), FileItem(id: UUID(), url: second.url, scan: second, phase: .inspected)]
        let firstID = store.items[0].id, secondID = store.items[1].id
        store.isBusy = true
        store.fileFilter = .withTags
        store.fileSort = .removableTags
        store.sortAscending = false
        XCTAssertEqual(store.visibleItemIDs, [firstID], "Display changes remain available while work runs")
        let sortCount = store.presentationSortCount, nameCount = store.presentationNameSortCount
        for tick in 1...100 {
            let row = try XCTUnwrap(store.index(for: firstID))
            store.items[row].progress = Double(tick) / 100
            store.items[row].detail = "Copying \(tick)%"
        }
        XCTAssertEqual(store.presentationSortCount, sortCount)
        XCTAssertEqual(store.presentationNameSortCount, nameCount)
        store.fileFilter = .both
        store.fileSort = .name
        XCTAssertEqual(store.visibleItemIDs, [firstID, secondID])
        store.setExpanded(true, for: secondID)
        XCTAssertTrue(store.items[try XCTUnwrap(store.index(for: secondID))].expanded)
        XCTAssertFalse(store.items[try XCTUnwrap(store.index(for: firstID))].expanded)
        store.sortAscending = true
        store.setExpanded(false, for: secondID)
        store.setExpanded(true, for: firstID)
        XCTAssertTrue(store.items[try XCTUnwrap(store.index(for: firstID))].expanded)
        XCTAssertFalse(store.items[try XCTUnwrap(store.index(for: secondID))].expanded)
        store.setExpanded(true, for: UUID()) // Stale row callback is a harmless no-op.
    }

    @MainActor
    func testHiddenReadyFilesStillCleanAndVerifiedCopiesKeepOriginalScanClassification() async throws {
        let a = try fixture("a.mp4", title: "A"), b = try fixture("b.mp4", title: "B")
        let bytes = try [a, b].map { try Data(contentsOf: $0) }
        let store = BatchStore()
        store.add([a, b])
        try await waitUntilIdle(store)
        store.fileFilter = .withoutTags
        XCTAssertEqual(store.filteredCount, 0)
        XCTAssertEqual(store.readyCount, 2)
        store.clean()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.verifiedCount, 2, "The filter must not narrow the cleaning operation")
        XCTAssertEqual(store.withTagsCount, 2, "A cleaned copy does not change metadata in its source")
        XCTAssertEqual(try [a, b].map { try Data(contentsOf: $0) }, bytes)
        XCTAssertTrue(store.items.allSatisfy { $0.output != nil && !$0.didReplaceOriginal })
    }

    @MainActor
    func testDisplayChangesDoNotInvalidateWholeQueueReplacementConfirmation() async throws {
        let a = try fixture("a.mp4", title: "A"), b = try fixture("b.mp4", title: "B")
        let store = BatchStore()
        store.add([a, b])
        try await waitUntilIdle(store)
        let ids = Set(store.items.map(\.id))
        store.setKeepOriginals(false)
        store.fileFilter = .withoutTags
        store.clean()
        let request = try XCTUnwrap(store.replacementRequest)
        XCTAssertEqual(Set(request.files.map(\.id)), ids)
        store.fileSort = .size
        store.sortAscending = false
        store.fileFilter = .withTags
        XCTAssertEqual(store.replacementRequest?.id, request.id)
        store.confirmReplacement(request)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.verifiedCount, 2)
        XCTAssertTrue(store.items.allSatisfy(\.didReplaceOriginal))
        XCTAssertEqual(Set(store.items.map(\.id)), ids)
        XCTAssertEqual(store.withTagsCount, 0)
        XCTAssertEqual(store.withoutTagsCount, 2, "Verified replacement updates the source's current removable-tag count")
        XCTAssertEqual(store.filteredCount, 0)
        XCTAssertFalse(try MediaScanner.scan(url: a).canClean)
        XCTAssertFalse(try MediaScanner.scan(url: b).canClean)
    }

    @MainActor
    func testFiveHundredRealFilesFilterSortRetryAndPolicyStayResponsive() async throws {
        let tagged = try playableFixture(tagged: true)
        let clean = try playableFixture(tagged: false)
        var urls: [URL] = []
        for index in 0..<500 {
            let target = directory.appendingPathComponent("clip \(index + 1).mp4")
            try (index < 8 ? tagged : clean).write(to: target)
            urls.append(target)
        }
        let store = BatchStore()
        var ticks = 0, maxHeartbeatGap: TimeInterval = 0
        let heartbeat = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
                let now = ProcessInfo.processInfo.systemUptime
                maxHeartbeatGap = max(maxHeartbeatGap, now - previous)
                previous = now
                ticks += 1
            }
        }
        defer { heartbeat.cancel() }
        let scanStart = ProcessInfo.processInfo.systemUptime
        store.add([directory])
        try await waitUntilIdle(store, timeout: 60)
        let scanSeconds = ProcessInfo.processInfo.systemUptime - scanStart
        XCTAssertEqual(store.items.count, 500)
        XCTAssertEqual(store.withTagsCount, 8)
        XCTAssertEqual(store.withoutTagsCount, 492)
        XCTAssertEqual(store.unknownTagsCount, 0)
        XCTAssertEqual(store.readyCount, 8)
        XCTAssertGreaterThan(ticks, 1, "Scanning must yield the main actor rather than blocking it for the entire directory")
        let initialNames = store.visibleItems.map { $0.url.lastPathComponent }
        XCTAssertEqual(initialNames.first, "clip 1.mp4")
        XCTAssertEqual(initialNames.last, "clip 500.mp4")
        let nameSortsAfterScan = store.presentationNameSortCount
        XCTAssertEqual(nameSortsAfterScan, 1, "Metadata scan completions must reuse the cached natural name order")

        var maxActionSeconds: TimeInterval = 0
        func action(_ operation: () -> Void) {
            let start = ProcessInfo.processInfo.systemUptime
            operation()
            maxActionSeconds = max(maxActionSeconds, ProcessInfo.processInfo.systemUptime - start)
        }
        action { store.fileFilter = .withTags }
        XCTAssertEqual(store.filteredCount, 8)
        XCTAssertEqual(Set(store.visibleItems.map(\.url)), Set(urls.prefix(8)))
        action { store.fileFilter = .withoutTags }
        XCTAssertEqual(store.filteredCount, 492)
        action { store.fileFilter = .both; store.fileSort = .removableTags; store.sortAscending = false }
        XCTAssertEqual(Set(store.visibleItems.prefix(8).map(\.url)), Set(urls.prefix(8)))
        action { store.fileSort = .size }
        XCTAssertEqual(store.visibleItems.compactMap { $0.scan?.fileSize }, store.items.compactMap { $0.scan?.fileSize }.sorted(by: >))
        action { store.fileSort = .status; store.sortAscending = true }
        XCTAssertEqual(store.visibleItems.prefix(492).map(\.phase), Array(repeating: .inspected, count: 492))

        action { store.fileSort = .name }
        let changedID = try XCTUnwrap(store.items.first(where: { $0.url == urls[0] })?.id)
        let sortsBeforeProgress = store.presentationSortCount
        for tick in 1...100 {
            action {
                let index = store.index(for: changedID)!
                store.items[index].progress = Double(tick) / 100
                store.items[index].detail = "Observed progress \(tick)"
            }
        }
        XCTAssertEqual(store.presentationSortCount, sortsBeforeProgress)
        XCTAssertEqual(store.presentationNameSortCount, nameSortsAfterScan)
        action { store.sortAscending = false; store.fileFilter = .withTags; store.setExpanded(true, for: changedID) }
        XCTAssertTrue(store.items[try XCTUnwrap(store.index(for: changedID))].expanded)
        XCTAssertEqual(store.items.filter(\.expanded).map(\.id), [changedID])

        // Change a previously clean disposable source, then retry under an active
        // filter. The same row ID returns only after a fresh scan finds its tags.
        let retryID = try XCTUnwrap(store.items.first(where: { $0.url == urls[8] })?.id)
        try tagged.write(to: urls[8], options: .atomic)
        action { store.retry(retryID) }
        XCTAssertFalse(store.visibleItemIDs.contains(retryID))
        XCTAssertNil(store.items[try XCTUnwrap(store.index(for: retryID))].scan)
        try await waitUntilIdle(store, timeout: 60)
        XCTAssertEqual(store.withTagsCount, 9)
        XCTAssertTrue(store.visibleItemIDs.contains(retryID))

        let policyStart = ProcessInfo.processInfo.systemUptime
        action { store.setKeepEncoderInfo(false) }
        XCTAssertEqual(store.unknownTagsCount, 500, "Old scan classifications must clear immediately when policy changes")
        XCTAssertEqual(store.filteredCount, 0)
        try await waitUntilIdle(store, timeout: 60)
        XCTAssertEqual(store.withTagsCount, 500)
        XCTAssertEqual(store.readyCount, 500)
        let removeEncoderRescanSeconds = ProcessInfo.processInfo.systemUptime - policyStart
        action { store.setKeepEncoderInfo(true) }
        try await waitUntilIdle(store, timeout: 60)
        XCTAssertEqual(store.withTagsCount, 9)
        XCTAssertEqual(store.withoutTagsCount, 491)
        XCTAssertEqual(store.presentationNameSortCount, nameSortsAfterScan)
        XCTAssertEqual(Set(store.items.map(\.url)), Set(urls))
        XCTAssertTrue(store.items.allSatisfy { $0.output == nil }, "Presentation and rescan tests never clean these real fixture copies")
        XCTAssertLessThan(maxActionSeconds, 1.0, "A synchronous filter/sort/progress action must return promptly for 500 files")
        XCTAssertLessThan(maxHeartbeatGap, 1.0, "The main actor must remain available while 500-file scans run")
        let metric: [String: Any] = ["files": 500, "initialWithTags": 8, "initialWithoutTags": 492, "scanSeconds": scanSeconds, "encoderPolicyRescanSeconds": removeEncoderRescanSeconds, "heartbeatTicks": ticks, "maximumHeartbeatGapSeconds": maxHeartbeatGap, "maximumSynchronousActionSeconds": maxActionSeconds, "naturalNameSorts": store.presentationNameSortCount, "progressUpdatesWithoutResort": 100]
        let data = try JSONSerialization.data(withJSONObject: metric, options: [.sortedKeys])
        print("STRIPPR_QUEUE_METRICS " + String(decoding: data, as: UTF8.self))
    }

    @MainActor
    private func waitUntilIdle(_ store: BatchStore, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(store.isBusy, "Timed out waiting for queue work")
        if store.isBusy { throw NSError(domain: "QueuePresentationTests", code: 1) }
    }

    /// One-frame 16x16 MPEG-4 videos generated from a black color source with
    /// FFmpeg, then remuxed with -map_metadata -1 for the clean variant. Embedding
    /// these public synthetic bytes keeps XCTest independent of FFmpeg and the
    /// ignored integration-fixture directory while exercising real movie tables.
    private func playableFixture(tagged: Bool) throws -> Data {
        let encoded: String
        if tagged {
            encoded = """
            AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAAGW1kYXQAAAGzABAHAAABthYLGCmbfgAAA4ptb292AAAA
            bG12aGQAAAAAAAAAAAAAAAAAAAPoAAAD6AABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAA
            AEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACanRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAD
            6AAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAEAAAABAAAAAAACRlZHRzAAAA
            HGVsc3QAAAAAAAAAAQAAA+gAAAAAAAEAAAAAAeJtZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAAEAAAABAAFXEAAAAAAAtaGRs
            cgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAGNbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRp
            bmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABTXN0YmwAAADpc3RzZAAAAAAAAAABAAAA2W1wNHYAAAAAAAAAAQAA
            AAAAAAAAAAAAAAAAAAAAEAAQAEgAAABIAAAAAAAAAAESTGF2YzYzLjEuMTAyIG1wZWc0AAAAAAAAAAAAAAAAAAAY//8AAABf
            ZXNkcwAAAAADgICATgABAASAgIBAIBEAAAAAAw1AAAAAiAWAgIAuAAABsAEAAAG1iRMAAAEAAAABIADEjYgADQCEAhRjAAAB
            skxhdmM2My4xLjEwMgaAgIABAgAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAw1AAAAAiAAAABhzdHRzAAAAAAAAAAEA
            AAABAABAAAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAQAAAAEAAAAUc3RzegAAAAAAAAARAAAAAQAAABRzdGNvAAAAAAAAAAEA
            AAAsAAAArHVkdGEAAACkbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAB3aWxzdAAAACWpbmFt
            AAAAHWRhdGEAAAABAAAAAEZpeHR1cmUgVGl0bGUAAAAmqUFSVAAAAB5kYXRhAAAAAQAAAABGaXh0dXJlIEFydGlzdAAAACSp
            dG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEwMg==
            """
        } else {
            encoded = """
            AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAAGW1kYXQAAAGzABAHAAABthYLGCmbfgAAAz9tb292AAAA
            bG12aGQAAAAAAAAAAAAAAAAAAEAAAABAAAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAA
            AEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACanRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAABA
            AAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAEAAAABAAAAAAACRlZHRzAAAA
            HGVsc3QAAAAAAAAAAQAAQAAAAAAAAAEAAAAAAeJtZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAAEAAAABAAFXEAAAAAAAtaGRs
            cgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAGNbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRp
            bmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABTXN0YmwAAADpc3RzZAAAAAAAAAABAAAA2W1wNHYAAAAAAAAAAQAA
            AAAAAAAAAAAAAAAAAAAAEAAQAEgAAABIAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAY//8AAABf
            ZXNkcwAAAAADgICATgABAASAgIBAIBEAAAAAAACIAAAAiAWAgIAuAAABsAEAAAG1iRMAAAEAAAABIADEjYgADQCEAhRjAAAB
            skxhdmM2My4xLjEwMgaAgIABAgAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAACIAAAAiAAAABhzdHRzAAAAAAAAAAEA
            AAABAABAAAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAQAAAAEAAAAUc3RzegAAAAAAAAARAAAAAQAAABRzdGNvAAAAAAAAAAEA
            AAAsAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9v
            AAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEwMg==
            """
        }
        return try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
    }

    private func scanFixture(_ name: String, title: String? = nil, artist: String? = nil) throws -> ScanResult {
        try MediaScanner.scan(url: fixture(name, title: title, artist: artist))
    }

    private func fixture(_ name: String, title: String? = nil, artist: String? = nil) throws -> URL {
        var fields = metadata([0xa9, 0x74, 0x6f, 0x6f], "Keep Encoder")
        if let title { fields.append(metadata([0xa9, 0x6e, 0x61, 0x6d], title)) }
        if let artist { fields.append(metadata([0xa9, 0x41, 0x52, 0x54], artist)) }
        let bytes = atom("ftyp", Data("isom0000isom".utf8)) + atom("mdat", Data("Preserved stream".utf8)) + atom("moov", atom("udta", atom("meta", be32(0) + atom("ilst", fields))))
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func metadata(_ type: [UInt8], _ value: String) -> Data {
        be32(UInt32(value.utf8.count + 24)) + Data(type) + atom("data", be32(1) + be32(0) + Data(value.utf8))
    }
    private func atom(_ type: String, _ payload: Data) -> Data { be32(UInt32(payload.count + 8)) + Data(type.utf8) + payload }
    private func be32(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
}
