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
    /// The finger went around the ring by `turn` radians, clockwise positive. On the first turn of
    /// a circle `undoesSwipe`: what the finger did before it was clear it was circling read as a swipe.
    case circle(turn: Double, undoesSwipe: Bool)
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
    /// How far a swipe goes, as a share of the surface's width, before it counts (`StraySwipe`).
    var swipeThreshold: Double
    let onGesture: (RemoteGesture) -> Void

    func makeUIView(context: Context) -> RemoteInputView {
        RemoteInputView(surface: surface)
    }

    func updateUIView(_ view: RemoteInputView, context: Context) {
        view.onGesture = onGesture
        view.isActive = isActive
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
    private lazy var sides: SidePressWatcher = {
        let sides = SidePressWatcher(target: nil, action: nil)
        sides.delegate = self
        sides.onChange = { [weak self] forward, isDown in self?.side(forward: forward, isDown: isDown) }
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
        surface.onTurn = { [weak self] turn, isFirst in self?.onGesture(.circle(turn: turn, undoesSwipe: isFirst)) }
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
            // Circling, the ring takes the finger's movement instead.
            guard !surface.isCircling else { return }
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

/// Sees the left and right arrow presses go down and up, without ever recognizing: the presses go
/// on to focus and SwiftUI's commands as if it weren't there.
private final class SidePressWatcher: UIGestureRecognizer {
    var onChange: ((_ forward: Bool, _ isDown: Bool) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedPressTypes = [UIPress.PressType.leftArrow, .rightArrow].map { NSNumber(value: $0.rawValue) }
        allowedTouchTypes = []
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        for press in presses {
            if let forward = Self.forward(press) { onChange?(forward, true) }
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        for press in presses {
            if let forward = Self.forward(press) { onChange?(forward, false) }
        }
        state = .failed
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        pressesEnded(presses, with: event)
    }

    private static func forward(_ press: UIPress) -> Bool? {
        switch press.type {
        case .rightArrow: true
        case .leftArrow: false
        default: nil
        }
    }
}

/// The finger on a Siri Remote's touch surface, through Game Controller, which unlike UIKit's
/// touches tells where on the surface it is: for circling the clickpad's ring, and for clicking a
/// side of the first Siri Remote's surface, which clicks as one button.
@MainActor
final class TouchSurface: NSObject {
    /// Told each turn of the finger around the ring, in radians clockwise, and whether it's the
    /// first, while active.
    var onTurn: ((_ turn: Double, _ isFirst: Bool) -> Void)?
    var isActive = false
    var isCircling: Bool { ring.isTurning }

    private var ring = RingTurn()
    private var point: SIMD2<Double>?
    /// The remote the finger is on clicks its sides as arrows of their own.
    private var sidesClickApart = true
    private var lastSidePress: ContinuousClock.Instant?
    private var remotes: [GCController] = []
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Control Center's remote connects as it opens.
        NotificationCenter.default.addObserver(self, selector: #selector(connected(_:)), name: .GCControllerDidConnect, object: nil)
        GCController.controllers().forEach(attach)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        NotificationCenter.default.removeObserver(self, name: .GCControllerDidConnect, object: nil)
        for remote in remotes {
            remote.microGamepad?.dpad.valueChangedHandler = nil
            remote.microGamepad?.reportsAbsoluteDpadValues = false
        }
        remotes = []
        ring = RingTurn()
        point = nil
    }

    func noteSidePress() {
        lastSidePress = .now
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

    private func attach(_ controller: GCController) {
        // The Siri Remotes and Control Center's remote; a game controller's stick isn't a surface.
        guard controller.extendedGamepad == nil, let gamepad = controller.microGamepad,
              !remotes.contains(where: { $0 === controller }) else { return }
        remotes.append(controller)
        gamepad.reportsAbsoluteDpadValues = true
        let sidesClickApart = controller.physicalInputProfile.dpads[GCInputDirectionalCardinalDpad] != nil
        // Called on the controller's handler queue, the main queue.
        gamepad.dpad.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated {
                self?.moved(to: x == 0 && y == 0 ? nil : SIMD2(Double(x), Double(y)), sidesClickApart: sidesClickApart)
            }
        }
    }

    private func moved(to point: SIMD2<Double>?, sidesClickApart: Bool) {
        self.point = point
        if point != nil { self.sidesClickApart = sidesClickApart }
        let wasTurning = ring.isTurning
        guard let turn = ring.update(point), isActive else { return }
        onTurn?(turn, !wasTurning)
    }
}
#endif
