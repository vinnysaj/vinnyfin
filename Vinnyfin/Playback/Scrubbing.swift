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
    /// How far the position moves for a finger's movement along a touchscreen's timeline: below
    /// 1 while the finger has slid up away from the bar to place it finely (`TimelineDrag`).
    var dragRate: Double = 1

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
        if dragRate != 1 { dragRate = 1 }
        let chosen = position
        if chosen != nil { position = nil }
        return chosen
    }

    /// Stops a scan, and returns where it landed: on a chapter's start when it was let go just
    /// before or after one (`ScrubMotion.landing`).
    func finishScan(chapterStarts: [Double]) -> Double? {
        let speed = scanSpeed
        guard let chosen = finish() else { return nil }
        guard let speed else { return chosen }
        return ScrubMotion.landing(chosen, speed: speed, chapterStarts: chapterStarts)
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
    static let scanStep: Double = 1.25
    /// Past the last of `scanSpeeds`, a long title scans faster still: across the whole of it in
    /// this many seconds.
    static let scanCrossing: Double = 15
    /// A scan let go within this many seconds of scanning of a chapter's start lands on it.
    static let scanLandingReach: Double = 0.5

    /// The speeds a held direction steps through for a title of `duration`: `scanSpeeds`, then one
    /// that crosses a long title in `scanCrossing`.
    static func scanLevels(duration: Double) -> [Double] {
        let crossing = duration / scanCrossing
        return crossing > scanSpeeds[scanSpeeds.count - 1] ? scanSpeeds + [crossing] : scanSpeeds
    }

    /// The speed after holding a direction `seconds`. A short title scans no faster than crosses it in eight seconds.
    static func scanSpeed(heldFor seconds: Double, duration: Double) -> Double {
        let levels = scanLevels(duration: duration)
        let level = levels[min(max(0, Int(seconds / scanStep)), levels.count - 1)]
        return min(level, max(duration / 8, scanSpeeds[0]))
    }

    /// Where a scan at `speed` let go at `position` lands: on the nearest chapter start it would
    /// have reached, or just passed, in `scanLandingReach` of scanning, else where it was let go.
    /// At speed there's no aiming finer than that, and a chapter's start is what's aimed for.
    static func landing(_ position: Double, speed: Double, chapterStarts: [Double]) -> Double {
        ChapterSnap.snapped(position, to: chapterStarts, within: abs(speed) * scanLandingReach)
    }
}

/// A finger dragging a touchscreen's timeline. The position moves as far as the finger does,
/// from where it was rather than from where the finger landed, so taking hold of the bar never
/// jumps; a touch that doesn't move is a tap, which does jump there. Sliding the finger up away
/// from the bar slows the position to half and then a quarter of the finger's movement, for
/// placing it finely.
nonisolated struct TimelineDrag: Equatable {
    /// How far, in points, a finger moves before its touch is a drag rather than a tap.
    static let tapSlop: Double = 4
    /// How far up from where it took hold, in points, the finger slides to scrub at half speed,
    /// and at a quarter.
    static let halfSpeedRise: Double = 48
    static let quarterSpeedRise: Double = 112

    let duration: Double
    /// The timeline's width in points.
    let width: Double
    /// Seconds of the title per point of finger movement along the bar.
    private(set) var rate: Double = 1
    /// Where the finger has taken the position, before any snap to a chapter (`ChapterSnap`).
    private(set) var position: Double
    private var anchorX: Double
    private var anchorPosition: Double

    /// The finger took hold at `x` along a bar `width` wide, the position then at `position`.
    init(startX x: Double, position: Double, duration: Double, width: Double) {
        self.duration = max(0, duration)
        self.width = max(1, width)
        self.position = min(max(0, position), self.duration)
        anchorX = x
        anchorPosition = self.position
    }

    /// The finger moved to `x` along the bar, `rise` points above where it took hold.
    mutating func move(toX x: Double, rise: Double) {
        let unclamped = anchorPosition + (x - anchorX) / width * duration * rate
        position = min(max(0, unclamped), duration)
        // Held at an end, the position moves back as soon as the finger does.
        if position != unclamped { reanchor(at: x) }
        let newRate = Self.rate(rise: rise)
        if newRate != rate {
            // From here, so a change of speed doesn't move the position.
            reanchor(at: x)
            rate = newRate
        }
    }

    /// The share of the finger's movement the position follows, `rise` points above where it
    /// took hold: all of it, a half, or a quarter.
    static func rate(rise: Double) -> Double {
        if rise >= quarterSpeedRise { return 0.25 }
        if rise >= halfSpeedRise { return 0.5 }
        return 1
    }

    /// Where a tap at `x` along a bar `width` wide jumps to.
    static func tapPosition(x: Double, width: Double, duration: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(max(0, x / width * duration), max(0, duration))
    }

    /// Seconds of the title within `points` of finger movement, at the drag's speed.
    func seconds(forPoints points: Double) -> Double {
        points / width * duration * rate
    }

    private mutating func reanchor(at x: Double) {
        anchorX = x
        anchorPosition = position
    }
}

