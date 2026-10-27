import AppKit
import Common

open class Window: TreeNode, Hashable {
    let windowId: UInt32
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    /// Where the window waits on the closet while its workspace is invisible, from the closet's top left corner. Nil
    /// while its workspace is visible
    var closetOffset: CGPoint? = nil
    /// Something other than AeroSpace and macOS put the window where it is: it's new, or something moved it while the
    /// displays held still. Only such a window may be on an ignored monitor on purpose. See
    /// ``normalizeIgnoredMonitorWindows()``
    var isPlacedByOthers = false
    /// Since when the window waits on an ignored monitor, unclaimed, for its claim to come. See ``Claims``
    var unclaimedSince: Date? = nil
    /// The least size the app lets the window have, as far as AeroSpace has seen. See ``learnMinSize(from:)``
    var minSize: CGSize = .zero
    /// What the app made of the last frame AeroSpace asked for, until something else moves the window
    var frameAnswer: FrameAnswer? = nil
    /// The frame AeroSpace is asking for now. See ``frameWritten(_:got:)``
    var pendingFrameRequest: PendingFrameRequest? = nil
    var frameRequestCount = 0
    /// Read by the refresh session for every window at once. See ``macosState(_:)``
    var refreshedMacosState: MacosWindowState? = nil
    var isFullscreen: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    var layoutReason: LayoutReason = .standard

    @MainActor
    init(id: UInt32, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: UInt32) -> Window? { // todo make non optional
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor
    func closeAxWindow() { die("Not implemented") }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { die("Not implemented") }
    func getTitle(_ cm: CancellationMode) async throws -> String { die("Not implemented") }
    func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { false }
    func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { false } // todo replace with enum MacOsWindowNativeState { normal, fullscreen, invisible }
    @MainActor func nativeFocus() { die("Not implemented") }
    func getAxRect(_ cm: CancellationMode) async throws -> Rect? { die("Not implemented") }
    func getCenter(_ cm: CancellationMode) async throws -> CGPoint? { try await getAxRect(cm)?.center }

    func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) { die("Not implemented") }
}

enum LayoutReason: Equatable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: NonLeafTreeNodeKind)
}

extension Window {
    var isFloating: Bool { // todo drop. It will be a source of bugs when sticky is introduced
        switch windowParentCases {
            case .floatingWindowsContainer: true
            case .macosFullscreenWindowsContainer: false
            case .macosHiddenAppsWindowsContainer: false
            case .macosMinimizedWindowsContainer: false
            case .macosPopupWindowsContainer: false
            case .ignoredMonitorWindowsContainer: false
            case .tilingContainer: false
            case .unbound: false
        }
    }

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}

extension Window {
    /// Whether the window hangs off a workspace in the workspace list or off one of the containers for windows that are on
    /// no workspace
    @MainActor
    var isInTheTree: Bool {
        var node: TreeNode = self
        while let parent = node.parent { node = parent }
        if let workspace = node as? Workspace { return workspace.isLive }
        return node === macosMinimizedWindowsContainer || node === macosPopupWindowsContainer || node === ignoredMonitorWindowsContainer
    }
}

/// What macOS shows of a window, read by the refresh pass
struct MacosWindowState: Sendable {
    let isFullscreen: Bool
    let isMinimized: Bool
}

extension Window {
    /// What the refresh session read, or else asked now
    @MainActor
    func macosState(_ cm: CancellationMode) async throws -> MacosWindowState {
        if let refreshedMacosState { return refreshedMacosState }
        let isFullscreen = try await isMacosFullscreen(cm)
        let isMinimized = isFullscreen ? false : try await isMacosMinimized(cm)
        return MacosWindowState(isFullscreen: isFullscreen, isMinimized: isMinimized)
    }
}
