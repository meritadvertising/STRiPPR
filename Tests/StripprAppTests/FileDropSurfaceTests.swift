import XCTest
import AppKit
import SwiftUI
@testable import STRiPPR

final class FileDropSurfaceTests: XCTestCase {
    @MainActor
    func testNativeFileDropRequestsCopyAndDeliversExactFileAndDirectoryURLs() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let urls = [
            URL(fileURLWithPath: "/tmp/STRiPPR drop tests/Björk 🌙.mp4"),
            URL(fileURLWithPath: "/tmp/STRiPPR drop tests/videos", isDirectory: true)
        ]
        XCTAssertTrue(board.writeObjects(urls.map { $0 as NSURL }))
        let drag = FileDragInfo(pasteboard: board)
        let view = FileDropHostingView(rootView: EmptyView())
        var received: [[URL]] = []
        var hover: [Bool] = []
        view.receiveFiles = { received.append($0) }
        view.hovering = { hover.append($0) }
        XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL))
        XCTAssertEqual(view.draggingEntered(drag), .copy)
        XCTAssertEqual(view.draggingUpdated(drag), .copy)
        XCTAssertTrue(view.prepareForDragOperation(drag))
        XCTAssertTrue(view.performDragOperation(drag))
        XCTAssertEqual(received, [urls])
        XCTAssertEqual(hover, [true, false])
    }

    @MainActor
    func testBusyReceiverRejectsFileDropWithoutDeliveringFiles() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects([URL(fileURLWithPath: "/tmp/queued.mp4") as NSURL]))
        let drag = FileDragInfo(pasteboard: board)
        let view = FileDropHostingView(rootView: EmptyView())
        view.dropEnabled = false
        var received = false
        var hover: [Bool] = []
        view.receiveFiles = { _ in received = true }
        view.hovering = { hover.append($0) }
        XCTAssertEqual(view.draggingEntered(drag), [])
        XCTAssertEqual(view.draggingUpdated(drag), [])
        XCTAssertFalse(view.prepareForDragOperation(drag))
        XCTAssertFalse(view.performDragOperation(drag))
        XCTAssertFalse(received)
        XCTAssertEqual(hover, [false, false])
    }

    @MainActor
    func testPlainTextThatLooksLikeFileURLIsRejected() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("file:///tmp/pretend-video.mp4", forType: .string))
        let drag = FileDragInfo(pasteboard: board)
        let view = FileDropHostingView(rootView: EmptyView())
        var received = false
        view.receiveFiles = { _ in received = true }
        XCTAssertEqual(view.draggingEntered(drag), [])
        XCTAssertEqual(view.draggingUpdated(drag), [])
        XCTAssertFalse(view.prepareForDragOperation(drag))
        XCTAssertFalse(view.performDragOperation(drag))
        XCTAssertFalse(received)
    }

    @MainActor
    func testRemoteURLIsRejectedAsNonFileInput() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/video.mp4"))
        XCTAssertTrue(board.writeObjects([remote as NSURL]))
        let drag = FileDragInfo(pasteboard: board)
        let view = FileDropHostingView(rootView: EmptyView())
        var received = false
        view.receiveFiles = { _ in received = true }
        XCTAssertEqual(view.draggingEntered(drag), [])
        XCTAssertFalse(view.prepareForDragOperation(drag))
        XCTAssertFalse(view.performDragOperation(drag))
        XCTAssertFalse(received)
    }

    @MainActor
    func testBecomingBusyAfterDragEntersRejectsTheDrop() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects([URL(fileURLWithPath: "/tmp/queued.mp4") as NSURL]))
        let drag = FileDragInfo(pasteboard: board)
        let view = FileDropHostingView(rootView: EmptyView())
        var received = false
        var hovering = false
        view.receiveFiles = { _ in received = true }
        view.hovering = { hovering = $0 }
        XCTAssertEqual(view.draggingEntered(drag), .copy)
        XCTAssertTrue(hovering)
        view.dropEnabled = false
        XCTAssertEqual(view.draggingUpdated(drag), [])
        XCTAssertFalse(view.prepareForDragOperation(drag))
        XCTAssertFalse(view.performDragOperation(drag))
        XCTAssertFalse(received)
        XCTAssertFalse(hovering)
    }

    @MainActor
    func testExitingOrEndingDragClearsHoverWithoutDeliveringFiles() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects([URL(fileURLWithPath: "/tmp/queued.mp4") as NSURL]))
        let drag = FileDragInfo(pasteboard: board)
        let view = FileDropHostingView(rootView: EmptyView())
        var received = false
        var hovering = false
        view.receiveFiles = { _ in received = true }
        view.hovering = { hovering = $0 }
        _ = view.draggingEntered(drag)
        XCTAssertTrue(hovering)
        view.draggingExited(drag)
        XCTAssertFalse(hovering)
        _ = view.draggingEntered(drag)
        XCTAssertTrue(hovering)
        view.draggingEnded(drag)
        XCTAssertFalse(hovering)
        XCTAssertFalse(received)
    }
}

/// This tests native destination callbacks with actual NSPasteboard URL data.
/// It does not simulate pointer routing, Finder, or a physical drag gesture.
@MainActor
private final class FileDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions,
                                for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
