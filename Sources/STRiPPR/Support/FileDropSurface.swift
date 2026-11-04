import AppKit
import SwiftUI

/// A native file-URL destination around the SwiftUI content. Finder supplies
/// URLs through NSPasteboard; no promises, thumbnails, or media decoding needed.
struct FileDropSurface<Content: View>: NSViewRepresentable {
    let enabled: Bool
    let receive: ([URL]) -> Void
    let hovering: (Bool) -> Void
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> FileDropHostingView<Content> {
        let view = FileDropHostingView(rootView: content())
        configure(view)
        return view
    }

    func updateNSView(_ view: FileDropHostingView<Content>, context: Context) {
        view.rootView = content()
        configure(view)
    }

    private func configure(_ view: FileDropHostingView<Content>) {
        view.dropEnabled = enabled
        view.receiveFiles = receive
        view.hovering = hovering
    }
}

final class FileDropHostingView<Content: View>: NSHostingView<Content> {
    var dropEnabled = true
    var receiveFiles: ([URL]) -> Void = { _ in }
    var hovering: (Bool) -> Void = { _ in }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @MainActor required init?(coder: NSCoder) { nil }

    private func files(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = dropEnabled && !files(sender).isEmpty
        hovering(accepted)
        return accepted ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropEnabled && !files(sender).isEmpty ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hovering(false) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropEnabled && !files(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovering(false)
        let urls = files(sender)
        guard dropEnabled, !urls.isEmpty else { return false }
        receiveFiles(urls)
        return true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) { hovering(false) }
}
