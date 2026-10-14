import AppKit

/// A window frame AeroSpace asks an app for. A nil part stays as it is
struct FrameRequest: Equatable, Sendable {
    let topLeft: CGPoint?
    let size: CGSize?

    var isEmpty: Bool { topLeft == nil && size == nil }

    /// The parts the window doesn't have yet. Apps round sizes to whole character cells, keep minimum sizes and keep
    /// windows out of the menu bar, so a window may never get exactly what it is asked for: what the app gave for the
    /// same request last time counts as done
    func missing(from current: Rect, lastAnswer: FrameAnswer?) -> FrameRequest {
        let expected = lastAnswer.flatMap { $0.asked == self ? $0.got : nil }
        return FrameRequest(
            topLeft: topLeft.flatMap { current.topLeftCorner.isNear(expected?.topLeftCorner ?? $0) ? nil : $0 },
            size: size.flatMap { current.size.isNear(expected?.size ?? $0) ? nil : $0 },
        )
    }
}

/// A ``FrameRequest`` on its way to the app, numbered, so that a late report of an earlier, identical request isn't
/// taken for this one
struct PendingFrameRequest: Equatable, Sendable {
    let request: FrameRequest
    let number: Int
}

/// What an app made of a ``FrameRequest``
struct FrameAnswer: Sendable {
    let asked: FrameRequest
    let got: Rect
}

extension CGPoint {
    /// Apps round frames to whole points
    func isNear(_ other: CGPoint) -> Bool { abs(x - other.x) < 1 && abs(y - other.y) < 1 }
}

extension CGSize {
    func isNear(_ other: CGSize) -> Bool { abs(width - other.width) < 1 && abs(height - other.height) < 1 }
}

extension Window {
    /// Whether `request` has to go to the app, and if so, notes it as on its way. Layout asks for every window's frame
    /// on every refresh session; a request on its way, or one the app answered with nothing else moving the window
    /// since, needs nothing
    func startFrameRequest(_ request: FrameRequest) -> PendingFrameRequest? {
        if request == (pendingFrameRequest?.request ?? frameAnswer?.asked) { return nil }
        frameRequestCount += 1
        let pending = PendingFrameRequest(request: request, number: frameRequestCount)
        pendingFrameRequest = pending
        return pending
    }

    /// A frame write finished. `got` is the frame the window ended up with, nil when it couldn't be read
    @MainActor
    func frameWritten(_ pending: PendingFrameRequest, got: Rect?) {
        guard pending == pendingFrameRequest else { return } // A later request replaced it
        pendingFrameRequest = nil
        // A drag that began during the write may have moved the window before it was read
        guard let got, !isLeftMouseButtonDown else {
            frameAnswer = nil
            return
        }
        let answer = FrameAnswer(asked: pending.request, got: got)
        frameAnswer = answer
        learnMinSize(from: answer)
    }

    /// Whether the window is where the app put it on AeroSpace's last request, so that an AXMoved or AXResized about it
    /// is AeroSpace's own doing
    @MainActor
    func isWhereAeroSpacePutIt(_ frame: Rect?) -> Bool {
        guard let frame, let got = frameAnswer?.got else { return false }
        return frame.topLeftCorner.isNear(got.topLeftCorner) && frame.size.isNear(got.size)
    }
}

extension AXUIElement {
    /// Read on the app's thread
    var frame: Rect? {
        guard let topLeft = get(Ax.topLeftCornerAttr), let size = get(Ax.sizeAttr) else { return nil }
        return Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: size.width, height: size.height)
    }
}
