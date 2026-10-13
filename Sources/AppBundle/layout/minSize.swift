import AppKit
import Common

/// Apps keep a window at its minimum size, and macOS has no attribute that tells it. Layout learns it when an app
/// refuses a smaller size, and gives the window at least that much from then on, taking the room from its siblings.
extension Window {
    /// Learned from a frame write the app refused. `refused` is zero in a dimension the app accepted
    @MainActor
    func learnMinSize(_ refused: CGSize) {
        let learned = CGSize(width: max(minSize.width, refused.width), height: max(minSize.height, refused.height))
        if learned == minSize { return }
        minSize = learned
        scheduleCancellableCompleteRefreshSession(.windowMinSize)
    }

    /// The user made the window smaller than its learned minimum, so the app's minimum is smaller now
    @MainActor
    func forgetMinSize(below size: CGSize) {
        minSize = CGSize(width: min(minSize.width, size.width), height: min(minSize.height, size.height))
    }
}

extension TreeNode {
    /// The least length the node takes along `orientation`, with `innerGap` between tiles
    @MainActor
    func minLength(_ orientation: Orientation, innerGap: CGFloat) -> CGFloat {
        switch nodeCases {
            case .window(let window):
                return orientation == .h ? window.minSize.width : window.minSize.height
            case .tilingContainer(let container):
                let children = container.children.map { $0.minLength(orientation, innerGap: innerGap) }
                if container.orientation != orientation { return children.max() ?? 0 }
                return switch container.layout {
                    case .tiles: children.sum() + innerGap * CGFloat(max(children.count - 1, 0))
                    case .accordion: (children.max() ?? 0) + (children.count > 1 ? 2 * CGFloat(config.accordionPadding) : 0)
                }
            case .workspace, .macosMinimizedWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .ignoredMonitorWindowsContainer, .floatingWindowsContainer:
                return 0
        }
    }
}

/// Lengths for tiles that share `total`: proportional to `weights`, but none below its minimum. When the minimums
/// don't fit, each tile gets its minimum
func fitLengths(_ weights: [CGFloat], minimums: [CGFloat], total: CGFloat) -> [CGFloat] {
    var atMinimum = Array(repeating: false, count: weights.count)
    while true {
        let free = total - weights.indices.filter { atMinimum[$0] }.map { minimums[$0] }.sum()
        let freeWeight = weights.indices.filter { !atMinimum[$0] }.map { weights[$0] }.sum()
        let lengths = weights.indices.map { i in
            atMinimum[i] || freeWeight <= 0 ? minimums[i] : max(weights[i], 0) / freeWeight * free
        }
        let short = weights.indices.filter { !atMinimum[$0] && lengths[$0] < minimums[$0] }
        if short.isEmpty || freeWeight <= 0 { return lengths }
        for i in short { atMinimum[i] = true }
    }
}

extension [CGFloat] {
    fileprivate func sum() -> CGFloat { reduce(0, +) }
}
