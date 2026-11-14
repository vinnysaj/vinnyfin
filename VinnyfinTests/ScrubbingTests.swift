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
        #expect(ScrubMotion.scanSpeed(heldFor: 1.5, duration: film) == 24)
        #expect(ScrubMotion.scanSpeed(heldFor: 2.6, duration: film) == 64)
        #expect(ScrubMotion.scanSpeed(heldFor: 4, duration: film) == 128)
    }

    @Test func aLongTitleScansOnToCrossItInFifteenSeconds() {
        let film = 2 * 3600.0
        #expect(ScrubMotion.scanLevels(duration: film) == [8, 24, 64, 128, 480])
        #expect(ScrubMotion.scanSpeed(heldFor: 5.1, duration: film) == 480)
        #expect(ScrubMotion.scanSpeed(heldFor: 60, duration: film) == 480)
        // An episode tops out where the speeds always did.
        #expect(ScrubMotion.scanLevels(duration: 22 * 60) == ScrubMotion.scanSpeeds)
        #expect(ScrubMotion.scanSpeed(heldFor: 60, duration: 22 * 60) == 128)
    }

    @Test func aScanLetGoJustPastAChapterLandsOnIt() {
        let starts = [0.0, 300, 900]
        // At 24× a half second of scanning is 12 seconds of the title, either side.
        #expect(ScrubMotion.landing(308, speed: 24, chapterStarts: starts) == 300)
        #expect(ScrubMotion.landing(292, speed: 24, chapterStarts: starts) == 300)
        #expect(ScrubMotion.landing(320, speed: 24, chapterStarts: starts) == 320)
        #expect(ScrubMotion.landing(870, speed: -64, chapterStarts: starts) == 900)
        // Never back to the title's start.
        #expect(ScrubMotion.landing(3, speed: -24, chapterStarts: starts) == 3)
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

    @Test func aScanFinishesOnAChapterItJustReached() async throws {
        let scrubbing = Scrubbing()
        scrubbing.beginScan(forward: true, from: 100, duration: 2 * 3600)
        try await Task.sleep(for: .milliseconds(400))
        // Somewhere past 101 at 8×, within four seconds of 105.
        #expect(scrubbing.finishScan(chapterStarts: [105]) == 105)
        #expect(!scrubbing.isActive)
    }

    @Test func aPositionMovedRatherThanScannedIsntPulledToAChapter() {
        let scrubbing = Scrubbing()
        scrubbing.move(by: 10, from: 20, duration: 600)
        #expect(scrubbing.finishScan(chapterStarts: [31]) == 30)
    }

    @Test func finishingSetsTheDragBackToFullSpeed() {
        let scrubbing = Scrubbing()
        scrubbing.move(by: 10, from: 20, duration: 600)
        scrubbing.dragRate = 0.25
        scrubbing.finish()
        #expect(scrubbing.dragRate == 1)
    }
}

struct TimelineDragTests {
    /// A ten-minute title on a timeline 400 points wide: 1.5 seconds a point.
    private func drag(from x: Double, at position: Double) -> TimelineDrag {
        TimelineDrag(startX: x, position: position, duration: 600, width: 400)
    }

    @Test func takingHoldOfTheBarDoesntJumpThePosition() {
        var drag = drag(from: 360, at: 60)
        drag.move(toX: 360, rise: 0)
        #expect(drag.position == 60)
        drag.move(toX: 380, rise: 0)
        #expect(drag.position == 90)
        drag.move(toX: 340, rise: 0)
        #expect(drag.position == 30)
    }

