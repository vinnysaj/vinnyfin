import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The player's choice panels. While one is open the controls stay up.
enum PlayerPanel: Identifiable {
    case audio, subtitles, speed, chapters

    var id: Self { self }

    var title: String {
        switch self {
        case .audio: "Audio"
        case .subtitles: "Subtitles"
        case .speed: "Speed"
        case .chapters: "Chapters"
        }
    }

    var symbol: String {
        switch self {
        case .audio: "speaker.wave.2"
        case .subtitles: "captions.bubble"
        case .speed: "gauge.with.dots.needle.67percent"
        case .chapters: "list.bullet.rectangle"
        }
    }
}

/// The speeds the player offers, and how it writes one.
enum PlaybackSpeed {
    static let choices: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// "1.5×".
    static func label(_ rate: Float) -> String {
        "\(rate.formatted())×"
    }

    /// What VoiceOver calls it, "Normal" at 1×.
    static func name(_ rate: Float) -> String {
        rate == 1 ? "Normal" : label(rate)
    }
}

/// A list of audio tracks, subtitle tracks or chapters, with the current one checked, or a row of
/// speeds with the current one lit.
struct TrackPanel: View {
    let model: PlayerModel
    let panel: PlayerPanel
    /// The height there's room for. The panel is as tall as its rows, up to that or its own limit.
    let room: CGFloat
    let onClose: () -> Void

    private struct Row: Identifiable {
        let id: String
        let title: String
        var spokenTitle: String?
        let detail: String?
        let isSelected: Bool
        /// A chapter's picture.
        var image: URL?
        let choose: () -> Void
    }

    #if os(tvOS)
    /// The remote starts on the current choice, inside the panel.
    @FocusState private var focusedRow: String?
    #endif

    private var rows: [Row] {
        switch panel {
        case .audio:
            return model.audioOptions.map { option in
                Row(id: "audio.\(option.id)", title: option.title, detail: option.detail,
                    isSelected: model.selectedAudio == option.id) { model.chooseAudio(option.id) }
            }
        case .subtitles:
            let off = Row(id: "subtitle.off", title: "Off", detail: nil, isSelected: model.selectedSubtitle == nil) {
                model.chooseSubtitle(nil)
            }
            return [off] + model.subtitleOptions.map { option in
                Row(id: "subtitle.\(option.id)", title: option.title, detail: option.detail,
                    isSelected: model.selectedSubtitle == option.id) { model.chooseSubtitle(option.id) }
            }
        case .speed:
            return PlaybackSpeed.choices.map { rate in
                Row(id: "speed.\(rate)", title: PlaybackSpeed.label(rate), spokenTitle: PlaybackSpeed.name(rate), detail: nil,
                    isSelected: model.rate == rate) { model.setRate(rate) }
            }
        case .chapters:
            let playing = ChapterMark.current(in: model.chapters, at: model.clock.time)
            return model.chapters.map { chapter in
                Row(id: "chapter.\(chapter.index)", title: chapter.name, detail: Scrubber.format(chapter.start),
                    isSelected: chapter == playing, image: chapter.image) { model.seek(to: chapter.start) }
            }
        }
    }

    /// Under the rows, when there's only one choice or none: why.
    private var note: String? {
        switch panel {
        case .audio where model.audioOptions.count == 1: "Only audio track"
        // While the playback starts, its tracks aren't all listed yet.
        case .subtitles where model.subtitleOptions.isEmpty && !isStarting: "No subtitles in this file"
        default: nil
        }
    }

