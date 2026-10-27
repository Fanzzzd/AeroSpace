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
