import AppKit
import SwiftUI

@main
struct STRiPPRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StoredState private var store = BatchStore()

    var body: some Scene {
        Window("STRiPPR", id: "main") {
            ContentView(store: store)
                .preferredColorScheme(.dark)
                .onAppear { delegate.store = store }
                .onOpenURL { store.add([$0]) }
        }
        .defaultSize(width: 1020, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Videos or Folders…") { store.chooseFiles() }
                    .keyboardShortcut("o").disabled(store.isBusy)
                Button("Strip Supported Tags") { store.clean() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.isBusy || store.readyCount == 0)
                Button("Cancel Current Batch") { store.cancel() }
                    .keyboardShortcut(".").disabled(!store.isBusy)
                Divider()
                Button("Clear Queue") { store.clear() }.disabled(store.isBusy || store.items.isEmpty)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: BatchStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the running Dock tile directly as well as declaring the bundle icon.
        // Launch Services can otherwise retain a placeholder after an in-place build.
        if let url = Bundle.main.url(forResource: "STRiPPR", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.isBusy else { return .terminateNow }
        store.cancel()
        Task { @MainActor in
            while store.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
