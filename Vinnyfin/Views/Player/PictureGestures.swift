#if os(macOS)
import AppKit
#endif
import SwiftUI

/// What taps on the picture do. The first tap of any run shows or hides the controls at once,
/// never waiting to see whether another follows. On a touchscreen a second tap soon after, on the
/// same side third of the picture, skips back or forward instead, and puts the controls back as
/// they were before the first; each tap after that on either side skips again while the taps keep
/// coming. The middle third only ever shows and hides the controls. On the Mac a double click
/// toggles full screen, putting the controls back as they were.
nonisolated struct PictureTaps {
    enum Mode {
        /// Double taps on the sides skip: iPhone and iPad.
        case sideSkips
        /// A double click toggles full screen: the Mac.
        case doubleClickFullScreen
        /// Each tap shows or hides the controls.
        case toggleOnly
    }

    enum Zone {
        case back, middle, forward
    }

    enum Action: Equatable {
        case toggleControls
        /// Skip, first putting the controls back as they were before the run's first tap when
        /// `restoresControls`.
        case skip(forward: Bool, restoresControls: Bool)
        /// Toggle full screen, putting the controls back as they were before the first click.
        case fullScreen
    }

    /// How soon a second tap follows the first to make a double tap, as the system's own.
    static let doubleTapInterval: Double = 0.3
    /// How soon each tap follows the last to keep a run of skips going.
    static let runInterval: Double = 0.7

    let mode: Mode
    let doubleTapInterval: Double
    private var last: (time: Double, zone: Zone)?
    private var isSkipping = false

    init(mode: Mode, doubleTapInterval: Double = Self.doubleTapInterval) {
        self.mode = mode
        self.doubleTapInterval = doubleTapInterval
    }

    /// The third of a picture `width` wide that `x` is in.
    static func zone(x: Double, width: Double) -> Zone {
        guard width > 0 else { return .middle }
        let share = x / width
        if share < 1.0 / 3 { return .back }
        if share > 2.0 / 3 { return .forward }
        return .middle
    }

    /// A tap at `time`, in seconds on any steady clock, in `zone`. `canSkip` says there's a
    /// timeline to skip along, and the run's first tap didn't close a panel.
    mutating func tap(at time: Double, zone: Zone, canSkip: Bool) -> Action {
        let gap = last.map { time - $0.time } ?? .infinity
        let previous = last
        last = (time, zone)
        switch mode {
        case .toggleOnly:
            return .toggleControls
        case .doubleClickFullScreen:
            guard gap <= doubleTapInterval else { return .toggleControls }
            // A third click starts over.
            last = nil
            return .fullScreen
        case .sideSkips:
            guard canSkip, zone != .middle else {
                isSkipping = false
                return .toggleControls
            }
            if isSkipping, gap <= Self.runInterval {
                return .skip(forward: zone == .forward, restoresControls: false)
            }
            isSkipping = false
            if gap <= doubleTapInterval, previous?.zone == zone {
                isSkipping = true
                return .skip(forward: zone == .forward, restoresControls: true)
            }
            return .toggleControls
        }
    }
}

#if os(iOS)
extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    /// The player's layers, where a tap on the picture lands and the ripples it makes spread
    /// from. One space for both: each view's own can start at the screen's edge or at its safe
    /// area's, as it ignores the safe area or not, and a ripple placed by one view's coordinates
    /// in another's would spread a safe area's inset from the finger.
    nonisolated static var playerPicture: Self { .named("player.picture") }
}

/// The picture's touches on iPhone and iPad: taps (`PictureTaps`), a press held to play at twice
/// the speed until let go, and a pinch to fill the screen or fit it.
struct PictureTouches: ViewModifier {
    /// A tap, and the picture's area, both in the player's layers (`playerPicture`), where the
    /// ripples it makes are placed too.
    let onTap: (_ location: CGPoint, _ area: CGRect) -> Void
    let onHoldBegan: () -> Void
    let onHoldEnded: () -> Void
    let onPinch: (_ magnification: CGFloat) -> Void
    @State private var area: CGRect = .zero
    @State private var isHolding = false
    /// When the press held last let go: the lift that ends a hold isn't a tap.
    @State private var holdEnded: Date?

    /// How long a press is held before it plays faster.
    static let holdDuration = 0.4

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .playerPicture) } action: { area = $0 }
            .gesture(
                SpatialTapGesture(coordinateSpace: .playerPicture)
                    .onEnded { value in
                        if isHolding { return }
                        if let holdEnded, Date.now.timeIntervalSince(holdEnded) < 0.3 { return }
                        onTap(value.location, area)
                    }
            )
            .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 12) {
                isHolding = true
                onHoldBegan()
            } onPressingChanged: { pressing in
                guard !pressing, isHolding else { return }
                isHolding = false
                holdEnded = .now
                onHoldEnded()
            }
            .simultaneousGesture(MagnifyGesture().onEnded { onPinch($0.magnification) })
    }
}

