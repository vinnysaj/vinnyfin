import Foundation
import Testing
@testable import vinnyfin

struct ScrubMotionTests {
    @Test func aQuickSwipeCoversMoreThanASlowOne() {
        let film = 2 * 3600.0
        let slow = ScrubMotion.swipe(0.5, speed: 0.2, duration: film)
        let quick = ScrubMotion.swipe(0.5, speed: 3, duration: film)
        #expect(slow > 0)
        #expect(quick > slow * 4)
        #expect(ScrubMotion.swipe(-0.5, speed: 3, duration: film) == -quick)
    }

    @Test func aSwipeAcrossCoversAShareOfTheTitleWithinLimits() {
        // An ordinary full-width swipe: a twelfth of the title, from 45 seconds to 8 minutes.
        #expect(ScrubMotion.swipe(1, speed: 1, duration: 22 * 60) == 22 * 60 / 12)
        #expect(ScrubMotion.swipe(1, speed: 1, duration: 3 * 60) == 45)
        #expect(ScrubMotion.swipe(1, speed: 1, duration: 3 * 3600) == 480)
    }

    @Test func aFullCircleMovesAFiftiethOfTheTitleWithinLimits() {
        #expect(ScrubMotion.circle(2 * .pi, duration: 2 * 3600) == 120)
        #expect(ScrubMotion.circle(2 * .pi, duration: 22 * 60) == 30)
        #expect(ScrubMotion.circle(-.pi, duration: 75 * 60) == -45)
    }

    @Test func holdingScansFasterTheLongerItsHeld() {
        let film = 2 * 3600.0
        #expect(ScrubMotion.scanSpeed(heldFor: 0.5, duration: film) == 8)
        #expect(ScrubMotion.scanSpeed(heldFor: 2.5, duration: film) == 24)
        #expect(ScrubMotion.scanSpeed(heldFor: 4.5, duration: film) == 64)
        #expect(ScrubMotion.scanSpeed(heldFor: 60, duration: film) == 128)
    }

    @Test func aShortTitleScansNoFasterThanCrossesItInEightSeconds() {
        #expect(ScrubMotion.scanSpeed(heldFor: 60, duration: 10 * 60) == 10 * 60 / 8)
        #expect(ScrubMotion.scanSpeed(heldFor: 60, duration: 30) == 8)
    }
}

struct RingTurnTests {
    /// Points every `step` degrees from `from` degrees, on a circle of `radius` around the middle.
    private func circle(from: Double, through degrees: Double, step: Double = 3, radius: Double = 0.85) -> [SIMD2<Double>] {
        let count = Int(abs(degrees) / step)
        return (0...count).map { index in
            let angle = (from + Double(index) * step * (degrees < 0 ? -1 : 1)) * .pi / 180
            return SIMD2(radius * cos(angle), radius * sin(angle))
        }
    }

    /// The turns the points come to, in order.
    private func turns(_ points: [SIMD2<Double>]) -> (turns: [Double], ring: RingTurn) {
        var ring = RingTurn()
        let turns = points.compactMap { ring.update($0) }
        return (turns, ring)
    }

    @Test func aClockwiseCircleTurnsForwardByAsFarAsItWent() {
        let (turns, ring) = turns(circle(from: 90, through: -360))
        #expect(ring.isTurning)
        #expect(abs(turns.reduce(0, +) - 2 * .pi) < 0.01)
    }

    @Test func aCounterclockwiseCircleTurnsBack() {
        let (turns, _) = turns(circle(from: 0, through: 180))
        #expect(abs(turns.reduce(0, +) + .pi) < 0.01)
    }

    @Test func aSwipeAlongTheEdgeIsntACircle() {
        let points = stride(from: -0.8, through: 0.8, by: 0.02).map { SIMD2($0, 0.9) }
        let (turns, ring) = turns(points)
        #expect(turns.isEmpty)
        #expect(!ring.isTurning)
    }

