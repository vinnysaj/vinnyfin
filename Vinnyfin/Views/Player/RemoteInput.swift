#if os(tvOS)
import GameController
import SwiftUI
import UIKit

/// What the remote did that focus and SwiftUI's commands don't carry: the finger moving across
/// the touch surface or around the clickpad's ring, and the clickpad's sides (or the arrow keys of
/// a keyboard, a TV's remote or a game controller) clicked or held.
enum RemoteGesture: Equatable {
    /// The finger moved across the touch surface by `distance` of its width, positive to the
    /// right, at `speed` widths a second. Only once the swipe is clearly sideways.
    case swipe(distance: Double, speed: Double)
    /// The finger went around the ring by `turn` radians, clockwise positive, at `speed` turns a
    /// second (`RingSpeed`), nil on a circle's first turn. On the first turn of a circle that
    /// wasn't armed `undoesSwipe`: what the finger did before it was clear it was circling read as
    /// a swipe.
    case circle(turn: Double, speed: Double?, undoesSwipe: Bool)
    /// The finger has rested still on the touch surface a moment (`TouchRest.peek`).
    case rest
    /// The finger left the touch surface.
    case lift
    /// A side clicked and let go.
    case click(forward: Bool)
    /// A side held: scanning, until `holdEnded`.
    case holdBegan(forward: Bool)
    case holdEnded
}

/// The remote's gestures anywhere in the player, through recognizers on the window, which see the
/// touch surface and the presses whatever has focus. They only watch, and only while `isActive`:
/// watching the arrows at all keeps focus from moving between buttons with them.
struct RemoteInput: UIViewRepresentable {
    let surface: TouchSurface
    var isActive: Bool
    /// The timeline shows, so a finger resting on the ring arms it (`RingTurn.arm()`) and the
    /// timeline shows the ring.
    var ringArms: Bool
    /// How far a swipe goes, as a share of the surface's width, before it counts (`StraySwipe`).
    var swipeThreshold: Double
    let onGesture: (RemoteGesture) -> Void

    func makeUIView(context: Context) -> RemoteInputView {
        RemoteInputView(surface: surface)
    }

    func updateUIView(_ view: RemoteInputView, context: Context) {
        view.onGesture = onGesture
        view.isActive = isActive
        surface.ringArms = ringArms
        view.swipeThreshold = CGFloat(swipeThreshold)
    }

    static func dismantleUIView(_ view: RemoteInputView, coordinator: ()) {
        view.detach()
    }
}

final class RemoteInputView: UIView, UIGestureRecognizerDelegate {
    var onGesture: (RemoteGesture) -> Void = { _ in }
    /// How far a swipe goes, as a share of the surface's width, before it counts.
    var swipeThreshold = CGFloat(StraySwipe.threshold)
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            pan.isEnabled = isActive
            sides.isEnabled = isActive
            surface.isActive = isActive
            guard !isActive, let hold else { return }
            // A side held as the remote moves on still lands its scan; one only pressed does nothing.
            hold.timer.cancel()
            self.hold = nil
            if hold.isScanning { onGesture(.holdEnded) }
        }
    }

    private let surface: TouchSurface
    private weak var attachedWindow: UIWindow?
    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.cancelsTouchesInView = false
        pan.delegate = self
        return pan
    }()
    private lazy var sides: ArrowPressWatcher = {
        let sides = ArrowPressWatcher(target: nil, action: nil)
        sides.delegate = self
        sides.onSide = { [weak self] forward, isDown in self?.side(forward: forward, isDown: isDown) }
        sides.onUpOrDown = { [weak self] isDown in self?.surface.noteVerticalPress(isDown: isDown) }
        return sides
    }()

    /// The swipe being followed: whether it's clearly sideways yet, or clearly not, and how far
    /// across it had gone when last passed on.
    private var swipeIsSideways: Bool?
    private var passedTranslation: CGFloat = 0
    private var hold: Hold?

    private struct Hold {
        let forward: Bool
        let timer: Task<Void, Never>
        var isScanning = false
    }

    /// A side held this long scans; let go sooner, it clicks.
    private static let holdDelay = Duration.milliseconds(400)

    init(surface: TouchSurface) {
        self.surface = surface
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        pan.isEnabled = false
        sides.isEnabled = false
        surface.onTurn = { [weak self] turn, speed, undoesSwipe in
            self?.onGesture(.circle(turn: turn, speed: speed, undoesSwipe: undoesSwipe))
        }
        surface.onRest = { [weak self] in self?.onGesture(.rest) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window !== attachedWindow else { return }
        detach()
        guard let window else { return }
        window.addGestureRecognizer(pan)
        window.addGestureRecognizer(sides)
        attachedWindow = window
        surface.start()
    }

    func detach() {
        attachedWindow?.removeGestureRecognizer(pan)
        attachedWindow?.removeGestureRecognizer(sides)
        attachedWindow = nil
        surface.stop()
        hold?.timer.cancel()
        hold = nil
    }

    // MARK: Touch surface

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let window = attachedWindow else { return }
        let width = max(window.bounds.width, 1)
        switch pan.state {
        case .began, .changed:
            let translation = pan.translation(in: window)
            if swipeIsSideways == nil {
                guard max(abs(translation.x), abs(translation.y)) >= width * swipeThreshold else { return }
                swipeIsSideways = abs(translation.x) > abs(translation.y) * 1.2
                passedTranslation = 0
            }
            guard swipeIsSideways == true else { return }
            let distance = translation.x - passedTranslation
            passedTranslation = translation.x
            // Circling, or armed to, the ring takes the finger's movement instead.
            guard !surface.holdsSwipes else { return }
            onGesture(.swipe(distance: distance / width, speed: abs(pan.velocity(in: window).x) / width))
        default:
            swipeIsSideways = nil
            passedTranslation = 0
            onGesture(.lift)
        }
    }

    // MARK: Sides

    private func side(forward: Bool, isDown: Bool) {
        guard isActive else { return }
        surface.noteSidePress()
        if isDown {
            hold?.timer.cancel()
            let timer = Task { [weak self] in
                try? await Task.sleep(for: Self.holdDelay)
                guard !Task.isCancelled, let self, self.hold?.forward == forward else { return }
                self.hold?.isScanning = true
                self.onGesture(.holdBegan(forward: forward))
            }
            hold = Hold(forward: forward, timer: timer)
        } else {
            guard let hold, hold.forward == forward else { return }
            hold.timer.cancel()
            self.hold = nil
            onGesture(hold.isScanning ? .holdEnded : .click(forward: forward))
        }
    }

    // Watching, they let every other recognizer, focus's among them, work alongside.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Sees the arrow presses go down and up, without ever recognizing: the presses go on to focus and
