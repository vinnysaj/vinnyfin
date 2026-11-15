import AetherEngine
import CoreGraphics
import SwiftUI
import Testing
@testable import vinnyfin

/// The Mac's player window takes the shape of each picture without leaving its screen.
struct PlayerWindowFrameTests {
    /// A 14-inch MacBook Pro's area for windows at its default size: below the menu bar, above
    /// the Dock.
    private let laptop = CGRect(x: 0, y: 70, width: 1512, height: 875)

    @Test func aWidePictureKeepsTheWindowsWidthAndTop() {
        let current = CGRect(x: 100, y: 200, width: 1280, height: 720)
        let frame = PlayerWindowFrame.frame(from: current, aspect: 2.39, on: laptop)
        #expect(frame.width == 1280)
        #expect(frame.height == (1280 / 2.39).rounded())
        #expect(frame.minX == 100)
        #expect(frame.maxY == current.maxY)
    }

    @Test func aPictureTooTallForTheScreenShrinksToFitItInItsShape() {
        let current = CGRect(x: 100, y: 200, width: 1280, height: 720)
        // 4:3 at 1280 wide is 960 tall: more than the laptop has room for.
        let frame = PlayerWindowFrame.frame(from: current, aspect: 4.0 / 3, on: laptop)
        #expect(laptop.contains(frame))
        #expect(frame.height == laptop.height)
        #expect(abs(frame.width / frame.height - 4.0 / 3) < 0.01)
    }

    @Test func aPhonesUprightVideoStandsOnTheScreen() {
        let current = CGRect(x: 100, y: 200, width: 1280, height: 720)
        let frame = PlayerWindowFrame.frame(from: current, aspect: 9.0 / 16, on: laptop)
        #expect(laptop.contains(frame))
        #expect(abs(frame.width / frame.height - 9.0 / 16) < 0.01)
        #expect(frame.height == laptop.height)
    }

    @Test func aWindowPushedOffTheScreenByItsNewShapeMovesBackOn() {
        // Its top near the bottom of the screen: 16:9 to 4:3 grows it downward, past the Dock.
        let current = CGRect(x: 1000, y: 100, width: 800, height: 450)
        let frame = PlayerWindowFrame.frame(from: current, aspect: 4.0 / 3, on: laptop)
        #expect(laptop.contains(frame))
        #expect(frame.size == CGSize(width: 800, height: 600))
    }

    @Test func aWindowWiderThanTheScreenNarrowsToIt() {
        let current = CGRect(x: 0, y: 70, width: 2000, height: 600)
        let frame = PlayerWindowFrame.frame(from: current, aspect: 16.0 / 9, on: laptop)
        #expect(laptop.contains(frame))
        #expect(frame.width == laptop.width)
    }

    @Test func theWindowsChromeIsLeftRoomFor() {
        let current = CGRect(x: 100, y: 100, width: 1280, height: 748)
        let chrome = CGSize(width: 0, height: 28)
        let frame = PlayerWindowFrame.frame(from: current, aspect: 4.0 / 3, chrome: chrome, on: laptop)
        #expect(laptop.contains(frame))
        // The content, below the title bar, has the picture's shape.
        #expect(abs(frame.width / (frame.height - chrome.height) - 4.0 / 3) < 0.01)
    }

    @Test func theSmallestWindowHasRoomForTheControlsInEveryShape() {
        func minimum(_ aspect: CGFloat, is size: CGSize) -> Bool {
            let found = PlayerWindowFrame.minimumSize(aspect: aspect)
            return abs(found.width - size.width) < 0.01 && abs(found.height - size.height) < 0.01
        }
        #expect(minimum(16.0 / 9, is: CGSize(width: 480, height: 270)))
        // As wide as it must be to stay 270 tall.
        #expect(minimum(2.4, is: CGSize(width: 648, height: 270)))
        #expect(minimum(4.0 / 3, is: CGSize(width: 480, height: 360)))
        // Upright, 480 tall: a width of 480 would make it taller than a laptop's screen.
        #expect(minimum(9.0 / 16, is: CGSize(width: 270, height: 480)))
    }

