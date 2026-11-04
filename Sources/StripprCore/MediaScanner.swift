import Foundation

public enum MediaScanner {
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "m4a", "avi", "mpg", "mpeg", "mpe", "vob", "ts", "mts", "m2ts", "mkv", "webm", "wmv", "asf", "flv", "3gp", "3g2"]

    public static func scan(url: URL, cancellation: CancellationToken = CancellationToken(), keepEncoderInfo: Bool = true) throws -> ScanResult {
        try cancellation.check()
        let identity = try SourceIdentity.read(url)
        guard identity.size >= 8 else { throw StripprError.invalidFile("File is too short.") }
        let reader = try MediaReader(url: url, size: identity.size, cancellation: cancellation)
        defer { try? reader.handle.close() }
        let head = try reader.read(0, count: Int(min(16, identity.size)))
        let state = ScanState(reader: reader, keepEncoderInfo: keepEncoderInfo)
        if !keepEncoderInfo {
            state.warnings.append("Only supported container encoder/software fields are removable. Codec/bitstream encoder identifiers and essential encoding parameters are preserved.")
        }
        let format: String
        if head.prefix(4) == Data("RIFF".utf8), head.count >= 12, head.subdata(in: 8..<12) == Data("AVI ".utf8) {
            format = "AVI"
            try state.scanAVI()
        } else if head.prefix(4) == Data([0x1a, 0x45, 0xdf, 0xa3]) {
            format = url.pathExtension.lowercased() == "webm" ? "WebM" : "Matroska"
            state.warnings.append("Read only: Matroska/WebM metadata is not safely editable by this version. Embedded tags are not inventoried; no file will be modified.")
        } else if head.prefix(3) == Data([0, 0, 1]) || (head[0] == 0x47 && ["ts", "mts", "m2ts"].contains(url.pathExtension.lowercased())) {
            format = "MPEG"
            state.warnings.append("Read only: MPEG program/transport streams are scanned for file identity only. No safe supported tag edits; embedded metadata is not inventoried. Tracks are never remuxed or dropped.")
        } else {
            let type = String(decoding: head[4..<8], as: UTF8.self)
            guard ["ftyp", "moov", "mdat", "free", "wide", "skip", "uuid", "pnot"].contains(type) else {
                throw StripprError.unsupported("Read only: this container is not supported. No metadata inventory or edits are available.")
            }
            format = url.pathExtension.lowercased() == "mov" ? "QuickTime MOV" : "ISO MP4"
            let atoms = try reader.atoms(0, end: identity.size)
            guard atoms.contains(where: { $0.type == Data("moov".utf8) }) else {
                throw StripprError.invalidFile("No movie atom (moov) was found; incomplete files are not editable.")
            }
            try state.scanAtoms(atoms, context: "root", depth: 0)
        }
        try cancellation.check()
        guard try SourceIdentity.read(url) == identity else { throw StripprError.sourceChanged }
        let edits = state.edits.sorted { $0.offset < $1.offset }
        for index in edits.indices.dropFirst() {
            guard edits[index - 1].offset + edits[index - 1].length <= edits[index].offset else {
                throw StripprError.invalidFile("Overlapping metadata ranges.")
            }
        }
        return ScanResult(url: url, format: format, fileSize: identity.size, tags: state.tags,
                          edits: edits, warnings: state.warnings, keepEncoderInfo: keepEncoderInfo, identity: identity)
    }
}

private struct Atom {
    let offset: UInt64
    let size: UInt64
    let headerSize: UInt64
    let type: Data
    let header: Data
    var payload: UInt64 { offset + headerSize }
    var end: UInt64 { offset + size }
    var name: String { String(data: type, encoding: .isoLatin1) ?? type.map { String(format: "%02x", $0) }.joined() }
}

