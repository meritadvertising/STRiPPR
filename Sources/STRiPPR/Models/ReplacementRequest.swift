import Foundation

struct ReplacementRequest: Identifiable {
    let id = UUID()
    let files: [FileItem]
    let keepEncoderInfo: Bool

    var message: String {
        let paths = files.prefix(6).map { $0.url.path }.joined(separator: "\n")
        let remaining = files.count > 6 ? "\n…and \(files.count - 6) more ready files in this batch." : ""
        let encoder = keepEncoderInfo ? "Encoder information will be kept." : "Supported container encoder/software tags will also be removed."
        return "Replace \(files.count) original \(files.count == 1 ? "file" : "files") at the current paths? This includes ready files hidden by a list filter. No separate original copy or automatic backup will be kept. Each cleaned file is fully verified before its atomic replacement begins.\n\n\(paths)\(remaining)\n\n\(encoder)"
    }
}
