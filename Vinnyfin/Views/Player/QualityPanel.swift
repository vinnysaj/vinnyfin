import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What plays and why ("Converted to 720p, the connection slowed"), and the ways to play the
/// title: Auto, each version as it is, and each size the server can convert the version playing
/// to. The way picked is checked. A download or a file has only what plays.
struct QualityPanel: View {
    let model: PlayerModel
    /// The height there's room for. The panel is as tall as its rows, up to that or its own limit.
    let room: CGFloat
    let onClose: () -> Void
    @Environment(AppSettings.self) private var settings
    #if os(tvOS)
    /// The remote starts on the way picked, inside the panel.
    @FocusState private var focusedRow: String?
    #endif

    private struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let option: QualityOption
    }

    private struct Section: Identifiable {
        let id: String
        let title: String?
        let rows: [Row]
    }

    private var sections: [Section] {
        let options = model.qualityOptions
        guard !options.isEmpty else { return [] }
        let sources = options.compactMap { option -> MediaSource? in
            if case .version(let source) = option { source } else { nil }
        }
        let versions = sources.map { source in
            Row(id: "quality.version.\(source.id)", title: Self.title(of: source, among: sources),
                detail: Self.detail(of: source), option: .version(source))
        }
        let sizes = options.compactMap { option -> Row? in
            guard case .converted(let quality) = option else { return nil }
            return Row(id: "quality.converted.\(quality.rawValue)", title: quality.label,
                       detail: "Up to \(QualityLearning.label(forBitrate: quality.transcodeBitrate))", option: option)
        }
        var sections = [Section(id: "auto", title: nil, rows: [Row(id: "quality.auto", title: "Auto", detail: autoDetail, option: .auto)]),
                        Section(id: "versions", title: sources.count > 1 ? "Versions" : "As It Is", rows: versions)]
        if !sizes.isEmpty { sections.append(Section(id: "converted", title: "Converted by the Server", rows: sizes)) }
        return sections
    }

    private var chosen: QualityOption { model.qualityPick ?? .auto }

    /// What Auto keeps to: the streaming quality, and with Adaptive Quality, the connection.
    private var autoDetail: String {
        let limit = settings.streamingQuality == .original ? "Best available" : "Up to \(settings.streamingQuality.label)"
        return settings.adaptiveQuality ? "\(limit), adjusting to the connection" : limit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(PlayerPanel.quality.title, systemImage: PlayerPanel.quality.symbol).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                #if !os(tvOS)
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.platformGlass)
                    .buttonBorderShape(.circle)
                    #if os(macOS)
                    .help("Close")
                    #endif
                #endif
            }
            .padding([.horizontal, .top])
            status
                .padding(.horizontal)
                .padding(.bottom, sections.isEmpty ? 16 : 4)
            if !sections.isEmpty { list }
        }
        .frame(width: Self.width)
        .frame(maxHeight: min(Self.maxHeight, room))
        .fixedSize(horizontal: false, vertical: true)
        .platformGlass(in: .rect(cornerRadius: 24))
        #if os(tvOS)
        .focusSection()
        .onAppear { focusedRow = sections.flatMap(\.rows).first { $0.option == chosen }?.id }
        #endif
        .accessibilityElement(children: .contain)
        // VoiceOver's two-finger scrub, and Escape, close it.
        .accessibilityAction(.escape, onClose)
        .accessibilityIdentifier("player.qualityPanel")
    }

    /// What plays and why.
    private var status: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.isReconnecting ? PlayerModel.reconnecting : model.qualityStatus?.summary ?? "Starting…")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !model.isReconnecting, let detail = model.qualityStatus?.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("quality.status")
    }

    private var list: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(sections) { section in
                        if let title = section.title {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                                #if os(tvOS)
                                .padding(.horizontal, Self.rowInset)
                                #endif
                                .padding(.top, 8)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(section.rows) { row in
                            rowButton(row)
                        }
                    }
                }
                .padding(.bottom, Self.rowInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            .task {
                if let picked = sections.flatMap(\.rows).first(where: { $0.option == chosen }) {
                    scroller.scrollTo(picked.id, anchor: .center)
                }
            }
        }
    }

    private func rowButton(_ row: Row) -> some View {
        let isSelected = row.option == chosen
        return Button {
            model.chooseQuality(row.option)
            #if os(iOS)
            UISelectionFeedbackGenerator().selectionChanged()
            #endif
            onClose()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .opacity(isSelected ? 1 : 0)
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
        #if os(tvOS)
        .buttonStyle(PanelRowStyle())
        .padding(.horizontal, Self.rowInset)
        .focused($focusedRow, equals: row.id)
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(row.id)
        .id(row.id)
    }

    /// "4K", or with another version the same size, "4K · Director's Cut".
    private static func title(of source: MediaSource, among sources: [MediaSource]) -> String {
        let label = PlaybackPlan.direct(source).label
        guard let label else { return source.name ?? "Version" }
        let sameSize = sources.filter { PlaybackPlan.direct($0).label == label }.count > 1
        guard sameSize, let name = source.name, !name.isEmpty, name != label else { return label }
        return "\(label) · \(name)"
    }

    /// "HEVC HDR10 · 25 Mbps"
    private static func detail(of source: MediaSource) -> String? {
        let parts = [source.videoStream?.displayTitle, VersionTraits(source).bitrate.map(QualityLearning.label(forBitrate:))]
        let line = parts.compactMap(\.self).joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    private static var width: CGFloat {
        #if os(tvOS)
        620
        #else
        340
        #endif
    }

    private static var maxHeight: CGFloat {
        #if os(tvOS)
        760
        #else
        480
        #endif
    }

    private static var rowSpacing: CGFloat {
        #if os(tvOS)
        12
        #else
        2
        #endif
    }

    private static var rowInset: CGFloat {
        #if os(tvOS)
        20
        #else
        6
        #endif
    }
}
