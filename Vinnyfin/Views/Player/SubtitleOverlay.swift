import AetherEngine
import MediaAccessibility
import SwiftUI

/// Draws the cues showing at the frame on screen: styled text near the bottom (or where the
/// cue asks), and picture subtitles (Blu-ray, DVD, DVB) where they were authored. Text takes
/// what the person chose in the system's caption style (Subtitles & Captioning › Style), on top
/// of the player's own look, and goes to a braille display as it shows.
struct SubtitleOverlay: View {
    let model: PlayerModel
    /// The picture's size in pixels, for placing picture subtitles; nil fills the view.
    var videoSize: CGSize?
    /// The top of the player's controls in global coordinates while they show. Captions at the
    /// bottom move up above them.
    var controlsTop: CGFloat?
    @Environment(AppSettings.self) private var settings
    @State private var captionStyle = CaptionStyleWatch()

    var body: some View {
        GeometryReader { geometry in
            let time = model.clock.sourceTime
            let active = model.cues.filter { $0.startTime <= time && time < $0.endTime }
            let videoRect = Self.fittedRect(content: videoSize ?? geometry.size, in: geometry.size)
            let clearAbove = controlsTop.map { $0 - geometry.frame(in: .global).minY }
            ZStack {
                ForEach(active) { cue in
                    switch cue.body {
                    case .image(let image):
                        picture(image, videoRect: videoRect)
                    case .text(let text):
                        caption(Self.styled([SubtitleTextRun(text: text, color: nil)], style: captionStyle.style),
                                placement: cue.placement, videoRect: videoRect, clearAbove: clearAbove)
                    case .richText(let runs):
                        caption(Self.styled(runs, style: captionStyle.style), placement: cue.placement, videoRect: videoRect,
                                clearAbove: clearAbove)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onChange(of: Self.texts(of: active), initial: true) { _, texts in Self.tellAccessibility(texts) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onDisappear { Self.tellAccessibility([]) }
    }

    /// The words on screen, for a braille display to show.
    private static func texts(of cues: [SubtitleCue]) -> [String] {
        cues.compactMap { cue in
            switch cue.body {
            case .image: nil
            case .text(let text): text
            case .richText(let runs): runs.map(\.text).joined()
            }
        }
    }

    /// Tells the system which captions are showing, for a braille display; none when empty.
    private static func tellAccessibility(_ texts: [String]) {
        MACaptionAppearanceDidDisplayCaptions(texts as CFArray)
    }

    private func caption(_ text: Text, placement: SubtitleTextPlacement?, videoRect: CGRect, clearAbove: CGFloat?) -> some View {
        let style = captionStyle.style
        let size = max(14, videoRect.height * 0.052 * settings.subtitleScale * style.sizeScale)
        let alignment = placement?.alignment ?? 2
        let vertical: VerticalAlignment = alignment >= 7 ? .top : (alignment >= 4 ? .center : .bottom)
        let margin = videoRect.height * 0.07
        var lift: CGFloat = 0
        if vertical == .bottom, let clearAbove {
            lift = max(0, videoRect.maxY - margin - (clearAbove - 12))
        }
        let horizontal: HorizontalAlignment = [1, 4, 7].contains(alignment) ? .leading : ([3, 6, 9].contains(alignment) ? .trailing : .center)
        return text
            .font(style.fontName.map { .custom($0.value, fixedSize: size) } ?? .system(size: size, weight: .semibold))
            .multilineTextAlignment(horizontal == .leading ? .leading : (horizontal == .trailing ? .trailing : .center))
            .modifier(CaptionEdge(style: style.edgeStyle?.value))
            .padding(.horizontal, style.backgroundFill == nil ? 0 : size * 0.3)
            .background(style.backgroundFill ?? .clear)
            .padding(style.windowFill == nil ? 0 : size * 0.3)
            .background(style.windowFill ?? .clear, in: .rect(cornerRadius: size * 0.2))
            .padding(.horizontal, videoRect.width * 0.06)
            .padding(.top, margin)
            .padding(.bottom, margin + lift)
            .frame(width: videoRect.width, height: videoRect.height, alignment: Alignment(horizontal: horizontal, vertical: vertical))
            .position(x: videoRect.midX, y: videoRect.midY)
    }

    private func picture(_ image: SubtitleImage, videoRect: CGRect) -> some View {
        let canvas = image.canvasSize.width > 0 ? image.canvasSize : (videoSize ?? videoRect.size)
        let canvasRect = Self.fittedRect(content: canvas, in: videoRect.size).offsetBy(dx: videoRect.minX, dy: videoRect.minY)
        let scale = canvasRect.width / max(1, canvas.width)
        let frame = CGRect(
            x: canvasRect.minX + image.position.minX * scale,
            y: canvasRect.minY + image.position.minY * scale,
            width: image.position.width * scale,
            height: image.position.height * scale
        )
        return Image(decorative: image.cgImage, scale: 1)
            .resizable()
            .accessibilityIgnoresInvertColors()
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    /// `content` scaled to fit `container`, centred.
    static func fittedRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The runs in their own styles, in the colors the cue and the system's caption style give
    /// them by the style's precedence: white where neither gives one.
    static func styled(_ runs: [SubtitleTextRun], style: SubtitleCaptionStyle) -> Text {
        let opacity = style.textOpacity?.value ?? 1
        return runs.reduce(Text("")) { text, run in
            var piece = Text(run.text)
            if run.isBold { piece = piece.bold() }
            if run.isItalic { piece = piece.italic() }
            if run.isUnderlined { piece = piece.underline() }
            if run.isStruckThrough { piece = piece.strikethrough() }
            let color = style.textColor?.resolved(cue: run.color) ?? run.color
            piece = piece.foregroundStyle((color.map(Color.init) ?? .white).opacity(opacity))
            return Text("\(text)\(piece)")
        }
    }
}

/// The system's caption style, kept current as the person changes it.
@Observable
private final class CaptionStyleWatch {
    private(set) var style = SubtitleCaptionStyle.current()
    @ObservationIgnored private var observation: SubtitleCaptionStyle.Observation?

    init() {
        observation = SubtitleCaptionStyle.observeChanges { [weak self] style in
            Task { @MainActor in self?.style = style }
        }
    }
}

/// The edges of caption text. The player's own look, a soft shadow that reads over any picture,
/// unless the system's caption style chose another.
private struct CaptionEdge: ViewModifier {
    let style: SubtitleCaptionStyle.EdgeStyle?

    func body(content: Content) -> some View {
        switch style {
        case nil:
            content
                .shadow(color: .black.opacity(0.9), radius: 1.5, x: 0, y: 1)
                .shadow(color: .black.opacity(0.7), radius: 5)
        case .none?:
            content
        case .dropShadow?:
            content.shadow(color: .black.opacity(0.9), radius: 1, x: 1.5, y: 1.5)
        case .raised?:
            content.shadow(color: .black, radius: 0, x: 1, y: 1)
        case .depressed?:
            content.shadow(color: .black, radius: 0, x: -1, y: -1)
        case .uniform?:
            content
                .shadow(color: .black, radius: 0, x: 1, y: 0)
                .shadow(color: .black, radius: 0, x: -1, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: 1)
                .shadow(color: .black, radius: 0, x: 0, y: -1)
        }
    }
}

private extension Color {
    init(_ color: SubtitleColor) {
        self.init(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
    }
}

private extension SubtitleCaptionStyle {
    /// Behind each caption, when the system's style has a background; nil leaves the text on the
    /// picture.
    var backgroundFill: Color? {
        guard backgroundColor != nil || backgroundOpacity != nil else { return nil }
        let opacity = backgroundOpacity?.value ?? 1
        guard opacity > 0 else { return nil }
        return (backgroundColor.map { Color($0.value) } ?? .black).opacity(opacity)
    }

    /// Around the whole caption, when the system's style turns its window on.
    var windowFill: Color? {
        guard let opacity = windowOpacity?.value, opacity > 0 else { return nil }
        return (windowColor.map { Color($0.value) } ?? .black).opacity(opacity)
    }
}
