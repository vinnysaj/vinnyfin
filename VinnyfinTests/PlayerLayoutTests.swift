import AetherEngine
import CoreGraphics
import Foundation
import Testing
#if os(iOS)
import UIKit
#endif
@testable import vinnyfin

struct SubtitleLayoutTests {
    private func cue(_ id: Int, _ text: String, from start: Double, alignment: Int? = nil, position: CGPoint? = nil) -> SubtitleCue {
        let placement = alignment == nil && position == nil ? nil : SubtitleTextPlacement(alignment: alignment, position: position)
        return SubtitleCue(id: id, startTime: start, endTime: start + 4, body: .text(text), placement: placement)
    }

    private func stacks(_ pieces: [SubtitleLayout.Piece]) -> [(SubtitleLayout.Band, [Int])] {
        pieces.compactMap { piece in
            guard case .stack(let band, let cues) = piece.kind else { return nil }
            return (band, cues.map(\.id))
        }
    }

    @Test func twoBottomLinesShowingAtOnceStackInTheOrderTheyStarted() {
        // Listed later-first, as a file can have them.
        let pieces = SubtitleLayout.pieces(of: [cue(2, "And so do I.", from: 11), cue(1, "I'm leaving.", from: 10)])
        let laidOut = stacks(pieces)
        #expect(laidOut.count == 1)
        #expect(laidOut.first?.0 == .bottom)
        #expect(laidOut.first?.1 == [1, 2])
    }

    @Test func linesStackByBandOfThePicture() {
        let pieces = SubtitleLayout.pieces(of: [
            cue(1, "Dialogue", from: 0),
            cue(2, "A sign", from: 0, alignment: 8),
            cue(3, "More dialogue", from: 1, alignment: 2),
            cue(4, "Narration", from: 0, alignment: 5),
        ])
        let laidOut = stacks(pieces)
        #expect(laidOut.map(\.0) == [.top, .middle, .bottom])
        #expect(laidOut.last?.1 == [1, 3])
    }

    @Test func aPositionedCueIsAnchoredInsteadOfStacked() {
        let pieces = SubtitleLayout.pieces(of: [cue(1, "Dialogue", from: 0), cue(2, "Shop sign", from: 0, position: CGPoint(x: 0.25, y: 0.3))])
        #expect(stacks(pieces).map(\.1) == [[1]])
        let anchored = pieces.compactMap { piece -> CGPoint? in
            guard case .anchored(let cue, let anchor) = piece.kind, cue.id == 2 else { return nil }
            return anchor
        }
        #expect(anchored == [CGPoint(x: 0.25, y: 0.3)])
    }

    @Test func aPositionedCueStaysInsideThePicture() {
        let picture = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let box = CGSize(width: 400, height: 60)
        // Bottom centre at the anchor, as ASS places a cue without an alignment.
        let placed = SubtitleLayout.origin(of: box, anchoredAt: CGPoint(x: 800, y: 300), alignment: nil, in: picture)
        #expect(placed == CGPoint(x: 600, y: 240))
        // Top left at the anchor with \an7.
        #expect(SubtitleLayout.origin(of: box, anchoredAt: CGPoint(x: 100, y: 50), alignment: 7, in: picture) == CGPoint(x: 100, y: 50))
        // Anchored off the picture, it's kept on it, whole.
        let anchor = SubtitleLayout.anchor(CGPoint(x: 1.3, y: -0.2))
        #expect(anchor == CGPoint(x: 1, y: 0))
        let corner = SubtitleLayout.origin(of: box, anchoredAt: CGPoint(x: anchor.x * picture.width, y: anchor.y * picture.height),
                                           alignment: 9, in: picture)
        #expect(corner == CGPoint(x: 1200, y: 0))
        #expect(picture.contains(CGRect(origin: corner, size: box)))
    }