/// Over the picture a double tap skipped on: with the controls hidden, the run's sum on the side
/// tapped; with the controls up, the sum is over the skip button instead. The picture ripples
/// like water from each tap (`PictureRipples`); where it can't, a ring of light spreads from where
/// the tap landed.
struct SkipRipple: View {
    let forward: Bool
    /// The run's sum, negative going back.
    let seconds: Double
    /// Counts the taps, each of which ripples.
    let taps: Int
    /// Where the last tap landed, in the player's layers (`playerPicture`).
    let tapLocation: CGPoint
    /// The picture ripples like water under it, in place of the ring of light.
    let bendsPicture: Bool
    let showsTally: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts the rings started: one as it shows, with the run's first skip, and one each tap after.
    @State private var ripples = 0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let origin = geometry.frame(in: .playerPicture).origin
            let reach = min(size.width * 0.4, 380)
            ZStack {
                if !reduceMotion, !bendsPicture {
                    Circle()
                        .stroke(.white.opacity(0.5), lineWidth: 2.5)
                        .frame(width: reach * 2, height: reach * 2)
                        .keyframeAnimator(initialValue: RippleFrame.done, trigger: ripples) { circle, frame in
                            circle.scaleEffect(frame.scale).opacity(frame.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.scale) {
                                LinearKeyframe(0.05, duration: 0)
                                SpringKeyframe(1, duration: 0.55, spring: .smooth)
                            }
                            KeyframeTrack(\.opacity) {
                                LinearKeyframe(1, duration: 0)
                                LinearKeyframe(1, duration: 0.2)
                                LinearKeyframe(0, duration: 0.35)
                            }
                        }
                        .position(x: tapLocation.x - origin.x, y: tapLocation.y - origin.y)
                }
                if showsTally {
                    SkipTally(seconds: seconds)
                        .fixedSize()
                        .foregroundStyle(.white)
                        .transition(.opacity)
                        .position(x: forward ? size.width - reach * 0.5 : reach * 0.5, y: size.height / 2)
                }
            }
        }
        .clipped()
        .onAppear { ripples += 1 }
        .onChange(of: taps) { ripples += 1 }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct RippleFrame {
        var scale: CGFloat
        var opacity: Double

        static let done = RippleFrame(scale: 1, opacity: 0)
    }
}
#endif

#if !os(tvOS)
/// A word over the top of the picture for a moment: the speed held, or the volume set.
struct PlayerFlash: View {
    enum Kind: Equatable {
        /// A press held on the picture plays at this speed.
        case speed(Float)
        /// The volume, from nothing to 1.
        case volume(Float, isMuted: Bool)
    }

