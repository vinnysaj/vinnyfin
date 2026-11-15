import SwiftUI

/// One version of an item: its name and what's in it.
struct VersionSummary: View {
    let source: MediaSource
    /// What to call it; nil leaves only what's in it.
    var name: String?

    init(source: MediaSource) {
        self.source = source
        name = source.name ?? "Default"
    }

    init(source: MediaSource, name: String?) {
        self.source = source
        self.name = name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let name {
                Text(name)
                    .font(.body)
                    .lineLimit(4)
            }
            let details = source.detailLine
            if !details.isEmpty {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
        ForEach(sources) { source in
            let isSelected = selection == source.id
            Button {
                selection = source.id
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VersionSummary(source: source)
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

/// The version a title's page plays and downloads, as a chip among its buttons that shows the one
/// picked, "4K", over its caption; it opens a menu of them all, each by its name and size over
/// what's in it. The pick holds for the page alone: everywhere else, and back on the page later,
/// playback starts with the version closest to the quality settings.
struct VersionMenu: View {
    let sources: [MediaSource]
    @Binding var selection: String?

    var body: some View {
        let names = VersionNames(sources)
        let picked = selection.flatMap { id in sources.first { $0.id == id } }.map(names.name)
        Menu {
            // Toggles rather than a picker's options: a menu reads the second text of a toggle's
            // label as a line under the first, where a picker makes each text an option of its own.
            Section("For Plays and Downloads from This Page") {
                ForEach(sources) { source in
                    Toggle(isOn: Binding(get: { selection == source.id }, set: { if $0 { selection = source.id } })) {
                        Text(names.title(of: source))
                        Text(source.detailLine(withSize: false))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
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
        .accessibilityValue(picked ?? "")
        .accessibilityIdentifier("detail.version")
    }
}

/// What a title's versions are called, each in a word or two from its picture: "4K", "1080p HDR",
/// "4K Dolby Vision". Where the picture says nothing, the server's name for it; and where two
/// would be called the same, each with the server's name after, "1080p · Director's Cut", or
/// failing that its place, "1080p · 2".
nonisolated struct VersionNames {
    private let names: [String: String]

    init(_ sources: [MediaSource]) {
        let plain = sources.map(Self.plainName)
        var names: [String: String] = [:]
        for (index, source) in sources.enumerated() {
            let name = plain[index]
            guard plain.filter({ $0 == name }).count > 1 else {
                names[source.id] = name
                continue
            }
            let own = source.name.flatMap { $0.isEmpty || $0 == name || $0 == "Default" ? nil : $0 }
            names[source.id] = "\(name) · \(own ?? String(index + 1))"
        }
        self.names = names
    }

    /// "4K"
    func name(_ source: MediaSource) -> String {
        names[source.id] ?? Self.plainName(source)
    }

    /// The version's name with its size, as the menu lists it: "4K · 40.5 MB".
    func title(of source: MediaSource) -> String {
        [name(source), source.plausibleSize?.formatted(.byteCount(style: .file))].compactMap(\.self).joined(separator: " · ")
    }

    /// From the picture's size and range, else the server's name, else "Version".
    static func plainName(_ source: MediaSource) -> String {
        let picture = [VersionTraits(source).resolutionClass.map(VersionTraits.label(forResolution:)), source.dynamicRangeName]
            .compactMap(\.self)
        if !picture.isEmpty { return picture.joined(separator: " ") }
        return source.name.flatMap { $0.isEmpty || $0 == "Default" ? nil : $0 } ?? "Version"
    }
}

nonisolated extension MediaSource {
    /// "1080p H264 SDR · AAC 5.1 +1 · 4.2 GB · MKV", with or without the size.
    func detailLine(withSize: Bool) -> String {
        var parts: [String] = []
        if let video = videoStream?.displayTitle { parts.append(video) }
        if let audio = audioStreams.first?.displayTitle {
            parts.append(audioStreams.count > 1 ? "\(audio) +\(audioStreams.count - 1)" : audio)
        }
        if !subtitleStreams.isEmpty { parts.append("\(subtitleStreams.count) subtitles") }
        if withSize, let size = plausibleSize { parts.append(size.formatted(.byteCount(style: .file))) }
        if let ext = fileExtension { parts.append(ext.uppercased()) }
        return parts.joined(separator: " · ")
    }

    /// "1080p H264 SDR · AAC 5.1 +1 · 4.2 GB · MKV"
    var detailLine: String { detailLine(withSize: true) }

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
