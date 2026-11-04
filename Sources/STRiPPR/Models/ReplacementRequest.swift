import Foundation

struct ReplacementRequest: Identifiable {
    let id = UUID()
    let files: [FileItem]
    let keepEncoderInfo: Bool

    var message: String {
        let paths = files.prefix(6).map { $0.url.path }.joined(separator: "\n")
        let remaining = files.count > 6 ? "\n…and \(files.count - 6) more ready files in this batch." : ""
        let encoder = keepEncoderInfo ? "Encoder information will be kept." : "Supported container encoder/software tags will also be removed."
        return "Replace \(files.count) original \(files.count == 1 ? "file" : "files") at the current paths? This includes ready files hidden by a list filter. No separate original copy or automatic backup is kept after a successful replacement. Each cleaned file is fully verified first. If this volume cannot safely replace originals, STRiPPR keeps the original and saves a cleaned copy in a new folder with a visible warning. A destination-refused com.apple.provenance attribute may be omitted with a security-tracking warning; other required attributes must be preserved.\n\n\(paths)\(remaining)\n\n\(encoder)"
    }
}
