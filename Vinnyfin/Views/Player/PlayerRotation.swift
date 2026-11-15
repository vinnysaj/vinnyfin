#if os(iOS)
import CoreMotion
import Observation
import OSLog
import SwiftUI
import UIKit

/// Keeps the player in the shape it opened in, either way up, however the phone turns, until the
/// viewer asks it to turn. Turning the phone out of that shape offers to turn the player with it:
/// a button that shows by itself for a few seconds, then waits among the controls for as long as
/// the phone stays turned; tapped, the player turns the way the phone is and keeps that shape
/// instead. Turning the phone back withdraws the offer. With Play Videos in Landscape, a landscape
/// title held upright turns the player to landscape as it opens, Portrait Orientation Lock or not,
/// and the offer is the way back to portrait. Closing the player turns the app the way the phone
/// is. iPhone only: an iPad turns its windows itself.
///
/// An iPhone Duo unfolded turns its windows itself too, ignoring the orientations they allow and
/// refusing to turn them on request. There the player locks the scene where it is
/// (`PlayerViewController.locksOrientation`), and the phone turning a quarter against the scene,
/// the way the system has it, offers to turn; taking the offer unlocks the scene for the system
/// to turn it the way the phone is, and locks it again once it has. The system's way, not
/// gravity's: unfolding moves the half that feels gravity, and it's the system's way the scene
/// turns. Folded shut again, the Duo's front screen keeps the shape it's in.
///
/// The system can still turn the scene unasked, or leave it when asked: the offer is weighed
/// against the shape the scene is actually in, looked at again as it changes and every second
/// besides, and folded, a scene out of the shape held for longer than a turn takes is held as
/// it is (`reconcile()`). The offer goes once the scene is the phone's shape, and comes late
/// for a turn that didn't happen.
///
/// Which way the phone is held comes from gravity (`Held`), not from the system's device
/// orientation, which Portrait Orientation Lock keeps upright however the phone is held: with
/// the lock on, the offer would stay the way back to portrait, and turning the phone would never
/// offer anything. The app turns the system's way as the player closes, upright under the lock.
@Observable
final class PlayerRotation {
    /// What the app's windows may turn to, as the app delegate tells the system.
    private(set) static var allowed = UIInterfaceOrientationMask.all
    /// An iPhone Duo is open, as the app last heard (`RootView`). The player's own word of the
    /// hinge comes only after it opens, which can be long enough to hold the inner screen as the
    /// front one.
    static var hingeIsOpen = false

    /// The hinge stands open, partly or flat, by `context`.
    static func isOpen(_ context: DeviceHingeContext) -> Bool {
        [.partiallyOpen, .fullyOpen].contains(context.hinge?.status)
    }
    /// Long enough to notice the offer and reach it, the phone just turned in the hand.
    static let offerShowsAlone: Duration = .seconds(7)

    /// The way the phone is turned while it's out of the player's shape: where the player turns
    /// when the viewer takes the offer. Nil when there's nothing to offer.
    private(set) var offer: UIInterfaceOrientation?
    /// The offer has just come, and shows by itself before it waits among the controls.
    private(set) var isAnnouncing = false