    @Test func aPictureSubtitleMovesUpOutOfTheControlsButStaysOnThePicture() {
        let picture = CGRect(x: 0, y: 40, width: 1600, height: 900)
        // Clear of a bar starting at 800: up to 12 points above it.
        #expect(SubtitleLayout.lift(top: 780, bottom: 860, clearAbove: 800, within: picture) == 72)
        // Already clear, or nothing covers the picture.
        #expect(SubtitleLayout.lift(top: 600, bottom: 700, clearAbove: 800, within: picture) == 0)
        #expect(SubtitleLayout.lift(top: 780, bottom: 860, clearAbove: nil, within: picture) == 0)
        // No higher than the picture's top.
        #expect(SubtitleLayout.lift(top: 100, bottom: 900, clearAbove: 300, within: picture) == 60)
    }
}

struct PlayerLayoutTests {
    @Test func theUpNextCardSitsAboveTheBottomBarOrNearTheEdge() {
        // A bar starting 130 points above the bottom of the view: the card 16 above that.
        #expect(PlayerLayout.bottomPadding(containerMaxY: 840, bottomBarTop: 710) == 130 + PlayerLayout.gapAboveControls)
        #expect(PlayerLayout.bottomPadding(containerMaxY: 840, bottomBarTop: nil) == PlayerLayout.gapAboveEdge)
    }

    @Test func anIPhoneOnItsSideGetsThePillWhileTheControlsShow() {
        // iPhone 17 Pro on its side: the bars about 206 points apart.
        let sideways = PlayerLayout.isShort(topBarBottom: 60, bottomBarTop: 266)
        #expect(sideways)
        #expect(PlayerLayout.upNextForm(controlsVisible: true, isShort: sideways) == .pill)
        #expect(PlayerLayout.upNextForm(controlsVisible: false, isShort: sideways) == .card)
        // Upright, and on a Mac's or an iPad's screen, the card fits under the transport.
        #expect(!PlayerLayout.isShort(topBarBottom: 122, bottomBarTop: 724))
        #expect(!PlayerLayout.isShort(topBarBottom: 84, bottomBarTop: 896))
        #expect(!PlayerLayout.isShort(topBarBottom: nil, bottomBarTop: 266))
    }

    @Test func theUpNextCardGrowsWithAWideScreen() {
        #expect(PlayerLayout.upNextCardWidth(containerWidth: 402) == 440)
        #expect(abs(PlayerLayout.upNextCardWidth(containerWidth: 1500) - 600) < 0.001)
        #expect(PlayerLayout.upNextCardWidth(containerWidth: 2560) == 640)
    }

    @Test func subtitlesClearTheHighestOfWhatCoversThePicture() {
        #expect(PlayerLayout.coveredBelow(700, 640) == 640)
        #expect(PlayerLayout.coveredBelow(nil, 640) == 640)
        #expect(PlayerLayout.coveredBelow(nil, nil) == nil)
    }
}

#if os(iOS)
struct PlayerOrientationRuleTests {
    @Test func theWindowIsHeldOnceItsWide() {
        var rule = PlayerOrientationLock.Rule()
        rule.relock(current: .portrait)
        #expect(rule.allowed == .all)
        rule.isWide = true
        rule.relock(current: .landscapeRight)
        #expect(rule.allowed == .landscape)
        // Lying down, the phone upright: the player offers to rotate rather than turning.
        #expect(rule.isTurnedAgainst(.portrait))
        #expect(!rule.isTurnedAgainst(.landscapeLeft))
    }

    @Test func rotatedUprightThePlayerTurnsSidewaysAgain() {
        var rule = PlayerOrientationLock.Rule()
        rule.isWide = true
        rule.relock(current: .landscapeRight)
        #expect(rule.rotate(to: .portrait) == .portrait)
        // Upright, it turns with the phone again.
        rule.isWide = false
        rule.relock(current: .portrait)
        #expect(rule.allowed == .all)
        #expect(!rule.isTurnedAgainst(.landscapeLeft))
        // Turned sideways, the window goes wide, and is held there again.
        rule.isWide = true
        rule.relock(current: .landscapeLeft)
        #expect(rule.allowed == .landscape)
    }

    @Test func standingHalfOpenTurnsFreely() {
        var rule = PlayerOrientationLock.Rule()
        rule.isWide = true
        rule.relock(current: .landscapeRight)
        rule.isHalfOpen = true
        rule.relock(current: .landscapeRight)
        #expect(rule.allowed == .all)
    }
}
#endif
