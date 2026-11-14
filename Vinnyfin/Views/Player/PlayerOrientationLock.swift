#if os(iOS)
import Observation
import OSLog
import UIKit

/// Turns the player with the phone, unless the viewer locks it in the shape it's in, as for
/// watching lying on your side. Locked, turning the phone the other way shows the lock on its own
/// for a few seconds, then it waits with the controls, so it's in reach to unlock; unlocking
/// turns the player the way the phone is. iPhone only; iPad windows can't be locked.
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

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "player")

    func start() {
        guard UIDevice.current.userInterfaceIdiom == .phone, observer == nil else { return }
        isAvailable = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceTurned() }
        }
        deviceTurned()
    }

    /// Lets the app turn freely again, as the player closes.
    func stop() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        withdraw()
        rule.unlock()
        isLocked = false
        isAvailable = false
        apply(.all)
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
            apply(rule.allowed, turningTo: turned.map(Rule.mask(for:)))
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

        var isLocked: Bool { locked != nil }

        /// What the windows may turn to.
        var allowed: UIInterfaceOrientationMask { isHalfOpen ? .all : locked ?? .all }

        /// Holds the window to the shape it's in, `current`: either way up of it.
        mutating func lock(current: UIInterfaceOrientation) {
            locked = Self.mask(for: current)
        }

        mutating func unlock() {
            locked = nil
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
