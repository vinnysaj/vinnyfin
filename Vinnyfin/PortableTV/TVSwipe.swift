import CoreGraphics
import Foundation

/// One touch on the remote's surface, read as moves of focus: a swipe moves a step however long
/// it is, a finger that keeps dragging moves again for each further stretch once the step before
/// has settled, and a flick glides on a few more. Less than a flick's travel is a tap.
nonisolated struct TVSwipe: Equatable, Sendable {
    /// What a touch came to as the finger lifted.
    enum Ending: Equatable, Sendable {
        case tap
        /// A swipe in `direction`. One too short to have moved focus yet `owesMove`, and a quick
        /// one goes on by `glide` steps after it.
        case swipe(TVDirection, owesMove: Bool, glide: Int)
    }

    /// How far a finger goes for each step of focus.
    static let step: CGFloat = 60
    /// A shorter swipe than a step still moves once; less than this is a tap.
    static let flick: CGFloat = 22
    /// How long after a step the finger's travel counts for nothing, so the rest of the swipe
    /// that made the step isn't taken for another.
    static let settle: TimeInterval = 0.25
    /// The speed a finger lifts at, in points a second, for a swipe to glide on a step, and how
    /// much faster for each step more.
    static let glideSpeed: CGFloat = 2000
    static let speedPerGlideStep: CGFloat = 800
    static let longestGlide = 6

    /// Where the stretch under way started.
    private var stretchStart: CGPoint
    /// When the touch last moved focus; nil until it has.
    private var lastStep: Date?

    init(from start: CGPoint) {
        stretchStart = start
    }

    /// The move of focus the finger makes by reaching `location` at `time`, if any.
    mutating func moved(to location: CGPoint, at time: Date) -> TVDirection? {
        if let lastStep, time.timeIntervalSince(lastStep) < Self.settle {
            stretchStart = location
            return nil
        }
        let dx = location.x - stretchStart.x
        let dy = location.y - stretchStart.y
        guard max(abs(dx), abs(dy)) >= Self.step else { return nil }
        stretchStart = location
        lastStep = time
        return Self.direction(dx: dx, dy: dy)
    }

    /// What the touch came to, lifting `translation` from where it began at `velocity`, in points a second.
    func ended(translation: CGSize, velocity: CGSize) -> Ending {
        let dx = translation.width
        let dy = translation.height
        let hasMoved = lastStep != nil
        if !hasMoved, max(abs(dx), abs(dy)) < Self.flick { return .tap }
        let direction = Self.direction(dx: dx, dy: dy)
        // The speed in the swipe's own direction: a finger lifting on its way back glides nowhere.
        let speed = switch direction {
        case .right: velocity.width
        case .left: -velocity.width
        case .down: velocity.height
        case .up: -velocity.height
        }
        let glide = speed < Self.glideSpeed ? 0 : min(Self.longestGlide, 1 + Int((speed - Self.glideSpeed) / Self.speedPerGlideStep))
        return .swipe(direction, owesMove: !hasMoved, glide: glide)
    }

    private static func direction(dx: CGFloat, dy: CGFloat) -> TVDirection {
        if abs(dx) > abs(dy) {
            dx > 0 ? .right : .left
        } else {
            dy > 0 ? .down : .up
        }
    }
}