private final class MediaReader {
    let handle: FileHandle
    let size: UInt64
    let cancellation: CancellationToken
    init(url: URL, size: UInt64, cancellation: CancellationToken) throws {
        self.handle = try FileHandle(forReadingFrom: url); self.size = size; self.cancellation = cancellation
    }
    func read(_ offset: UInt64, count: Int) throws -> Data {
        try cancellation.check()
        guard offset <= size, count >= 0, UInt64(count) <= size - offset else {
            throw StripprError.invalidFile("Read exceeds file bounds.")
        }
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: count) ?? Data()
        guard bytes.count == count else { throw StripprError.invalidFile("Unexpected end of file.") }
        return bytes
    }
    func atoms(_ start: UInt64, end: UInt64) throws -> [Atom] {
        guard start <= end, end <= size else { throw StripprError.invalidFile("Invalid container bounds.") }
        var result: [Atom] = []
        var offset = start
        while offset < end {
            guard end - offset >= 8 else { throw StripprError.invalidFile("Truncated atom header at \(offset).") }
            var h = try read(offset, count: 8)
            let shortSize = h.uint32BE()
            var headerSize: UInt64 = 8
            let atomSize: UInt64
            if shortSize == 1 {
                guard end - offset >= 16 else { throw StripprError.invalidFile("Truncated extended atom size.") }
                h.append(try read(offset + 8, count: 8)); headerSize = 16; atomSize = h.uint64BE(8)
            } else if shortSize == 0 { atomSize = end - offset }
            else { atomSize = UInt64(shortSize) }
            guard atomSize >= headerSize, atomSize <= end - offset else {
                throw StripprError.invalidFile("Invalid atom length at \(offset).")
            }
            result.append(Atom(offset: offset, size: atomSize, headerSize: headerSize, type: h.subdata(in: 4..<8), header: h))
            guard result.count <= 200_000 else { throw StripprError.invalidFile("Excessive atom count.") }
            offset += atomSize
        }
        return result
    }
}

private final class ScanState {
    let reader: MediaReader
    var tags: [MetadataTag] = []
    var edits: [MetadataEdit] = []
    var warnings: [String] = []
    let keepEncoderInfo: Bool
    init(reader: MediaReader, keepEncoderInfo: Bool) { self.reader = reader; self.keepEncoderInfo = keepEncoderInfo }

