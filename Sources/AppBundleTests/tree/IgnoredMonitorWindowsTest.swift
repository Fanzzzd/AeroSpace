@testable import AppBundle
import XCTest

@MainActor
final class IgnoredMonitorWindowsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testWindowTheUserSwitchedToWithItsAppIsJustFocusedWithItsApp() {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let other = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        XCTAssertFalse(window.isJustFocused)

        noteNativeFocusChange(to: window)
        XCTAssertTrue(window.isJustFocused)
        XCTAssertTrue(window.isJustFocusedWithItsApp)
        XCTAssertFalse(other.isJustFocused)
    }

    func testWindowThatGotTheFocusFromAnotherWindowOfItsAppIsNotJustFocusedWithItsApp() {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let next = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        noteNativeFocusChange(to: window)
        noteNativeFocusChange(to: next) // Window 1 closed, and macOS focused the next window of the app

        XCTAssertTrue(next.isJustFocused)
        XCTAssertFalse(next.isJustFocusedWithItsApp)
        XCTAssertFalse(window.isJustFocused)
    }

    func testNewWindowIsHeldWhenClaimedWherever() {
        let screen = CGPoint(x: 100, y: 100)
        let agentDisplay = Rect(topLeftX: 3000, topLeftY: 0, width: 1920, height: 1080)
        // An accessory app's claimed window, first seen on the user's screen when its app comes to the front
        XCTAssertTrue(Claims.holdsNewWindow(7, center: screen, claimed: [7], ignoredRects: [agentDisplay]))
        XCTAssertTrue(Claims.holdsNewWindow(7, center: nil, claimed: [7], ignoredRects: []))
        XCTAssertFalse(Claims.holdsNewWindow(8, center: screen, claimed: [7], ignoredRects: [agentDisplay]))
    }

    func testNewUnclaimedWindowIsHeldOnAnIgnoredMonitorOnlyWhileClaimsAreLive() {
        let agentDisplay = Rect(topLeftX: 3000, topLeftY: 0, width: 1920, height: 1080)
        let onAgentDisplay = CGPoint(x: 3500, y: 500)
        XCTAssertTrue(Claims.holdsNewWindow(8, center: onAgentDisplay, claimed: [], ignoredRects: [agentDisplay]))
        XCTAssertFalse(Claims.holdsNewWindow(8, center: nil, claimed: [], ignoredRects: [agentDisplay]))
        // Without a live claim file AeroSpace guesses later, in normalizeLayoutReason
        XCTAssertFalse(Claims.holdsNewWindow(8, center: onAgentDisplay, claimed: nil, ignoredRects: [agentDisplay]))
    }

    func testReleasedWindowCanBeMovedBackToAWorkspaceByItsId() {
        let window = TestWindow.new(id: 1, parent: ignoredMonitorWindowsContainer)
        defer { window.unbindFromParent() }
        let target = window.toLiveFocusOrReportError(CmdIoImpl.emptyStdinIgnoringOut)
        XCTAssertTrue(target?.windowOrNil === window)
        XCTAssertTrue(target?.workspace === focus.workspace)

        let workspace = Workspace.get(byName: name)
        _ = moveWindowToWorkspace(window, workspace, CmdIoImpl.emptyStdinIgnoringOut, focusFollowsWindow: false, failIfNoop: false)
        XCTAssertTrue(window.nodeWorkspace === workspace)
    }
}
