import AetherEngine
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The player's choice panels. While one is open the controls stay up. The track panels are
/// `TrackPanel`'s, the quality `QualityPanel`'s, and the show's episodes `EpisodesPanel`'s; on
/// Apple TV the episodes and the info are the tabs a swipe down from the buttons (`PlayerTabs`).
enum PlayerPanel: Identifiable {
    /// The audio tracks when there's a choice, the subtitles and their timing, and the sound tools.
    case audioAndSubtitles
    case chapters, episodes
    /// What plays and the ways to play it, and the speed.
    case quality
    case info

    var id: Self { self }

    var title: String {
        switch self {
        case .audioAndSubtitles: "Audio & Subtitles"
        case .chapters: "Chapters"
        case .episodes: "Episodes"
        case .quality: "Quality"
        case .info: "Info"
        }
    }

    var symbol: String {
        switch self {
        case .audioAndSubtitles: "captions.bubble"
        case .chapters: "list.bullet.rectangle"
        case .episodes: "rectangle.stack"
        case .quality: "sparkles.tv"
        case .info: "info.circle"
        }
    }

    /// A list of `TrackPanel`'s.
    var isTrackPanel: Bool {
        switch self {
        case .audioAndSubtitles, .chapters: true
        case .episodes, .quality, .info: false
        }
    }

    /// One of Apple TV's tabs below the buttons, which focus opens.
    var isTab: Bool {
        #if os(tvOS)
        self == .episodes || self == .info
        #else
        false
        #endif
    }

    /// Picking a choice closes it; the audio and subtitles panel, with more to set beside the
    /// choice, stays.
    var closesOnChoice: Bool { self != .audioAndSubtitles }

    /// It opens in a popover from its button rather than over the picture. On iPhone and iPad the
    /// popover's glass grows out of the button's; the episodes are a drawer along the bottom or a
    /// sheet. On Vision Pro the buttons are in an ornament below the window, out of the picture's
    /// coordinates, so a panel over the picture could neither find its button nor keep off it.
    var opensInPopover: Bool {
        #if os(visionOS)
        !isTab
        #elseif os(iOS)
        self != .episodes
        #else
        false
        #endif
    }
}

extension View {
    /// A panel's glass, but in a popover, which is glass already.
    @ViewBuilder func panelGlass(in shape: some InsettableShape, for panel: PlayerPanel) -> some View {
        if panel.opensInPopover {
            self
        } else {
            platformGlass(in: shape)
        }
    }
}

/// Where each panel's button is, in global coordinates, for the panel to open above it.
struct PanelButtonFrames: PreferenceKey {
    static let defaultValue: [PlayerPanel: CGRect] = [:]