    @Test func aSmallWindowGrowsToTheSmallestForItsShape() {
        let current = CGRect(x: 100, y: 200, width: 300, height: 400)
        let frame = PlayerWindowFrame.frame(from: current, aspect: 16.0 / 9, on: laptop)
        #expect(frame.size == CGSize(width: 480, height: 270))
    }

    @Test func theShapeIsSixteenByNineUntilThePictureSays() {
        #expect(PlayerWindowFrame.aspect(of: nil) == 16.0 / 9)
        #expect(PlayerWindowFrame.aspect(of: CGSize(width: 0, height: 0)) == 16.0 / 9)
        #expect(PlayerWindowFrame.aspect(of: CGSize(width: 1440, height: 1080)) == 4.0 / 3)
    }
}

/// A media key, an AirPods press or Control Center reaches one handler, on either decode path.
@MainActor
struct NowPlayingOwnershipTests {
    @Test func theEngineServesTheSharedCentersOnlyWhereThePlayerDoesnt() throws {
        let engine = try AetherEngine()
        PlayerCoordinator.shareNowPlaying(with: engine)
        // Both serving them would toggle Play/Pause twice, a press doing nothing.
        #expect(engine.ownsSoftwareNowPlaying != PlayerModel.servesSharedTransport)
        #if os(macOS) || os(visionOS)
        #expect(PlayerModel.servesSharedTransport)
        #expect(!engine.ownsSoftwareNowPlaying)
        #else
        #expect(!PlayerModel.servesSharedTransport)
        #expect(engine.ownsSoftwareNowPlaying)
        #endif
        #expect(engine.remoteSkipInterval == PlayerModel.skipInterval)
    }
}

#if !os(tvOS)
/// The Playback menu: what's enabled for a playback, the chapters' moves, and the tooltips that
/// name the keys.
struct PlaybackMenuTests {
    @Test func commandsNeedWhatTheyActOn() {
        let movie = PlayerCommandOffers()
        #expect(PlayerCommand.playPause.isEnabled(in: movie))
        #expect(PlayerCommand.floatOnTop.isEnabled(in: movie))
        #expect(!PlayerCommand.previousEpisode.isEnabled(in: movie))
        #expect(!PlayerCommand.nextEpisode.isEnabled(in: movie))
        #expect(!PlayerCommand.episodes.isEnabled(in: movie))
        #expect(!PlayerCommand.nextChapter.isEnabled(in: movie))
        #expect(!PlayerCommand.previousChapter.isEnabled(in: movie))
        #expect(!PlayerCommand.subtitles.isEnabled(in: movie))
        #expect(!PlayerCommand.pictureInPicture.isEnabled(in: movie))

        let lastEpisode = PlayerCommandOffers(isEpisode: true, hasNextEpisode: false, hasChapters: true, hasSubtitles: true)
        #expect(PlayerCommand.previousEpisode.isEnabled(in: lastEpisode))
        #expect(PlayerCommand.episodes.isEnabled(in: lastEpisode))
        #expect(!PlayerCommand.nextEpisode.isEnabled(in: lastEpisode))
        #expect(PlayerCommand.nextChapter.isEnabled(in: lastEpisode))
        #expect(PlayerCommand.subtitles.isEnabled(in: lastEpisode))
    }

    @Test func pictureInPictureIsThereWhileItCanStartOrIsUp() {
        func offers(possible: Bool, active: Bool) -> PlayerCommandOffers {
            PlayerCommandOffers(pictureInPicture: PictureInPictureButton(isPossible: possible, isActive: active) {})
        }
        #expect(PlayerCommand.pictureInPicture.isEnabled(in: offers(possible: true, active: false)))
        #expect(PlayerCommand.pictureInPicture.isEnabled(in: offers(possible: false, active: true)))
        #expect(!PlayerCommand.pictureInPicture.isEnabled(in: offers(possible: false, active: false)))
    }

    private let chapters = [0.0, 300, 900].enumerated().map { ChapterMark(index: $0, start: $1, name: "\($0)", image: nil) }

    @Test func nextChapterGoesToTheNextOnesStartAndNowhereFromTheLast() {
        #expect(ChapterMark.next(in: chapters, after: 10)?.start == 300)
        #expect(ChapterMark.next(in: chapters, after: 300)?.start == 900)
        #expect(ChapterMark.next(in: chapters, after: 1000) == nil)
    }

