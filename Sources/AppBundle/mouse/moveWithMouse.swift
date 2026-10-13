import AppKit
import Common

@MainActor
private var moveWithMouseTask: Task<(), any Error>? = nil

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    let notif = notif as String
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        moveWithMouseTask?.cancel()
        moveWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await moveWithMouse(window)
            }
        }
    }
}

@MainActor
private func moveWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case .floatingWindowsContainer:
            try await moveFloatingWindow(window)
        case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer, .macosPopupWindowsContainer,
             .ignoredMonitorWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Unconventional windows can't be moved with mouse
        case .tilingContainer:
            if currentlyManipulatedWithMouseWindowId != window.windowId {
                mouseManipulation = MouseManipulation(windowId: window.windowId, tile: window.lastAppliedLayoutPhysicalRect)
            }
            // Resizing with the mouse measures from it, and a window that is being moved isn't being resized
            window.lastAppliedLayoutPhysicalRect = nil
            guard let rect = try await window.getAxRect(.cancellable), let tile = mouseManipulation?.tile else { return }
            moveTilingWindow(window, rect: rect, tile: tile)
        case .unbound: return
    }
}

@MainActor
private func moveFloatingWindow(_ window: Window) async throws {
    guard let targetWorkspace = try await window.getCenter(.cancellable)?.monitorApproximation.activeWorkspace else { return }
    guard let parent = window.parent else { return }
    if targetWorkspace != parent {
        window.bindAsFloatingWindow(to: targetWorkspace)
    }
}

/// Puts a tiling window that is being dragged where it is now, at `rect`, away from its `tile`. The window keeps its
/// size; the others make room:
/// - Along its container, it moves like an item in a list. The edge on the side it is dragged to leads; for each tile
///   whose middle that edge has passed, the window moves one place. An edge off the screen has passed them all.
/// - Across its container, such as into the next column, it goes next to the window there, once the leading edge has
///   passed the middle of that window's tile.
/// - Onto another monitor, it goes next to the window under its center
@MainActor
func moveTilingWindow(_ window: Window, rect: Rect, tile: Rect) {
    let center = rect.center
    let workspace = center.monitorApproximation.activeWorkspace
    if workspace != window.nodeWorkspace {
        insert(window, at: center, in: workspace)
        return
    }
    let offset = center - tile.center
    let orientation: Orientation = abs(offset.x) >= abs(offset.y) ? .h : .v
    let forward = offset.getProjection(orientation) > 0
    if offset.getProjection(orientation) == 0 { return }
    let leadingEdge = orientation == .h ? (forward ? rect.maxX : rect.minX) : (forward ? rect.maxY : rect.minY)
    guard let parent = window.parent as? TilingContainer, let ownIndex = window.ownIndex else { return }

    if parent.orientation == orientation && parent.layout == .tiles {
        // Tiles along a container are in order, so are their middles
        let middles = parent.children.map { $0.lastAppliedLayoutPhysicalRect?.center.getProjection(orientation) }
        let passed = forward
            ? middles[(ownIndex + 1)...].prefix { $0.map { leadingEdge >= $0 } ?? false }.count
            : middles[..<ownIndex].reversed().prefix { $0.map { leadingEdge <= $0 } ?? false }.count
        if passed == 0 { return }
        let binding = window.unbindFromParent()
        window.bind(to: parent, adaptiveWeight: binding.adaptiveWeight, index: forward ? ownIndex + passed : ownIndex - passed)
        return
    }

    // Kept on the monitor, so that an edge off the screen still finds the tile at the screen's edge
    let probe = (orientation == .h
        ? CGPoint(x: forward ? leadingEdge - 1 : leadingEdge, y: center.y)
        : CGPoint(x: center.x, y: forward ? leadingEdge - 1 : leadingEdge))
        .clamped(to: workspace.workspaceMonitor.visibleRect)
    guard let middle = probe.windowUnder(in: workspace, except: window)?.lastAppliedLayoutPhysicalRect?.center.getProjection(orientation),
          forward ? leadingEdge >= middle : leadingEdge <= middle
    else { return }
    insert(window, at: probe, in: workspace)
}

/// Puts the window next to the one at `point`, on the side of that one's middle `point` is. With no window there, the
/// window goes first in the workspace
@MainActor
private func insert(_ window: Window, at point: CGPoint, in workspace: Workspace) {
    guard let target = point.windowUnder(in: workspace, except: window),
          let parent = target.parent as? TilingContainer,
          let middle = target.lastAppliedLayoutPhysicalRect?.center.getProjection(parent.orientation)
    else {
        window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: 0)
        return
    }
    _ = window.unbindFromParent()
    let index = target.ownIndex.orDie() + (point.getProjection(parent.orientation) >= middle ? 1 : 0)
    window.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: index)
}

extension CGPoint {
    @MainActor
    fileprivate func windowUnder(in workspace: Workspace, except window: Window) -> Window? {
        findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)?.takeIf { $0 != window }
    }

    fileprivate func clamped(to rect: Rect) -> CGPoint {
        CGPoint(x: x.coerce(in: rect.minX ... rect.maxX - 1), y: y.coerce(in: rect.minY ... rect.maxY - 1))
    }
}

extension CGPoint {
    @MainActor
    func findWindowRecursively(
        in tree: TilingContainer,
        virtual: Bool,
        fullscreenCoversAll: Bool,
    ) -> Window? {
        if fullscreenCoversAll {
            if let window = tree.mostRecentWindowRecursive, window.isFullscreen {
                return window
            }
        }
        return _findWindowRecursively(in: tree, virtual: virtual)
    }

    @MainActor
    private func _findWindowRecursively(in tree: TilingContainer, virtual: Bool) -> Window? {
        let point = self
        let target: TreeNode? = switch tree.layout {
            case .tiles:
                tree.children.first(where: {
                    (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
                })
            case .accordion:
                tree.mostRecentChild
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): _findWindowRecursively(in: container, virtual: virtual)
        }
    }
}