    static func reduce(value: inout [PlayerPanel: CGRect], nextValue: () -> [PlayerPanel: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Where a panel opens over the button that opened it.
nonisolated enum PanelPlacement {
    /// The gap between a panel and the top of its button.
    static let gap: CGFloat = 10

    /// The leading edge of a panel `width` wide, centered over a button whose middle is at
    /// `buttonMidX`, kept `margin` inside a container `containerWidth` wide.
    static func leading(width: CGFloat, buttonMidX: CGFloat, containerWidth: CGFloat, margin: CGFloat) -> CGFloat {
        let centered = buttonMidX - width / 2
        return min(max(margin, centered), max(margin, containerWidth - margin - width))
    }
}

/// A panel of choices with the current one checked: the audio tracks when there's a choice, the
/// subtitles and their timing, and the sound tools; or the chapters.
struct TrackPanel: View {
    let model: PlayerModel
    let panel: PlayerPanel
    /// The height there's room for. The panel is as tall as its rows, up to that or its own limit.
    let room: CGFloat
    let onClose: () -> Void

    private struct Row: Identifiable {
        let id: String
        let title: String
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

    private var audioRows: [Row] {
        model.audioOptions.map { option in
            Row(id: "audio.\(option.id)", title: option.title, detail: option.detail,
                isSelected: model.selectedAudio == option.id) { model.chooseAudio(option.id) }
        }
    }

    private var subtitleRows: [Row] {
        let off = Row(id: "subtitle.off", title: "Off", detail: nil, isSelected: model.selectedSubtitle == nil) {
            model.chooseSubtitle(nil)
        }
        return [off] + model.subtitleOptions.map { option in
            Row(id: "subtitle.\(option.id)", title: option.title, detail: option.detail,
                isSelected: model.selectedSubtitle == option.id) { model.chooseSubtitle(option.id) }
        }
    }

    private var chapterRows: [Row] {
        let playing = ChapterMark.current(in: model.chapters, at: model.clock.time)
        return model.chapters.map { chapter in
            Row(id: "chapter.\(chapter.index)", title: chapter.name, detail: Scrubber.format(chapter.start),
                isSelected: chapter == playing, image: chapter.image) { model.seek(to: chapter.start) }
        }
    }

    /// The audio tracks are a choice only when there's more than one; one track has nothing to pick.
    private var showsAudioTracks: Bool { model.audioOptions.count > 1 }

    /// The choice the remote starts on and a long list opens at: the subtitles' in the audio and
    /// subtitles panel, which its button is for.
    private var currentRow: String? {
        switch panel {
        case .audioAndSubtitles: subtitleRows.first(where: \.isSelected)?.id
        case .chapters: chapterRows.first(where: \.isSelected)?.id ?? chapterRows.first?.id
        case .episodes, .quality, .info: nil
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
                    .help("Close")
                    .buttonStyle(.platformGlass)
                    .buttonBorderShape(.circle)
                #endif
            }
            .padding([.horizontal, .top])
            switch panel {
            case .audioAndSubtitles: tracks
            case .chapters: chapters
            // Panels of their own (`PlayerPanel.isTrackPanel`).
            case .episodes, .quality, .info: EmptyView()
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: min(Self.maxHeight, room))
        // As tall as its rows; a popover, short of room, scrolls them instead.
        .fixedSize(horizontal: false, vertical: !panel.opensInPopover)
        .panelGlass(in: .rect(cornerRadius: 24), for: panel)
        #if os(tvOS)
        .focusSection()
        .onAppear { focusedRow = currentRow }
        #endif
        .accessibilityElement(children: .contain)
        // VoiceOver's two-finger scrub, and Escape, close it.
        .accessibilityAction(.escape, onClose)
        .accessibilityIdentifier("player.panel")
    }

    // MARK: Audio and subtitles

    private var tracks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                if showsAudioTracks {
                    sectionHeader("Audio")
                    ForEach(audioRows) { rowButton($0) }
                }
                sectionHeader("Subtitles")
                ForEach(subtitleRows) { rowButton($0) }
                // While the playback starts, its tracks aren't all listed yet.
                if model.subtitleOptions.isEmpty, !isStarting {
                    noteLabel("No subtitles in this file")
                }
                if model.selectedSubtitle != nil {
                    SubtitleTiming(model: model)
                        .padding(.horizontal, Self.rowInset)
                }
                sectionHeader("Sound")
                soundToggle("Boost Dialogue", detail: "Voices clearer over music and effects", id: "sound.dialogue",
                            isOn: model.sound.boostsDialogue, set: model.setBoostsDialogue)
                soundToggle("Reduce Loud Sounds", detail: "Loud scenes closer to quiet ones", id: "sound.loud",
                            isOn: model.sound.reducesLoudSounds, set: model.setReducesLoudSounds)
                if model.soundShapingState == .unavailable {
                    noteLabel("Not available for this stream")
                } else if let note = model.soundToolsNote {
                    noteLabel(note)
                }
            }
            .padding(.bottom, Self.rowInset + 6)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.horizontal, Self.rowInset)
            .padding(.top, Self.sectionGap)
            .accessibilityAddTraits(.isHeader)
    }

    /// A sound tool, on or off, which stays on for every playback until it's turned off.
    @ViewBuilder private func soundToggle(_ title: String, detail: String, id: String, isOn: Bool,
                                          set: @escaping (Bool) -> Void) -> some View {
        #if os(tvOS)
        Button {
            set(!isOn)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(isOn ? "On" : "Off").foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .buttonStyle(PanelRowStyle())
        .padding(.horizontal, Self.rowInset)
        .focused($focusedRow, equals: id)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityIdentifier("panel.\(id)")
        #else
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityIdentifier("panel.\(id)")
        #endif
    }

    // MARK: Chapters

    /// The chapters, opening on the one playing, as far down a long list as it is.
    private var chapters: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(chapterRows) { rowButton($0) }
                }
                .padding(.vertical, Self.rowInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Once laid out, and again as another panel takes this one's place.
            .task(id: panel) {
                if let currentRow { scroller.scrollTo(currentRow, anchor: .center) }
            }
        }
    }

    private func rowButton(_ row: Row) -> some View {
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

    /// Makes a choice, closing a panel that closes on one. The choice ticks on iPhone here, as
    /// it's made: a panel closing with it would be gone before a sensory feedback modifier on it
    /// could see the change.
    private func choose(_ choice: () -> Void) {
        choice()
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
        if panel.closesOnChoice { onClose() }
    }

    private static var width: CGFloat {
        #if os(tvOS)
        560
        #else
        320
        #endif
    }

    private static var maxHeight: CGFloat {
        #if os(tvOS)
        760
        #else
        480
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

    /// Above a section's title, apart from the section before.
    private static var sectionGap: CGFloat {
        #if os(tvOS)
        16
        #else
        10
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

}

/// Moves the subtitles a tenth of a second earlier or later, holding a button to keep going, and
/// shows how far off the file's timing they are; the amount resets it. VoiceOver adjusts it as one
/// control.
private struct SubtitleTiming: View {
    let model: PlayerModel

    var body: some View {
        let offset = model.subtitleOffset
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Timing")
                Text(offset == 0 ? "As the file times them" : offset > 0 ? "Later than the file" : "Earlier than the file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            step(later: false)
            Button(SubtitleOffsets.label(offset)) { model.setSubtitleOffset(0) }
                .buttonStyle(SpeedChipStyle(isSelected: false))
                .monospacedDigit()
                .disabled(offset == 0)
            step(later: true)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subtitle Timing")
        .accessibilityValue(SubtitleOffsets.spoken(offset))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.shiftSubtitles(later: true)
            case .decrement: model.shiftSubtitles(later: false)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("panel.timing")
    }

    private func step(later: Bool) -> some View {
        Button {
            model.shiftSubtitles(later: later)
        } label: {
            Image(systemName: later ? "plus" : "minus")
                .fontWeight(.semibold)
                .frame(minHeight: 20)
        }
        .buttonStyle(SpeedChipStyle(isSelected: false))
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(later ? "Later" : "Earlier")
    }
}

#if os(tvOS)
/// A panel row with focus: on a rounded card inside the panel's glass, lifted a little, rather than
/// the plain style's square lift from edge to edge over the rows beside it.
struct PanelRowStyle: ButtonStyle {
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
