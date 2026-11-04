import XCTest
import Foundation
@testable import StripprCore

final class AlbumMetadataTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("STRiPPR-album-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testStandardITunesAlbumIsRemoved() throws {
        let items = item(Data([0xa9, 0x61, 0x6c, 0x62]), "Fixture Album")
            + item(Data([0xa9, 0x74, 0x6f, 0x6f]), "Keep Encoder")
        try check(movie: atom("udta", atom("meta", be32(0) + atom("ilst", items))), expected: 1)
    }

    func testLegacyQuickTimeAlbumIsRemoved() throws {
        let text = Data("Fixture Album".utf8)
        let legacyValue = Data([0, UInt8(text.count), 0, 0]) + text
        try check(movie: atom("udta", atom(Data([0xa9, 0x61, 0x6c, 0x62]), legacyValue)), expected: 1)
    }

    func test3GPPAlbumIsRemoved() throws {
        // 3GPP albm: full-box flags, packed language, UTF-8 album and optional track number.
        try check(movie: atom("udta", atom("albm", be32(0) + Data([0x15, 0xc7]) + Data("Fixture Album\0".utf8) + Data([1]))), expected: 1)
    }

    func testRootMetadataAndUppercaseMdtaAlbumAreRemoved() throws {
        let names = ["ALBUM", "ENCODER", "com.apple.quicktime.video-orientation"]
        let keyEntries = names.map { be32(UInt32($0.utf8.count + 8)) + Data("mdta".utf8) + Data($0.utf8) }.reduce(Data(), +)
        let keys = atom("keys", be32(0) + be32(UInt32(names.count)) + keyEntries)
        let items = item(be32(1), "Fixture Album") + item(be32(2), "Keep Encoder") + item(be32(3), "90")
        let rootMeta = atom("meta", be32(0) + keys + atom("ilst", items))
        try check(movie: Data(), extraRoot: rootMeta, expected: 1, retained: ["Keep Encoder", "90"])
    }

    func testFreeformAlbumIsRemovedAndOtherNamespacesStayIntact() throws {
        let items = freeform(mean: "com.apple.iTunes", name: "ALBUM", value: "Fixture Album")
            + freeform(mean: "private.namespace", name: "ALBUM", value: "Keep Private Album")
            + freeform(mean: "com.apple.iTunes", name: "iTunSMPB", value: "Keep Timing Data")
        try check(movie: atom("udta", atom("meta", be32(0) + atom("ilst", items))), expected: 1,
                  retained: ["Keep Private Album", "Keep Timing Data"])
    }

    func testNestedUppercaseQuickTimeAlbumIsRemoved() throws {
        let key = "COM.APPLE.QUICKTIME.ALBUM"
        let keys = atom("keys", be32(0) + be32(1) + be32(UInt32(key.utf8.count + 8)) + Data("mdta".utf8) + Data(key.utf8))
        try check(movie: atom("meta", be32(0) + keys + atom("ilst", item(be32(1), "Fixture Album"))), expected: 1)
    }

    private func check(movie: Data, extraRoot: Data = Data(), expected: Int, retained: [String] = []) throws {
        let payload = Data("media payload: do not alter".utf8)
        let original = atom("ftyp", Data("isom0000isom".utf8)) + atom("mdat", payload) + atom("moov", movie) + extraRoot
        let source = directory.appendingPathComponent("album.mp4")
        try original.write(to: source)
        let scan = try MediaScanner.scan(url: source)
        XCTAssertEqual(scan.removableTagCount, expected)
        XCTAssertTrue(scan.tags.contains { $0.key == "Album" && $0.removable })
        let result = try MediaCleaner.clean(scan)
        let cleaned = try Data(contentsOf: result.outputURL)
        XCTAssertEqual(cleaned.count, original.count)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNil(cleaned.range(of: Data("Fixture Album".utf8)))
        for value in retained { XCTAssertNotNil(cleaned.range(of: Data(value.utf8))) }
        for index in original.indices where !scan.edits.contains(where: { UInt64(index) >= $0.offset && UInt64(index) < $0.offset + $0.length }) {
            XCTAssertEqual(cleaned[index], original[index])
        }
        XCTAssertFalse(try MediaScanner.scan(url: result.outputURL).canClean)
    }
    private func freeform(mean: String, name: String, value: String) -> Data {
        atom("----", atom("mean", be32(0) + Data(mean.utf8)) + atom("name", be32(0) + Data(name.utf8))
             + atom("data", be32(1) + be32(0) + Data(value.utf8)))
    }
    private func item(_ type: Data, _ text: String) -> Data { atom(type, atom("data", be32(1) + be32(0) + Data(text.utf8))) }
    private func atom(_ type: String, _ payload: Data) -> Data { atom(Data(type.utf8), payload) }
    private func atom(_ type: Data, _ payload: Data) -> Data { be32(UInt32(payload.count + 8)) + type + payload }
    private func be32(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
}