    @ObservationIgnored private var hold = Hold()
    /// The way the phone is held, as an interface orientation.
    @ObservationIgnored private var turned: UIInterfaceOrientation?
    @ObservationIgnored private var held = Held()
    /// Gravity, while the player is open on a device that feels it. The simulator doesn't, and
    /// follows the system's device orientation instead.
    @ObservationIgnored private var motion: CMMotionManager?
    /// The way the system has the phone turned, which Portrait Orientation Lock keeps upright.
    @ObservationIgnored private var systemTurned: UIInterfaceOrientation?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var announcing: Task<Void, Never>?
    /// Play Videos in Landscape is on.
    @ObservationIgnored private var playsInLandscape = false
    /// Unfolded, whether the way the system had the phone turned was the scene's shape as the
    /// scene locked. It needn't be: the simulator's device is a quarter turn from its unfolded
    /// screen.
    @ObservationIgnored private var lockedAgreement: Bool?
    /// Unfolded, the scene is unlocked for the system to turn it to this shape, the way the phone
    /// is, and locks again once it has.
    @ObservationIgnored private var turningSceneTo: UIInterfaceOrientation?
    /// Locks the scene where it is should the system not turn it, as it won't if the phone is
    /// already the way the scene is.
    @ObservationIgnored private var turnTimeout: Task<Void, Never>?
    /// How long the system has to start turning the scene once it's unlocked, or asked to turn.
    private static let turnAllowance: Duration = .seconds(1)
    /// When the windows were last told what they may turn to, or asked to turn, which the system
    /// has `holdAllowance` to do.
    @ObservationIgnored private var appliedAt: ContinuousClock.Instant?
    /// Changes to the scene's shape, however they came.
    @ObservationIgnored private var sceneObservation: NSKeyValueObservation?
    /// Looks at the scene again every second, for a change nothing told of.
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    private static let heartbeatInterval: Duration = .seconds(1)
    /// How long the system has to turn the scene into the shape held, folded, before the scene is
    /// held as it is. A turn asked for as the player opens is refused while it's presented, and
    /// comes as the presentation ends, half a second on.
    private static let holdAllowance: Duration = .seconds(2)

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "player")

    /// Holds the shape the app is in as the player opens; with `landscapeTitles`, a landscape
    /// title turns it to landscape (`pictureShaped`).
    func start(landscapeTitles: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone, observer == nil else { return }
        playsInLandscape = landscapeTitles
        hold.isUnfolded = Self.hingeIsOpen
        if let current = currentOrientation { hold.hold(current) }
        apply(hold.allowed)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemOrientationChanged() }
        }
        let motion = CMMotionManager()
        Self.log.debug("""
            Player opened \(self.currentOrientation.logName, privacy: .public), holding \(self.hold.allowed.rawValue), \
            unfolded \(self.hold.isUnfolded), gravity \(motion.isDeviceMotionAvailable)
            """)
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = Held.interval
            motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
                guard let sample else { return }
                let (x, y, time) = (sample.gravity.x, sample.gravity.y, sample.timestamp)
                MainActor.assumeIsolated { self?.felt(x: x, y: y, at: time) }
            }
            self.motion = motion
        }
        sceneObservation = scene?.observe(\.effectiveGeometry) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                self?.reconcile()
            }
        }
        // Unfolded, it locks the scene once the system says which way the phone is turned.
        systemOrientationChanged()
    }

    /// Lets the app turn freely again as the player closes, turning it the way the phone is,
    /// which with Portrait Orientation Lock on is upright.
    func stop() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
        motion?.stopDeviceMotionUpdates()
        motion = nil
        sceneObservation?.invalidate()
        sceneObservation = nil
        heartbeat?.cancel()
        heartbeat = nil
        appliedAt = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        withdraw()
        unlockScene()
        // Opened again, it starts over, a landscape title turning it again.
        let isUnfolded = hold.isUnfolded
        hold = Hold()
        hold.isUnfolded = isUnfolded
        turned = nil
        held = Held()
        // Turned the phone's way under Portrait Orientation Lock, the app would stay sideways
        // with nothing to turn it back. Flat on a table, the phone says no way up: the app stays
        // as it is.
        apply(.all, turningTo: systemTurned.map(Hold.mask(for:)))
    }

    /// The picture of the title playing is `size`: a landscape one, held upright, turns the player
    /// to landscape and holds it there, once as the player opens (`Hold.pictureShaped`).
    func pictureShaped(_ size: CGSize) {
        guard observer != nil, let current = currentOrientation,
              hold.pictureShaped(size, current: current, playsInLandscape: playsInLandscape) else { return }
        apply(hold.allowed, turningTo: .landscape)
        reconsiderOffer()
    }

    /// Unfolded, the player locks the scene where the system put it; folded shut, it holds the
    /// shape the front screen is in, which is the way the system has the phone turned.
    func hingeChanged(isUnfolded: Bool) {
        Self.hingeIsOpen = isUnfolded
        guard isUnfolded != hold.isUnfolded else { return }
        Self.log.debug("\(isUnfolded ? "Unfolded" : "Folded shut", privacy: .public)")
        hold.isUnfolded = isUnfolded
        if !isUnfolded, let shape = systemTurned ?? currentOrientation { hold.hold(shape) }
        apply(hold.allowed)
        if isUnfolded { lockScene() } else { unlockScene() }
        reconsiderOffer()
    }

    /// Takes the offer: turns the player the way the phone is, and holds it there.
    func turn() {
        guard observer != nil, let offer, let turned else { return }
        withdraw()
        if hold.isUnfolded {
            Self.log.debug("Unlocking the scene to turn \(Optional(offer).logName, privacy: .public)")
            turningSceneTo = offer
            lockedAgreement = nil
            setSceneLocked(false)
            turnTimeout?.cancel()
            turnTimeout = Task {
                try? await Task.sleep(for: Self.turnAllowance)
                guard !Task.isCancelled, turningSceneTo != nil else { return }
                Self.log.debug("The scene didn't turn; locking it where it is")
                turningSceneTo = nil
                lockScene()
                reconsiderOffer()
            }
            return
        }
        guard hold.offers(turned) else { return }
        hold.turn(to: turned)
        apply(hold.allowed, turningTo: Hold.mask(for: turned))
    }

    /// The player's screen is `size`: unfolded, a scene unlocked to turn locks again once it's
    /// the shape it was turning to.
    func screenChanged(_ size: CGSize) {
        guard let target = turningSceneTo, (size.width > size.height) == target.isLandscape else { return }
        turningSceneTo = nil
        turnTimeout?.cancel()
        lockScene(shaped: Hold.mask(for: target))
        reconsiderOffer()
    }

    /// Squares the player with the shape the scene is actually in, as the system can turn it
    /// unasked, or not turn it when asked. Folded, a scene out of the shape held for longer than
    /// the system takes to turn it (`holdAllowance`) is held as it is: the offer then shows if
    /// the phone isn't that shape, and goes if it is. Unfolded, the offer is weighed against the
    /// scene as it is already.
    private func reconcile() {
        guard observer != nil, let current = currentOrientation else { return }
        if !hold.isUnfolded, !hold.allowed.contains(Hold.mask(for: current)),
           appliedAt.map({ ContinuousClock.now - $0 >= Self.holdAllowance }) ?? true {
            Self.log.debug("The scene is \(Optional(current).logName, privacy: .public), out of the shape held; holding it there")
            hold.hold(current)
            apply(hold.allowed)
        }
        reconsiderOffer()
    }

    // MARK: Following the phone

    private func felt(x: Double, y: Double, at time: TimeInterval) {
        guard let orientation = held.felt(x: x, y: y, at: time) else { return }
        Self.log.debug("Held \(Optional(orientation).logName, privacy: .public)")
        turned = orientation
        reconsiderOffer()
    }

    private func systemOrientationChanged() {
        // Flat on a table, or unknown: nothing new about which way is up.
        guard let orientation = Self.interfaceOrientation(facing: UIDevice.current.orientation) else { return }
        Self.log.debug("System turned \(Optional(orientation).logName, privacy: .public)")
        systemTurned = orientation
        if motion == nil { turned = orientation }
        if hold.isUnfolded, lockedAgreement == nil { lockScene() }
        reconsiderOffer()
    }

    /// Where the player would turn: unfolded, the other shape from the scene's, once the way the
    /// system has the phone turned is a quarter turn against the scene from how the two stood as
    /// it locked; folded, the way the phone is held, out of the shape the player holds, once the
    /// scene is in that shape: before, it's turning, or about to be held as it is (`reconcile()`).
    private var turnOffered: UIInterfaceOrientation? {
        guard hold.isUnfolded else {
            guard let turned, let current = currentOrientation, hold.allowed.contains(Hold.mask(for: current)) else { return nil }
            return hold.offers(turned) ? turned : nil
        }
        guard let systemTurned, let current = currentOrientation, let lockedAgreement,
              (Hold.mask(for: systemTurned) == Hold.mask(for: current)) != lockedAgreement else { return nil }
        return current.isLandscape ? .portrait : .landscapeRight
    }

    private func reconsiderOffer() {
        guard let turned = turnOffered else { return withdraw() }
        guard turned != offer else { return }
        let isNew = offer == nil
        offer = turned
        guard isNew else { return }
        Self.log.debug("Offering \(Optional(turned).logName, privacy: .public)")
        isAnnouncing = true
        announcing?.cancel()
        announcing = Task {
            try? await Task.sleep(for: Self.offerShowsAlone)
            if !Task.isCancelled { isAnnouncing = false }
        }
    }

    private func withdraw() {
        announcing?.cancel()
        // Only as it changes: it's looked at every second, and the player's views follow it.
        if offer != nil { offer = nil }
        if isAnnouncing { isAnnouncing = false }
    }

    /// Lets the windows turn to `mask`, and with `turningTo`, turns them that way now, unless the
    /// device turns them itself.
    private func apply(_ mask: UIInterfaceOrientationMask, turningTo turn: UIInterfaceOrientationMask? = nil) {
        guard mask != Self.allowed || turn != nil else { return }
        Self.log.debug("Allowing \(mask.rawValue), turning to \(turn?.rawValue ?? 0)")
        Self.allowed = mask
        appliedAt = .now
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

    // MARK: Unfolded

    /// Unfolded, locks the scene where it is, or `shape`, the one it just turned to, minding how
    /// the way the system has the phone turned stands to it. Not before the system says which way
    /// that is, nor while it's turning the scene.
    private func lockScene(shaped shape: UIInterfaceOrientationMask? = nil) {
        guard observer != nil, hold.isUnfolded, turningSceneTo == nil, let systemTurned,
              let shape = shape ?? currentOrientation.map(Hold.mask(for:)) else { return }
        lockedAgreement = Hold.mask(for: systemTurned) == shape
        Self.log.debug("""
            Locking the scene \(shape == .landscape ? "landscape" : "portrait", privacy: .public), \
            turned \(Optional(systemTurned).logName, privacy: .public)
            """)
        setSceneLocked(true)
    }

    private func unlockScene() {
        lockedAgreement = nil
        turningSceneTo = nil
        turnTimeout?.cancel()
        setSceneLocked(false)
    }

    private func setSceneLocked(_ locks: Bool) {
        guard let scene else { return }
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                (current as? PlayerViewController)?.locksOrientation = locks
                controller = current.presentedViewController
            }
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

    /// The way the phone is held, from gravity along its screen. It's settled once the phone has
    /// stayed turned well toward a new way for a moment, so holding it near 45 degrees, or a
    /// jolt, doesn't flicker the offer; lying near flat says nothing new.
    nonisolated struct Held {
        /// How often gravity is felt.
        static let interval: TimeInterval = 0.1
        /// How long the phone stays turned toward a new way before it's held that way.
        static let settling: TimeInterval = 0.4
        /// Tipped up less than this from lying flat, the phone isn't turned any way.
        private static let leastTilt = 30.0
        /// Turned further than this from a way up, it isn't turned toward it.
        private static let widestTurn = 30.0

        private(set) var orientation: UIInterfaceOrientation?
        /// The new way the phone's turned toward, since when.
        private var leaning: (orientation: UIInterfaceOrientation, since: TimeInterval)?

        /// Gravity is `x`, `y` along the screen, in g, at `time`, in seconds: the way the phone is
        /// held, when that's just settled.
        mutating func felt(x: Double, y: Double, at time: TimeInterval) -> UIInterfaceOrientation? {
            // Between ways, or near flat, it's still leaning the way it was.
            guard let toward = Self.toward(x: x, y: y) else { return nil }
            guard toward != orientation else {
                leaning = nil
                return nil
            }
            guard let leaning, leaning.orientation == toward else {
                leaning = (toward, time)
                return nil
            }
            guard time - leaning.since >= Self.settling else { return nil }
            orientation = toward
            self.leaning = nil
            return toward
        }

        /// The way up the phone is turned toward, with gravity `x`, `y` along its screen: the
        /// interface orientation upright that way. Landscape is mirrored as the device's is: the
        /// phone's left side down shows its interface turned right.
        static func toward(x: Double, y: Double) -> UIInterfaceOrientation? {
            let along = (x * x + y * y).squareRoot()
            guard along >= sin(leastTilt * .pi / 180) else { return nil }
            let ways: [(UIInterfaceOrientation, Double)] = [
                (.portrait, -y), (.portraitUpsideDown, y), (.landscapeRight, -x), (.landscapeLeft, x),
            ]
            return ways.first { $0.1 / along >= cos(widestTurn * .pi / 180) }?.0
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
private extension UIInterfaceOrientation? {
    var logName: String {
        switch self {
        case .portrait: "portrait"
        case .portraitUpsideDown: "upside down"
        case .landscapeLeft: "landscape left"
        case .landscapeRight: "landscape right"
        default: "unknown"
        }
    }
}
#endif
