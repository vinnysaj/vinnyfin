#if os(iOS)
import Observation
import OSLog
import UIKit

/// Keeps the player in the shape it opened in, either way up, however the phone turns, until the
/// viewer asks it to turn. Turning the phone out of that shape offers to turn the player with it:
/// a button that shows by itself for a few seconds, then waits among the controls for as long as
/// the phone stays turned; tapped, the player turns the way the phone is and keeps that shape
/// instead. Turning the phone back withdraws the offer. With Play Videos in Landscape, a landscape
/// title held upright turns the player to landscape as it opens, Portrait Orientation Lock or not,
/// and the offer is the way back to portrait. Closing the player turns the app the way the phone
/// is. iPhone only: an iPad turns its windows itself, as does an iPhone Duo unfolded, which
/// ignores the orientations its windows allow and refuses to turn them on request, so there the
/// player turns with the device. Folded shut again, the Duo's front screen keeps the shape it's in.
@Observable
final class PlayerRotation {
    /// What the app's windows may turn to, as the app delegate tells the system.
    private(set) static var allowed = UIInterfaceOrientationMask.all
    /// Long enough to notice the offer and reach it, the phone just turned in the hand.
    static let offerShowsAlone: Duration = .seconds(7)

    /// The way the phone is turned while it's out of the player's shape: where the player turns
    /// when the viewer takes the offer. Nil when there's nothing to offer.
    private(set) var offer: UIInterfaceOrientation?
    /// The offer has just come, and shows by itself before it waits among the controls.
    private(set) var isAnnouncing = false

    @ObservationIgnored private var hold = Hold()
    /// The way the phone is turned, as an interface orientation.
    @ObservationIgnored private var turned: UIInterfaceOrientation?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var announcing: Task<Void, Never>?
    /// Play Videos in Landscape is on.
    @ObservationIgnored private var playsInLandscape = false

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "player")

    /// Holds the shape the app is in as the player opens; with `landscapeTitles`, a landscape
    /// title turns it to landscape (`pictureShaped`).
    func start(landscapeTitles: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone, observer == nil else { return }
        playsInLandscape = landscapeTitles
        if let current = currentOrientation { hold.hold(current) }
        apply(hold.allowed)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceTurned() }
        }
        deviceTurned()
    }

    /// Lets the app turn freely again as the player closes, turning it the way the phone is,
    /// which with Portrait Orientation Lock on is upright.
    func stop() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        withdraw()
        // Opened again, it starts over, a landscape title turning it again.
        let isUnfolded = hold.isUnfolded
        hold = Hold()
        hold.isUnfolded = isUnfolded
        // Flat on a table, the phone says no way up: the app stays as it is.
        apply(.all, turningTo: turned.map(Hold.mask(for:)))
    }

    /// The picture of the title playing is `size`: a landscape one, held upright, turns the player
    /// to landscape and holds it there, once as the player opens (`Hold.pictureShaped`).
    func pictureShaped(_ size: CGSize) {
        guard observer != nil, let current = currentOrientation,
              hold.pictureShaped(size, current: current, playsInLandscape: playsInLandscape) else { return }
        apply(hold.allowed, turningTo: .landscape)
        deviceTurned()
    }

    /// Unfolded, the player turns with the device; folded shut, it holds the shape the front
    /// screen is in, which is the way the phone is turned.
    func hingeChanged(isUnfolded: Bool) {
        guard isUnfolded != hold.isUnfolded else { return }
        hold.isUnfolded = isUnfolded
        if !isUnfolded, let shape = turned ?? currentOrientation { hold.hold(shape) }
        apply(hold.allowed)
        deviceTurned()
    }

    /// Takes the offer: turns the player the way the phone is, and holds it there.
    func turn() {
        guard observer != nil, let turned, hold.offers(turned) else { return }
        hold.turn(to: turned)
        withdraw()
        apply(hold.allowed, turningTo: Hold.mask(for: turned))
    }

    // MARK: Following the phone

    private func deviceTurned() {
        // Flat on a table, or unknown: nothing new about which way is up.
        if let orientation = Self.interfaceOrientation(facing: UIDevice.current.orientation) { turned = orientation }
        guard let turned, hold.offers(turned) else { return withdraw() }
        let isNew = offer == nil
        offer = turned
        guard isNew else { return }
        isAnnouncing = true
        announcing?.cancel()
        announcing = Task {
            try? await Task.sleep(for: Self.offerShowsAlone)
            if !Task.isCancelled { isAnnouncing = false }
        }
    }

    private func withdraw() {
        announcing?.cancel()
        offer = nil
        isAnnouncing = false
    }

    /// Lets the windows turn to `mask`, and with `turningTo`, turns them that way now, unless the
    /// device turns them itself.
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
        guard let turn, !hold.isUnfolded else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: turn)) { error in
            Self.log.error("Couldn't rotate the player: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// The way the app's window is turned, when it's known.
    private var currentOrientation: UIInterfaceOrientation? {
        guard let orientation = scene?.effectiveGeometry.interfaceOrientation, orientation != .unknown else { return nil }
        return orientation
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

    /// The shape the player keeps, apart from the system that's asked: the one it opened in, until
    /// the viewer turns it.
    nonisolated struct Hold: Equatable {
        /// Nil, before the shape it opened in is known, turns with the phone.
        private(set) var shape: UIInterfaceOrientationMask?
        /// An iPhone Duo unfolded, standing half open or lying flat, turns its windows itself, as an
        /// iPad does: the player turns with it, into the folded layout and back.
        var isUnfolded = false
        /// Whether a landscape title turns the player has been settled for this opening: by the
        /// first picture shape known, or by the viewer turning it first.
        private(set) var hasSettledLandscape = false

        /// What the windows may turn to.
        var allowed: UIInterfaceOrientationMask { isUnfolded ? .all : shape ?? .all }

        /// Keeps the shape of `orientation`, either way up, without settling anything: as the
        /// player opens, and as an iPhone Duo folds shut.
        mutating func hold(_ orientation: UIInterfaceOrientation) {
            shape = Self.mask(for: orientation)
        }

        /// The viewer took the offer to turn to `orientation`, the way the phone is.
        mutating func turn(to orientation: UIInterfaceOrientation) {
            shape = Self.mask(for: orientation)
            hasSettledLandscape = true
        }

        /// The title's picture is `size`, the window `current`: whether to turn the player to
        /// landscape, which it then holds. With Play Videos in Landscape (`playsInLandscape`), for
        /// a picture wider than tall, a window upright and not unfolded, the first time
        /// a shape is known while the player is open, unless the viewer has turned it already.
        /// Later titles, as the next episode, leave the shape the viewer has.
        mutating func pictureShaped(_ size: CGSize, current: UIInterfaceOrientation, playsInLandscape: Bool) -> Bool {
            guard !hasSettledLandscape, size.width > 0, size.height > 0 else { return false }
            hasSettledLandscape = true
            guard playsInLandscape, !isUnfolded, current.isPortrait, size.width > size.height else { return false }
            shape = .landscape
            return true
        }

        /// Whether the phone, turned to `turned`, is out of the player's shape, so the player
        /// offers to turn to it.
        func offers(_ turned: UIInterfaceOrientation) -> Bool {
            !allowed.contains(Self.mask(for: turned))
        }

        /// Both orientations of the same shape, so turning the phone end over end still follows.
        static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
            orientation.isLandscape ? .landscape : .portrait
        }
    }
}
#endif
