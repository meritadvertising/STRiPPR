import XCTest
import Foundation
@testable import StripprCore

final class MetadataCoverageTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("STRiPPR-coverage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testCatalogNumbersCreditsAndSortValuesAreRemovedWithoutTouchingPlaybackFields() throws {
        let descriptions: [(String, String)] = [
            ("tvnn", "Remove TV network"), ("sosn", "Remove sort show"), ("purl", "Remove podcast URL"),
            ("egid", "Remove episode identifier"), ("©pub", "Remove publisher"), ("©dir", "Remove director"),
            ("©prd", "Remove producer"), ("©PRD", "Remove alternate producer"), ("©aut", "Remove author"),
            ("©com", "Remove composer"), ("©arg", "Remove arranger"), ("©con", "Remove conductor"),
            ("©wrk", "Remove work"), ("©mvn", "Remove movement name"), ("©lyr", "Remove lyrics")
        ]
        var items = descriptions.map { item($0.0, Data($0.1.utf8)) }.reduce(Data(), +)
        items += item("trkn", Data([0, 0, 0, 3, 0, 12, 0, 0]), type: 0)
        items += item("disk", Data([0, 0, 0, 2, 0, 4]), type: 0)
        for (key, value) in [("tvsn", 2), ("tves", 4), ("cpil", 1), ("rtng", 2), ("tmpo", 120), ("pcst", 1), ("©mvi", 2), ("©mvc", 3), ("shwm", 1)] {
            items += item(key, be32(UInt32(value)), type: 21)
        }
        items += item("pgap", Data([1]), type: 21) + item("stik", Data([10]), type: 21) + item("hdvd", Data([1]), type: 21)
        items += item("©too", Data("Keep Encoder".utf8)) + item("covr", Data([0xff, 0xd8, 0xff, 0xd9]), type: 13)
        let verified = try verify(items: items, expectedRemovable: descriptions.count + 11)
        for (_, value) in descriptions { XCTAssertNil(verified.clean.range(of: Data(value.utf8))) }
        XCTAssertTrue(verified.scan.tags.contains { $0.key == "Track number" && $0.value == "3 / 12" })
        XCTAssertTrue(verified.scan.tags.contains { $0.key == "Disc number" && $0.value == "2 / 4" })
        XCTAssertTrue(verified.scan.tags.contains { $0.key == "TV season" && $0.value == "2" })
        for key in ["pgap", "stik", "hdvd"] { XCTAssertTrue(verified.after.tags.contains { $0.key == key && !$0.removable }) }
        XCTAssertTrue(verified.after.tags.contains { $0.key == "Artwork" && !$0.removable })
        XCTAssertNotNil(verified.clean.range(of: Data("Keep Encoder".utf8)))
    }

    func testFiniteFreeformDescriptorsRemovedWhileTimingNormalizationAndEncoderRemain() throws {
        let removable = ["LABEL", "LYRICIST", "CONDUCTOR", "PRODUCER", "MusicBrainz Track Id", "MusicBrainz Album Id", "CATALOGNUMBER", "iTunEXTC"]
        let protected = ["iTunSMPB", "iTunNORM", "REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_ALBUM_PEAK", "Encoding Params", "ENCODER", "iTunMOVI", "unknown-private-field"]
        var items = removable.map { freeform(name: $0, value: "Remove \($0)") }.reduce(Data(), +)
        items += protected.map { freeform(name: $0, value: "Keep \($0)") }.reduce(Data(), +)
        items += freeform(namespace: "private.namespace", name: "LABEL", value: "Keep private namespace")
        let result = try verify(items: items, expectedRemovable: removable.count)
        for name in removable { XCTAssertNil(result.clean.range(of: Data("Remove \(name)".utf8))) }
        for name in protected { XCTAssertNotNil(result.clean.range(of: Data("Keep \(name)".utf8))) }
        XCTAssertNotNil(result.clean.range(of: Data("Keep private namespace".utf8)))
        XCTAssertTrue(result.after.tags.contains { $0.key.contains("iTunSMPB") && $0.reason.contains("Playback") })
        XCTAssertTrue(result.after.tags.contains { $0.key.contains("Encoding Params") && $0.reason.contains("Encoder") })
    }

    func testMdtaDescriptiveKeysAreDistinctFromLanguageOrientationColorAndPairedMediaIdentity() throws {
        let removable = ["publisher", "lyrics", "album_artist", "track", "disc", "show", "episode_id", "season_number", "com.apple.quicktime.director", "com.apple.quicktime.location.name"]
        let protected = ["language", "encoder", "com.apple.quicktime.video-orientation", "com.apple.quicktime.content.identifier", "com.apple.quicktime.camera.lens_model", "color_primaries"]
        let names = removable + protected
        let entries = names.map { be32(UInt32($0.utf8.count + 8)) + Data("mdta".utf8) + Data($0.utf8) }.reduce(Data(), +)
        let keys = atom("keys", be32(0) + be32(UInt32(names.count)) + entries)
        let items = names.enumerated().map { index, name in item(be32(UInt32(index + 1)), Data("\(index < removable.count ? "Remove" : "Keep") \(name)".utf8)) }.reduce(Data(), +)
        let result = try verify(items: items, keys: keys, expectedRemovable: removable.count)
        for key in protected { XCTAssertNotNil(result.clean.range(of: Data("Keep \(key)".utf8))) }
        for key in removable { XCTAssertNil(result.clean.range(of: Data("Remove \(key)".utf8))) }
    }

    func testDuplicateOrUnknownFreeformStructureNeverGrantsRemoval() throws {
        let malformed = atom("----", atom("mean", be32(0) + Data("com.apple.iTunes".utf8))
            + atom("name", be32(0) + Data("LABEL".utf8)) + atom("name", be32(0) + Data("Encoding Params".utf8))
            + atom("data", be32(1) + be32(0) + Data("Keep ambiguous freeform".utf8)))
        let binaryNamedLabel = atom("----", atom("mean", be32(0) + Data("com.apple.iTunes".utf8))
            + atom("name", be32(0) + Data("LABEL".utf8))
            + atom("data", be32(0) + be32(0) + Data("Keep unknown structured label".utf8)))
        let result = try verify(items: malformed + binaryNamedLabel + item("©nam", Data("Remove title".utf8)), expectedRemovable: 1)
        XCTAssertNotNil(result.clean.range(of: Data("Keep ambiguous freeform".utf8)))
        XCTAssertNotNil(result.clean.range(of: Data("Keep unknown structured label".utf8)))
    }

    func testNewlyRecognizedFourCCInsidePayloadOrTrackStructureIsNotMetadata() throws {
        let decoy = item("trkn", Data("Keep payload track marker".utf8)) + item("©dir", Data("Keep payload director".utf8))
        let extraMovie = atom("trak", item("©pub", Data("Keep nonmetadata publisher".utf8)))
        let result = try verify(items: item("©nam", Data("Remove title".utf8)), payload: decoy, extraMovie: extraMovie, expectedRemovable: 1)
        XCTAssertNotNil(result.clean.range(of: Data("Keep payload track marker".utf8)))
        XCTAssertNotNil(result.clean.range(of: Data("Keep payload director".utf8)))
        XCTAssertNotNil(result.clean.range(of: Data("Keep nonmetadata publisher".utf8)))
    }

    private func verify(items: Data, keys: Data = Data(), payload: Data = Data("Unchanged media bytes".utf8), extraMovie: Data = Data(), expectedRemovable: Int) throws -> (scan: ScanResult, clean: Data, after: ScanResult) {
        let original = atom("ftyp", Data("isom0000isom".utf8)) + atom("mdat", payload)
            + atom("moov", extraMovie + atom("udta", atom("meta", be32(0) + keys + atom("ilst", items))))
        let source = directory.appendingPathComponent("coverage.mp4")
        try original.write(to: source)
        let scan = try MediaScanner.scan(url: source)
        XCTAssertEqual(scan.removableTagCount, expectedRemovable)
        let result = try MediaCleaner.clean(scan)
        let clean = try Data(contentsOf: result.outputURL)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(clean.count, original.count)
        for index in original.indices where !scan.edits.contains(where: { UInt64(index) >= $0.offset && UInt64(index) < $0.offset + $0.length }) {
            XCTAssertEqual(clean[index], original[index], "Unapproved byte changed at \(index)")
        }
        let after = try MediaScanner.scan(url: result.outputURL)
        XCTAssertFalse(after.canClean)
        return (scan, clean, after)
    }
    private func freeform(namespace: String = "com.apple.iTunes", name: String, value: String) -> Data {
        atom("----", atom("mean", be32(0) + Data(namespace.utf8)) + atom("name", be32(0) + Data(name.utf8))
            + atom("data", be32(1) + be32(0) + Data(value.utf8)))
    }
    private func item(_ name: String, _ value: Data, type: UInt32 = 1) -> Data { item(Data(name.data(using: .isoLatin1)!), value, type: type) }
    private func item(_ name: Data, _ value: Data, type: UInt32 = 1) -> Data { atom(name, atom("data", be32(type) + be32(0) + value)) }
    private func atom(_ name: String, _ payload: Data) -> Data { atom(Data(name.utf8), payload) }
    private func atom(_ name: Data, _ payload: Data) -> Data { be32(UInt32(payload.count + 8)) + name + payload }
    private func be32(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
}