    let kind: Kind
    /// The bottom of the controls' top bar in global coordinates while they show, which it keeps below.
    var controlsBottom: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let clearBelow = controlsBottom.map { max(0, $0 - geometry.frame(in: .global).minY) } ?? 0
            label
                .padding(.top, clearBelow + 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var label: some View {
        Group {
            switch kind {
            case .speed(let speed):
                Label(PlaybackSpeed.label(speed), systemImage: "forward.fill")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            case .volume(let level, let isMuted):
                HStack(spacing: 10) {
                    Image(systemName: isMuted || level == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: Double(level))
                        .frame(width: 26)
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white).frame(width: 140 * CGFloat(isMuted ? 0 : level))
                        }
                        .frame(width: 140, height: 6)
                }
                .font(.callout.weight(.semibold))
                .animation(.easeOut(duration: 0.15), value: level)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .platformGlass(in: .capsule)
    }
}
#endif

/// The player window on the Mac and Vision Pro, shaped like its picture: how small it goes, and
/// how it takes the shape of a new picture, on the Mac without leaving the screen. Sizes are the
/// window's content, in points.
nonisolated enum PlayerWindowFrame {
    /// Along the picture's long side and its short side, the least the controls fit in.
    static let longSide: CGFloat = 480
    static let shortSide: CGFloat = 270

    /// The width over the height of a picture `size` big; 16:9 until it's known.
    static func aspect(of size: CGSize?) -> CGFloat {
        guard let size, size.width > 0, size.height > 0 else { return 16.0 / 9.0 }
        return size.width / size.height
    }

    /// The smallest window of a picture `aspect` wide for its height: at least `longSide` along
    /// its long side and `shortSide` along its short one. Small enough for any Mac's screen
    /// whatever the shape, which a minimum width alone isn't for a tall picture.
    static func minimumSize(aspect: CGFloat) -> CGSize {
        if aspect >= 1 {
            let width = max(longSide, shortSide * aspect)
            return CGSize(width: width, height: width / aspect)
        }
        let height = max(longSide, shortSide / aspect)
        return CGSize(width: height * aspect, height: height)
    }

    /// The window's frame for a picture `aspect` wide for its height, from its frame `current`,
    /// on a screen whose area for windows is `visible`. `chrome` is how much bigger the frame is
    /// than the content, which has the picture's shape. The window keeps its width, unless the
    /// picture's height at that width is more than the screen has room for: then it's as tall
    /// as there's room, as wide as the shape makes that, and never smaller than `minimumSize`
    /// but where the screen is smaller still. Its top stays where it was, and then it moves
    /// onto the screen where it's off it.
    static func frame(from current: CGRect, aspect: CGFloat, chrome: CGSize = .zero, on visible: CGRect) -> CGRect {
        guard aspect > 0 else { return current }
        let room = CGSize(width: max(1, visible.width - chrome.width), height: max(1, visible.height - chrome.height))
        let minimum = minimumSize(aspect: aspect)
        var width = max(current.width - chrome.width, minimum.width)
        width = min(width, room.width, room.height * aspect)
        let content = CGSize(width: width.rounded(), height: (width / aspect).rounded())
        let size = CGSize(width: content.width + chrome.width, height: content.height + chrome.height)
        let top = current.maxY
        var origin = CGPoint(x: current.minX, y: top - size.height)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    /// On Vision Pro, how wide the player window goes, in points.
    static let visionWidths: ClosedRange<CGFloat> = 640...3200

    /// On Vision Pro, the player window's size for a picture `aspect` wide for its height, from
    /// its size `current`: as wide as it was, within `visionWidths`, and the picture's shape.
    static func visionSize(from current: CGSize, aspect: CGFloat) -> CGSize {
        guard aspect > 0 else { return current }
        let width = min(max(current.width, visionWidths.lowerBound), visionWidths.upperBound).rounded()
        return CGSize(width: width, height: (width / aspect).rounded())
    }
}

#if os(macOS)
extension EnvironmentValues {
    /// The player's window is in full screen.
    @Entry var playerIsFullScreen = false
}

/// The player window: kept to the picture's shape as it's resized, and turned to the shape of
/// each new picture within its screen (`PlayerWindowFrame`), floated above other windows when
/// asked, and followed in and out of full screen.
struct PlayerWindowShape: NSViewRepresentable {
    /// The picture's shape; nil until it's known.
    let videoSize: CGSize?
    var floatsOnTop = false
    /// Given the window as the player moves into it, and nil as it leaves.
    var onWindow: (NSWindow?) -> Void = { _ in }
    let onFullScreenChange: (Bool) -> Void

    func makeNSView(context: Context) -> ShapeView {
        ShapeView()
    }

    func updateNSView(_ view: ShapeView, context: Context) {
        view.onFullScreenChange = onFullScreenChange
        view.onWindow = onWindow
        view.floatsOnTop = floatsOnTop
        view.videoSize = videoSize
    }

    final class ShapeView: NSView {
        var onFullScreenChange: (Bool) -> Void = { _ in }
        var onWindow: (NSWindow?) -> Void = { _ in }
        var floatsOnTop = false {
            didSet { if floatsOnTop != oldValue { applyLevel() } }
        }
        var videoSize: CGSize? {
            didSet {
                guard videoSize != oldValue else { return }
                // Once SwiftUI has given the window the new shape's minimum size
                // (`PlayerWindow`): a frame below the old one's would be pushed back out to it.
                DispatchQueue.main.async { [weak self] in self?.applyShape() }
            }
        }
        private var observers: [any NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            onWindow(window)
            guard let window else { return }
            applyLevel()
            for (name, isFullScreen) in [(NSWindow.didEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onFullScreenChange(isFullScreen) }
                })
            }
            onFullScreenChange(window.styleMask.contains(.fullScreen))
            applyShape()
        }

        private func applyLevel() {
            window?.level = floatsOnTop ? .floating : .normal
        }

        /// Gives the window the picture's shape on its screen; in full screen the system
        /// letterboxes it instead.
        private func applyShape() {
            guard let window, let videoSize, videoSize.width > 0, videoSize.height > 0 else { return }
            window.contentAspectRatio = videoSize
            guard !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            let chrome = CGSize(width: window.frame.width - content.width, height: window.frame.height - content.height)
            let frame = PlayerWindowFrame.frame(from: window.frame, aspect: PlayerWindowFrame.aspect(of: videoSize),
                                                chrome: chrome, on: screen.visibleFrame)
            let current = window.frame
            guard abs(frame.minX - current.minX) > 1 || abs(frame.maxY - current.maxY) > 1
                    || abs(frame.width - current.width) > 1 || abs(frame.height - current.height) > 1 else { return }
            window.setFrame(frame, display: true, animate: true)
        }
    }
}
#endif

#if os(visionOS)
/// The player window on Vision Pro, which the picture fills edge to edge: it takes the shape of
/// each new picture, and pulled to another size it keeps that shape. Pulled freely, it would show
/// clear bands beside the picture and leave the controls' ornament off the picture's bottom edge.
struct PlayerWindowShape: UIViewRepresentable {
    /// The width over the height of the picture.
    let aspect: CGFloat

    func makeUIView(context: Context) -> ShapeView { ShapeView() }

    func updateUIView(_ view: ShapeView, context: Context) {
        view.aspect = aspect
    }

    final class ShapeView: UIView {
        var aspect: CGFloat = 16.0 / 9.0 {
            didSet { if aspect != oldValue { applyShape() } }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyShape()
        }

        private func applyShape() {
            guard let window, let scene = window.windowScene else { return }
            let size = PlayerWindowFrame.visionSize(from: window.bounds.size, aspect: aspect)
            scene.requestGeometryUpdate(.Vision(size: size, resizingRestrictions: .uniform))
        }
    }
}
#endif