/// A position being chosen holds at a chapter's start while it's near one, so the start of a
/// scene is easy to land on.
nonisolated enum ChapterSnap {
    /// How near a chapter's start, in points of finger movement, a dragged position holds at it.
    static let reach: Double = 5

    /// The chapter start nearest `position` within `tolerance` seconds of it, else `position`.
    /// The title's own start and end aren't chapter starts to hold at.
    static func snapped(_ position: Double, to starts: [Double], within tolerance: Double) -> Double {
        guard tolerance > 0 else { return position }
        let nearest = starts.filter { $0 > 0 }.min { abs($0 - position) < abs($1 - position) }
        guard let nearest, abs(nearest - position) <= tolerance else { return position }
        return nearest
    }
}

/// What a tick marks as the position being chosen moves: reaching either end of the title,
/// coming to hold at a chapter's start, or crossing into another chapter.
nonisolated enum ScrubLandmark: Equatable {
    case start, end
    /// The chapter's index; nil without chapters.
    case chapter(Int?)
    /// Holding at the start of the chapter with this index.
    case chapterStart(Int)

    /// Where `position` is among `chapters`; nil when nothing is being chosen.
    static func at(_ position: Double?, duration: Double, chapters: [ChapterMark]) -> ScrubLandmark? {
        guard let position else { return nil }
        if position <= 0 { return .start }
        if position >= duration { return .end }
        let chapter = ChapterMark.current(in: chapters, at: position)
        if let chapter, chapter.start == position { return .chapterStart(chapter.index) }
        return .chapter(chapter?.index)
    }

    /// Reaching an end ticks, as does coming to hold at a chapter's start or crossing from one
    /// chapter into another without holding. Leaving an end or a hold, and starting or ending a
    /// drag, don't.
    static func ticks(from old: ScrubLandmark?, to new: ScrubLandmark?) -> Bool {
        guard let old, let new, old != new else { return false }
        switch (old, new) {
        case (_, .start), (_, .end), (_, .chapterStart), (.chapter, .chapter): return true
        default: return false
        }
    }
}

/// How the Apple TV remote keeps a thumb resting on its touch surface from moving the timeline:
/// with the controls hidden a swipe has to go further before it counts, and a position chosen
/// while playing that's left alone goes away rather than holding the timeline up.
nonisolated enum StraySwipe {
    /// How far a swipe goes, as a share of the surface's width, before it moves the timeline
    /// with the controls up, or one already moving.
    static let threshold = 0.02
    /// With the controls hidden, past the drift of a thumb resting on the surface or picking the
    /// remote up.
    static let hiddenThreshold = 0.07
    /// A position chosen while playing, left this long without a gesture, is dropped.
    static let idleLimit: Duration = .seconds(4)

    /// How far a swipe goes before it counts.
    static func threshold(controlsHidden: Bool, isScrubbing: Bool) -> Double {
        controlsHidden && !isScrubbing ? hiddenThreshold : threshold
    }

    /// Whether a position chosen and left alone for `idleLimit` is dropped: while playing, where
    /// it would hold the timeline over the picture. Paused, it waits for a click; scanning, the
    /// side is still held.
    static func dropsIdlePosition(isPlaying: Bool, isScanning: Bool) -> Bool {
        isPlaying && !isScanning
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
