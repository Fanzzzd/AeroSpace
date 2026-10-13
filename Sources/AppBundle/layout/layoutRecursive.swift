import AppKit

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws {
        // The workspace is visible: its windows leave the closet
        for window in allLeafWindowsRecursive { window.closetOffset = nil }
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, LayoutContext(self))
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                try await workspace.floatingWindowsContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .floatingWindowsContainer(let container):
                for window in container.children.filterIsInstance(of: Window.self) {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    try await window.layoutFloatingWindow(context)
                }
            case .window(let window):
                if window.windowId != mouseManipulation?.windowId {
                    lastAppliedLayoutVirtualRect = virtual
                    if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        lastAppliedLayoutPhysicalRect = physicalRect
                        window.isFullscreen = false
                        window.setAxFrame(point, CGSize(width: width, height: height))
                    }
                } else {
                    mouseManipulation?.tile = physicalRect
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                switch container.layout {
                    case .tiles:
                        try await container.layoutTiles(point, width: width, height: height, virtual: virtual, context)
                    case .accordion:
                        try await container.layoutAccordion(point, width: width, height: height, virtual: virtual, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .ignoredMonitorWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

private struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps

    @MainActor
    init(_ workspace: Workspace) {
        self.workspace = workspace
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext) async throws {
        let workspace = context.workspace
        let windowRect = try await getAxRect(.cancellable) // Probably not idempotent
        // A window that is elsewhere, on the closet or on a monitor that shows another workspace, comes over to the same
        // relative spot
        if let windowRect, let sourceRect = sourceRect(of: windowRect, for: workspace) {
            let proportion = sourceRect.proportion(of: windowRect.topLeftCorner)
            setAxFrame(workspace.workspaceMonitor.visibleRect.topLeft(at: proportion, for: windowRect.size), nil)
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    /// The closet, or the monitor of a workspace other than `workspace`, when the window is there
    @MainActor
    private func sourceRect(of windowRect: Rect, for workspace: Workspace?) -> Rect? {
        if let closet = Closet.shared.rect, closet.contains(windowRect.topLeftCorner) { return closet }
        let monitor = windowRect.center.monitorApproximation
        return monitor.activeWorkspace == workspace ? nil : monitor.visibleRect
    }

    /// Moves the window of an invisible workspace onto the closet, to the spot that matches where it was on its monitor.
    /// ``layoutFloatingWindow(_:)`` brings it back the same way. The first time, that needs `windowRect`, where the
    /// window is, unless layout placed it. Returns false when it's needed
    @discardableResult
    @MainActor
    func parkInCloset(_ closet: Rect, windowRect: Rect? = nil) -> Bool {
        if closetOffset == nil {
            guard let windowRect = windowRect ?? lastAppliedLayoutPhysicalRect else { return false }
            // An app may open a new window next to its hidden ones, on the closet
            let sourceRect = sourceRect(of: windowRect, for: nil) ?? closet
            let topLeft = closet.topLeft(at: sourceRect.proportion(of: windowRect.topLeftCorner), for: windowRect.size)
            closetOffset = topLeft - closet.topLeftCorner
            if isFloating {
                lastFloatingSize = windowRect.size
            }
        }
        // Each refresh session asks again: the frame write skips windows that are already there
        if let closetOffset { setAxFrame(closet.topLeftCorner + closetOffset, nil) }
        return true
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect = noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitor.visibleRect
            : context.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        setAxFrame(monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        var point = point
        var virtualPoint = virtual.topLeftCorner

        let total = orientation == .h ? width : height
        guard let delta = (total - CGFloat(children.sumOfDouble { $0.getWeight(orientation) })).div(children.count) else { return }
        for child in children {
            child.setWeight(orientation, child.getWeight(orientation) + delta)
        }

        let lastIndex = children.indices.last
        let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
        // Gaps. Consider 4 cases:
        // 1. Multiple children. Layout first child
        // 2. Multiple children. Layout last child
        // 3. Multiple children. Layout child in the middle
        // 4. Single child
        let gaps = children.indices.map { i in rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0) }
        // The weights are what the user asked for. Tiles get less only where an app refuses to make its window smaller
        let lengths = fitLengths(
            children.map { $0.getWeight(orientation) },
            minimums: children.indices.map { children[$0].minLength(orientation, innerGap: rawGap) + gaps[$0] },
            total: total,
        )
        // When the minimums don't fit, tiles overlap evenly, so that the last still ends at the edge
        let excess: CGFloat = lengths.reduce(0, +) - total
        let overlap: CGFloat = max(excess, 0) / CGFloat(max(children.count - 1, 1))

        for (i, child) in children.enumerated() {
            try await child.layoutRecursive(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? lengths[i] - gaps[i] : width,
                height: orientation == .v ? lengths[i] - gaps[i] : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? lengths[i] : width,
                    height: orientation == .v ? lengths[i] : height,
                ),
                context,
            )
            virtualPoint = virtualPoint.addingOffset(orientation, lengths[i] - overlap)
            point = point.addingOffset(orientation, lengths[i] - overlap)
        }
    }

    @MainActor
    fileprivate func layoutAccordion(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        guard let mruIndex: Int = mostRecentChild?.ownIndex else { return }
        for (index, child) in children.enumerated() {
            let padding = CGFloat(config.accordionPadding)
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where children.count == 1: (0, 0)
                case 0:                           (0, padding)
                case children.indices.last:       (padding, 0)
                case mruIndex - 1:                (0, 2 * padding)
                case mruIndex + 1:                (2 * padding, 0)
                default:                          (padding, padding)
            }
            switch orientation {
                case .h:
                    try await child.layoutRecursive(
                        point + CGPoint(x: lPadding, y: 0),
                        width: width - rPadding - lPadding,
                        height: height,
                        virtual: virtual,
                        context,
                    )
                case .v:
                    try await child.layoutRecursive(
                        point + CGPoint(x: 0, y: lPadding),
                        width: width,
                        height: height - lPadding - rPadding,
                        virtual: virtual,
                        context,
                    )
            }
        }
    }
}
