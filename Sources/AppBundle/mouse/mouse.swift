import AppKit

/// The window the user moves or resizes with the mouse. Layout doesn't move that window, but notes its tile
struct MouseManipulation {
    let windowId: UInt32
    var tile: Rect?
}

@MainActor var mouseManipulation: MouseManipulation? = nil
var isLeftMouseButtonDown: Bool { NSEvent.pressedMouseButtons == 1 }

@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    try await (window.closetOffset == nil && // Don't allow to resize/move windows of hidden workspaces
        isLeftMouseButtonDown &&
        (mouseManipulation.map { $0.windowId == window.windowId } ?? true))
        .andAsync { @Sendable @MainActor in try await getNativeFocusedWindow(.cancellable) == window }
}

/// Same motivation as in monitorFrameNormalized
var mouseLocation: CGPoint { NSEvent.mouseLocation.withYAxisFlipped }
