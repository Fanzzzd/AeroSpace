@testable import AppBundle
import Common
import XCTest

@MainActor
final class MoveWithMouseTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// A 1200 pt wide window 1 next to a 720 pt wide window 2, window 1 being dragged right
    private func sideBySide() -> (TilingContainer, Window) {
        var dragged: Window! = nil
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            dragged = TestWindow.new(id: 1, parent: $0)
            assertEquals(dragged.focusWindow(), true)
            TestWindow.new(id: 2, parent: $0).lastAppliedLayoutPhysicalRect =
                Rect(topLeftX: 1200, topLeftY: 0, width: 720, height: 1080)
        }
        return (root, dragged)
    }

    func testWindowHeldByItsRightEndDoesntSwapWhileItsCenterIsHome() {
        // The pointer would already be over window 2
        let (root, dragged) = sideBySide()
        moveTilingWindow(dragged, center: CGPoint(x: 900, y: 540))
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testWindowSwapsOnceItsCenterIsOverTheOther() {
        // The pointer may still be over window 1's tile
        let (root, dragged) = sideBySide()
        moveTilingWindow(dragged, center: CGPoint(x: 1300, y: 540))
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1)]))
    }
}
