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

    @Test func theStartingTitleSitsAboveTheUpNextCardOrTheChip() {
        // Upright, the card above the bar: the title goes above the card.
        let card = CGRect(x: 20, y: 600, width: 362, height: 110)
        let upright = PlayerLayout.caption(bottomBarTop: 724, corner: card, isShort: false)
        #expect(upright.coveredBelow == 600)
        #expect(upright.trailingInset == 0)
        // Nothing in the corner.
        let alone = PlayerLayout.caption(bottomBarTop: 724, corner: nil, isShort: true)
        #expect(alone.coveredBelow == 724)
        #expect(alone.trailingInset == 0)
    }

    @Test func onAnIPhoneOnItsSideTheStartingTitleSharesTheRowWithThePill() {
        // iPhone SE on its side: above the pill would be in the transport, so the title keeps to
        // the pill's leading side, in the row above the bar.
        let pill = CGRect(x: 380, y: 222, width: 267, height: 44)
        let sideways = PlayerLayout.caption(bottomBarTop: 282, corner: pill, isShort: true)
        #expect(sideways.coveredBelow == 282)
        #expect(sideways.trailingInset == 267 + PlayerLayout.gapBesideCorner)
    }
}

#if os(iOS)
struct PlayerRotationHoldTests {
    @Test func thePlayerTurnsWithThePhoneUntilItKnowsItsShape() {
        let hold = PlayerRotation.Hold()
        #expect(hold.allowed == .all)
        #expect(!hold.offers(.landscapeRight))
        #expect(!hold.offers(.portrait))
    }

    @Test func itKeepsTheShapeItOpenedInEitherWayUp() {
        var hold = PlayerRotation.Hold()
        hold.hold(.portrait)
        #expect(hold.allowed == .portrait)
        // The phone on its side: the player stays upright and offers to turn.
        #expect(hold.offers(.landscapeLeft))
        #expect(hold.offers(.landscapeRight))
        // End over end it still follows.
        #expect(!hold.offers(.portraitUpsideDown))

        var sideways = PlayerRotation.Hold()
        sideways.hold(.landscapeRight)
        #expect(sideways.allowed == .landscape)
        // Lying down, the phone upright: the picture stays sideways.
        #expect(sideways.offers(.portrait))
        #expect(!sideways.offers(.landscapeLeft))
    }

    @Test func takingTheOfferKeepsTheNewShape() {
        var hold = PlayerRotation.Hold()
        hold.hold(.portrait)
        hold.turn(to: .landscapeLeft)
        #expect(hold.allowed == .landscape)
        #expect(!hold.offers(.landscapeRight))
        // Turned back upright, it offers to turn back.
        #expect(hold.offers(.portrait))
    }

    @Test func unfoldedItTurnsFreely() {
        var hold = PlayerRotation.Hold()
        hold.hold(.landscapeRight)
        hold.isUnfolded = true
        #expect(hold.allowed == .all)
        #expect(!hold.offers(.portrait))
        // Folded shut, in the shape the front screen is in.
        hold.isUnfolded = false
        hold.hold(.portrait)
        #expect(hold.allowed == .portrait)
    }

    private let film = CGSize(width: 1920, height: 800)

    @Test func aLandscapeTitleHeldUprightTurnsThePlayerAndHoldsItThere() {
        var hold = PlayerRotation.Hold()
        hold.hold(.portrait)
        let turns = hold.pictureShaped(film, current: .portrait, playsInLandscape: true)
        #expect(turns)
        #expect(hold.allowed == .landscape)
        // Still upright, the offer is the way back to portrait.
        #expect(hold.offers(.portrait))
        hold.turn(to: .portrait)
        #expect(hold.allowed == .portrait)
    }

    @Test func itTurnsOnlyForTheFirstShapeKnownWhileOpen() {
        var hold = PlayerRotation.Hold()
        hold.hold(.portrait)
        let turns = hold.pictureShaped(film, current: .portrait, playsInLandscape: true)
        #expect(turns)
        hold.turn(to: .portrait)
        // The next episode, or the stream's own size arriving after the server's, leaves the
        // shape the viewer turned it back to.
        let turns2 = hold.pictureShaped(film, current: .portrait, playsInLandscape: true)
        #expect(!turns2)
        #expect(hold.allowed == .portrait)
    }

