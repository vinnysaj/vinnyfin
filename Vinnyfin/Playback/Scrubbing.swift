import Foundation
import Observation

/// Where the viewer is taking the timeline before letting go: dragged on a touchscreen, or on
/// Apple TV swiped, circled, stepped or scanned with the remote. Playback carries on where it
/// was until the player commits the position, which seeks there, or drops it.
@MainActor @Observable
final class Scrubbing {
    /// The position being chosen; nil when nothing is.
    var position: Double?
    /// Seconds of the title a second while a held direction scans through it, negative going
    /// back; nil when nothing is scanning.
    private(set) var scanSpeed: Double?
    /// The skips taken in a row, whose sum shows by the timeline for a moment.
    private(set) var skipRun: SkipRun?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var skipRunTask: Task<Void, Never>?

    struct SkipRun: Equatable {
        /// The skips' sum, negative going back.
        let seconds: Double
        /// New for each run, so a run that starts over reads as a new one.
        let id: Int
        fileprivate let lastSkip: ContinuousClock.Instant
    }

    /// Skips this close together add up to one run.
    private static let skipRunGap = Duration.seconds(1.5)

    var isActive: Bool { position != nil }
    var isScanning: Bool { scanSpeed != nil }

    /// Moves the position by `seconds`, starting it from the playhead `time` when nothing was
    /// being chosen, and keeps it within the title.
    func move(by seconds: Double, from time: Double, duration: Double) {
        position = Self.clamp((position ?? time) + seconds, duration: duration)
    }

    /// Runs the position forward, or back, faster the longer it goes, until `finish()`.
    func beginScan(forward: Bool, from time: Double, duration: Double) {
        scanTask?.cancel()
        if position == nil { position = Self.clamp(time, duration: duration) }
        let clock = ContinuousClock()
        let began = clock.now
        scanTask = Task { [weak self] in
            var last = began
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                let now = clock.now
                let speed = ScrubMotion.scanSpeed(heldFor: (now - began) / .seconds(1), duration: duration) * (forward ? 1 : -1)
                if self.scanSpeed != speed { self.scanSpeed = speed }
                let elapsed = (now - last) / .seconds(1)
                last = now
                if let position = self.position {
                    self.position = Self.clamp(position + speed * elapsed, duration: duration)
                }
            }
        }
    }

    /// Stops choosing, and returns the position chosen.
    @discardableResult
    func finish() -> Double? {
        scanTask?.cancel()
        scanTask = nil
        if scanSpeed != nil { scanSpeed = nil }
        let chosen = position
        if chosen != nil { position = nil }
        return chosen
    }

    /// Counts a skip into the run of skips, or starts a new one going the other way or after a pause.
    func noteSkip(_ seconds: Double) {
        let now = ContinuousClock.now
        if let run = skipRun, now - run.lastSkip < Self.skipRunGap, (run.seconds < 0) == (seconds < 0) {
            skipRun = SkipRun(seconds: run.seconds + seconds, id: run.id, lastSkip: now)
        } else {
            skipRun = SkipRun(seconds: seconds, id: (skipRun?.id ?? 0) + 1, lastSkip: now)
        }
        skipRunTask?.cancel()
        skipRunTask = Task { [weak self] in
            try? await Task.sleep(for: Self.skipRunGap)
            guard !Task.isCancelled else { return }
            self?.skipRun = nil
        }
    }

    /// Within the title, short of its last second, which would end it.
    private static func clamp(_ seconds: Double, duration: Double) -> Double {
        max(0, duration > 1 ? min(seconds, duration - 1) : seconds)
    }
}

