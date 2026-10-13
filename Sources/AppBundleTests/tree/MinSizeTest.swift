@testable import AppBundle
import Common
import XCTest

@MainActor
final class MinSizeTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testLengthsFollowWeightsWithoutMinimums() {
        assertEquals(fitLengths([300, 600, 300], minimums: [0, 0, 0], total: 1200), [300, 600, 300])
    }

    func testTileBelowItsMinimumTakesRoomFromTheOthers() {
        // The first tile needs 500. The other two share what is left, 2:1 as their weights say
        assertEquals(fitLengths([200, 600, 300], minimums: [500, 0, 0], total: 1100), [500, 400, 200])
    }

    func testMinimumsThatDontFitAreKept() {
        assertEquals(fitLengths([400, 400, 400], minimums: [500, 500, 500], total: 1200), [500, 500, 500])
    }

    func testContainerAddsMinimumsAlongItsOrientationAndTakesTheLargestAcross() {
        let root = Workspace.get(byName: name).rootTilingContainer
        TestWindow.new(id: 1, parent: root).minSize = CGSize(width: 400, height: 300)
        TestWindow.new(id: 2, parent: root).minSize = CGSize(width: 500, height: 700)
        assertEquals(root.minLength(.h, innerGap: 10), 910)
        assertEquals(root.minLength(.v, innerGap: 10), 700)
    }
}
