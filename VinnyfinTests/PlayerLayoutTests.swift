import AetherEngine
import CoreGraphics
import Foundation
import Testing
#if os(iOS)
import UIKit
#endif
@testable import vinnyfin

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