    @Test func itDoesntTurnWhenItNeedntOrIsntAsked() {
        // The setting off.
        var off = PlayerRotation.Hold()
        off.hold(.portrait)
        let turns = off.pictureShaped(film, current: .portrait, playsInLandscape: false)
        #expect(!turns)
        #expect(off.allowed == .portrait)
        // A picture taller than wide.
        var upright = PlayerRotation.Hold()
        let turns2 = upright.pictureShaped(CGSize(width: 1080, height: 1920), current: .portrait, playsInLandscape: true)
        #expect(!turns2)
        // On its side already.
        var sideways = PlayerRotation.Hold()
        sideways.hold(.landscapeLeft)
        let turns3 = sideways.pictureShaped(film, current: .landscapeLeft, playsInLandscape: true)
        #expect(!turns3)
        #expect(sideways.allowed == .landscape)
        // An iPhone Duo unfolded, which turns its windows itself.
        var unfolded = PlayerRotation.Hold()
        unfolded.isUnfolded = true
        let turns4 = unfolded.pictureShaped(film, current: .portrait, playsInLandscape: true)
        #expect(!turns4)
    }

    @Test func theViewersOwnTurnComesFirst() {
        var hold = PlayerRotation.Hold()
        hold.hold(.landscapeLeft)
        hold.turn(to: .portrait)
        let turns = hold.pictureShaped(film, current: .portrait, playsInLandscape: true)
        #expect(!turns)
        #expect(hold.allowed == .portrait)
    }

    @Test func aShapeNotYetKnownSettlesNothing() {
        var hold = PlayerRotation.Hold()
        hold.hold(.portrait)
        let turns = hold.pictureShaped(.zero, current: .portrait, playsInLandscape: true)
        #expect(!turns)
        let turns2 = hold.pictureShaped(film, current: .portrait, playsInLandscape: true)
        #expect(turns2)
    }
}
struct PlayerRotationHeldTests {
    @Test func gravityAlongTheScreenSaysWhichWayIsUp() {
        #expect(PlayerRotation.Held.toward(x: 0, y: -1) == .portrait)
        #expect(PlayerRotation.Held.toward(x: 0, y: 1) == .portraitUpsideDown)
        // Its left side down, the interface is turned right, as the device's own orientation says.
        #expect(PlayerRotation.Held.toward(x: -1, y: 0) == .landscapeRight)
        #expect(PlayerRotation.Held.toward(x: 1, y: 0) == .landscapeLeft)
    }

    @Test func nearFlatOrHalfwayItIsntTurnedAnyWay() {
        // Lying on a table.
        #expect(PlayerRotation.Held.toward(x: 0.1, y: -0.3) == nil)
        // Halfway round.
        #expect(PlayerRotation.Held.toward(x: -0.6, y: -0.6) == nil)
        // Tipped back, but upright.
        #expect(PlayerRotation.Held.toward(x: 0.1, y: -0.6) == .portrait)
    }

    @Test func aWaySettlesOnceThePhoneStaysTurnedThatWay() {
        var held = PlayerRotation.Held()
        #expect(held.felt(x: 0, y: -1, at: 0) == nil)
        #expect(held.felt(x: 0, y: -1, at: 0.2) == nil)
        #expect(held.felt(x: 0, y: -1, at: 0.4) == .portrait)
        #expect(held.orientation == .portrait)
        // A jolt sideways and back doesn't turn it.
        #expect(held.felt(x: -1, y: 0, at: 1) == nil)
        #expect(held.felt(x: 0, y: -1, at: 1.1) == nil)
        #expect(held.felt(x: -1, y: 0, at: 1.5) == nil)
        // Passing halfway on its way round, it's still turning toward landscape.
        #expect(held.felt(x: -0.6, y: -0.6, at: 1.7) == nil)
        #expect(held.felt(x: -1, y: 0, at: 2) == .landscapeRight)
        #expect(held.orientation == .landscapeRight)
    }
}

#endif