/// SwiftUI's commands as if it weren't there. Left and right are the sides clicked or held; up and
/// down tell a click on the ring's top or bottom from a swipe (`VerticalMove`).
private final class ArrowPressWatcher: UIGestureRecognizer {
    var onSide: ((_ forward: Bool, _ isDown: Bool) -> Void)?
    var onUpOrDown: ((_ isDown: Bool) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedPressTypes = [UIPress.PressType.leftArrow, .rightArrow, .upArrow, .downArrow].map { NSNumber(value: $0.rawValue) }
        allowedTouchTypes = []
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        for press in presses { changed(press, isDown: true) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        for press in presses { changed(press, isDown: false) }
        state = .failed
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        pressesEnded(presses, with: event)
    }

    private func changed(_ press: UIPress, isDown: Bool) {
        switch press.type {
        case .rightArrow: onSide?(true, isDown)
        case .leftArrow: onSide?(false, isDown)
        case .upArrow, .downArrow: onUpOrDown?(isDown)
        default: break
        }
    }
}

/// The finger on a Siri Remote's touch surface, through Game Controller, which unlike UIKit's
/// touches tells where on the surface it is: for circling the clickpad's ring, for a finger resting
/// on the surface, and for clicking a side of the first Siri Remote's surface, which clicks as one
/// button. Follows every remote connected, Control Center's among them, and lets go of one that
/// disconnects, as a remote does as the Apple TV sleeps.
@MainActor @Observable
final class TouchSurface: NSObject {
    /// Told each turn of the finger around the ring, in radians clockwise, with its speed in turns
    /// a second (nil on a circle's first turn) and whether it undoes what read as a swipe before it,
    /// while active.
    @ObservationIgnored var onTurn: ((_ turn: Double, _ speed: Double?, _ undoesSwipe: Bool) -> Void)?
    /// Told when the finger has rested still a moment (`TouchRest.peek`), while active.
    @ObservationIgnored var onRest: (() -> Void)?
    @ObservationIgnored var isActive = false {
        didSet { if !isActive { disarm() } }
    }
    /// A finger resting on the ring arms it: the timeline is up to show its ring.
    @ObservationIgnored var ringArms = false {
        didSet { if !ringArms { disarm() } }
    }
    /// What the finger on the ring is doing, as far as it can be told yet.
    private(set) var reading = RingTurn.Reading.none
    /// The ring takes the finger's movement, rather than a swipe: circling, or armed to.
    var holdsSwipes: Bool { ring.isTurning || ring.isArmed }

