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