    // Finite descriptive allowlists. Sources and exclusions are documented in
    // docs/METADATA-SUPPORT.md. These names are interpreted only inside metadata containers.
    private let atomNames: [String: String] = [
        "©nam": "Title", "©ART": "Artist", "©aut": "Author", "aART": "Album artist", "©alb": "Album",
        "©cmt": "Comment", "desc": "Description", "ldes": "Long description", "sdes": "Store description",
        "©gen": "Genre", "gnre": "Genre", "©day": "Date", "©wrt": "Composer", "©com": "Composer",
        "cprt": "Copyright", "©cpy": "Copyright", "©grp": "Grouping", "©lyr": "Lyrics",
        "©mak": "Camera make", "©mod": "Camera model", "©swr": "Software description", "©xyz": "Location",
        "name": "Title", "titl": "Title", "auth": "Author", "dscp": "Description", "perf": "Performer",
        "albm": "Album", "yrrc": "Year", "kywd": "Keywords", "keyw": "Keywords", "catg": "Category",
        "purd": "Purchase date", "©url": "URL", "©src": "Source", "©hst": "Host computer", "©des": "Description",
        "covr": "Artwork", "tvsh": "TV show", "tven": "TV episode identifier", "tvnn": "TV network",
        "tvsn": "TV season", "tves": "TV episode number", "trkn": "Track number", "disk": "Disc number",
        "©trk": "Track number", "cpil": "Compilation", "rtng": "Content advisory", "rate": "Rating", "tmpo": "Tempo",
        "pcst": "Podcast", "purl": "Podcast URL", "egid": "Podcast episode identifier",
        "snam": "Sort title", "sonm": "Sort title", "soar": "Sort artist", "soal": "Sort album",
        "soco": "Sort composer", "soaa": "Sort album artist", "sosn": "Sort TV show",
        "©pub": "Publisher", "©dir": "Director", "©prd": "Producer", "©PRD": "Producer",
        "©arg": "Arranger", "©ard": "Art director", "©con": "Conductor", "©sol": "Soloist",
        "©sne": "Sound engineer", "©xpd": "Executive producer", "©ope": "Original artist", "©prf": "Performers",
        "©inf": "Information", "©lnt": "Liner notes", "©phg": "Phonogram rights", "©thx": "Acknowledgements",
        "©wrk": "Work", "©mvn": "Movement name", "©mvi": "Movement number", "©mvc": "Movement count",
        "shwm": "Show work and movement", "©st3": "Work subtitle"
    ]
    private let mdtaNames: [String: String] = [
        "com.apple.quicktime.title": "Title", "com.apple.quicktime.artist": "Artist", "com.apple.quicktime.album": "Album",
        "com.apple.quicktime.author": "Author", "com.apple.quicktime.comment": "Comment",
        "com.apple.quicktime.description": "Description", "com.apple.quicktime.displayname": "Display name",
        "com.apple.quicktime.keywords": "Keywords", "com.apple.quicktime.copyright": "Copyright",
        "com.apple.quicktime.creationdate": "Creation date", "com.apple.quicktime.location.ISO6709": "Location",
        "com.apple.quicktime.location.name": "Location name", "com.apple.quicktime.location.body": "Location body",
        "com.apple.quicktime.location.note": "Location note", "com.apple.quicktime.location.role": "Location role",
        "com.apple.quicktime.location.date": "Location date", "com.apple.quicktime.location.accuracy.horizontal": "Location accuracy",
        "com.apple.quicktime.make": "Camera make", "com.apple.quicktime.model": "Camera model",
        "com.apple.quicktime.genre": "Genre", "com.apple.quicktime.publisher": "Publisher",
        "com.apple.quicktime.director": "Director", "com.apple.quicktime.information": "Information",
        "title": "Title", "artist": "Artist", "album": "Album", "album_artist": "Album artist", "albumartist": "Album artist",
        "comment": "Comment", "description": "Description", "synopsis": "Synopsis", "copyright": "Copyright",
        "date": "Date", "genre": "Genre", "author": "Author", "composer": "Composer", "grouping": "Grouping",
        "lyrics": "Lyrics", "keywords": "Keywords", "category": "Category", "publisher": "Publisher",
        "director": "Director", "producer": "Producer", "performer": "Performer", "lyricist": "Lyricist",
        "conductor": "Conductor", "arranger": "Arranger", "track": "Track number", "disc": "Disc number",
        "compilation": "Compilation", "bpm": "Tempo", "rating": "Rating", "show": "TV show",
        "episode_id": "TV episode identifier", "episode_sort": "TV episode number", "season_number": "TV season",
        "network": "TV network", "sort_name": "Sort title", "sort_artist": "Sort artist", "sort_album": "Sort album",
        "sort_album_artist": "Sort album artist", "sort_composer": "Sort composer", "sort_show": "Sort TV show"
    ]
    private let freeformNames: [String: String] = [
        "album": "Album", "title": "Title", "artist": "Artist", "albumartist": "Album artist", "composer": "Composer",
        "comment": "Comment", "description": "Description", "lyrics": "Lyrics", "genre": "Genre", "date": "Date",
        "copyright": "Copyright", "grouping": "Grouping", "label": "Label", "publisher": "Publisher", "mood": "Mood",
        "lyricist": "Lyricist", "conductor": "Conductor", "remixer": "Remixer", "engineer": "Engineer",
        "producer": "Producer", "djmixer": "DJ mixer", "mixer": "Mixer", "artists": "Artists",
        "director": "Director", "director_of_photography": "Director of photography",
        "production_designer": "Production designer", "costume_designer": "Costume designer",
        "screenplay_by": "Screenwriter", "edited_by": "Editor", "actors": "Actors",
        "subtitle": "Work subtitle", "discsubtitle": "Disc subtitle", "tracknumber": "Track number", "discnumber": "Disc number",
        "originalyear": "Original year", "originaldate": "Original date", "releasedate": "Release date",
        "catalognumber": "Catalog number", "barcode": "Barcode", "isrc": "ISRC", "asin": "ASIN",
        "rating": "Rating", "itunextc": "Content rating", "license": "License",
        "musicbrainz track id": "MusicBrainz track ID", "musicbrainz artist id": "MusicBrainz artist ID",
        "musicbrainz album id": "MusicBrainz album ID", "musicbrainz album artist id": "MusicBrainz album artist ID",
        "musicbrainz release group id": "MusicBrainz release group ID", "musicbrainz release track id": "MusicBrainz release track ID",
        "musicbrainz work id": "MusicBrainz work ID", "musicbrainz album release country": "MusicBrainz release country",
        "musicbrainz album status": "MusicBrainz album status", "musicbrainz album type": "MusicBrainz album type"
    ]

    func scanAtoms(_ atoms: [Atom], context: String, depth: Int) throws {
        guard depth < 16 else { throw StripprError.invalidFile("Metadata nesting is too deep.") }
        for atom in atoms {
            try reader.cancellation.check()
            let type = atom.name
            if ["free", "skip", "wide"].contains(type) { continue }
            if context == "ilst" {
                try addMetadata(atom, key: type, displayName: atomNames[type], iTunes: true)
            } else if type == "moov" || (type == "trak" && context == "moov") || (type == "udta" && ["moov", "trak"].contains(context)) {
                try scanAtoms(reader.atoms(atom.payload, end: atom.end), context: type, depth: depth + 1)
            } else if type == "meta" && ["root", "moov", "trak", "udta"].contains(context) {
                try scanMeta(atom, depth: depth + 1)
            } else if context == "udta" {
                try addMetadata(atom, key: type, displayName: atomNames[type], iTunes: false)
            }
        }
    }

