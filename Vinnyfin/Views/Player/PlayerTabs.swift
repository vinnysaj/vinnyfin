#if os(tvOS)
import AetherEngine
import SwiftUI

/// A swipe down from the Apple TV player's buttons: Episodes, for an episode, and Info. The tab
/// focus reaches opens below them, the timeline and buttons moving up to make room, and stays
/// open until Back or a swipe up. Episodes is the show's, a season at a time; Info is what the
/// title is about, when it ends, and what plays.
struct PlayerTabs: View {
    let model: PlayerModel
    @Binding var panel: PlayerPanel?
    let focus: FocusState<PlayerFocus?>.Binding
    let onInteraction: () -> Void

    private var tabs: [PlayerPanel] {
        let episodes = model.item.map { $0.isEpisode && $0.seriesId != nil } ?? false
        return (episodes ? [.episodes] : []) + [.info]
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 16) {
                ForEach(tabs) { tab in
                    Button {
                        panel = tab
                        onInteraction()
                    } label: {
                        Text(tab.title)
                    }
                    .buttonStyle(TabStyle(isOpen: panel == tab))
                    .focused(focus, equals: .panel(tab))
                    .accessibilityAddTraits(panel == tab ? .isSelected : [])
                    .accessibilityIdentifier("player.tab.\(tab.title)")
                }
            }
            // Above, the buttons are out of reach while a tab is open: up closes it.
            .onMoveCommand { direction in
                if direction == .up, panel?.isTab == true { close() }
            }
            if let open = panel, open.isTab {
                content(open)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Across the screen, so a swipe down from any of the buttons finds the tabs.
        .frame(maxWidth: .infinity)
        .focusSection()
        .animation(.snappy, value: panel)
        .onChange(of: focus.wrappedValue) { _, focused in
            if case .panel(let tab) = focused, tab.isTab, tabs.contains(tab), panel != tab { panel = tab }
        }
    }

    @ViewBuilder private func content(_ tab: PlayerPanel) -> some View {
        switch tab {
        case .episodes:
            if let item = model.item {
                EpisodeStrip(model: model, playing: item, onInteraction: onInteraction, onPlay: close)
                    .padding(.bottom, 12)
            }
        default:
            PlayerInfo(model: model)
        }
    }

    /// Closes the tab, focus going back up to the buttons.
    private func close() {
        panel = nil
        focus.wrappedValue = .playPause
    }
}

/// A tab's name, on white glass with focus and on clear glass while it's open, as the system
/// player's are.
private struct TabStyle: ButtonStyle {
    let isOpen: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .foregroundStyle(isFocused ? AnyShapeStyle(.black) : isOpen ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.6)))
            .glassEffect(isFocused ? .focused : isOpen ? .regular : .identity, in: .capsule)
            .scaleEffect(isFocused && !reduceMotion ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// What the title is about, when it ends at its speed, and what plays: the picture, the sound,
/// and the quality and why.
private struct PlayerInfo: View {
    let model: PlayerModel

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline).lineLimit(2)
                if !facts.isEmpty {
                    Text(facts).font(.caption).foregroundStyle(.secondary)
                }
                if let overview = model.item?.overview, !overview.isEmpty {
                    Text(overview).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 10) {
                if model.duration > 0 {
                    GridRow {
                        name("Ends")
                        TimelineView(.everyMinute) { _ in
                            let end = TimeLabel.end(after: model.duration - model.clock.time, rate: model.rate, from: .now)
                            value(end.formatted(.dateTime.hour().minute()))
                        }
                    }
                }
                if let video { fact("Picture", video) }
                if let audio { fact("Sound", audio) }
                if let quality = model.qualityStatus?.summary { fact("Quality", quality) }
            }
            .frame(width: 760, alignment: .leading)
        }
        .padding(36)
        .platformGlass(in: .rect(cornerRadius: 36))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.info")
    }

    private func fact(_ title: String, _ text: String) -> some View {
        GridRow {
            name(title)
            value(text)
        }
    }

    private func name(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.callout).lineLimit(2)
    }

    /// "S1, E2 · The Night Ferry", or the title.
    private var title: String {
        guard let item = model.item, item.isEpisode else { return model.title }
        return [item.episodeCode, item.name].compactMap(\.self).joined(separator: " · ")
    }

    /// "2024 · TV-14 · 45 min"
    private var facts: String {
        guard let item = model.item else { return "" }
        let year = item.premiereDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
        return [item.isEpisode ? item.seriesName : year, item.officialRating, item.runtimeText]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }

    /// "4K · Dolby Vision · HEVC"
    private var video: String? {
        let format: String? = switch model.videoFormat {
        case .dolbyVision: "Dolby Vision"
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10+"
        case .hlg: "HLG"
        case .sdr: "SDR"
        }
        let codec = model.current?.mediaSource?.videoStream?.codec?.uppercased()
        let parts = [model.qualityLabel, format, codec].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "English · Dolby Digital Plus 5.1 Atmos", and below it what the sound tools on are doing to
    /// it: "Without Atmos, as 5.1 surround, while Boost Dialogue is on".
    private var audio: String? {
        guard let option = model.audioOptions.first(where: { $0.id == model.selectedAudio }) else { return nil }
        let track = [option.title, option.detail].compactMap(\.self).joined(separator: " · ")
        return [track, model.soundToolsEffect].compactMap(\.self).joined(separator: "\n")
    }
}
#endif