    @Test func aThumbsArcAlongTheEdgeIsntACircle() {
        // A thumb sweeping across the top, pivoting on its joint below the remote.
        for (center, radius) in [(-2.2, 3.1), (-0.6, 1.5)] {
            let points = stride(from: -0.8, through: 0.8, by: 0.02).map { x in
                SIMD2(x, center + (radius * radius - x * x).squareRoot())
            }
            #expect(turns(points).turns.isEmpty)
        }
    }

    @Test func aSwipeThroughTheMiddleIsntACircle() {
        let points = stride(from: -0.9, through: 0.9, by: 0.02).map { SIMD2($0, 0.05) }
        #expect(turns(points).turns.isEmpty)
    }

    @Test func circlingStopsWhenTheFingerComesToTheMiddle() {
        var points = circle(from: 90, through: -180)
        points += stride(from: 0.85, through: 0, by: -0.05).map { SIMD2(0, -$0) }
        let (_, ring) = turns(points)
        #expect(!ring.isTurning)
    }

    @Test func liftingStartsOver() {
        var ring = RingTurn()
        for point in circle(from: 90, through: -120) { _ = ring.update(point) }
        #expect(ring.isTurning)
        let turn = ring.update(nil)
        #expect(turn == nil)
        #expect(!ring.isTurning)
    }
}

@MainActor
struct ScrubbingTests {
    @Test func movesFromThePlayheadAndStaysWithinTheTitle() {
        let scrubbing = Scrubbing()
        scrubbing.move(by: 30, from: 100, duration: 600)
        #expect(scrubbing.position == 130)
        scrubbing.move(by: -500, from: 100, duration: 600)
        #expect(scrubbing.position == 0)
        scrubbing.move(by: 5000, from: 100, duration: 600)
        // Short of the last second, which would end it.
        #expect(scrubbing.position == 599)
    }

    @Test func finishingGivesThePositionAndForgetsIt() {
        let scrubbing = Scrubbing()
        #expect(scrubbing.finish() == nil)
        scrubbing.move(by: 10, from: 20, duration: 600)
        #expect(scrubbing.isActive)
        #expect(scrubbing.finish() == 30)
        #expect(!scrubbing.isActive)
    }

    @Test func skipsInARowAddUpUntilOneGoesTheOtherWay() {
        let scrubbing = Scrubbing()
        scrubbing.noteSkip(10)
        scrubbing.noteSkip(10)
        scrubbing.noteSkip(10)
        let run = scrubbing.skipRun
        #expect(run?.seconds == 30)
        scrubbing.noteSkip(-10)
        #expect(scrubbing.skipRun?.seconds == -10)
        #expect(scrubbing.skipRun?.id != run?.id)
    }

    @Test func scanningRunsThePositionForwardUntilFinished() async throws {
        let scrubbing = Scrubbing()
        scrubbing.beginScan(forward: true, from: 100, duration: 2 * 3600)
        #expect(scrubbing.position == 100)
        try await Task.sleep(for: .milliseconds(400))
        #expect(scrubbing.scanSpeed == 8)
        let position = try #require(scrubbing.finish())
        #expect(position > 101 && position < 110)
        #expect(!scrubbing.isScanning)
    }

    @Test func scanningBackStopsAtTheStart() async throws {
        let scrubbing = Scrubbing()
        scrubbing.beginScan(forward: false, from: 1, duration: 600)
        try await Task.sleep(for: .milliseconds(400))
        #expect(scrubbing.scanSpeed == -8)
        #expect(scrubbing.finish() == 0)
    }
}

struct TrickplayWidthTests {
    @Test func appleTVPrefersPreviewsSharpOnA4KTV() {
        let tv = TrickplayTiles.preferredWidth(onTV: true)
        #expect(TrickplayTiles.width(among: [320, 640, 1280], atLeast: tv) == 640)
        #expect(TrickplayTiles.width(among: [320, 960], atLeast: tv) == 960)
        // Without any that wide, the widest there is.
        #expect(TrickplayTiles.width(among: [240, 320], atLeast: tv) == 320)
    }

    @Test func otherDevicesKeepTheNarrowerPreviews() {
        let phone = TrickplayTiles.preferredWidth(onTV: false)
        #expect(TrickplayTiles.width(among: [320, 640, 1280], atLeast: phone) == 320)
    }
}
