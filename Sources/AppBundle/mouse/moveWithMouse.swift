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
                draggedWindowTile = window.lastAppliedLayoutPhysicalRect
            }
            currentlyManipulatedWithMouseWindowId = window.windowId
            window.lastAppliedLayoutPhysicalRect = nil
            guard let rect = try await window.getAxRect(.cancellable), let tile = draggedWindowTile else { return }
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

/// Puts a tiling window that is being dragged where it is now, at `rect`, away from its `tile`:
/// - On another monitor, next to the window under its center.
/// - On its own monitor, in the place of the window whose tile's middle its leading edge has passed: the edge on the
///   side it was dragged to. Next to that window, it keeps its size and the others make room, as in a list. A wide
///   window and a narrow one swap after the same short distance either way
@MainActor
func moveTilingWindow(_ window: Window, rect: Rect, tile: Rect) {
    let center = rect.center
    let targetWorkspace = center.monitorApproximation.activeWorkspace
    if targetWorkspace != window.nodeWorkspace {
        let target = center
            .findWindowRecursively(in: targetWorkspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)
        let index: Int = if let target, let parent = target.parent as? TilingContainer, let targetRect = target.lastAppliedLayoutPhysicalRect {
            center.getProjection(parent.orientation) >= targetRect.center.getProjection(parent.orientation)
                ? target.ownIndex.orDie() + 1
                : target.ownIndex.orDie()
        } else {
            0
        }
        window.bind(to: target?.parent ?? targetWorkspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: index)
        return
    }
    let offset = center - tile.center
    let orientation: Orientation = abs(offset.x) >= abs(offset.y) ? .h : .v
    let forward = offset.getProjection(orientation) > 0
    if offset.getProjection(orientation) == 0 { return }
    let edge = orientation == .h
        ? CGPoint(x: forward ? rect.maxX - 1 : rect.minX, y: center.y)
        : CGPoint(x: center.x, y: forward ? rect.maxY - 1 : rect.minY)
    guard let target = edge.findWindowRecursively(in: targetWorkspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false),
          target != window,
          let targetTile = target.lastAppliedLayoutPhysicalRect
    else { return }
    let middle = targetTile.center.getProjection(orientation)
    if forward ? edge.getProjection(orientation) < middle : edge.getProjection(orientation) > middle { return }
    if let parent = target.parent as? TilingContainer, parent == window.parent {
        let index = target.ownIndex.orDie()
        let binding = window.unbindFromParent()
        window.bind(to: parent, adaptiveWeight: binding.adaptiveWeight, index: index)
    } else {
        swapWindows(mruDominant: window, target)
    }
}

@MainActor
func swapWindows(mruDominant window1: Window, _ window2: Window) {
    if window1 == window2 { return }

    let binding2 = window2.unbindFromParent()
    let binding1 = window1.unbindFromParent()

    window2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    window1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
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
