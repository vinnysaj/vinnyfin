#if os(iOS)
import Observation
import OSLog
import UIKit

/// Turns the player with the phone, unless the viewer locks it in the shape it's in, as for
/// watching lying on your side. Locked, turning the phone the other way shows the lock on its own
/// for a few seconds, then it waits with the controls, so it's in reach to unlock; unlocking
/// turns the player the way the phone is. With Play Videos in Landscape, a landscape title held
/// upright turns the player to landscape and locks it there, Portrait Orientation Lock or not:
/// the lock, unlocked, is the way back to portrait, and closing the player goes back too. iPhone
/// only; iPad windows can't be locked.
@Observable
final class PlayerOrientationLock {
    /// What the app's windows may turn to, as the app delegate tells the system.
    private(set) static var allowed = UIInterfaceOrientationMask.all
    /// Long enough to notice the lock and reach it, the phone just turned in the hand.
    static let announcement: Duration = .seconds(4)

    /// The player can be locked: on iPhone, while it's open.
    private(set) var isAvailable = false
    private(set) var isLocked = false
    /// The phone is turned out of the shape the player is locked in.
    private(set) var isTurnedAgainst = false
    /// The phone has just turned against the lock, which shows on its own before it waits with
    /// the controls.
    private(set) var isAnnouncing = false

    @ObservationIgnored private var rule = Rule()
    /// The way the phone is turned, as an interface orientation.
    @ObservationIgnored private var turned: UIInterfaceOrientation?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var announcing: Task<Void, Never>?
    /// Play Videos in Landscape is on.
    @ObservationIgnored private var playsInLandscape = false

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "player")

    /// Follows the phone as the player opens; with `landscapeTitles`, a landscape title turns it
    /// to landscape (`pictureShaped`).
    func start(landscapeTitles: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone, observer == nil else { return }
        playsInLandscape = landscapeTitles
        isAvailable = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceTurned() }
        }
        deviceTurned()
    }

    /// Lets the app turn freely again, as the player closes: a player held in a shape, as a
    /// landscape title holds it, turns back the way the phone is, which with Portrait Orientation
    /// Lock on is upright.
    func stop() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        withdraw()
        let wasLocked = rule.isLocked
        // Opened again, it starts over, a landscape title turning it again.
        let isHalfOpen = rule.isHalfOpen
        rule = Rule()
        rule.isHalfOpen = isHalfOpen
        isLocked = false
        isAvailable = false
        apply(.all, turningTo: wasLocked ? Rule.mask(for: turned ?? .portrait) : nil)
    }

    /// The picture of the title playing is `size`: a landscape one, held upright, turns the player
    /// to landscape and locks it there, once as the player opens (`Rule.pictureShaped`).
    func pictureShaped(_ size: CGSize) {
        guard observer != nil, let current = scene?.effectiveGeometry.interfaceOrientation,
              rule.pictureShaped(size, current: current, playsInLandscape: playsInLandscape) else { return }
        isLocked = true
        apply(rule.allowed, turningTo: .landscape)
        deviceTurned()
    }

    func hingeChanged(isHalfOpen: Bool) {
        rule.isHalfOpen = isHalfOpen
        apply(rule.allowed)
        deviceTurned()
    }

    /// Locks the player in the shape it's in, or unlocks it and turns it the way the phone is.
    func toggle() {
        guard observer != nil else { return }
        if rule.isLocked {
            rule.unlock()
            isLocked = false
            withdraw()
            // Flat on a table, the phone says no way up: upright, as a landscape title's way back.
            apply(rule.allowed, turningTo: Rule.mask(for: turned ?? .portrait))
        } else if let current = scene?.effectiveGeometry.interfaceOrientation {
            rule.lock(current: current)
            isLocked = true
            apply(rule.allowed)
            deviceTurned()
        }
    }

    // MARK: Following the phone

    private func deviceTurned() {
        // Flat on a table, or unknown: nothing new about which way is up.
        if let orientation = Self.interfaceOrientation(facing: UIDevice.current.orientation) { turned = orientation }
        guard let turned, rule.isTurnedAgainst(turned) else { return withdraw() }
        guard !isTurnedAgainst else { return }
        isTurnedAgainst = true
        isAnnouncing = true
        announcing?.cancel()
        announcing = Task {
            try? await Task.sleep(for: Self.announcement)
            if !Task.isCancelled { isAnnouncing = false }
        }
    }

    private func withdraw() {
        announcing?.cancel()
        isTurnedAgainst = false
        isAnnouncing = false
    }

    /// Lets the windows turn to `mask`, and with `turningTo`, turns them that way now.
    private func apply(_ mask: UIInterfaceOrientationMask, turningTo turn: UIInterfaceOrientationMask? = nil) {
        guard mask != Self.allowed || turn != nil else { return }
        Self.allowed = mask
        guard let scene else { return }
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
        guard let turn else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: turn)) { error in
            Self.log.error("Couldn't rotate the player: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// The interface orientation that's upright with the device turned this way. Landscape is
    /// mirrored: a device turned left shows its interface turned right.
    private static func interfaceOrientation(facing device: UIDeviceOrientation) -> UIInterfaceOrientation? {
        switch device {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
    }

    /// What the player is held to, apart from the system that's asked: nothing, so it turns with
    /// the phone, until the viewer locks it in a shape.
    nonisolated struct Rule: Equatable {
        /// Nil turns with the phone.
        private(set) var locked: UIInterfaceOrientationMask?
        /// iPhone Duo standing half open turns freely, into the folded layout and back, locked or not.
        var isHalfOpen = false
        /// Whether a landscape title turns the player has been settled for this opening: by the
        /// first picture shape known, or by the viewer locking or unlocking it first.
        private(set) var hasSettledLandscape = false

        var isLocked: Bool { locked != nil }

        /// What the windows may turn to.
        var allowed: UIInterfaceOrientationMask { isHalfOpen ? .all : locked ?? .all }

        /// Holds the window to the shape it's in, `current`: either way up of it.
        mutating func lock(current: UIInterfaceOrientation) {
            locked = Self.mask(for: current)
            hasSettledLandscape = true
        }

        mutating func unlock() {
            locked = nil
            hasSettledLandscape = true
        }

        /// The title's picture is `size`, the window `current`: whether to turn the player to
        /// landscape, which holds it there until unlocked. With Play Videos in Landscape
        /// (`playsInLandscape`), for a picture wider than tall, a window upright and not standing
        /// half open, the first time a shape is known while the player is open, unless the viewer
        /// has locked or unlocked it already. Later titles, as the next episode, leave the shape
        /// the viewer has.
        mutating func pictureShaped(_ size: CGSize, current: UIInterfaceOrientation, playsInLandscape: Bool) -> Bool {
            guard !hasSettledLandscape, size.width > 0, size.height > 0 else { return false }
            hasSettledLandscape = true
            guard playsInLandscape, !isHalfOpen, !isLocked, current.isPortrait, size.width > size.height else { return false }
            locked = .landscape
            return true
        }

        /// Whether the phone, turned to `turned`, is out of the shape the player is held to.
        func isTurnedAgainst(_ turned: UIInterfaceOrientation) -> Bool {
            !allowed.contains(Self.mask(for: turned))
        }

        /// Both orientations of the same shape, so turning the phone end over end still follows.
        static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
            orientation.isLandscape ? .landscape : .portrait
        }
    }
}
#endif