    func scanMeta(_ meta: Atom, depth: Int) throws {
        guard meta.size - meta.headerSize >= 4 else { throw StripprError.invalidFile("Truncated meta full box.") }
        let full = try reader.read(meta.payload, count: 4)
        // A version/flags prefix of zero is the normal ISO full-box form. Some QuickTime files omit it.
        let childStart = full == Data(repeating: 0, count: 4) ? meta.payload + 4 : meta.payload
        let children = try reader.atoms(childStart, end: meta.end)
        var keyMap: [UInt32: String] = [:]
        if let keys = children.first(where: { $0.name == "keys" }) {
            guard keys.end - keys.payload >= 8 else { throw StripprError.invalidFile("Truncated metadata key table.") }
            let head = try reader.read(keys.payload, count: 8)
            guard head.uint32BE(0) == 0 else { throw StripprError.invalidFile("Unsupported metadata keys version.") }
            let count = head.uint32BE(4)
            guard count <= 100_000 else { throw StripprError.invalidFile("Excessive metadata keys.") }
            var position = keys.payload + 8
            for index in 0..<count {
                guard position <= keys.end, keys.end - position >= 8 else { throw StripprError.invalidFile("Truncated metadata key.") }
                let h = try reader.read(position, count: 8)
                let length = UInt64(h.uint32BE())
                guard length >= 8, length <= keys.end - position else { throw StripprError.invalidFile("Invalid metadata key length.") }
                if h.subdata(in: 4..<8) == Data("mdta".utf8), length <= 16_384 {
                    let name = try reader.read(position + 8, count: Int(length - 8))
                    if let text = String(data: name, encoding: .utf8) { keyMap[index + 1] = text }
                }
                position += length
            }
            guard position == keys.end else { throw StripprError.invalidFile("Metadata key table has unexplained bytes.") }
        }
        for child in children where child.name == "ilst" {
            for item in try reader.atoms(child.payload, end: child.end) {
                if item.name == "free" || item.name == "skip" { continue }
                let index = item.type.uint32BE()
                if let key = keyMap[index] {
                    try addMetadata(item, key: key, displayName: metadataName(forKey: key), iTunes: true)
                } else if index < 0x0100_0000 && !keyMap.isEmpty {
                    try addMetadata(item, key: "Unknown metadata key \(index)", displayName: nil, iTunes: true)
                } else {
                    try addMetadata(item, key: item.name, displayName: atomNames[item.name], iTunes: true)
                }
            }
        }
        for child in children where !["ilst", "keys", "hdlr", "free", "skip"].contains(child.name) {
            tags.append(MetadataTag(id: "atom-\(child.offset)", key: "Metadata atom \(child.name)", value: "\(child.size - child.headerSize) bytes", removable: false, reason: "Unknown or structural metadata is retained."))
        }
    }

