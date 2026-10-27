import AppKit
import os

/// The window the user moves or resizes with the mouse. Layout doesn't move that window, but notes its tile
struct MouseManipulation {
    let windowId: UInt32
    var tile: Rect?
}

@MainActor var mouseManipulation: MouseManipulation? = nil
@MainActor private var mouseTasks: [String: Task<(), any Error>] = [:]
/// Numbers notifications as they come, on the apps' threads, so that one handled late doesn't undo a newer one
private let notificationCount = OSAllocatedUnfairLock(initialState: 0)
@MainActor private var newestMouseNotification: [String: Int] = [:]

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
    let number = notificationCount.withLock { count in
        count += 1
        return count
    }
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        let window = windowId.flatMap { Window.get(byId: $0) }
        if window?.isWhereAeroSpacePutIt(frame) == true { return }
        window?.frameAnswer = nil // Something else moved it
        // macOS moves windows with the displays, and apps pull them back onto screens, right after the displays change.
        // With claims, that's no guess: a window that lands on an ignored monitor waits there for its claim
        if Claims.shared.isActive || !Closet.displaysChangedRecently { window?.isPlacedByOthers = true }
        guard let window, let frame, try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        if number < newestMouseNotification[notif, default: 0] { return }
        newestMouseNotification[notif] = number
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