/// How far the remote's gestures take the timeline, tuned so a slow movement places it to the
/// second and a quick one crosses a film.
nonisolated enum ScrubMotion {
    /// Seconds a swipe of `distance` across the touch surface (a fraction of its width, positive to
    /// the right) moves the timeline when the finger travels at `speed` widths a second. A full
    /// width at an ordinary pace covers about a twelfth of the title, between 45 seconds and 8
    /// minutes; slower swipes cover less of it, down to a third, and quicker ones up to four times.
    static func swipe(_ distance: Double, speed: Double, duration: Double) -> Double {
        let span = min(max(duration / 12, 45), 480)
        let gain = min(max(0.3 + 0.7 * abs(speed), 0.3), 4)
        return distance * span * gain
    }

    /// Seconds of the title one full circle of the clickpad's ring moves the timeline: a fiftieth
    /// of the title, between 30 seconds and two minutes, for placing it finely.
    static func secondsPerTurn(duration: Double) -> Double {
        min(max(duration / 50, 30), 120)
    }

    /// Seconds the timeline moves for `turn` radians around the ring, clockwise positive.
    static func circle(_ turn: Double, duration: Double) -> Double {
        turn / (2 * .pi) * secondsPerTurn(duration: duration)
    }

    /// The scanning speeds, in seconds of the title a second, that a held direction steps through.
    static let scanSpeeds: [Double] = [8, 24, 64, 128]
    /// How long each scanning speed lasts before the next.
    static let scanStep: Double = 2

    /// The speed after holding a direction `seconds`. A short title scans no faster than crosses it in eight seconds.
    static func scanSpeed(heldFor seconds: Double, duration: Double) -> Double {
        let level = scanSpeeds[min(max(0, Int(seconds / scanStep)), scanSpeeds.count - 1)]
        return min(level, max(duration / 8, scanSpeeds[0]))
    }
}

/// Tells a finger circling the edge of the remote's touch surface, the Siri Remote's clickpad ring,
/// from one swiping across it, from where on the surface the finger is. Circling, the direction it
/// moves in turns as far as it goes around the middle; swiping, even in an arc along the edge, it
/// turns much less.
nonisolated struct RingTurn {
    /// The finger is circling: each new point turns the timeline.
    private(set) var isTurning = false
    private var last: SIMD2<Double>?
    /// Where the stretch of movement being measured for its direction began.
    private var anchor: SIMD2<Double>?
    private var heading: Double?
    /// How far the direction of movement has turned, counterclockwise positive.
    private var bend: Double = 0
    /// How far around the middle the finger has gone, counterclockwise positive.
    private var sweep: Double = 0

    /// Nearer the middle than this, the finger isn't on the ring.
    static let ringRadius = 0.6
    /// Circling stops when the finger comes this near the middle.
    static let leaveRadius = 0.35
    /// How far around it goes before it counts as circling: about a seventh of a turn.
    static let startingSweep = 0.9
    /// The movement turns at least this share of the way around, circling.
    static let bendShare = 0.7
    /// Distance the finger travels between measures of its direction.
    private static let stretch = 0.06

    /// Takes where the finger is, x to the right and y up, each from -1 to 1, or nil when it has
    /// lifted. Returns the turn to apply in radians, clockwise positive, while circling: on the
    /// point that shows it is, the whole way it has gone round since it reached the ring.
    mutating func update(_ point: SIMD2<Double>?) -> Double? {
        guard let point else {
            self = RingTurn()
            return nil
        }
        let radius = (point * point).sum().squareRoot()
        defer { last = point }
        guard let last else {
            if radius >= Self.ringRadius { anchor = point }
            return nil
        }
        let turn = Self.wrapped(Self.angle(point) - Self.angle(last))
        if isTurning {
            guard radius >= Self.leaveRadius else {
                isTurning = false
                restart()
                return nil
            }
            return -turn
        }
        guard radius >= Self.ringRadius else {
            restart()
            return nil
        }
        guard let anchor else {
            self.anchor = point
            return nil
        }
        sweep += turn
        let move = point - anchor
        guard (move * move).sum().squareRoot() >= Self.stretch else { return nil }
        let direction = atan2(move.y, move.x)
        if let heading { bend += Self.wrapped(direction - heading) }
        heading = direction
        self.anchor = point
        guard abs(sweep) >= Self.startingSweep, (bend < 0) == (sweep < 0), abs(bend) >= abs(sweep) * Self.bendShare else { return nil }
        isTurning = true
        return -sweep
    }

    private mutating func restart() {
        anchor = nil
        heading = nil
        bend = 0
        sweep = 0
    }

    private static func angle(_ point: SIMD2<Double>) -> Double { atan2(point.y, point.x) }

    /// Within a half turn either way.
    private static func wrapped(_ angle: Double) -> Double {
        var angle = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if angle > .pi { angle -= 2 * .pi }
        if angle < -.pi { angle += 2 * .pi }
        return angle
    }
}