    func metadataName(forKey key: String) -> String? {
        // mdta names are text keys; writers may use uppercase generic names such as ALBUM.
        // Only the existing descriptive allowlist is matched, never arbitrary key substrings.
        mdtaNames[key] ?? mdtaNames.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    func freeformIdentity(_ atom: Atom) throws -> (namespace: String, name: String, isText: Bool)? {
        let children = try reader.atoms(atom.payload, end: atom.end)
        guard children.allSatisfy({ ["mean", "name", "data"].contains($0.name) }),
              children.filter({ $0.name == "mean" }).count == 1,
              children.filter({ $0.name == "name" }).count == 1,
              children.filter({ $0.name == "data" }).count == 1,
              let mean = children.first(where: { $0.name == "mean" }),
              let name = children.first(where: { $0.name == "name" }),
              let data = children.first(where: { $0.name == "data" }), data.end - data.payload >= 8 else { return nil }
        func text(_ child: Atom) throws -> String? {
            guard child.end - child.payload >= 4, child.end - child.payload <= 16_384,
                  try reader.read(child.payload, count: 4) == Data(repeating: 0, count: 4) else { return nil }
            return String(data: try reader.read(child.payload + 4, count: Int(child.end - child.payload - 4)), encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        }
        guard let namespace = try text(mean), let name = try text(name) else { return nil }
        let type = try reader.read(data.payload, count: 4).uint32BE()
        return (namespace, name, type == 1 || type == 2)
    }

    func addMetadata(_ atom: Atom, key: String, displayName: String?, iTunes: Bool) throws {
        var resolvedName = displayName
        var visibleKey = key
        var semanticKey = key.lowercased()
        if key == "----", iTunes, let freeform = try freeformIdentity(atom) {
            visibleKey = "\(freeform.namespace) / \(freeform.name)"
            if freeform.namespace == "com.apple.iTunes" {
                semanticKey = freeform.name.lowercased()
                resolvedName = freeform.isText ? freeformNames[semanticKey] : nil
            }
        }
        let encoder = ["©too", "©enc", "©swr", "com.apple.quicktime.software", "com.apple.quicktime.encoded_with",
                       "encoder", "encoding_tool", "encoding", "encodedby", "encoded_by", "encoding params", "tool", "tool name", "tool version"].contains(semanticKey)
        let playback = ["pgap", "gaplessplayback", "gapless_playback", "itunsmpb", "itunpgap", "itunnorm", "hdvd", "stik",
                        "r128_track_gain", "r128_album_gain"].contains(semanticKey) || semanticKey.hasPrefix("replaygain_")
        let artwork = key == "covr"
        // Only these container-level fields can be removed by the encoder switch.
        // Freeform encoding parameters, stream descriptions, and bitstream encoder labels stay intact.
        let safeEncoderField = key != "----" && ["©too", "©enc", "©swr", "com.apple.quicktime.software", "encoder", "encoding_tool"].contains(key.lowercased())
        let removeEncoder = !keepEncoderInfo && safeEncoderField
        let removable = ((resolvedName != nil && !encoder) || removeEncoder) && !playback && !artwork
        let value = try value(atom, iTunes: iTunes)
        let reason: String
        if removeEncoder { reason = "Supported container encoder/software field; removed because Keep encoder info is off." }
        else if removable { reason = "Supported descriptive field; removed from cleaned copy." }
        else if encoder { reason = "Encoder information is preserved." }
        else if playback { reason = "Playback, normalization, or media classification information is preserved." }
        else if artwork { reason = "Embedded artwork is preserved because it may be exposed as an attached image stream." }
        else { reason = "Unrecognized or structural metadata is retained." }
        tags.append(MetadataTag(id: "atom-\(atom.offset)", key: encoder ? "Encoder / \(visibleKey)" : (resolvedName ?? visibleKey), value: value, removable: removable, reason: reason))
        if removable {
            var header = atom.header
            header.replaceSubrange(4..<8, with: Data("free".utf8))
            edits.append(MetadataEdit(offset: atom.offset, length: atom.size, replacementHeader: header))
        }
    }

    func value(_ atom: Atom, iTunes: Bool) throws -> String {
        let length = atom.end - atom.payload
        if atom.name == "covr" { return "Embedded artwork (\(length) bytes)" }
        var valueStart = atom.payload
        var valueLength = length
        var dataType: UInt32 = 1
        if iTunes {
            let children = try reader.atoms(atom.payload, end: atom.end)
            if let data = children.first(where: { $0.name == "data" }), data.end - data.payload >= 8 {
                let header = try reader.read(data.payload, count: 8)
                dataType = header.uint32BE() & 0x00ff_ffff
                valueStart = data.payload + 8; valueLength = data.end - valueStart
            } else { return "Structured metadata (\(length) bytes)" }
        }
        let bytes = try reader.read(valueStart, count: Int(min(valueLength, 4096)))
        if iTunes, ["trkn", "disk"].contains(atom.name), bytes.count >= 6 {
            let number = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            let total = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
            return total > 0 ? "\(number) / \(total)" : "\(number)"
        }
        if iTunes, [21, 22].contains(dataType), (1...8).contains(bytes.count) {
            let integer = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            if dataType == 21, bytes[0] & 0x80 != 0 {
                let signed = bytes.count == 8 ? integer : integer | (~UInt64(0) << (bytes.count * 8))
                return String(Int64(bitPattern: signed))
            }
            return String(integer)
        }
        var text: String?
        if dataType == 2 { text = String(data: bytes, encoding: .utf16BigEndian) }
        else { text = String(data: bytes, encoding: .utf8) }
        if !iTunes, bytes.count >= 4 {
            let declared = Int(bytes[0]) * 256 + Int(bytes[1])
            if declared > 0, declared <= bytes.count - 4 {
                text = String(data: bytes.subdata(in: 4..<4+declared), encoding: .utf8)
                    ?? String(data: bytes.subdata(in: 4..<4+declared), encoding: .macOSRoman)
            }
        }
        if let text {
            let clean = text.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
            if !clean.isEmpty, clean.unicodeScalars.filter({ CharacterSet.controlCharacters.contains($0) }).count < 3 {
                return clean + (valueLength > 4096 ? " … (truncated preview)" : "")
            }
        }
        return "Binary / structured value (\(valueLength) bytes)"
    }

    func scanAVI() throws {
        var root: UInt64 = 0
        var segments = 0
        while root < reader.size {
            guard reader.size - root >= 12 else { throw StripprError.invalidFile("Truncated RIFF segment.") }
            let h = try reader.read(root, count: 12)
            guard h.prefix(4) == Data("RIFF".utf8), [Data("AVI ".utf8), Data("AVIX".utf8)].contains(h.subdata(in: 8..<12)) else {
                throw StripprError.invalidFile("Unexpected data after AVI RIFF segment.")
            }
            let length = UInt64(h.uint32LE(4))
            guard length >= 4, length <= reader.size - root - 8 else { throw StripprError.invalidFile("Invalid AVI segment length.") }
            try scanRIFF(root + 12, end: root + 8 + length, inInfo: false, depth: 0)
            root += 8 + length + (length % 2)
            segments += 1
            guard segments < 100_000 else { throw StripprError.invalidFile("Excessive AVI segments.") }
        }
    }

    func scanRIFF(_ start: UInt64, end: UInt64, inInfo: Bool, depth: Int) throws {
        guard depth < 16 else { throw StripprError.invalidFile("Excessive RIFF nesting.") }
        let names = ["INAM": "Title", "IART": "Artist", "ICMT": "Comment", "IPRD": "Product / album", "ICRD": "Creation date", "ICOP": "Copyright", "IGNR": "Genre", "ISBJ": "Subject", "IKEY": "Keywords", "ISRC": "Source", "IENG": "Engineer", "ITCH": "Technician", "ICMS": "Commissioned by", "IARL": "Archival location"]
        var position = start
        var count = 0
        while position < end {
            guard end - position >= 8 else { throw StripprError.invalidFile("Truncated RIFF chunk.") }
            let h = try reader.read(position, count: 8)
            let name = String(data: h.prefix(4), encoding: .ascii) ?? "????"
            let length = UInt64(h.uint32LE(4))
            guard length <= end - position - 8 else { throw StripprError.invalidFile("Invalid RIFF chunk length.") }
            let next = position + 8 + length + (length % 2)
            guard next <= end else { throw StripprError.invalidFile("Missing RIFF alignment byte.") }
            if name == "LIST" {
                guard length >= 4 else { throw StripprError.invalidFile("Truncated RIFF LIST.") }
                let listType = try reader.read(position + 8, count: 4)
                if listType == Data("INFO".utf8) {
                    try scanRIFF(position + 12, end: position + 8 + length, inInfo: true, depth: depth + 1)
                }
                // Do not descend into movi/rec or interpret video payload as tags.
            } else if inInfo && name != "JUNK" {
                let bytes = try reader.read(position + 8, count: Int(min(length, 4096)))
                let value = (String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252) ?? "Binary value").trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
                let removeEncoder = name == "ISFT" && !keepEncoderInfo
                let removable = names[name] != nil || removeEncoder
                tags.append(MetadataTag(id: "riff-\(position)", key: name == "ISFT" ? "Encoder / ISFT" : (names[name] ?? name), value: value.isEmpty ? "Empty value" : value, removable: removable,
                                        reason: removeEncoder ? "Supported container encoder/software field; removed because Keep encoder info is off." : (removable ? "Supported RIFF INFO field; removed from cleaned copy." : (name == "ISFT" ? "Encoder information is preserved." : "Unrecognized RIFF INFO field is retained."))))
                if removable {
                    var header = Data("JUNK".utf8); header.append(h.subdata(in: 4..<8))
                    edits.append(MetadataEdit(offset: position, length: 8 + length, replacementHeader: header))
                }
            }
            position = next; count += 1
            guard count <= 200_000 else { throw StripprError.invalidFile("Excessive RIFF chunks.") }
        }
    }
}
