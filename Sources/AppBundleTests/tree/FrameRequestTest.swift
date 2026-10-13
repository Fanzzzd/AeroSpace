@testable import AppBundle
import Common
import XCTest

final class FrameRequestTest: XCTestCase {
    private let current = Rect(topLeftX: 1733, topLeftY: 1152, width: 155, height: 1073)

    func testShowingAParkedWindowMovesItWithoutResizing() {
        let request = FrameRequest(topLeft: CGPoint(x: 164, y: 38), size: CGSize(width: 155.4, height: 1073))
        assertEquals(request.missing(from: current, lastAnswer: nil), FrameRequest(topLeft: CGPoint(x: 164, y: 38), size: nil))
    }

    func testWindowThatHasItAllNeedsNothing() {
        let request = FrameRequest(topLeft: CGPoint(x: 1733.4, y: 1152), size: nil)
        assertTrue(request.missing(from: current, lastAnswer: nil).isEmpty)
    }

    func testWhatTheAppGaveForTheSameRequestCountsAsDone() {
        // A terminal rounds 160 pt down to whole cells
        let request = FrameRequest(topLeft: CGPoint(x: 1733, y: 1152), size: CGSize(width: 160, height: 1073))
        let answer = FrameAnswer(asked: request, got: current)
        assertTrue(request.missing(from: current, lastAnswer: answer).isEmpty)
    }

    func testAnAnswerToAnotherRequestDoesntCount() {
        let request = FrameRequest(topLeft: CGPoint(x: 1733, y: 1152), size: CGSize(width: 160, height: 1073))
        let answer = FrameAnswer(asked: FrameRequest(topLeft: nil, size: CGSize(width: 300, height: 1073)), got: current)
        assertEquals(request.missing(from: current, lastAnswer: answer), FrameRequest(topLeft: nil, size: CGSize(width: 160, height: 1073)))
    }

    func testWindowMovedAwayFromWhatTheAppGaveIsWrittenAgain() {
        let request = FrameRequest(topLeft: CGPoint(x: 1733, y: 1152), size: nil)
        let answer = FrameAnswer(asked: request, got: current)
        let dragged = Rect(topLeftX: 400, topLeftY: 300, width: 155, height: 1073)
        assertEquals(request.missing(from: dragged, lastAnswer: answer), request)
    }

    @MainActor
    func testMoveIsAeroSpacesOwnWhenTheWindowIsWhereTheAppPutIt() {
        setUpWorkspacesForTests()
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        assertTrue(!window.isWhereAeroSpacePutIt(current))
        window.frameAnswer = FrameAnswer(asked: FrameRequest(topLeft: CGPoint(x: 1733, y: 1152), size: nil), got: current)
        assertTrue(window.isWhereAeroSpacePutIt(Rect(topLeftX: 1733.4, topLeftY: 1152, width: 155, height: 1073)))
        assertTrue(!window.isWhereAeroSpacePutIt(Rect(topLeftX: 400, topLeftY: 300, width: 155, height: 1073)))
    }
}
