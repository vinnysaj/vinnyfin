import AetherEngine
import MediaAccessibility
import SwiftUI

/// Draws the cues showing at the frame on screen, as the title's subtitle timing moves them
/// (`PlayerModel.subtitleOffset`): styled text near the bottom (or where the
/// cue asks), and picture subtitles (Blu-ray, DVD, DVB) where they were authored. Lines showing
/// at once stack rather than print over each other (`SubtitleLayout`). Text takes what the
/// person chose in the system's caption style (Subtitles & Captioning › Style), on top of the
/// player's own look, and goes to a braille display as it shows.
struct SubtitleOverlay: View {
    let model: PlayerModel
    /// The picture's size in pixels, for placing picture subtitles; nil fills the view.
    var videoSize: CGSize?
    /// Where what covers the bottom of the picture starts, in global coordinates: the controls'
    /// bottom bar while they show, or the up-next card. Subtitles that would reach below it,
    /// text and pictures alike, move up above it.
    var coveredBelow: CGFloat?
    @Environment(AppSettings.self) private var settings
    @State private var captionStyle = CaptionStyleWatch()

    var body: some View {
        GeometryReader { geometry in
            let time = model.subtitleTime
            let active = model.cues.filter { $0.startTime <= time && time < $0.endTime }
            let videoRect = Self.fittedRect(content: videoSize ?? geometry.size, in: geometry.size)
            let clearAbove = coveredBelow.map { $0 - geometry.frame(in: .global).minY }
            ZStack {
                ForEach(SubtitleLayout.pieces(of: active)) { piece in
                    switch piece.kind {
                    case .picture(let image):
                        picture(image, videoRect: videoRect, clearAbove: clearAbove)
                    case .stack(let band, let cues):
                        stack(cues, band: band, videoRect: videoRect, clearAbove: clearAbove)
                    case .anchored(let cue, let anchor):
                        anchored(cue, at: anchor, videoRect: videoRect, clearAbove: clearAbove)
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

    private func fontSize(in videoRect: CGRect) -> CGFloat {
        max(14, videoRect.height * 0.052 * settings.subtitleScale * captionStyle.style.sizeScale)
    }

    /// One cue's text in the caption style, each line aligned as the cue asks.
    private func line(_ cue: SubtitleCue, size: CGFloat) -> some View {
        let style = captionStyle.style
        let runs: [SubtitleTextRun] = switch cue.body {
        case .text(let text): [SubtitleTextRun(text: text, color: nil)]
        case .richText(let runs): runs
        case .image: []
        }
        let horizontal = SubtitleLayout.horizontalAlignment(cue.placement?.alignment)
        return Self.styled(runs, style: style)
            .font(style.fontName.map { .custom($0.value, fixedSize: size) } ?? .system(size: size, weight: .semibold))
            .multilineTextAlignment(horizontal == .leading ? .leading : (horizontal == .trailing ? .trailing : .center))
            .modifier(CaptionEdge(style: style.edgeStyle?.value))
            .padding(.horizontal, style.backgroundFill == nil ? 0 : size * 0.3)
            .background(style.backgroundFill ?? .clear)
    }

    /// The text cues showing in one band of the picture, in a column in the order they started.
    /// At the bottom the column moves up out of the way of what covers the picture there.
    private func stack(_ cues: [SubtitleCue], band: SubtitleLayout.Band, videoRect: CGRect, clearAbove: CGFloat?) -> some View {
        let style = captionStyle.style
        let size = fontSize(in: videoRect)
        let margin = videoRect.height * 0.07
        var lift: CGFloat = 0
        if band == .bottom, let clearAbove {
            lift = max(0, videoRect.maxY - margin - (clearAbove - SubtitleLayout.clearance))
        }
        let vertical: VerticalAlignment = switch band {
        case .top: .top
        case .middle: .center
        case .bottom: .bottom
        }
        return VStack(spacing: size * 0.2) {
            ForEach(cues) { cue in
                line(cue, size: size)
                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: SubtitleLayout.horizontalAlignment(cue.placement?.alignment),
                                                                     vertical: .center))
            }
        }
        .padding(style.windowFill == nil ? 0 : size * 0.3)
        .background(style.windowFill ?? .clear, in: .rect(cornerRadius: size * 0.2))
        .padding(.horizontal, videoRect.width * 0.06)
        .padding(.top, margin)
        .padding(.bottom, margin + lift)
        .frame(width: videoRect.width, height: videoRect.height, alignment: Alignment(horizontal: .center, vertical: vertical))
        .position(x: videoRect.midX, y: videoRect.midY)
    }

    /// A cue the script put at a point of the picture, by the point of its box its alignment
    /// names, kept inside the picture, and above what covers its bottom.
    private func anchored(_ cue: SubtitleCue, at anchor: CGPoint, videoRect: CGRect, clearAbove: CGFloat?) -> some View {
        let style = captionStyle.style
        let size = fontSize(in: videoRect)
        let bounds = CGRect(origin: .zero, size: videoRect.size)
        let point = CGPoint(x: anchor.x * videoRect.width, y: anchor.y * videoRect.height)
        let clear = clearAbove.map { $0 - videoRect.minY }
        let alignment = cue.placement?.alignment
        // Where the box goes, from its size, which only layout knows.
        let origin: @Sendable (ViewDimensions) -> CGPoint = { dimensions in
            let box = CGSize(width: dimensions.width, height: dimensions.height)
            let origin = SubtitleLayout.origin(of: box, anchoredAt: point, alignment: alignment, in: bounds)
            let lift = SubtitleLayout.lift(top: origin.y, bottom: origin.y + box.height, clearAbove: clear, within: bounds)
            return CGPoint(x: origin.x, y: origin.y - lift)
        }
        return line(cue, size: size)
            .padding(style.windowFill == nil ? 0 : size * 0.3)
            .background(style.windowFill ?? .clear, in: .rect(cornerRadius: size * 0.2))
            .frame(maxWidth: videoRect.width * 0.88)
            .fixedSize(horizontal: false, vertical: true)
            .alignmentGuide(.leading) { -origin($0).x }
            .alignmentGuide(.top) { -origin($0).y }
            .frame(width: videoRect.width, height: videoRect.height, alignment: .topLeading)
            .position(x: videoRect.midX, y: videoRect.midY)
    }

    /// A picture subtitle where it was authored, moved up out of the way of what covers the
    /// bottom of the picture, as text is, but never off the picture.
    private func picture(_ image: SubtitleImage, videoRect: CGRect, clearAbove: CGFloat?) -> some View {
        let canvas = image.canvasSize.width > 0 ? image.canvasSize : (videoSize ?? videoRect.size)
        let canvasRect = Self.fittedRect(content: canvas, in: videoRect.size).offsetBy(dx: videoRect.minX, dy: videoRect.minY)
        let scale = canvasRect.width / max(1, canvas.width)
        let frame = CGRect(
            x: canvasRect.minX + image.position.minX * scale,
            y: canvasRect.minY + image.position.minY * scale,
            width: image.position.width * scale,
            height: image.position.height * scale
        )
        let lift = SubtitleLayout.lift(top: frame.minY, bottom: frame.maxY, clearAbove: clearAbove, within: videoRect)
        return Image(decorative: image.cgImage, scale: 1)
            .resizable()
            .accessibilityIgnoresInvertColors()
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY - lift)
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

/// Where the subtitles showing at once go. Text cues in the same band of the picture (the top,
/// the middle or the bottom, by ASS `\an`, the bottom without one) share one column, in the
/// order they started, so two speakers' lines or a line and a song's stack instead of printing
/// over each other. A cue the script anchored at a point (ASS `\pos`) goes there, inside the
/// picture. Picture subtitles carry their own place.
nonisolated enum SubtitleLayout {
    enum Band: Hashable {
        case top, middle, bottom
    }

    struct Piece: Identifiable {
        enum Kind {
            /// Text cues in the order they started.
            case stack(Band, [SubtitleCue])
            /// A text cue at a point of the picture, in fractions of its width and height.
            case anchored(SubtitleCue, CGPoint)
            case picture(SubtitleImage)
        }

        let id: String
        let kind: Kind
    }

    /// How far above what covers the picture's bottom a subtitle moved out of its way ends.
    static let clearance: CGFloat = 12

    /// The cues showing, laid out: picture subtitles, anchored cues, then a column for each band
    /// with text in it, top to bottom.
    static func pieces(of cues: [SubtitleCue]) -> [Piece] {
        var pieces: [Piece] = []
        var bands: [Band: [SubtitleCue]] = [:]
        for cue in cues {
            switch cue.body {
            case .image(let image):
                pieces.append(Piece(id: "cue-\(cue.id)", kind: .picture(image)))
            case .text, .richText:
                if let position = cue.placement?.position {
                    pieces.append(Piece(id: "cue-\(cue.id)", kind: .anchored(cue, anchor(position))))
                } else {
                    bands[band(cue.placement?.alignment), default: []].append(cue)
                }
            }
        }
        for band in [Band.top, .middle, .bottom] {
            guard let cues = bands[band] else { continue }
            let ordered = cues.sorted { ($0.startTime, $0.id) < ($1.startTime, $1.id) }
            pieces.append(Piece(id: "band-\(band)", kind: .stack(band, ordered)))
        }
        return pieces
    }

    /// The band an ASS numpad alignment puts a cue in: 1 to 3 the bottom, 4 to 6 the middle,
    /// 7 to 9 the top.
    static func band(_ alignment: Int?) -> Band {
        switch numpad(alignment) {
        case 7...9: .top
        case 4...6: .middle
        default: .bottom
        }
    }

    static func horizontalAlignment(_ alignment: Int?) -> HorizontalAlignment {
        switch numpad(alignment) % 3 {
        case 1: .leading
        case 0: .trailing
        default: .center
        }
    }

    /// An anchor kept on the picture: a script may anchor outside it on purpose, which a
    /// player drawing only over the picture can't show.
    static func anchor(_ position: CGPoint) -> CGPoint {
        CGPoint(x: min(max(position.x, 0), 1), y: min(max(position.y, 0), 1))
    }

    /// The top-left corner of a box of `size` whose point named by `alignment` is at `anchor`, as
    /// ASS places a `\pos` cue (by its bottom centre without an alignment), moved as little as
    /// keeps it inside `bounds`.
    static func origin(of size: CGSize, anchoredAt anchor: CGPoint, alignment: Int?, in bounds: CGRect) -> CGPoint {
        let alignment = numpad(alignment)
        let column = CGFloat((alignment - 1) % 3) / 2
        let row = 1 - CGFloat((alignment - 1) / 3) / 2
        let x = anchor.x - size.width * column
        let y = anchor.y - size.height * row
        return CGPoint(x: min(max(x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
                       y: min(max(y, bounds.minY), max(bounds.minY, bounds.maxY - size.height)))
    }

    /// How far up something from `top` to `bottom` moves to end `clearance` above `clearAbove`,
    /// where what covers the picture starts: as far as that takes, but no further than its top
    /// reaching the top of `bounds`.
    static func lift(top: CGFloat, bottom: CGFloat, clearAbove: CGFloat?, within bounds: CGRect) -> CGFloat {
        guard let clearAbove else { return 0 }
        let needed = bottom - (clearAbove - clearance)
        guard needed > 0 else { return 0 }
        return min(needed, max(0, top - bounds.minY))
    }

    private static func numpad(_ alignment: Int?) -> Int {
        guard let alignment, (1...9).contains(alignment) else { return 2 }
        return alignment
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
