import SwiftUI

/// One version of an item, as a picker lists it: its picture's size with tags for what sets it
/// apart (`VersionLabel`), over its main audio, bitrate and size.
struct VersionSummary: View {
    let label: VersionLabel
    let size: Int64?

    /// `label` is the version's among the title's others (`VersionNames`), which tells it apart
    /// from them; without one, its own.
    init(source: MediaSource, label: VersionLabel? = nil) {
        self.label = label ?? VersionLabel(source)
        size = source.plausibleSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TaggedTitle(title: label.title, tags: label.tags)
            if let caption = label.caption(size: size) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The versions of a title as rows, the chosen one checked. Rows of a List inside one, a stack
/// of rows elsewhere.
struct VersionPicker: View {
    let sources: [MediaSource]
    @Binding var selection: String?

    var body: some View {
        let names = VersionNames(sources)
        ForEach(sources) { source in
            let isSelected = selection == source.id
            Button {
                selection = source.id
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VersionSummary(source: source, label: names.label(source))
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .opacity(isSelected ? 1 : 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.artwork)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("version.\(source.name ?? source.id)")
        }
    }
}

/// The version of a title downloaded to this device, which its page plays unless another is
/// picked.
struct DownloadedVersion: Equatable {
    let sourceId: String
    /// What the server made of it for the download, "Transcoded 1080p"; nil for its file as it is.
    var transcode: String?
    /// The download's size, which a transcode's own is.
    var size: Int64?
}

/// The version a title's page plays and downloads, as a chip among its buttons that shows the one
/// picked, "4K", over its caption; it opens a menu of them all, each by its name and size over
/// its tags, audio and bitrate. The one downloaded to this device comes first, under a note
/// that it's downloaded, and plays unless another is picked to stream instead. The pick holds
/// for the page alone: everywhere else, and back on the page later, playback starts with the
/// download, else the version closest to the quality settings.
struct VersionMenu: View {
    let sources: [MediaSource]
    @Binding var selection: String?
    var downloaded: DownloadedVersion?

    var body: some View {
        let names = VersionNames(sources)
        let picked = selection.flatMap { id in sources.first { $0.id == id } }.map(names.name)
        let download = downloaded.flatMap { downloaded in sources.first { $0.id == downloaded.sourceId } }
        let playsDownload = download != nil && selection == download?.id
        Menu {
            if let download, let downloaded {
                Section(playsDownload ? "Downloaded · Plays from This \(Device.name)" : "Downloaded to This \(Device.name)") {
                    option(download,
                           title: [names.name(download), (downloaded.size ?? download.plausibleSize)?.formatted(.byteCount(style: .file))]
                               .compactMap(\.self).joined(separator: " · "),
                           details: downloaded.transcode ?? names.label(download).details)
                }
                Section("Stream Instead") {
                    ForEach(sources.filter { $0.id != download.id }) { source in
                        option(source, title: names.title(of: source), details: names.label(source).details)
                    }
                }
            } else {
                ForEach(sources) { source in
                    option(source, title: names.title(of: source), details: names.label(source).details)
                }
            }
        } label: {
            HStack(spacing: 5) {
                if playsDownload {
                    Image(systemName: "arrow.down.circle.fill")
                        .accessibilityHidden(true)
                }
                Text(picked ?? "Version")
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.platformGlass)
        .controlSize(.large)
        .actionCaption("Version")
        .help("Version")
        .accessibilityLabel("Version")
        .accessibilityValue([picked, playsDownload ? "Downloaded" : nil].compactMap(\.self).joined(separator: ", "))
        .accessibilityIdentifier("detail.version")
    }

    /// Toggles rather than a picker's options: a menu reads the second text of a toggle's label as
    /// a line under the first, where a picker makes each text an option of its own.
    private func option(_ source: MediaSource, title: String, details: String?) -> some View {
        Toggle(isOn: Binding(get: { selection == source.id }, set: { if $0 { selection = source.id } })) {
            Text(title)
            if let details {
                Text(details)
            }
        }
    }
}

/// A title with its tags after it, "4K" then "Dolby Vision", "Remux", wrapping onto more lines as
/// the room runs out.
struct TaggedTitle: View {
    let title: String
    let tags: [String]

    var body: some View {
        TagFlow {
            Text(title)
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                TagChip(text: tag)
            }
        }
    }
}

/// One of a version's or a track's tags, small in a capsule, in the colors of the text around it,
/// so on Apple TV it darkens with a row that has focus.
struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.secondary)
            .background(.quaternary, in: .capsule)
    }
}

