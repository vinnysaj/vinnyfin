import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What plays and why ("Converted to 720p, the connection slowed"), the speed, and the ways to
/// play the title: Auto, or the download in its place when there is one, each version as it is,
/// by its size and tags (`VersionNames`), and each size the server can convert the version
/// playing to. The way picked is checked. While the download plays, the versions and sizes stream
/// in its place, once the server has given them; a file of this device's has only what plays.
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
        var tags: [String] = []
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
        let names = VersionNames(sources)
        let versions = sources.map { source in
            let label = names.label(source)
            return Row(id: "quality.version.\(source.id)", title: label.title, tags: label.tags,
                       detail: Self.detail(of: label), option: .version(source))
        }
        let sizes = options.compactMap { option -> Row? in
            guard case .converted(let quality) = option else { return nil }
            return Row(id: "quality.converted.\(quality.rawValue)", title: quality.label,
                       detail: "Up to \(QualityLearning.label(forBitrate: quality.transcodeBitrate))", option: option)
        }
        let hasDownload = options.contains(.download)
        let first = hasDownload ? downloadRow : Row(id: "quality.auto", title: "Auto", detail: autoDetail, option: .auto)
        let versionsTitle = hasDownload ? "Stream from the Server" : sources.count > 1 ? "Versions" : "As It Is"
        var sections = [Section(id: "first", title: nil, rows: [first]), Section(id: "versions", title: versionsTitle, rows: versions)]
        if !sizes.isEmpty { sections.append(Section(id: "converted", title: "Converted by the Server", rows: sizes)) }
        return sections
    }

    private var chosen: QualityOption { model.qualityChoice }

    /// The download, tagged with its picture's size and what sets it apart.
    private var downloadRow: Row {
        let label = model.downloadedVersion.map(VersionLabel.init)
        let tags = label.map { ($0.title == "Version" ? [] : [$0.title]) + $0.tags } ?? []
        let detail = ["On this \(Device.name)", label?.bitrateText].compactMap(\.self).joined(separator: " · ")
        return Row(id: "quality.download", title: "Downloaded", tags: tags, detail: detail, option: .download)
    }

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
            speed
                .padding(.bottom, sections.isEmpty ? 16 : 4)
            if !sections.isEmpty { list }
        }
        .frame(width: Self.width)
        .frame(maxHeight: min(Self.maxHeight, room))
        // As tall as its rows; a popover, short of room, scrolls them instead.
        .fixedSize(horizontal: false, vertical: !PlayerPanel.quality.opensInPopover)
        .panelGlass(in: .rect(cornerRadius: 24), for: .quality)
        #if os(tvOS)
        .focusSection()
        .onAppear {
            focusedRow = sections.flatMap(\.rows).first { $0.option == chosen }?.id ?? SpeedChips.focusID(model.rate)
        }
        #endif
        // A download's versions to stream instead, when the server didn't answer as it started.
        .task { await model.lookUpServerVersions() }
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

    private var speed: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Speed")
            #if os(tvOS)
            SpeedChips(model: model, onChoose: onClose, focus: $focusedRow)
                .padding(.horizontal, Self.rowInset)
            #else
            SpeedChips(model: model, onChoose: onClose)
            #endif
        }
        .padding(.horizontal)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private var list: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(sections) { section in
                        if let title = section.title {
                            sectionTitle(title)
                                .padding(.horizontal)
                                #if os(tvOS)
                                .padding(.horizontal, Self.rowInset)
                                #endif
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
                VStack(alignment: .leading, spacing: 3) {
                    TaggedTitle(title: row.title, tags: row.tags)
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

    /// A version's main audio and bitrate, which tells apart even files alike in all else:
    /// "Dolby Atmos · 7.1 · 25 Mbps".
    private static func detail(of label: VersionLabel) -> String? {
        let parts = [label.audio, label.bitrateText].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Every speed fits across it.
    private static var width: CGFloat {
        #if os(tvOS)
        780
        #else
        360
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