    @Test func slidingUpSlowsThePositionToHalfThenAQuarter() {
        #expect(TimelineDrag.rate(rise: 0) == 1)
        #expect(TimelineDrag.rate(rise: 47) == 1)
        #expect(TimelineDrag.rate(rise: 48) == 0.5)
        #expect(TimelineDrag.rate(rise: 112) == 0.25)
        #expect(TimelineDrag.rate(rise: -200) == 1)

        var drag = drag(from: 0, at: 300)
        drag.move(toX: 40, rise: 0)
        #expect(drag.position == 360)
        // Changing speed doesn't move the position; moving on does, at the new speed.
        drag.move(toX: 40, rise: 60)
        #expect(drag.position == 360)
        #expect(drag.rate == 0.5)
        drag.move(toX: 80, rise: 60)
        #expect(drag.position == 390)
        drag.move(toX: 80, rise: 120)
        #expect(drag.rate == 0.25)
        drag.move(toX: 120, rise: 120)
        #expect(drag.position == 405)
        #expect(drag.seconds(forPoints: 4) == 1.5)
        // Back down, full speed again.
        drag.move(toX: 120, rise: 0)
        drag.move(toX: 100, rise: 0)
        #expect(drag.position == 375)
    }

    @Test func heldAtAnEndThePositionComesBackAsSoonAsTheFingerDoes() {
        var drag = drag(from: 200, at: 570)
        drag.move(toX: 390, rise: 0)
        #expect(drag.position == 600)
        drag.move(toX: 380, rise: 0)
        #expect(drag.position == 585)
        drag.move(toX: -300, rise: 0)
        #expect(drag.position == 0)
        drag.move(toX: -296, rise: 0)
        #expect(drag.position == 6)
    }

    @Test func aTapJumpsToWhereItLanded() {
        #expect(TimelineDrag.tapPosition(x: 100, width: 400, duration: 600) == 150)
        #expect(TimelineDrag.tapPosition(x: -8, width: 400, duration: 600) == 0)
        #expect(TimelineDrag.tapPosition(x: 410, width: 400, duration: 600) == 600)
        #expect(TimelineDrag.tapPosition(x: 10, width: 0, duration: 600) == 0)
    }
}

struct ChapterSnapTests {
    @Test func aPositionNearAChapterStartHoldsAtIt() {
        let starts = [0.0, 300, 900]
        #expect(ChapterSnap.snapped(296, to: starts, within: 5) == 300)
        #expect(ChapterSnap.snapped(304, to: starts, within: 5) == 300)
        #expect(ChapterSnap.snapped(290, to: starts, within: 5) == 290)
        #expect(ChapterSnap.snapped(296, to: starts, within: 0) == 296)
        #expect(ChapterSnap.snapped(296, to: [], within: 5) == 296)
    }

    @Test func theNearestStartWinsAndTheTitlesOwnStartIsntOne() {
        #expect(ChapterSnap.snapped(604, to: [600, 606], within: 10) == 606)
        #expect(ChapterSnap.snapped(2, to: [0, 300], within: 5) == 2)
    }
}

struct ScrubLandmarkTests {
    private let chapters = [0.0, 300, 900].enumerated().map { index, start in
        ChapterMark(index: index, start: start, name: "Chapter \(index + 1)", image: nil)
    }

    @Test func knowsWhereAPositionIs() {
        #expect(ScrubLandmark.at(nil, duration: 1200, chapters: chapters) == nil)
        #expect(ScrubLandmark.at(0, duration: 1200, chapters: chapters) == .start)
        #expect(ScrubLandmark.at(1200, duration: 1200, chapters: chapters) == .end)
        #expect(ScrubLandmark.at(100, duration: 1200, chapters: chapters) == .chapter(0))
        #expect(ScrubLandmark.at(300, duration: 1200, chapters: chapters) == .chapterStart(1))
        #expect(ScrubLandmark.at(301, duration: 1200, chapters: chapters) == .chapter(1))
        #expect(ScrubLandmark.at(100, duration: 1200, chapters: []) == .chapter(nil))
    }

    @Test func ticksOnReachingAnEndOrAChapter() {
        #expect(ScrubLandmark.ticks(from: .chapter(0), to: .chapterStart(1)))
        #expect(ScrubLandmark.ticks(from: .chapter(0), to: .chapter(1)))
        #expect(ScrubLandmark.ticks(from: .chapter(2), to: .end))
        #expect(ScrubLandmark.ticks(from: .chapter(0), to: .start))
    }