/// Views in lines as wide as the room, each line's views centered on one another. One wider than
/// the room alone, as a long title, wraps to it.
struct TagFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(subviews, width: proposal.width ?? .infinity)
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        // Broken as they were measured: the bounds are the measured width rounded to the pixel,
        // which can be a hair short of it, and would move the last tag to a line of its own.
        for line in lines(subviews, width: proposal.width ?? .infinity) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2),
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    /// The first line's first view's baseline, so a checkmark beside a title lines up with it.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, let line = lines(subviews, width: proposal.width ?? .infinity).first,
              let first = line.items.first else { return nil }
        let baseline = subviews[first.index].dimensions(in: ProposedViewSize(first.size))[.firstTextBaseline]
        return bounds.minY + (line.height - first.size.height) / 2 + baseline
    }

    private func lines(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width, width.isFinite {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if !line.items.isEmpty, line.width + spacing + size.width > width {
                lines.append(line)
                line = Line()
            }
            line.width += (line.items.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.items.append((index, size))
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}

/// What a title's versions are called, each told apart from the others. Each is its picture's
/// size with tags for what sets it apart (`VersionLabel`), over its bitrate, which every row
/// shows; where two would be alike in tags and bitrate, its release group is one more tag, or
/// failing that its place, "Version 2". Its name in a word or two is the size with as many of its
/// tags as tell it from the others of that size, and failing those its bitrate: "4K", "4K · Dolby
/// Vision", "1080p · Director's Cut", "1080p · 8.3 Mbps".
nonisolated struct VersionNames {
    private let labels: [String: VersionLabel]
    private let names: [String: String]

    init(_ sources: [MediaSource]) {
        let plain = sources.map(VersionLabel.init)
        var told = plain
        for (index, label) in plain.enumerated() {
            let alike = plain.filter { $0.title == label.title && $0.tags == label.tags }
            guard alike.count > 1 else { continue }
            let bitrates = alike.map(\.bitrateText)
            if !bitrates.contains(nil), Set(bitrates).count == alike.count { continue }
            let groups = alike.map(\.group)
            if let group = label.group, !groups.contains(nil), Set(groups).count == alike.count {
                told[index].tags.append(group)
            } else {
                told[index].tags.append("Version \(index + 1)")
            }
        }
        var names: [String: String] = [:]
        for (index, label) in told.enumerated() {
            let others = told.indices.filter { $0 != index && told[$0].title == label.title }.map { told[$0] }
            guard !others.isEmpty else {
                names[sources[index].id] = label.title
                continue
            }
            // Its tags the others of its size don't all have, then its bitrate, as few of them as tell it apart.
            let shared = others.reduce(Set(label.tags)) { $0.intersection($1.tags) }
            let tellingOf = { (other: VersionLabel) in other.tags.filter { !shared.contains($0) } + [other.bitrateText].compactMap(\.self) }
            let telling = tellingOf(label)
            let count = (0...telling.count).first { count in
                others.allSatisfy { Array(tellingOf($0).prefix(count)) != Array(telling.prefix(count)) }
            } ?? telling.count
            names[sources[index].id] = ([label.title] + telling.prefix(count)).joined(separator: " · ")
        }
        labels = Dictionary(zip(sources.map(\.id), told)) { first, _ in first }
        self.names = names
    }

    /// The version's label, told apart from the others'.
    func label(_ source: MediaSource) -> VersionLabel {
        labels[source.id] ?? VersionLabel(source)
    }

    /// "4K", "4K · Dolby Vision"
    func name(_ source: MediaSource) -> String {
        names[source.id] ?? VersionLabel(source).title
    }

    /// The version's name with its size, as the menu lists it: "4K · 40.5 MB".
    func title(of source: MediaSource) -> String {
        [name(source), source.plausibleSize?.formatted(.byteCount(style: .file))].compactMap(\.self).joined(separator: " · ")
    }
}

nonisolated extension VersionLabel {
    /// Its tags, audio and bitrate on one line, as a menu has room for: "Dolby Vision · Remux ·
    /// Dolby Atmos · 7.1 · 52 Mbps". Nil with none of them.
    var details: String? {
        let parts = tags + [audio, bitrateText].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Its audio, bitrate and `size`: "Dolby Atmos · 7.1 · 52 Mbps · 58.2 GB". Nil with none.
    func caption(size: Int64?) -> String? {
        let parts = [audio, bitrateText, size.map { $0.formatted(.byteCount(style: .file)) }].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

nonisolated extension MediaSource {
    /// The picture's high dynamic range, by the video stream's range or the version's name:
    /// "Dolby Vision", "HDR10+", "HDR" or "HLG"; nil for standard range.
    var dynamicRangeName: String? {
        let range = videoStream?.videoRangeType?.uppercased() ?? ""
        let name = (name ?? "").uppercased()
        if range.hasPrefix("DOVI") || name.contains("DOLBY VISION") || name.contains(" DV") { return "Dolby Vision" }
        if range.contains("HDR10PLUS") || name.contains("HDR10+") { return "HDR10+" }
        if range.contains("HDR") || name.contains("HDR") { return "HDR" }
        if range.contains("HLG") { return "HLG" }
        return nil
    }

    /// Words of the name and video description, for matching versions across episodes.
    var matchTokens: Set<String> {
        let text = [name, videoStream?.displayTitle, container].compactMap(\.self).joined(separator: " ").lowercased()
        return Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// The version in `candidates` most like this one (by shared words), for picking the same
    /// release across episodes. Nil when nothing shares a word.
    func closestMatch(in candidates: [MediaSource]) -> MediaSource? {
        let tokens = matchTokens
        let scored = candidates.map { candidate -> (MediaSource, Double) in
            let other = candidate.matchTokens
            let union = tokens.union(other).count
            return (candidate, union == 0 ? 0 : Double(tokens.intersection(other).count) / Double(union))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }
}

#if !os(tvOS)
/// What a download's status line says. While bytes arrive, that comes first, with what the
/// download waits for once its transfers under way finish, if it waits.
enum JobStatus: Equatable {
    case arriving(bytesPerSecond: Int64, next: String?)
    /// What a transcoded download's server is doing (`TranscodedDownloads.note`), with how fast
    /// its pieces arrive while they do.
    case transcoding(String, bytesPerSecond: Int64?, next: String?)
    case pausing(bytesPerSecond: Int64)
    case heldForPlayback
    case waiting(DownloadWait)
    case offline
    /// Waiting out a retry, or trying again; `othersGoFirst` while it yields.
    case retrying(at: Date?, error: String?, othersGoFirst: Bool)
    case queued
    /// In hand, it waits for another file's transfers under way to finish first.
    case startingAfter(String)
    case waitingForServer
    case paused
    case failed(String)
    case downloaded

    /// `bytesPerSecond` is how fast the job's bytes arrive, smoothed, which counts only while
    /// `isTransferring` (it has transfers under way); `transcodeNote` what its server is doing,
    /// for a transcode; `fileInHand` the job the session works on, and `waitsOn` the files whose
    /// transfers under way it waits for.
    static func of(_ job: DownloadJob, bytesPerSecond: Double?, isTransferring: Bool, transcodeNote: String? = nil,
                   waits: [UUID: DownloadWait], isPausedForPlayback: Bool, isNetworkReachable: Bool, fileInHand: UUID?,
                   waitsOn: [DownloadJob], now: Date) -> JobStatus {
        let speed = isTransferring && (bytesPerSecond ?? 0) >= 1024 ? Int64(bytesPerSecond ?? 0) : nil
        switch job.status {
        case .active:
            if let speed {
                let next = waits[job.id]?.next ?? (fileInHand != job.id && !job.yields ? "then queued" : nil)
                if let transcodeNote { return .transcoding(transcodeNote, bytesPerSecond: speed, next: next) }
                return .arriving(bytesPerSecond: speed, next: next)
            }
            if isPausedForPlayback { return .heldForPlayback }
            if let wait = waits[job.id] { return .waiting(wait) }
            if !isNetworkReachable { return .offline }
            let retryAt = job.retryAt.flatMap { $0 > now ? $0 : nil }
            if job.isFailing || retryAt != nil { return .retrying(at: retryAt, error: job.lastError, othersGoFirst: job.yields) }
            if let transcodeNote { return .transcoding(transcodeNote, bytesPerSecond: nil, next: nil) }
            if fileInHand != job.id { return .queued }
            if let overtaken = waitsOn.first { return .startingAfter(overtaken.shortName) }
            return .waitingForServer
        case .paused:
            return speed.map { .pausing(bytesPerSecond: $0) } ?? .paused
        case .failed:
            return .failed(job.lastError ?? "Failed")
        case .completed:
            return .downloaded
        }
    }
}

/// An icon just before its words, as in a line of text. A list row's own labels set their icons in
/// a column as wide as a row's leading icon, which leaves a gap in a caption under a title.
struct InlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// How a job is doing, in words, with the controls that apply to it. Looked at again as its
/// retry comes due, and a second later, as the countdown to it ends then: an update can come a
/// moment early, and a schedule's first update gives its first date, not the time.
struct JobStatusLine: View {
    @Environment(DownloadManager.self) private var downloads
    let job: DownloadJob

    var body: some View {
        TimelineView(.explicit(job.retryAt.map { [$0, $0.addingTimeInterval(1)] } ?? [])) { _ in
            line(JobStatus.of(job, bytesPerSecond: downloads.bytesPerSecond[job.id],
                              isTransferring: downloads.transferringJobIds.contains(job.id),
                              transcodeNote: downloads.transcodes.note(for: job), waits: downloads.waits,
                              isPausedForPlayback: downloads.isPausedForPlayback, isNetworkReachable: downloads.isNetworkReachable,
                              fileInHand: downloads.downloadingJobId,
                              waitsOn: downloads.jobs.filter { downloads.fileInHandWaitsOn.contains($0.id) }, now: .now))
        }
        .labelStyle(InlineLabelStyle())
    }

    @ViewBuilder private func line(_ status: JobStatus) -> some View {
        switch status {
        case .arriving(let speed, let next):
            Text([Self.speed(speed), next].compactMap(\.self).joined(separator: " · "))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .transcoding(let note, let speed, let next):
            Label([note, speed.map(Self.speed), next].compactMap(\.self).joined(separator: " · "), systemImage: "server.rack")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier("job.transcodeNote")
        case .pausing(let speed):
            Label("Pausing once the parts under way finish · \(Self.speed(speed))", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .heldForPlayback:
            Label("Paused while you watch", systemImage: "play.rectangle")
                .foregroundStyle(.secondary)
        case .waiting(let wait):
            Label(wait.status, systemImage: wait.systemImage)
                .foregroundStyle(.orange)
        case .offline:
            Label("Waiting for a network connection", systemImage: "wifi.slash")
                .foregroundStyle(.orange)
        case .retrying(let retryAt, let error, let othersGoFirst):
            VStack(alignment: .leading, spacing: 2) {
                if let retryAt {
                    Text("Retrying \(Text(retryAt, style: .relative))")
                } else {
                    Text("Trying again")
                }
                if let error { Text(error).foregroundStyle(.secondary) }
                if othersGoFirst { Text("The downloads after it go first meanwhile.").foregroundStyle(.secondary) }
            }
            .foregroundStyle(.orange)
        case .queued:
            Label("Queued", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .startingAfter(let title):
            Label("Starting once \(title) finishes the parts under way", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .waitingForServer:
            Text("Waiting for the server…").foregroundStyle(.secondary)
        case .paused:
            Label("Paused", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .failed(let error):
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .downloaded:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    /// On one line however the status wraps: split, the number and its unit read as two things.
    private static func speed(_ bytesPerSecond: Int64) -> String {
        "\(bytesPerSecond.formatted(.byteCount(style: .file)))/s".replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}

/// How far a download has got, in bytes, and while they arrive steadily, how long the rest will
/// take. The ring beside it in Downloads draws the fraction.
struct JobProgress: View {
    @Environment(DownloadManager.self) private var downloads
    let job: DownloadJob
    /// Since when its bytes have been arriving, without a pause.
    @State private var arrivingSince: Date?

    /// How long the bytes have to keep arriving before the time left is told from their speed:
    /// the first moments' speed says little about the rest.
    static let steadyAfter: TimeInterval = 5

    var body: some View {
        let received = downloads.receivedBytes[job.id] ?? job.bytesOnDisk
        let total = job.displayTotalBytes
        let speed = downloads.bytesPerSecond[job.id] ?? 0
        let isArriving = downloads.transferringJobIds.contains(job.id) && speed >= 1024
        // A transcode's size is an estimate until it's all here, as its time left would be.
        let isEstimate = job.transcode != nil && job.totalBytes == nil
        let timeLeft = isEstimate || !isSteady(at: .now) ? nil
            : total.flatMap { Self.timeLeft(remaining: $0 - received, bytesPerSecond: speed) }
        Text([Self.amount(received: received, total: total, isEstimate: isEstimate), timeLeft].compactMap(\.self)
            .joined(separator: " · "))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .onChange(of: isArriving, initial: true) { _, arriving in
                arrivingSince = arriving ? .now : nil
            }
    }

    private func isSteady(at now: Date) -> Bool {
        arrivingSince.map { now.timeIntervalSince($0) >= Self.steadyAfter } ?? false
    }

    /// "22.8 MB of 1.66 GB", and before the first byte, the size alone, "2.41 GB": the status
    /// line under it says why none has come yet. An estimate is "about" it.
    static func amount(received: Int64, total: Int64?, isEstimate: Bool) -> String {
        guard let total, total > 0 else { return received.formatted(.byteCount(style: .file)) }
        let size = total.formatted(.byteCount(style: .file))
        guard received > 0 else { return isEstimate ? "About \(size)" : size }
        return "\(received.formatted(.byteCount(style: .file))) of \(isEstimate ? "about " : "")\(size)"
    }

    /// "12 min left", "1 hr, 5 min left", "Less than a minute left", at `bytesPerSecond`; nil
    /// without a speed to tell it from.
    static func timeLeft(remaining: Int64, bytesPerSecond: Double) -> String? {
        guard bytesPerSecond >= 1024, remaining > 0 else { return nil }
        let seconds = Double(remaining) / bytesPerSecond
        guard seconds < 100 * 3600 else { return nil }
        guard seconds >= 60 else { return "Less than a minute left" }
        let minutes = Duration.seconds(Int((seconds / 60).rounded(.up)) * 60)
        return "\(minutes.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left"
    }
}
#endif
