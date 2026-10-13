@testable import AppBundle
import Common
import XCTest

@MainActor
final class MoveWithMouseTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func tile(_ x: CGFloat, _ width: CGFloat) -> Rect { Rect(topLeftX: x, topLeftY: 0, width: width, height: 1080) }

    /// Window 1 in a 1200 pt tile, window 2 in a 720 pt tile right of it
    private func wideAndNarrow() -> (TilingContainer, Window, Window) {
        var wide: Window! = nil
        var narrow: Window! = nil
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            wide = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1200)
            narrow = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 720)
        }
        assertEquals(wide.focusWindow(), true)
        wide.lastAppliedLayoutPhysicalRect = tile(0, 1200)
        narrow.lastAppliedLayoutPhysicalRect = tile(1200, 720)
        return (root, wide, narrow)
    }

    func testWideWindowStaysUntilItsLeadingEdgePassesTheMiddleOfTheNextTile() {
        let (root, wide, _) = wideAndNarrow()
        moveTilingWindow(wide, rect: tile(300, 1200), tile: tile(0, 1200))
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testWideWindowMovesOverAndKeepsItsSize() {
        let (root, wide, _) = wideAndNarrow()
        // Its right edge, at 1599, is past the middle of window 2's tile, at 1560. Its center is still in its own tile
        moveTilingWindow(wide, rect: tile(400, 1200), tile: tile(0, 1200))
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1)]))
        assertEquals(wide.getWeight(.h), 1200)
    }

    func testNarrowWindowMovesOverOnceItsLeftEdgePassesTheMiddleOfTheWideTile() {
        let (root, _, narrow) = wideAndNarrow()
        moveTilingWindow(narrow, rect: tile(700, 720), tile: tile(1200, 720))
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
        moveTilingWindow(narrow, rect: tile(500, 720), tile: tile(1200, 720))
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1)]))
        assertEquals(narrow.getWeight(.h), 720)
    }

    /// Four narrow windows, then a wide one
    private func fourNarrowAndAWideOne() -> (TilingContainer, [Window]) {
        let root = Workspace.get(byName: name).rootTilingContainer
        var windows: [Window] = []
        for i in 0 ..< 4 {
            windows.append(TestWindow.new(id: UInt32(i + 1), parent: root, adaptiveWeight: 155))
            windows[i].lastAppliedLayoutPhysicalRect = tile(CGFloat(i) * 155, 155)
        }
        windows.append(TestWindow.new(id: 5, parent: root, adaptiveWeight: 1300))
        windows[4].lastAppliedLayoutPhysicalRect = tile(620, 1300)
        assertEquals(windows[4].focusWindow(), true)
        return (root, windows)
    }

    func testWideWindowDraggedOffTheLeftEdgeGoesFirst() {
        let (root, windows) = fourNarrowAndAWideOne()
        windows[4].lastAppliedLayoutPhysicalRect = nil
        moveTilingWindow(windows[4], rect: tile(-200, 1300), tile: tile(620, 1300))
        assertEquals(root.layoutDescription, .h_tiles([.window(5), .window(1), .window(2), .window(3), .window(4)]))
    }

    func testNarrowWindowDraggedOffTheRightEdgeGoesLast() {
        let (root, windows) = fourNarrowAndAWideOne()
        windows[0].lastAppliedLayoutPhysicalRect = nil
        moveTilingWindow(windows[0], rect: tile(1800, 155), tile: tile(0, 155))
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(3), .window(4), .window(5), .window(1)]))
    }

    func testWindowMovesOnePlaceForEachMiddleItsEdgePasses() {
        let (root, windows) = fourNarrowAndAWideOne()
        windows[4].lastAppliedLayoutPhysicalRect = nil
        // The left edge, at 300, is past the middles of tiles 3 and 4, at 387 and 542, not of tile 2, at 232
        moveTilingWindow(windows[4], rect: tile(300, 1300), tile: tile(620, 1300))
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(5), .window(3), .window(4)]))
    }

    func testWindowDraggedIntoTheNextColumnGoesNextToTheWindowThere() {
        // Window 1 left, a column of windows 2 and 3 right. Window 3 is dragged left, past the middle of window 1
        var dragged: Window! = nil
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0).lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 960, height: 1080)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0).lastAppliedLayoutPhysicalRect = Rect(topLeftX: 960, topLeftY: 0, width: 960, height: 540)
                dragged = TestWindow.new(id: 3, parent: $0)
            }
        }
        assertEquals(dragged.focusWindow(), true)
        let tile = Rect(topLeftX: 960, topLeftY: 540, width: 960, height: 540)
        moveTilingWindow(dragged, rect: Rect(topLeftX: 600, topLeftY: 540, width: 960, height: 540), tile: tile)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
        moveTilingWindow(dragged, rect: Rect(topLeftX: 400, topLeftY: 540, width: 960, height: 540), tile: tile)
        assertEquals(root.layoutDescription, .h_tiles([.window(3), .window(1), .v_tiles([.window(2)])]))
    }
}