    private var isStarting: Bool {
        switch model.status {
        case .preparing, .loading: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(panel.title, systemImage: panel.symbol).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                #if !os(tvOS)
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.platformGlass)
                    .buttonBorderShape(.circle)
                #endif
            }
            .padding([.horizontal, .top])
            if panel == .speed { speeds } else { list }
        }
        // The speeds' row sets the width of theirs.
        .frame(width: panel == .speed ? nil : Self.width)
        .frame(maxHeight: min(440, room))
        .fixedSize(horizontal: panel == .speed, vertical: true)
        .platformGlass(in: .rect(cornerRadius: 24))
        #if os(tvOS)
        .focusSection()
        .onAppear { focusedRow = rows.first(where: \.isSelected)?.id ?? rows.first?.id }
        #endif
        .accessibilityElement(children: .contain)
        // VoiceOver's two-finger scrub, and Escape, close it.
        .accessibilityAction(.escape, onClose)
        .accessibilityIdentifier("player.panel")
    }

    /// The rows, opening on the current choice, as far down a long list as it is.
    private var list: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(rows) { row in
                        Button {
                            choose(row.choose)
                        } label: {
                            rowLabel(row)
                        }
                        #if os(tvOS)
                        .buttonStyle(PanelRowStyle())
                        .padding(.horizontal, Self.rowInset)
                        .focused($focusedRow, equals: row.id)
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
                        .accessibilityIdentifier("panel.\(row.id)")
                        .id(row.id)
                    }
                    if let note {
                        noteLabel(note)
                    }
                }
                .padding(.vertical, Self.rowInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Once laid out, and again as another panel takes this one's place.
            .task(id: panel) {
                if let selected = rows.first(where: \.isSelected) { scroller.scrollTo(selected.id, anchor: .center) }
            }
        }
    }

    private func rowLabel(_ row: Row) -> some View {
        HStack(alignment: row.image == nil ? .firstTextBaseline : .center, spacing: 10) {
            Image(systemName: "checkmark")
                .fontWeight(.semibold)
                .opacity(row.isSelected ? 1 : 0)
            if let image = row.image {
                Artwork(url: image, aspectRatio: 16.0 / 9.0, cornerRadius: 6, placeholder: "photo")
                    .frame(width: Self.imageWidth)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                if let detail = row.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }

    /// In line with the rows' titles, past where their checkmarks go.
    private func noteLabel(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark").fontWeight(.semibold).hidden()
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        #if os(tvOS)
        .padding(.horizontal, Self.rowInset)
        #endif
        .padding(.bottom, 10)
        .accessibilityIdentifier("panel.note")
    }

    /// Every speed in one row, in reach in any orientation. They keep their size past the default
    /// text size, as the player's buttons do, and the Large Content Viewer shows each one large.
    private var speeds: some View {
        HStack(spacing: Self.chipSpacing) {
            ForEach(rows) { row in
                speedChip(row)
            }
        }
        .padding(.horizontal, Self.chipInset)
        .padding(.bottom, Self.chipInset)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private func speedChip(_ row: Row) -> some View {
        Button {
            choose(row.choose)
        } label: {
            Text(row.title)
                .frame(minWidth: Self.chipMinWidth)
        }
        .buttonStyle(SpeedChipStyle(isSelected: row.isSelected))
        #if os(tvOS)
        .focused($focusedRow, equals: row.id)
        #endif
        .accessibilityLabel(row.spokenTitle ?? row.title)
        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier("panel.\(row.id)")
    }

    /// Makes a choice and closes the panel. The choice ticks on iPhone here, as it's made: the
    /// panel closes with it, before a sensory feedback modifier on it could see the change.
    private func choose(_ choice: () -> Void) {
        choice()
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
        onClose()
    }

    private static var width: CGFloat {
        #if os(tvOS)
        560
        #else
        320
        #endif
    }

    private static var imageWidth: CGFloat {
        #if os(tvOS)
        180
        #else
        88
        #endif
    }

    /// Apple TV keeps rows apart, so the one with focus lifts clear of its neighbours.
    private static var rowSpacing: CGFloat {
        #if os(tvOS)
        12
        #else
        2
        #endif
    }

    /// Between the rows and the glass: on Apple TV room for the focused row's card to lift.
    private static var rowInset: CGFloat {
        #if os(tvOS)
        20
        #else
        0
        #endif
    }

    /// Between the speeds and the glass: on Apple TV room for the focused one to lift.
    private static var chipInset: CGFloat {
        #if os(tvOS)
        28
        #else
        16
        #endif
    }

    private static var chipSpacing: CGFloat {
        #if os(tvOS)
        20
        #else
        4
        #endif
    }

    private static var chipMinWidth: CGFloat {
        #if os(tvOS)
        48
        #else
        20
        #endif
    }
}

/// A speed's chip, lit when it's the speed, like a season's chip on a show's page but closer cut,
/// so every speed fits across a phone held upright. A finger's height to tap, though drawn shorter.
private struct SpeedChipStyle: ButtonStyle {
    let isSelected: Bool
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, Self.padding)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
            .background(fill, in: .capsule)
            #if os(tvOS)
            // With Reduce Motion, focus lifts it with its shadow alone.
            .scaleEffect(isFocused && !reduceMotion ? 1.12 : 1)
            .shadow(radius: isFocused ? 12 : 0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            #else
            .padding(.vertical, 4)
            .contentShape(.rect)
            #endif
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    /// The speed lit white; on Apple TV the chip with focus brighter than the rest.
    private var fill: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white) }
        #if os(tvOS)
        if isFocused { return AnyShapeStyle(.white.opacity(0.35)) }
        #endif
        return AnyShapeStyle(.quaternary)
    }

    private static var padding: CGFloat {
        #if os(tvOS)
        18
        #else
        8
        #endif
    }
}

#if os(tvOS)
/// A panel row with focus: on a rounded card inside the panel's glass, lifted a little, rather than
/// the plain style's square lift from edge to edge over the rows beside it.
private struct PanelRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? .black : .white)
            .background(.white.opacity(isFocused ? 1 : 0), in: .rect(cornerRadius: 12))
            // With Reduce Motion, focus shows in the card and its shadow alone.
            .scaleEffect(configuration.isPressed ? 0.98 : isFocused && !reduceMotion ? 1.02 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 8, y: 4)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
#endif