    @Test func doesntTickOnLeavingOneOrStartingAndEndingADrag() {
        #expect(!ScrubLandmark.ticks(from: .chapterStart(1), to: .chapter(1)))
        #expect(!ScrubLandmark.ticks(from: .start, to: .chapter(0)))
        #expect(!ScrubLandmark.ticks(from: .chapter(1), to: .chapter(1)))
        #expect(!ScrubLandmark.ticks(from: nil, to: .chapter(0)))
        #expect(!ScrubLandmark.ticks(from: .chapter(0), to: nil))
        #expect(!ScrubLandmark.ticks(from: .chapter(nil), to: .chapter(nil)))
    }
}

struct StraySwipeTests {
    @Test func withTheControlsHiddenASwipeGoesFurtherBeforeItCounts() {
        #expect(StraySwipe.threshold(controlsHidden: true, isScrubbing: false) == StraySwipe.hiddenThreshold)
        #expect(StraySwipe.threshold(controlsHidden: false, isScrubbing: false) == StraySwipe.threshold)
        // Once the timeline is moving, it keeps following small movements.
        #expect(StraySwipe.threshold(controlsHidden: true, isScrubbing: true) == StraySwipe.threshold)
        #expect(StraySwipe.hiddenThreshold > StraySwipe.threshold * 3)
    }

    @Test func onlyAPositionLeftWhilePlayingIsDropped() {
        #expect(StraySwipe.dropsIdlePosition(isPlaying: true, isScanning: false))
        #expect(!StraySwipe.dropsIdlePosition(isPlaying: false, isScanning: false))
        #expect(!StraySwipe.dropsIdlePosition(isPlaying: true, isScanning: true))
        #expect(StraySwipe.idleLimit == .seconds(4))
    }
}

@MainActor
struct TimeLabelTests {
    @Test func theFastestScanReadsWholeBesideHourLongTimes() {
        // A film scanned at full speed an hour in, its preview's caption: speed, time, distance.
        #expect(TimeLabel.scanSpeed(128) == "128×")
        #expect(TimeLabel.scanSpeed(-128) == "128×")
        #expect(Scrubber.format(3725) == "1:02:05")
        #expect(TimeLabel.distance(3900) == "+1:05:00")
        #expect(TimeLabel.distance(-285) == "\u{2212}4:45")
    }

    @Test func everyScanSpeedFitsTheWidthKeptForTheFastest() {
        for duration: Double in [30, 22 * 60, 2 * 3600, 4 * 3600] {
            let widest = TimeLabel.widestScanSpeed(duration: duration)
            for held in stride(from: 0.0, through: 10, by: 0.25) {
                let speed = TimeLabel.scanSpeed(ScrubMotion.scanSpeed(heldFor: held, duration: duration))
                #expect(speed.count <= widest.count)
            }
        }
        #expect(TimeLabel.widestScanSpeed(duration: 2 * 3600) == "480×")
    }

    @Test func slowedScrubbingSaysSo() {
        #expect(TimeLabel.dragRate(1) == nil)
        #expect(TimeLabel.dragRate(0.5) == "Half-Speed Scrubbing")
        #expect(TimeLabel.dragRate(0.25) == "Fine Scrubbing")
    }

    @Test func timeLeftTakesAMinusSignNotAHyphen() {
        #expect(TimeLabel.remaining(4742) == "\u{2212}1:19:02")
        #expect(TimeLabel.remaining(-3) == "\u{2212}0:00")
    }

    @Test func theEndTimeAllowsForTheSpeed() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        #expect(TimeLabel.end(after: 3600, rate: 1, from: now) == now.addingTimeInterval(3600))
        #expect(TimeLabel.end(after: 3600, rate: 1.5, from: now) == now.addingTimeInterval(2400))
        #expect(TimeLabel.end(after: 3600, rate: 0.5, from: now) == now.addingTimeInterval(7200))
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
