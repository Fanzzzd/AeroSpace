import Foundation

@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self))
    try await validateStillPopups()
    if let claimed = Claims.shared.windows {
        try await normalizeClaimedWindows(claimed)
    } else {
        try await guessIgnoredMonitorWindows()
    }
}

/// Windows a live process claims are released wherever they are, and every other window is the user's. An unclaimed
/// window on an ignored monitor waits there for a moment, since the claim for a new window may come just after it
/// appears and the claim for a window being taken back goes just before it's moved, and is then laid out on the focused
/// workspace. This runs before layout, which would otherwise move a claimed window.
@MainActor
private func normalizeClaimedWindows(_ claimed: Set<UInt32>) async throws {
    let ignoredRects = ignoredMonitorRects
    for workspace in Workspace.all {
        for window in workspace.allLeafWindowsRecursive {
            if claimed.contains(window.windowId) {
                ClosetLog.write("release: window \(window.windowId) of \(window.app.name ?? "?") on workspace \(workspace.name), claimed")
                window.isPlacedByOthers = false
                window.bind(to: ignoredMonitorWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                continue
            }
            guard window.isPlacedByOthers else { continue }
            window.isPlacedByOthers = false
            guard let center = try await window.getCenter(.cancellable), ignoredRects.contains(where: { $0.contains(center) }) else { continue }
            window.unclaimedSince = .now
            window.bind(to: ignoredMonitorWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        }
    }
    var nextCheck: Date? = nil
    for node in ignoredMonitorWindowsContainer.children {
        let window = node as! Window
        if claimed.contains(window.windowId) {
            window.unclaimedSince = nil
            continue
        }
        let center = try await window.getCenter(.cancellable)
        if let center, !ignoredRects.contains(where: { $0.contains(center) }) {
            window.unclaimedSince = nil
            try await window.relayoutWindow(on: center.monitorApproximation.activeWorkspace, .cancellable)
            continue
        }
        let since = window.unclaimedSince ?? .now
        window.unclaimedSince = since
        let deadline = since.addingTimeInterval(unclaimedWindowWait)
        if deadline <= .now {
            ClosetLog.write("reclaim: window \(window.windowId) of \(window.app.name ?? "?") to workspace \(focus.workspace.name), unclaimed")
            window.unclaimedSince = nil
            try await window.relayoutWindow(on: focus.workspace, .cancellable)
        } else {
            nextCheck = min(nextCheck ?? deadline, deadline)
        }
    }
    if let nextCheck { scheduleClaimCheck(at: nextCheck) }
}

private let unclaimedWindowWait: TimeInterval = 1
@MainActor private var claimCheck: Task<(), any Error>? = nil

@MainActor
private func scheduleClaimCheck(at date: Date) {
    claimCheck?.cancel()
    claimCheck = Task.startUnstructured {
        try await Task.sleep(for: .seconds(max(date.timeIntervalSinceNow, 0) + 0.05))
        if TrayMenuModel.shared.isEnabled { scheduleCancellableCompleteRefreshSession(.claimHeldWindows) }
    }
}

/// Without claims: windows that were put on a monitor from `ignored-monitors` on purpose are released, and windows that were moved back
/// are laid out on the workspace of the monitor they landed on.
///
/// A window is on an ignored monitor on purpose only if it opened there, or something moved it there while the displays
/// held still, such as Agent Screen handing it to an agent. When the displays change, macOS moves windows with them and
/// apps pull windows back onto screens, which may land a window, a hidden one too, on an ignored monitor: layout puts
/// such a window back. So only windows marked ``Window/isPlacedByOthers`` are asked where they are. This runs before
/// layout, which would otherwise put a released window back.
///
/// Apps also open windows where they were last, which may be an ignored monitor the user can't see. Agents don't focus
/// windows, so a window the user just opened or switched to stays, and a released window the user switches to with
/// its app comes back to the focused workspace.
@MainActor
private func guessIgnoredMonitorWindows() async throws {
    let ignoredRects = ignoredMonitorRects
    for node in ignoredMonitorWindowsContainer.children {
        let window = node as! Window
        if window.isJustFocusedWithItsApp {
            ClosetLog.write("reclaim: window \(window.windowId) of \(window.app.name ?? "?") to workspace \(focus.workspace.name), the user switched to it")
            try await window.relayoutWindow(on: focus.workspace, .cancellable)
            _ = window.focusWindow()
            continue
        }
        guard let center = try await window.getCenter(.cancellable) else { continue }
        if !ignoredRects.contains(where: { $0.contains(center) }) {
            try await window.relayoutWindow(on: center.monitorApproximation.activeWorkspace, .cancellable)
        }
    }
    if ignoredRects.isEmpty { return }
    for workspace in Workspace.all {
        for window in workspace.allLeafWindowsRecursive where window.layoutReason == .standard && window.isPlacedByOthers {
            window.isPlacedByOthers = false
            if window.isJustFocused { continue }
            guard let center = try await window.getCenter(.cancellable) else { continue }
            if ignoredRects.contains(where: { $0.contains(center) }) {
                ClosetLog.write("release: window \(window.windowId) of \(window.app.name ?? "?") on workspace \(workspace.name), center \(center)")
                window.bind(to: ignoredMonitorWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
            }
        }
    }
}

@MainActor
private func validateStillPopups() async throws {
    for node in macosPopupWindowsContainer.children {
        let popup = (node as! MacWindow)
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await popup.isWindowHeuristic(windowLevel, .cancellable) {
            try await popup.relayoutWindow(on: focus.workspace, .cancellable)
            await tryOnWindowDetected(popup)
        }
    }
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window]) async throws {
    for window in windows {
        let state = try await window.macosState(.cancellable)
        let isMacosFullscreen = state.isFullscreen
        let isMacosMinimized = state.isMinimized
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden
        switch window.layoutReason {
            case .standard:
                guard let parent = window.parent else { continue }
                switch true {
                    case isMacosFullscreen:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    case isMacosMinimized:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    case isMacosWindowOfHiddenApp:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    default: break
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
                }
        }
    }
}

@MainActor
func exitMacOsNativeUnconventionalState(
    window: Window,
    prevParentKind: NonLeafTreeNodeKind,
    workspace: Workspace,
    _ cm: CancellationMode,
) async throws {
    switch prevParentKind {
        case .floatingWindowsContainer:
            window.bindAsFloatingWindow(to: workspace)
        case .workspace:
            break // Not possible
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, cm, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer,
             .ignoredMonitorWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace, cm)
    }
    // Only now: a canceled relayout leaves the window in the macOS container, and while it's marked so, the next pass
    // tries again. Marked standard, it would stay there
    window.layoutReason = .standard
}
