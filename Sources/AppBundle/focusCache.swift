import Common
import Foundation


@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil
@MainActor private var lastKnownNativeFocusedPid: pid_t? = nil

/// The window that last got the native focus, when, and whether its app got activated for it. Agents work on windows
/// without focusing them, so a window that just got the focus is one the user opened or switched to
struct NativeFocusChange {
    let windowId: UInt32
    let date: Date
    let activatedApp: Bool
}
@MainActor private(set) var lastNativeFocusChange: NativeFocusChange? = nil

extension Window {
    /// The user opened the window or switched to it a moment ago
    @MainActor var isJustFocused: Bool { justFocusedChange != nil }

    /// The user switched to the app of the window a moment ago, and macOS focused the window for it. Unlike a window
    /// that gets the focus when another window of its app closes, the user asked for this one
    @MainActor var isJustFocusedWithItsApp: Bool { justFocusedChange?.activatedApp == true }

    @MainActor private var justFocusedChange: NativeFocusChange? {
        guard let change = lastNativeFocusChange, change.windowId == windowId, change.date.distance(to: .now) < 3 else { return nil }
        return change
    }
}

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
        if let nativeFocused { noteNativeFocusChange(to: nativeFocused) }
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}

@MainActor func noteNativeFocusChange(to window: Window) {
    let pid = window.app.pid
    lastNativeFocusChange = NativeFocusChange(windowId: window.windowId, date: .now, activatedApp: pid != lastKnownNativeFocusedPid)
    lastKnownNativeFocusedPid = pid
}

@MainActor func resetNativeFocusCacheForTests() {
    lastKnownNativeFocusedWindowId = nil
    lastKnownNativeFocusedPid = nil
    lastNativeFocusChange = nil
}
