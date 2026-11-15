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

