import Foundation
import StripprCore

enum FilePhase: String {
    case scanning = "Scanning", ready = "Ready", inspected = "Inspected", readOnly = "Read only"
    case cleaning = "Cleaning", verified = "Verified copy", failed = "Failed", cancelled = "Cancelled"
}

struct FileItem: Identifiable {
    let id: UUID
    let url: URL
    var scan: ScanResult?
    var phase: FilePhase = .scanning
    var progress: Double = 0
    var detail = "Reading metadata…"
    var output: URL?
    var didReplaceOriginal = false
    var outcomeWarnings: [String] = []
    var expanded = false

    var removableCount: Int { scan?.tags.filter(\.removable).count ?? 0 }
    var sizeLabel: String {
        guard let size = scan?.fileSize else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
