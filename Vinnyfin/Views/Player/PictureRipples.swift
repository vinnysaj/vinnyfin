#if os(iOS)
import AVFoundation
import CoreImage
import SwiftUI

/// Water rippling over the picture from where it was double-tapped to skip: the frame on screen as
/// the tap lands, bent by `waterRipple` (WaterRipple.metal) and laid over the picture only where
/// the water moves, so the picture plays on around it. The frame comes from an output on the
/// engine's AVPlayer item. A picture the engine draws itself, as a codec AVPlayer can't play, has
/// none: SwiftUI's shaders can't read a video layer, so that one ripples with light alone
/// (`SkipRipple`).
@Observable
final class PictureRipples {
    struct Ripple {
        let origin: CGPoint
        let began: Date
    }

    /// The frame the water bends, as the last tap found the picture.
    private(set) var frame: CGImage?
    private(set) var ripples: [Ripple] = []

    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private weak var item: AVPlayerItem?
    /// The frame last read, which stays the one on screen while the picture is still.
    @ObservationIgnored private var lastBuffer: CVPixelBuffer?
    @ObservationIgnored private var clearing: Task<Void, Never>?

    /// How long a ripple takes to settle.
    static let lifetime: Duration = .seconds(1.4)
    /// The ripples at once, a tap's each: older ones give way.
    static let most = 3

    /// Reads frames from `item`, the engine's AVPlayer item as it changes; nil when the engine
    /// draws the picture itself, or the player closes.
    func attach(to item: AVPlayerItem?) {
        guard item !== self.item || item == nil else { return }
        if let output, let old = self.item { old.remove(output) }
        output = nil
        lastBuffer = nil
        self.item = item
        guard let item else { return }
        // In the picture's own format, so nothing is converted for frames that go unread.
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        self.output = output
    }

    /// A double tap at `origin`, in the picture's coordinates: ripples the frame on screen from
    /// there. False when there's no frame to bend.
    func splash(at origin: CGPoint) -> Bool {
        guard let buffer = displayedBuffer() else { return false }
        let frame = FrameBuffer(buffer: buffer)
        Task {
            guard let image = await Self.image(of: frame) else { return }
            self.frame = image
            ripples = Array((ripples + [Ripple(origin: origin, began: .now)]).suffix(Self.most))
            clearing?.cancel()
            clearing = Task {
                try? await Task.sleep(for: Self.lifetime)
                guard !Task.isCancelled else { return }
                ripples = []
                self.frame = nil
            }
        }
        return true
    }

    private func displayedBuffer() -> CVPixelBuffer? {
        guard let output else { return nil }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) { lastBuffer = buffer }
        return lastBuffer
    }

    private nonisolated struct FrameBuffer: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    /// No wider than this: the water blurs what it bends, and a smaller frame is quicker to make.
    private nonisolated static let widest: CGFloat = 1280
    private nonisolated static let context = CIContext()

    @concurrent
    private nonisolated static func image(of frame: FrameBuffer) async -> CGImage? {
        var image = CIImage(cvPixelBuffer: frame.buffer)
        let scale = min(1, widest / max(1, image.extent.width))
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        return context.createCGImage(image, from: image.extent)
    }
}

/// The water over the picture while it ripples (`PictureRipples`), placed as the picture is: fit
/// to the view, or filling it.
struct PictureRippleView: View {
    let ripples: PictureRipples
    /// The picture's width over its height; the frame's own until it's known.
    let aspect: CGFloat?
    let fillsScreen: Bool

    var body: some View {
        if let frame = ripples.frame, !ripples.ripples.isEmpty {
            TimelineView(.animation) { context in
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(aspect ?? CGFloat(frame.width) / CGFloat(max(1, frame.height)),
                                 contentMode: fillsScreen ? .fill : .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .layerEffect(Self.water(ripples.ripples, at: context.date), maxSampleOffset: Self.reach)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// How far the steepest wave moves the picture, in points.
    private static let amplitude: Float = 14
    /// Room for the picture to move into view from beyond the edges: the waves of every ripple
    /// at once, red bent furthest.
    private static let reach = CGSize(width: CGFloat(amplitude) * 1.4 * CGFloat(PictureRipples.most),
                                      height: CGFloat(amplitude) * 1.4 * CGFloat(PictureRipples.most))

    private static func water(_ ripples: [PictureRipples.Ripple], at date: Date) -> Shader {
        let values = ripples.flatMap { ripple in
            [Float(ripple.origin.x), Float(ripple.origin.y), Float(date.timeIntervalSince(ripple.began))]
        }
        return ShaderLibrary.waterRipple(.floatArray(values), .float(amplitude), .float(56), .float(640),
                                         .float(2.2), .float(0.35))
    }
}
#endif
