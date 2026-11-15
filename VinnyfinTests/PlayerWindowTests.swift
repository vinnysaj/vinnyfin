import AetherEngine
import CoreGraphics
import SwiftUI
import Testing
@testable import vinnyfin

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
