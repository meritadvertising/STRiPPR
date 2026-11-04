import SwiftUI

struct BatchControls: View {
    @Bindable var store: BatchStore

    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 14) {
                Toggle("Keep originals", isOn: Binding(get: { store.keepOriginals }, set: { store.setKeepOriginals($0) }))
                    .help("Save cleaned copies and leave the original files in place.")
                Toggle("Keep encoder info", isOn: Binding(get: { store.keepEncoderInfo }, set: { store.setKeepEncoderInfo($0) }))
                    .help("Container encoder/software tags; codec data stays unchanged.")
                Divider().frame(height: 16)
                if store.keepOriginals {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(Theme.cyan)
                        Text("Save copies:").foregroundStyle(.secondary)
                        Text(store.outputDirectory?.path ?? "Beside originals")
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            .layoutPriority(-1)
                            .help(store.outputDirectory?.path ?? "Save beside each original file")
                        Button("Choose folder…") { store.chooseDestination() }.controlSize(.small)
                        if store.outputDirectory != nil {
                            Button("Reset") { store.outputDirectory = nil }.buttonStyle(.borderless)
                        }
                    }
                } else {
                    Label("Replace originals · confirmation required", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.pink).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .toggleStyle(.checkbox).font(.system(size: 11, weight: .medium))
            .fixedSize(horizontal: false, vertical: true).disabled(store.isBusy)

            HStack {
                Text(store.keepEncoderInfo ? "Supported descriptive tags only. Encoder info stays." : "Supported descriptive and container encoder tags. Stream data stays intact.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 12)
                Button { store.clean() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                        Text(store.isBusy && !store.isScanning ? "STRiPPING…" : (store.keepOriginals ? "STRIP SUPPORTED TAGS" : "STRIP & REPLACE ORIGINALS"))
                            .tracking(0.7)
                        if store.readyCount > 0 { Text("\(store.readyCount)").foregroundStyle(.black.opacity(0.6)) }
                    }
                    .font(.system(size: 12, weight: .heavy))
                    .padding(.horizontal, 20).padding(.vertical, 15)
                    .foregroundStyle(store.readyCount == 0 || store.isBusy ? Color.secondary : Color.black)
                    .background(store.readyCount == 0 || store.isBusy ? Color.white.opacity(0.06) : Theme.cyan, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain).disabled(store.isBusy || store.readyCount == 0)
                .help("Process every ready file in the queue, including rows hidden by the filter.")
                .accessibilityLabel(store.keepOriginals ? "Strip supported tags" : "Strip tags and replace originals")
            }
        }
    }
}