struct PointerOnControlsTests {
    @Test func thePointerIsOnTheControlsOnEitherBar() {
        #expect(PlayerLayout.isOnBars(y: 40, topBarBottom: 80, bottomBarTop: 900))
        #expect(PlayerLayout.isOnBars(y: 950, topBarBottom: 80, bottomBarTop: 900))
        #expect(!PlayerLayout.isOnBars(y: 500, topBarBottom: 80, bottomBarTop: 900))
        // Bars not laid out yet hold nothing.
        #expect(!PlayerLayout.isOnBars(y: 40, topBarBottom: nil, bottomBarTop: nil))
    }
}

struct PictureTapsTests {
    @Test func theThirdsOfThePicture() {
        #expect(PictureTaps.zone(x: 10, width: 300) == .back)
        #expect(PictureTaps.zone(x: 150, width: 300) == .middle)
        #expect(PictureTaps.zone(x: 290, width: 300) == .forward)
        #expect(PictureTaps.zone(x: 10, width: 0) == .middle)
    }

    @Test func theFirstTapShowsOrHidesTheControlsAtOnce() {
        var taps = PictureTaps(mode: .sideSkips)
        #expect(taps.tap(at: 0, zone: .forward, canSkip: true) == .toggleControls)
        // A second tap long after is another first tap.
        #expect(taps.tap(at: 5, zone: .forward, canSkip: true) == .toggleControls)
    }

    @Test func aDoubleTapOnASideSkipsAndTheTapsAfterKeepSkipping() {
        var taps = PictureTaps(mode: .sideSkips)
        #expect(taps.tap(at: 0, zone: .back, canSkip: true) == .toggleControls)
        #expect(taps.tap(at: 0.2, zone: .back, canSkip: true) == .skip(forward: false, restoresControls: true))
        // Slower taps keep the run going, and may change sides.
        #expect(taps.tap(at: 0.8, zone: .back, canSkip: true) == .skip(forward: false, restoresControls: false))
        #expect(taps.tap(at: 1.4, zone: .forward, canSkip: true) == .skip(forward: true, restoresControls: false))
        // A pause ends the run.
        #expect(taps.tap(at: 3, zone: .forward, canSkip: true) == .toggleControls)
    }

    @Test func theMiddleOnlyEverShowsAndHidesTheControls() {
        var taps = PictureTaps(mode: .sideSkips)
        #expect(taps.tap(at: 0, zone: .middle, canSkip: true) == .toggleControls)
        #expect(taps.tap(at: 0.1, zone: .middle, canSkip: true) == .toggleControls)
    }

    @Test func tapsOnDifferentSidesOrWithoutATimelineDontSkip() {
        var taps = PictureTaps(mode: .sideSkips)
        #expect(taps.tap(at: 0, zone: .back, canSkip: true) == .toggleControls)
        #expect(taps.tap(at: 0.1, zone: .forward, canSkip: true) == .toggleControls)
        var live = PictureTaps(mode: .sideSkips)
        #expect(live.tap(at: 0, zone: .back, canSkip: false) == .toggleControls)
        #expect(live.tap(at: 0.1, zone: .back, canSkip: false) == .toggleControls)
    }

    @Test func aDoubleClickTogglesFullScreenAndAThirdStartsOver() {
        var clicks = PictureTaps(mode: .doubleClickFullScreen, doubleTapInterval: 0.5)
        #expect(clicks.tap(at: 0, zone: .middle, canSkip: true) == .toggleControls)
        #expect(clicks.tap(at: 0.3, zone: .middle, canSkip: true) == .fullScreen)
        #expect(clicks.tap(at: 0.6, zone: .middle, canSkip: true) == .toggleControls)
    }
}

struct PanelPlacementTests {
    @Test func aPanelSitsOverItsButtonWithinTheEdges() {
        // Centered over a button in the middle.
        #expect(PanelPlacement.leading(width: 300, buttonMidX: 500, containerWidth: 1000, margin: 20) == 350)
        // Kept off the edges near either side.
        #expect(PanelPlacement.leading(width: 300, buttonMidX: 40, containerWidth: 1000, margin: 20) == 20)
        #expect(PanelPlacement.leading(width: 300, buttonMidX: 980, containerWidth: 1000, margin: 20) == 680)
    }
}
