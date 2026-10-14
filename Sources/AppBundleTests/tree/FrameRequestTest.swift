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

    @MainActor
    func testRequestGoesToTheAppOnceUntilSomethingElseMovesTheWindow() {
        setUpWorkspacesForTests()
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        let request = FrameRequest(topLeft: CGPoint(x: 5, y: 38), size: CGSize(width: 855, height: 1073))
        let pending = window.startFrameRequest(request)!
        assertTrue(window.startFrameRequest(request) == nil) // On its way
        window.frameWritten(pending, got: Rect(topLeftX: 5, topLeftY: 38, width: 855, height: 1073))
        assertTrue(window.startFrameRequest(request) == nil) // Answered
        window.frameAnswer = nil // AXMoved from something else
        assertTrue(window.startFrameRequest(request) != nil)
    }

    @MainActor
    func testLateReportOfAnEarlierIdenticalRequestIsIgnored() {
        setUpWorkspacesForTests()
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        let x = FrameRequest(topLeft: CGPoint(x: 5, y: 38), size: nil)
        let y = FrameRequest(topLeft: CGPoint(x: 1733, y: 1152), size: nil)
        let first = window.startFrameRequest(x)!
        _ = window.startFrameRequest(y)!
        let third = window.startFrameRequest(x)!
        window.frameWritten(first, got: Rect(topLeftX: 5, topLeftY: 38, width: 855, height: 1073))
        assertEquals(window.pendingFrameRequest, third)
        assertTrue(window.frameAnswer == nil)
    }
}
