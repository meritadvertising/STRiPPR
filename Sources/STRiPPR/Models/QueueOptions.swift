import Foundation

enum FileFilter: String, CaseIterable, Identifiable {
    case both, withTags, withoutTags

    var id: Self { self }
    var title: String {
        switch self {
        case .both: return "Both"
        case .withTags: return "With removable tags"
        case .withoutTags: return "Without removable tags"
        }
    }
    var shortTitle: String {
        switch self {
        case .both: return "Both"
        case .withTags: return "With tags"
        case .withoutTags: return "Without tags"
        }
    }
}

enum FileSort: String, CaseIterable, Identifiable {
    case name, removableTags, size, status

    var id: Self { self }
    var title: String {
        switch self {
        case .name: return "Name"
        case .removableTags: return "Removable tags"
        case .size: return "Size"
        case .status: return "Status"
        }
    }
}

enum QueueTagCategory: Equatable {
    case withTags, withoutTags, unknown
}

/// A row normally describes its source's latest valid scan. A verified copy does
/// not change that source. A verified replacement does, so its current count is 0.
/// Unsupported inventories and failed/cancelled rows with no positive evidence
/// stay unknown instead of being presented as having no removable metadata.
struct QueueEntry: Equatable {
    let id: UUID
    let url: URL
    let category: QueueTagCategory
    let removableTags: Int?
    let size: UInt64?
    let phase: FilePhase

    init(_ item: FileItem) {
        id = item.id
        url = item.url
        size = item.scan?.fileSize
        phase = item.phase
        if let scan = item.scan,
           item.phase != .scanning, item.phase != .readOnly,
           !scan.warnings.contains(where: { $0.hasPrefix("Read only:") }) {
            if item.phase == .verified && item.didReplaceOriginal {
                category = .withoutTags
                removableTags = 0
            } else if scan.removableTagCount > 0 {
                category = .withTags
                removableTags = scan.removableTagCount
            } else if item.phase != .failed && item.phase != .cancelled {
                category = .withoutTags
                removableTags = 0
            } else {
                category = .unknown
                removableTags = nil
            }
        } else {
            category = .unknown
            removableTags = nil
        }
    }

    // Alphabetical order of the displayed status names, without string work in
    // the sorting comparator. File name is the stable secondary sort key.
    var statusOrder: Int {
        switch phase {
        case .cancelled: return 0
        case .cleaning: return 1
        case .failed: return 2
        case .inspected: return 3
        case .readOnly: return 4
        case .ready: return 5
        case .scanning: return 6
        case .verified: return 7
        }
    }
}
