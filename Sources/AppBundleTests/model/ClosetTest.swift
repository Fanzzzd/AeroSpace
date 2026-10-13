@testable import AppBundle
import Common
import XCTest

final class ClosetTest: XCTestCase {
    private let laptop = Rect(topLeftX: 0, topLeftY: 0, width: 1728, height: 1117)
    private let closet = Rect(topLeftX: 1728, topLeftY: 1117, width: 2560, height: 1440)

    func testParkedWindowKeepsItsRelativeSpot() {
        let window = CGPoint(x: 432, y: 279.25)
        let proportion = laptop.proportion(of: window)
        assertEquals(proportion, CGPoint(x: 0.25, y: 0.25))
        let parked = closet.topLeft(at: proportion, for: CGSize(width: 800, height: 600))
        assertEquals(parked, CGPoint(x: 2368, y: 1477))
        // Back from the closet, the window is where it was
        assertEquals(laptop.topLeft(at: closet.proportion(of: parked), for: CGSize(width: 800, height: 600)), window)
    }

    func testWindowStaysInsideWhenItFits() {
        let topLeft = laptop.topLeft(at: CGPoint(x: 0.9, y: 0.9), for: CGSize(width: 800, height: 600))
        assertEquals(topLeft, CGPoint(x: 928, y: 517))
    }

    func testWindowLargerThanTheRectStartsAtItsTopLeft() {
        let topLeft = laptop.topLeft(at: CGPoint(x: 0.5, y: 0.5), for: CGSize(width: 3000, height: 2000))
        assertEquals(topLeft, CGPoint(x: 0, y: 0))
    }

    func testClosetGoesToTheBottomRightCornerOfTheOnlyDisplay() {
        let laptop = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        assertEquals(Closet.target(size: CGSize(width: 1728, height: 1117), others: [laptop]), CGPoint(x: 1728, y: 1117))
    }

    func testClosetSharesNoEdgeWithADisplay() {
        let laptop = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        // Right of the laptop, lower than it: the laptop's corner would put the closet against this display's left edge
        let side = CGRect(x: 1728, y: 300, width: 1920, height: 1080)
        assertEquals(Closet.target(size: CGSize(width: 1920, height: 1117), others: [laptop, side]), CGPoint(x: 3648, y: 1380))
    }
}