    @ObservationIgnored private var ring = RingTurn()
    @ObservationIgnored private var speed = RingSpeed()
    @ObservationIgnored private var rest = TouchRest()
    @ObservationIgnored private var restWait: Task<Void, Never>?
    @ObservationIgnored private var point: SIMD2<Double>?
    /// The remote the finger is on clicks its sides as arrows of their own.
    @ObservationIgnored private var sidesClickApart = true
    @ObservationIgnored private var lastSidePress: ContinuousClock.Instant?
    @ObservationIgnored private var lastVerticalPress: ContinuousClock.Instant?
    @ObservationIgnored private var verticalPressIsDown = false
    @ObservationIgnored private var roster = RemoteRoster<GCController>()
    @ObservationIgnored private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Control Center's remote connects as it opens; a Siri Remote again as the Apple TV wakes.
        NotificationCenter.default.addObserver(self, selector: #selector(connected(_:)), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(disconnected(_:)), name: .GCControllerDidDisconnect, object: nil)
        GCController.controllers().forEach(attach)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        NotificationCenter.default.removeObserver(self, name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.removeObserver(self, name: .GCControllerDidDisconnect, object: nil)
        for remote in roster.remotes {
            remote.microGamepad?.dpad.valueChangedHandler = nil
            remote.microGamepad?.reportsAbsoluteDpadValues = false
        }
        roster.removeAll()
        lifted()
    }

    /// A click, the finger resting on the ring as it clicks there, isn't a circle: the ring armed
    /// by the rest lets go, and focus can move with the click.
    func noteSidePress() {
        lastSidePress = .now
        disarm()
    }

    func noteVerticalPress(isDown: Bool) {
        verticalPressIsDown = isDown
        lastVerticalPress = .now
        if isDown { disarm() }
    }

    /// An up or down arrow is down, or was pressed just now (`VerticalMove.pressReach`): a click
    /// on the ring's top or bottom, or a key, rather than a swipe.
    var verticalPressCame: Bool {
        if verticalPressIsDown { return true }
        guard let lastVerticalPress else { return false }
        return ContinuousClock.now - lastVerticalPress < .seconds(VerticalMove.pressReach)
    }

    /// The side of the surface a click just now was on, forward for the right: on a remote whose
    /// whole surface clicks as one button, with the finger well to one side. Nil in the middle, on
    /// a remote whose sides click as arrows, and when an arrow press just came, as a tap on the
    /// edge of the first remote's surface sends one.
    func clickedSide() -> Bool? {
        guard !sidesClickApart, let point, abs(point.x) > 0.5, abs(point.x) > abs(point.y) * 1.5 else { return nil }
        if let lastSidePress, ContinuousClock.now - lastSidePress < .milliseconds(500) { return nil }
        return point.x > 0
    }

    @objc private func connected(_ note: Notification) {
        if let controller = note.object as? GCController { attach(controller) }
    }

    @objc private func disconnected(_ note: Notification) {
        guard let controller = note.object as? GCController else { return }
        controller.microGamepad?.dpad.valueChangedHandler = nil
        // The finger on it lifted with it, as far as anything here will hear.
        if roster.disconnected(controller) { lifted() }
    }

    /// Follows `controller`'s surface, again if it was followed before: one that connects again
    /// may have lost the handler.
    private func attach(_ controller: GCController) {
        // The Siri Remotes and Control Center's remote; a game controller's stick isn't a surface.
        guard controller.extendedGamepad == nil, let gamepad = controller.microGamepad else { return }
        roster.connected(controller)
        gamepad.reportsAbsoluteDpadValues = true
        let sidesClickApart = controller.physicalInputProfile.dpads[GCInputDirectionalCardinalDpad] != nil
        // Called on the controller's handler queue, the main queue.
        gamepad.dpad.valueChangedHandler = { [weak self, weak controller] _, x, y in
            MainActor.assumeIsolated {
                guard let self, let controller else { return }
                self.moved(on: controller, to: x == 0 && y == 0 ? nil : SIMD2(Double(x), Double(y)), sidesClickApart: sidesClickApart)
            }
        }
    }

    private func moved(on remote: GCController, to point: SIMD2<Double>?, sidesClickApart: Bool) {
        guard let point else { return lifted() }
        roster.touched(remote)
        self.point = point
        self.sidesClickApart = sidesClickApart
        let now = ProcessInfo.processInfo.systemUptime
        if rest.moved(to: point, at: now) { waitOnRest() }
        let wasTurning = ring.isTurning
        let wasArmed = ring.isArmed
        let turn = ring.update(point)
        updateReading()
        guard let turn else {
            if !ring.isTurning { speed.reset() }
            return
        }
        // A circle's first turn catches up on how far it went round before it was one.
        let measured: Double? = wasTurning ? speed.note(turn, at: now) : nil
        guard isActive else { return }
        onTurn?(turn, measured, !wasTurning && !wasArmed)
    }

    private func lifted() {
        point = nil
        _ = ring.update(nil)
        _ = rest.moved(to: nil, at: 0)
        speed.reset()
        restWait?.cancel()
        updateReading()
    }

    /// From a new rest: after `TouchRest.peek` tells of it, and after `TouchRest.arming`, with the
    /// finger on the ring and the timeline up, arms the ring.
    private func waitOnRest() {
        restWait?.cancel()
        restWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TouchRest.peek))
            guard let self, !Task.isCancelled else { return }
            if self.isActive { self.onRest?() }
            try? await Task.sleep(for: .seconds(TouchRest.arming - TouchRest.peek))
            guard !Task.isCancelled, self.isActive, self.ringArms, self.ring.arm() else { return }
            self.speed.reset()
            self.updateReading()
        }
    }

    private func disarm() {
        ring.disarm()
        updateReading()
    }

    private func updateReading() {
        let reading = ring.reading
        if reading != self.reading { self.reading = reading }
    }
}
#endif