    @Test func previousChapterGoesBackToTheStartAndThenToTheOneBefore() {
        // Well into the second chapter: its start.
        #expect(ChapterMark.previous(in: chapters, before: 400)?.start == 300)
        // Just past its start: the chapter before.
        #expect(ChapterMark.previous(in: chapters, before: 301)?.start == 0)
        // In the first chapter, its start.
        #expect(ChapterMark.previous(in: chapters, before: 1)?.start == 0)
        #expect(ChapterMark.previous(in: [], before: 100) == nil)
    }

    @Test func tooltipsNameTheKey() {
        #expect(PlayerCommand.playPause.tooltip("Play") == "Play (Space)")
        #expect(PlayerCommand.skipBack.tooltip("Back 10 Seconds") == "Back 10 Seconds (←)")
        #expect(PlayerCommand.nextEpisode.tooltip("Next Episode") == "Next Episode (N)")
        #expect(PlayerCommand.nextChapter.tooltip("Next Chapter") == "Next Chapter (⇧⌘→)")
        #expect(PlayerCommand.close.tooltip("Close") == "Close (Esc)")
        // Without a key, the name alone.
        #expect(PlayerCommand.pictureInPicture.tooltip("Picture in Picture") == "Picture in Picture")
    }
}
#endif

/// On Vision Pro the player's buttons are in an ornament below the window, so each panel opens in
/// a popover from its button, off the picture; elsewhere they open over the picture by it.
struct PanelPopoverTests {
    private let panelsWithButtons: [PlayerPanel] = [.audioAndSubtitles, .speed, .chapters, .quality, .episodes]

    @Test func panelsOpenInPopoversOnlyOnVisionPro() {
        for panel in panelsWithButtons {
            #if os(visionOS)
            #expect(panel.opensInPopover, "\(panel.title)")
            #else
            #expect(!panel.opensInPopover, "\(panel.title)")
            #endif
        }
    }

    /// Apple TV's tabs open by focus, below the buttons, never in a popover.
    @Test func tabsNeverOpenInPopovers() {
        for panel in [PlayerPanel.episodes, .info] where panel.isTab {
            #expect(!panel.opensInPopover)
        }
    }
}

/// Vision Pro's player window takes each picture's shape at the width it was.
struct VisionPlayerWindowTests {
    @Test func aNewShapeKeepsTheWidth() {
        #expect(PlayerWindowFrame.visionSize(from: CGSize(width: 1280, height: 720), aspect: 2.39) == CGSize(width: 1280, height: 536))
        #expect(PlayerWindowFrame.visionSize(from: CGSize(width: 1280, height: 536), aspect: 16.0 / 9.0) == CGSize(width: 1280, height: 720))
    }

    @Test func theWidthStaysWithinTheWindowsRange() {
        #expect(PlayerWindowFrame.visionSize(from: CGSize(width: 500, height: 300), aspect: 4.0 / 3.0) == CGSize(width: 640, height: 480))
        #expect(PlayerWindowFrame.visionSize(from: CGSize(width: 4000, height: 2250), aspect: 16.0 / 9.0) == CGSize(width: 3200, height: 1800))
    }

    @Test func noShapeLeavesTheSize() {
        #expect(PlayerWindowFrame.visionSize(from: CGSize(width: 1280, height: 720), aspect: 0) == CGSize(width: 1280, height: 720))
    }
}

/// The volume slider on the Mac and Vision Pro sets the level, and the speaker beside it says
/// whether anything plays.
struct VolumeSliderTests {
    @Test func theSliderSetsTheLevelWithinRangeAndUnmutes() {
        var volume = PlayerVolume(level: 0.5)
        volume.toggleMute()
        volume.set(0.3)
        #expect(!volume.isMuted)
        #expect(volume.output == 0.3)
        volume.set(1.4)
        #expect(volume.level == 1)
        volume.set(-0.2)
        #expect(volume.level == 0)
    }

    @Test func theSpeakerIsStruckThroughWhileNothingPlays() {
        var volume = PlayerVolume(level: 0.5)
        #expect(volume.symbol == "speaker.wave.3.fill")
        volume.toggleMute()
        #expect(volume.symbol == "speaker.slash.fill")
        volume.set(0)
        #expect(volume.symbol == "speaker.slash.fill")
    }
}
