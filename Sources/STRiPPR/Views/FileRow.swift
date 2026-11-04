import AppKit
import SwiftUI

struct FileRow: View {
    @Binding var item: FileItem
    let busy: Bool
    let retry: () -> Void

    private var color: Color {
        switch item.phase {
        case .verified: return item.outcomeWarnings.isEmpty ? Theme.green : Theme.amber
        case .failed, .readOnly: return Theme.pink
        case .cancelled, .inspected: return .secondary
        default: return Theme.cyan
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "doc").font(.system(size: 23, weight: .light)).foregroundStyle(color).frame(width: 27)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 9) {
                        Text(item.scan?.format ?? item.url.pathExtension.uppercased())
                        Text(item.sizeLabel)
                        if item.removableCount > 0 { Text("\(item.removableCount) \(item.phase == .verified ? "removed" : "removable")").foregroundStyle(Theme.cyan) }
                    }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 5) {
                        if item.phase == .verified { Image(systemName: item.outcomeWarnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill") }
                        Text(item.phase == .verified && item.didReplaceOriginal ? "Verified replacement" : item.phase.rawValue)
                        if item.phase == .cleaning { Text("\(Int(item.progress * 100))%") }
                    }.font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                    Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 290, alignment: .trailing)
                }
                Button { item.expanded.toggle() } label: {
                    Image(systemName: item.expanded ? "chevron.up" : "chevron.down").frame(width: 22, height: 26)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(item.expanded ? "Hide metadata for \(item.url.lastPathComponent)" : "Show metadata for \(item.url.lastPathComponent)")
            }
            .padding(.horizontal, 18).padding(.vertical, 15)
            if !item.outcomeWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(item.outcomeWarnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(Theme.amber)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 12)
                .accessibilityLabel("Saved with warnings")
            }
            if item.phase == .cleaning || item.phase == .verified || item.phase == .cancelled {
                ThinProgress(value: item.progress, color: color, height: 2).padding(.horizontal, 18).padding(.bottom, 10)
                    .accessibilityLabel("File progress")
            }
            if item.expanded { details }
        }
        .contextMenu {
            Button("Show Source in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            if let output = item.output { Button(item.didReplaceOriginal ? "Show Verified Replacement in Finder" : "Show Verified Copy in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
            if item.phase == .cancelled || item.phase == .failed { Button("Rescan and Queue Again", action: retry).disabled(busy) }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.url.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if let scan = item.scan {
                ForEach(Array(scan.tags.enumerated()), id: \.offset) { _, tag in
                    HStack(alignment: .top, spacing: 12) {
                        Text(tag.removable ? (item.phase == .verified ? "REMOVED" : "REMOVE") : "KEEP")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(tag.removable ? Theme.cyan : Theme.pink).frame(width: 58, alignment: .leading)
                        Text(tag.key).font(.system(size: 11, weight: .medium)).frame(width: 120, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tag.value).font(.system(size: 11)).textSelection(.enabled)
                            if !tag.removable { Text(tag.reason).font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                }
                if scan.tags.isEmpty {
                    Text("No recognized descriptive tags. This is a limited metadata scan; it does not certify that every kind of metadata is absent.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(Array(scan.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let output = item.output {
                HStack {
                    Text("\(item.didReplaceOriginal ? "Replaced" : "Copy"): \(output.path)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.green).textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }.buttonStyle(.borderless)
                }
            }
            if item.phase == .failed || item.phase == .cancelled {
                Text(item.detail).font(.system(size: 11)).foregroundStyle(Theme.pink).textSelection(.enabled)
                Button("Rescan and queue again", action: retry).disabled(busy)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 18).padding(.top, 3)
    }
}
