import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: BatchStore
    @StoredState private var dropTargeted = false
    private let logo = Bundle.main.url(forResource: "STRiPPR-logo", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        FileDropSurface(enabled: !store.isBusy, receive: store.add, hovering: { dropTargeted = $0 }) {
            mainContent
        }
        .frame(minWidth: 820, minHeight: 600)
        .alert(item: Binding(get: { store.replacementRequest }, set: { store.replacementRequest = $0 })) { request in
            Alert(
                title: Text("Replace original files?"),
                message: Text(request.message),
                primaryButton: .destructive(Text("Replace Originals")) { store.confirmReplacement(request) },
                secondaryButton: .cancel { store.cancelReplacement() }
            )
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 18) {
                batchProgress
                FilesQueue(store: store)
                BatchControls(store: store)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(minWidth: 820, minHeight: 600)
        .background(Theme.background)
        .tint(Theme.cyan)
        .contentShape(Rectangle())
        .overlay {
            if dropTargeted && !store.isBusy {
                RoundedRectangle(cornerRadius: 18).stroke(Theme.cyan, style: StrokeStyle(lineWidth: 3, dash: [8, 5])).padding(8).allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 24) {
            if let logo {
                Image(nsImage: logo).resizable().scaledToFit().frame(width: 255, height: 85).accessibilityLabel("STRiPPR")
            } else {
                Text("STRiPPR").font(.system(size: 39, weight: .black, design: .rounded)).italic().foregroundStyle(Theme.cyan)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Strip the tags. Keep the video.").font(.system(size: 18, weight: .semibold))
                Text(store.keepOriginals ? "Verified copies. Original quality. Zero re-encoding." : "Verified replacement. Original quality. Zero re-encoding.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button { store.clear() } label: {
                    Label("Clear", systemImage: "xmark.circle")
                        .frame(width: 164)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.pink)
                .foregroundStyle(.black)
                .disabled(store.isBusy || store.items.isEmpty)
                .keyboardShortcut(.delete, modifiers: [.command])
                .help("Clear the file list. Saved copies are kept.")
                .accessibilityLabel("Clear file list")

                Button { store.chooseFiles() } label: {
                    Label("Add Files or Folders", systemImage: "plus")
                        .frame(width: 164)
                }
                .buttonStyle(.bordered)
                .tint(Theme.cyan)
                .disabled(store.isBusy)
            }
            .font(.system(size: 12, weight: .semibold))
            .controlSize(.regular)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 17)
    }

    private var batchProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(store.isScanning ? "SCANNING" : "BATCH PROGRESS", systemImage: store.isScanning ? "magnifyingglass" : "waveform.path")
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(Theme.cyan)
                Spacer()
                Text(store.isBusy ? "\(Int(store.overallProgress * 100))%" : "\(store.verifiedCount) verified / \(store.items.count) \(store.items.count == 1 ? "file" : "files")")
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            ThinProgress(value: store.overallProgress, height: 6).accessibilityLabel("Overall batch progress")
            HStack {
                Text(store.activity).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if store.isBusy {
                    Button(store.isCancelling ? "Cancelling…" : "Cancel") { store.cancel() }.disabled(store.isCancelling)
                        .buttonStyle(.borderless).foregroundStyle(Theme.pink)
                }
            }
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

}
