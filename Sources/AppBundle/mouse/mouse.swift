import AppKit

/// The window the user moves or resizes with the mouse. Layout doesn't move that window, but notes its tile
struct MouseManipulation {
    let windowId: UInt32
    var tile: Rect?
}

@MainActor var mouseManipulation: MouseManipulation? = nil
@MainActor private var mouseTasks: [String: Task<(), any Error>] = [:]

/// AXMoved and AXResized. A window where AeroSpace's last request put it needs nothing. A window the user drags goes to
/// `byMouse`, with its frame as the app's thread read it when the notification came. Others start a refresh session
func windowFrameChanged(
    _ ax: AXUIElement,
    _ notif: CFString,
    byMouse: @escaping @Sendable @MainActor (Window, Rect) async throws -> (),
) {
    let notif = notif as String
    let windowId = ax.containingWindowId()
    let frame = ax.frame
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        let window = windowId.flatMap { Window.get(byId: $0) }
        if window?.isWhereAeroSpacePutIt(frame) == true { return }
        window?.frameAnswer = nil // Something else moved it
        guard let window, let frame, try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        mouseTasks[notif]?.cancel()
        mouseTasks[notif] = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) { try await byMouse(window, frame) }
        }
    }
}
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
