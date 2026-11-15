import AetherEngine
import Foundation

/// Something to play, as handed to the player (and, on the Mac, to the player window).
nonisolated struct PlaybackRequest: Codable, Hashable, Identifiable, Sendable {
    enum Source: Codable, Hashable, Sendable {
        /// A server item, from a downloaded copy when there is one. A nil version lets the
        /// player choose one for the streaming quality.
        case item(id: String, mediaSourceId: String?)
        /// A file on this device, as a bookmark so it stays reachable after a relaunch.
        case file(bookmark: Data, name: String)
    }

    /// Where, and with which of the server's streams, another device asked this one to start, in
    /// place of the resume position and the language settings.
    struct StartingPoint: Codable, Hashable, Sendable {
        var position: Double
        var audioStreamIndex: Int?
        /// -1 turns the subtitles off; nil leaves them to the subtitle setting.
        var subtitleStreamIndex: Int?
        /// The title's resume position wins when it's later, as for a playback another of the
        /// person's devices handed off: it may have been watched further somewhere since.
        var yieldsToLaterResume = false
    }

    var id = UUID()
    let source: Source
    /// Shown while the player gets ready.
    var title: String
    var startFromBeginning = false
    var startingPoint: StartingPoint?
    /// The item as `JellyfinClient.item(id:userId:)` gave it moments ago, versions and all, which
    /// saves the player asking for it again. Not kept when the request is saved: by the time a
    /// saved request plays again, the item may have changed.
    var loadedItem: JellyfinItem?
    /// The title as the screen it was picked on had it, whose picture the player shows while it
    /// asks the server for the rest. Not kept when the request is saved.
    var shownItem: JellyfinItem?
    /// The episodes the playback goes through, in an order of their own, as a show shuffled.
    /// Kept when the request is saved, as for the Mac's and Vision Pro's player window, whose
    /// Next follows it there too.
    var order: PlayOrder?

    private enum CodingKeys: String, CodingKey {
        case id, source, title, startFromBeginning, startingPoint, order
    }

    /// `continuingFrom` is where another of the person's devices had got to, for a playback it
    /// handed off. `loaded` is the item as the title's page has it, which saves asking for it again
    /// when it's the page's own (`hasDetails`).
    static func item(_ item: JellyfinItem, mediaSourceId: String? = nil, fromBeginning: Bool = false,
                     continuingFrom position: Double? = nil, loaded: JellyfinItem? = nil) -> PlaybackRequest {
        var request = PlaybackRequest(source: .item(id: item.id, mediaSourceId: mediaSourceId), title: item.name,
                                      startFromBeginning: fromBeginning,
                                      startingPoint: position.map { StartingPoint(position: $0, yieldsToLaterResume: true) })
        request.shownItem = item
        if let loaded, loaded.id == item.id, hasDetails(loaded) { request.loadedItem = loaded }
        return request
    }

    /// Whether `item` is as `JellyfinClient.item(id:userId:)` gives it, versions, chapters and
    /// scrub previews and all, which a playback starts from. Lists leave out the chapters, and
    /// most leave out the versions.
    static func hasDetails(_ item: JellyfinItem) -> Bool {
        item.mediaSources != nil && item.chapters != nil
    }

    /// How far before a saved position a resume starts, so the scene picks up rather than
    /// starting mid-sentence.
    static let resumeLeadIn: Double = 5

    /// The same title again from `position`, as a playback that ended plays again when it's moved
    /// back: from the start at 0, else from exactly there, whatever the title's resume position.
    func replaying(from position: Double, title: String) -> PlaybackRequest {
        PlaybackRequest(source: source, title: title, startFromBeginning: position <= 0,
                        startingPoint: position > 0 ? StartingPoint(position: position) : nil, order: order)
    }

    /// This request tried again after a failure: from `position`, where the playback had got to,
    /// when it got anywhere, with the streams another device asked for kept.
    func retrying(from position: Double?) -> PlaybackRequest {
        guard let position, position > 0 else { return self }
        var again = self
        again.startFromBeginning = false
        again.startingPoint = StartingPoint(position: position, audioStreamIndex: startingPoint?.audioStreamIndex,
                                            subtitleStreamIndex: startingPoint?.subtitleStreamIndex)
        return again
    }

    /// Whether `other` plays the same title: the same server item, in whichever version, or the
    /// same file.
    func playsSameTitle(as other: PlaybackRequest) -> Bool {
        switch (source, other.source) {
        case (.item(let id, _), .item(let otherId, _)): id == otherId
        case (.file(let bookmark, _), .file(let otherBookmark, _)): bookmark == otherBookmark
        default: false
        }
    }

    /// Where to start, given where the title resumes: `resumeLeadIn` before it, unless another
    /// device, a link or the group watching together asked for somewhere else, which starts
    /// exactly there.
    func start(resuming resume: Double?) -> Double? {
        guard let startingPoint else { return resume.map { max(0, $0 - Self.resumeLeadIn) } }
        guard startingPoint.yieldsToLaterResume else { return startingPoint.position }
        return max(startingPoint.position, resume ?? 0)
    }

    /// Whether a playback that starts where `start(resuming:)` says picks up the title's saved
    /// position, which the player says it did and offers to start over from.
    func resumesSavedPosition(_ resume: Double?) -> Bool {
        startingPoint == nil && (start(resuming: resume) ?? 0) > 0
    }

    /// Bookmarks a file the user picked. The caller holds access to it while this runs.
    static func file(_ url: URL) throws -> PlaybackRequest {
        #if os(macOS)
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        return PlaybackRequest(source: .file(bookmark: bookmark, name: url.lastPathComponent), title: url.deletingPathExtension().lastPathComponent)
    }
}

/// Everything the player needs to start a playback, worked out from a request.
struct ResolvedPlayback {
    /// What the server is told about the playback. Nil for files that aren't the server's.
    struct Reporting {
        let itemId: String
        let mediaSourceId: String?
        let playSessionId: String
        let playMethod: String
    }

    /// What the server was asked to make of the version. Its audio and subtitles are in the
    /// stream, chosen by the server's stream index.
    struct Transcode: Equatable {
        let quality: VideoQuality
        let audioIndex: Int?
        let subtitleIndex: Int?
    }

    var url: URL
    var title: String
    var subtitle: String?
    var item: JellyfinItem?
    var mediaSource: MediaSource?
    var startPosition: Double?
    var duration: Double?
    var externalSubtitles: [ExternalSubtitleTrack] = []
    /// The key the position is kept under in `WatchHistory`.
    var historyKey: String
    var reporting: Reporting?
    /// Nil when the version plays as it is.
    var transcode: Transcode?
    /// A downloaded copy of a server item.
    var isDownload = false
    /// The skippable stretches saved with a download.
    var segments: [MediaSegment] = []
    var trickplay: TrickplayTiles?
    var chapters: [ChapterMark] = []
    /// A security-scoped URL to stop accessing when playback ends.
    var scopedURL: URL?
    /// It starts at the title's saved position (`PlaybackRequest.resumesSavedPosition`).
    var resumesSavedPosition = false
    /// The audio and subtitles the viewer picked for the show, this session or last time, which
    /// the version's tracks are chosen by where nothing comes before them (`TrackPicks`).
    var trackPicks: TrackPicks?

    var isTranscode: Bool { transcode != nil }

    /// A server stream, which another version or a transcode of the title can stand in for.
    var isStream: Bool { reporting != nil && !isDownload }

    /// How the version is getting to the screen; nil for files that aren't the server's streams.
    var plan: PlaybackPlan? {
        guard isStream, let mediaSource else { return nil }
        return transcode.map { .transcode(mediaSource, $0.quality) } ?? .direct(mediaSource)
    }
}

nonisolated enum PlaybackError: LocalizedError {
    case notSignedIn
    case noVersions
    case transcodeRefused(String?)
    case fileUnavailable(String)
    /// The server has nothing to play of it yet (`JellyfinItem.isNotYetAvailable`).
    case notYetAvailable(String)
    /// An episode the server lists without a file: one that hasn't aired, or isn't in the library.
    case episodeNotYetAvailable(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to a server to play this."
        case .noVersions: "The server lists no versions of this title."
        case .transcodeRefused(let code): "The server couldn't prepare a stream\(code.map { " (\($0))" } ?? "")."
        case .fileUnavailable(let name): "\(name) can't be opened. It may have been moved or deleted."
        case .notYetAvailable(let name): "\(name) isn't out yet. It plays here as soon as any copy of it is out, even one filmed in a theater."
        case .episodeNotYetAvailable(let name): "\(name) isn't on the server yet. It plays here once the server has the episode."
        }
    }

    /// Nothing to play of `item` yet, said the way that fits it.
    static func notYetAvailable(_ item: JellyfinItem) -> PlaybackError {
        guard item.isEpisode else { return .notYetAvailable(item.titleWithYear) }
        return .episodeNotYetAvailable([item.episodeCode, item.name].compactMap(\.self).joined(separator: " · "))
    }
}

/// What the player says when a playback fails, in a plain sentence: what failed and what might
/// help. The engine's own wording and the system's, which can be a log line or a sentence about
/// HTTP, go to the log instead.
nonisolated enum PlaybackFailureMessage {
    /// For an error a load threw. `engine` is the engine's account of a failure of its own, which
    /// classifies it better than the error it threw.
    static func text(for error: any Error, engine info: PlaybackErrorInfo? = nil) -> String {
        if let info { return text(for: info) }
        switch error {
        // The app's own errors already say what happened in words for the screen.
        case let error as PlaybackError: return error.localizedDescription
        case let error as JellyfinError: return error.localizedDescription
        case let error as URLError: return text(for: error.code)
        default:
            let error = error as NSError
            return error.domain == NSURLErrorDomain ? text(for: URLError.Code(rawValue: error.code)) : unknown
        }
    }

    /// For a failure the engine published.
    static func text(for info: PlaybackErrorInfo) -> String {
        switch info.kind {
        case .sourceRefused:
            return switch info.underlyingCode {
            case 401: "The server no longer accepts this sign-in. Sign in again to play this."
            case 403: "This account isn't allowed to play this. An administrator can allow it in Jellyfin's dashboard."
            case 404: "The server couldn't find this video. It may have been removed from the library."
            case let status? where status >= 500: "The server ran into a problem playing this."
            default: "The server turned down the request to play this."
            }
        case .sourceRateLimited:
            return "The server is too busy to play this right now. Wait a moment, then try again."
        case .sourceCertificateRejected:
            return untrusted
        case .storageExhausted:
            return "This device is full. Free up some space, then try again."
        default:
            break
        }
        // A failure underneath that was the connection's, whichever part of the engine met it.
        if info.underlyingDomain == NSURLErrorDomain, let code = info.underlyingCode {
            return text(for: URLError.Code(rawValue: code))
        }
        switch info.kind {
        case .vodSourceFailed, .liveSourceUnavailable, .reloadFailed, .liveReloadNeverReady:
            return "The connection to the server was lost."
        case .sourceOpenFailed, .customSourceProbeFailed:
            return "This video couldn't be opened. The file may be damaged."
        case .dolbyVisionRequiresHardware:
            return "This device can't play this Dolby Vision video."
        case .hlsFormatUnsupported, .hlsIngestFailed, .hlsPlaylistOnRawLivePath, .demuxedAudioLiveUnsupported,
             .nativeItemFailed, .noPlayableTrackWithinBudget, .masterPlaylistRejected, .softwarePipelineFailed,
             .audioSessionFailed, .audioTrackSwitchFailed, .audioBridgeProducedNoOutput:
            return "This device couldn't play this video."
        default:
            return unknown
        }
    }

    static func text(for code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            "This device is offline. Connect to the internet, then try again."
        case .networkConnectionLost:
            "The connection to the server was lost."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut, .resourceUnavailable:
            "The server can't be reached. It may be off, or on another network."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired, .secureConnectionFailed:
            untrusted
        case .userAuthenticationRequired, .userCancelledAuthentication:
            "The server no longer accepts this sign-in. Sign in again to play this."
        case .badServerResponse, .cannotParseResponse, .zeroByteResource, .cannotDecodeRawData, .cannotDecodeContentData:
            "The server sent something that isn't a video."
        case .fileDoesNotExist, .noPermissionsToReadFile:
            "This video can't be opened. It may have been moved or deleted."
        default:
            "The server can't be reached. It may be off, or on another network."
        }
    }

    private static let untrusted = "The server's certificate isn't trusted, so this device won't play from it."
    static let unknown = "Something went wrong while playing this."
}

/// Turns a request into a URL and the details around it.
@MainActor
struct PlaybackResolver {
    let accounts: AccountStore
    let settings: AppSettings
    let history: WatchHistory
    /// A finished download of the item (and version, when given), with the item, its segments
    /// and its extras as they were saved.
    let downloadedCopy: (_ itemId: String, _ mediaSourceId: String?) -> DownloadedCopy?

    /// A download and the extras saved with it, which play as the server's do for a stream.
    struct DownloadedCopy {
        let url: URL
        let item: JellyfinItem?
        let segments: [MediaSegment]
        /// The server's subtitle files, by the stream index the item lists them under.
        var subtitleFiles: [Int: URL] = [:]
        /// The sheets of scrub previews at the player's width, by number.
        var trickplaySheets: [Int: URL] = [:]
        /// The chapters' pictures, by the chapter's place in the item's list.
        var chapterImages: [Int: URL] = [:]
    }

    /// `tracks` are the audio and subtitles a playback of the title had, which a transcode is asked
    /// for; a version that plays as it is picks its own from them once it's loaded. `picks` are
    /// those the viewer picked in a show this session, which its episodes start with.
    func resolve(_ request: PlaybackRequest, carrying tracks: TrackSelection? = nil, picks: ShowPicks? = nil) async throws -> ResolvedPlayback {
        switch request.source {
        case .file(let bookmark, let name):
            return try resolveFile(bookmark: bookmark, name: name, request: request)
        case .item(let id, let mediaSourceId):
            if let copy = downloadedCopy(id, mediaSourceId) {
                var resolved = resolveDownload(copy, itemId: id, request: request)
                resolved.trackPicks = resolved.item.flatMap { trackPicks(for: $0, session: picks) }
                return resolved
            }
            return try await resolveStream(itemId: id, mediaSourceId: mediaSourceId, request: request, tracks: tracks, picks: picks)
        }
    }

    /// The audio and subtitles the viewer picked for `item`'s show: this session's, else those
    /// remembered from last time.
    private func trackPicks(for item: JellyfinItem, session: ShowPicks?) -> TrackPicks? {
        guard let seriesId = item.seriesId else { return nil }
        return TrackPicks.starting(session: session?.seriesId == seriesId ? session?.picks : nil,
                                   remembered: settings.trackMemory.picks(forShow: seriesId))
    }

    // MARK: Files

    private func resolveFile(bookmark: Data, name: String, request: PlaybackRequest) throws -> ResolvedPlayback {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw PlaybackError.fileUnavailable(name)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        let key = WatchHistory.fileKey(name: url.lastPathComponent, size: size)
        let externalSubtitles = Self.sidecarSubtitles(for: url)
        let resume = request.startFromBeginning ? nil : history.resumePosition(for: key)
        var resolved = ResolvedPlayback(
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            startPosition: request.start(resuming: resume),
            duration: history.entry(for: key)?.duration,
            externalSubtitles: externalSubtitles,
            historyKey: key,
            scopedURL: scoped ? url : nil
        )
        resolved.resumesSavedPosition = request.resumesSavedPosition(resume)
        return resolved
    }

    /// Subtitle files next to a video that share its name: "Movie.en.srt" for "Movie.mkv".
    static func sidecarSubtitles(for video: URL) -> [ExternalSubtitleTrack] {
        let folder = video.deletingLastPathComponent()
        let stem = video.deletingPathExtension().lastPathComponent.lowercased()
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let formats: Set<String> = ["srt", "ass", "ssa", "vtt", "sup"]
        return files.filter { file in
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            return formats.contains(file.pathExtension.lowercased()) && (name == stem || name.hasPrefix(stem + "."))
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { file in
            // "Movie.en.forced.srt": the parts between the name and the format.
            let middle = file.deletingPathExtension().lastPathComponent.dropFirst(stem.count)
                .split(separator: ".").map { $0.lowercased() }
            let language = middle.first { $0.count == 2 || $0.count == 3 }
            return ExternalSubtitleTrack(
                url: file,
                name: file.lastPathComponent,
                language: language,
                isForced: middle.contains("forced"),
                isHearingImpaired: middle.contains("sdh") || middle.contains("hi")
            )
        }
    }

    // MARK: Downloads

    private func resolveDownload(_ copy: DownloadedCopy, itemId: String, request: PlaybackRequest) -> ResolvedPlayback {
        let item = copy.item
        // The server's position when it was last seen, unless this device has a newer one.
        var start = item?.resumeSeconds
        if let local = history.entry(for: itemId) {
            let serverDate = item?.lastPlayedDate ?? .distantPast
            if local.updatedAt > serverDate { start = local.played ? nil : (local.position > 0 ? local.position : nil) }
        }
        let reporting = accounts.client.map { _ in
            ResolvedPlayback.Reporting(itemId: itemId, mediaSourceId: item?.mediaSources?.first?.id,
                                       playSessionId: Self.newPlaySessionId(), playMethod: "DirectPlay")
        }
        let source = item?.mediaSources?.first
        let length = source?.runtimeSeconds ?? item?.runtimeSeconds
        // The server's subtitle files as a stream has them, then any others someone put beside the file.
        let saved = source.map { ExternalSubtitleTrack.of($0) { _, index, _ in copy.subtitleFiles[index] } } ?? []
        let savedFiles = Set(copy.subtitleFiles.values.map(\.standardizedFileURL))
        let others = Self.sidecarSubtitles(for: copy.url).filter { !savedFiles.contains($0.url.standardizedFileURL) }
        let resume = request.startFromBeginning ? nil : Self.resumable(start, length: length)
        return ResolvedPlayback(
            url: copy.url,
            title: item?.titleWithYear ?? request.title,
            subtitle: item.flatMap(Self.subtitle),
            item: item,
            mediaSource: source,
            startPosition: request.start(resuming: resume),
            duration: length,
            externalSubtitles: saved + others,
            historyKey: itemId,
            reporting: reporting,
            isDownload: true,
            segments: copy.segments,
            trickplay: item.flatMap { item in
                source.flatMap { TrickplayTiles.of(item, sourceId: $0.id) { _, index in copy.trickplaySheets[index] } }
            },
            chapters: item.map { ChapterMark.of($0) { index, _ in copy.chapterImages[index] } } ?? [],
            resumesSavedPosition: request.resumesSavedPosition(resume)
        )
    }

    // MARK: Streaming

    private func resolveStream(itemId: String, mediaSourceId: String?, request: PlaybackRequest,
                               tracks: TrackSelection?, picks: ShowPicks?) async throws -> ResolvedPlayback {
        guard let client = accounts.client, let account = accounts.account else { throw PlaybackError.notSignedIn }
        let item: JellyfinItem
        if let loaded = request.loadedItem, loaded.id == itemId {
            item = loaded
        } else {
            item = try await client.item(id: itemId, userId: account.userId)
        }
        // The server offers such a title to play, with a placeholder version that fails once streamed.
        if item.isNotYetAvailable() { throw PlaybackError.notYetAvailable(item) }
        guard let plan = streamingPlan(for: item, mediaSourceId: mediaSourceId) else { throw PlaybackError.noVersions }

        // Where the version played last got to, whichever version plays now.
        var start = request.startFromBeginning ? nil : item.resumeSeconds
        if !request.startFromBeginning, let local = history.entry(for: itemId), local.needsSync, !local.played {
            start = local.position > 0 ? local.position : start
        }

        let asked = request.startingPoint
        let saved = Self.resumable(start, length: plan.source.runtimeSeconds ?? item.runtimeSeconds)
        let resume = request.start(resuming: saved)
        let picks = trackPicks(for: item, session: picks)
        var resolved: ResolvedPlayback
        switch plan {
        case .direct(let source):
            resolved = try direct(item: item, source: source, start: resume)
        case .transcode(let source, let quality):
            let streams = Self.streamIndexes(in: source, asked: asked, carrying: tracks, picks: picks, settings: settings)
            resolved = try await transcode(item: item, source: source, quality: quality, audioIndex: streams.audio,
                                           subtitleIndex: streams.subtitle, start: resume)
        }
        resolved.resumesSavedPosition = request.resumesSavedPosition(saved)
        resolved.trackPicks = picks
        return resolved
    }

    /// The server's indexes of the audio and subtitle streams of `source` to ask a transcode for:
    /// those another device asked for, then the same as a stream of the title had (`tracks`),
    /// then the viewer's picks for the show, then what the language settings ask for. Nil
    /// subtitles are off.
    static func streamIndexes(in source: MediaSource, asked: PlaybackRequest.StartingPoint?, carrying tracks: TrackSelection?,
                              picks: TrackPicks?, settings: AppSettings) -> (audio: Int?, subtitle: Int?) {
        let carried = tracks?.streamIndexes(in: source, settings: settings)
        let audioIndex = asked?.audioStreamIndex ?? carried?.audio
            ?? picks?.audio(in: source.audioStreams.compactMap(TrackChooser.Candidate.init))
            ?? preferredAudioIndex(in: source, language: settings.audioLanguage)
        let subtitleIndex: Int? = if let asked = asked?.subtitleStreamIndex {
            asked < 0 ? nil : asked
        } else if let carried {
            carried.subtitle
        } else if let picked = picks?.subtitles(in: source.subtitleStreams.compactMap(TrackChooser.Candidate.init)) {
            picked.trackId
        } else {
            preferredSubtitleIndex(in: source, audioIndex: audioIndex, settings: settings)
        }
        return (audioIndex, subtitleIndex)
    }

    /// How a stream of `item` would get to the screen: the version picked, or the one the streaming
    /// limit allows, as it is or through the server's transcoder.
    private func streamingPlan(for item: JellyfinItem, mediaSourceId: String?) -> PlaybackPlan? {
        let sources = item.mediaSources ?? []
        let preferred = mediaSourceId.flatMap { id in sources.first { $0.id == id } }
        return VersionChooser.planStreaming(sources: sources, preferred: preferred,
                                            limit: settings.streamingLimit, allowTranscoding: settings.allowTranscoding)
    }

    /// The address a playback of `item` (as `JellyfinClient.item(id:userId:)` gives it) would open,
    /// for warming it up ahead of time: a version that streams as it is. Nil for a download, which
    /// plays from this device, and for a transcode, which AVPlayer fetches itself and the server
    /// only starts once asked.
    func addressToWarm(for item: JellyfinItem) -> URL? {
        guard downloadedCopy(item.id, nil) == nil, !item.isNotYetAvailable(), let client = accounts.client,
              case .direct(let source) = streamingPlan(for: item, mediaSourceId: nil) else { return nil }
        return client.streamURL(itemId: item.id, mediaSourceId: source.id)
    }

    /// Plays `source` as it is.
    func direct(item: JellyfinItem, source: MediaSource, start: Double?) throws -> ResolvedPlayback {
        guard let client = accounts.client else { throw PlaybackError.notSignedIn }
        return ResolvedPlayback(
            url: client.streamURL(itemId: item.id, mediaSourceId: source.id),
            title: item.titleWithYear,
            subtitle: Self.subtitle(item),
            item: item,
            mediaSource: source,
            startPosition: start,
            duration: source.runtimeSeconds ?? item.runtimeSeconds,
            externalSubtitles: ExternalSubtitleTrack.of(source) { _, index, format in
                client.externalSubtitleURL(itemId: item.id, mediaSourceId: source.id, streamIndex: index, format: format)
            },
            historyKey: item.id,
            reporting: .init(itemId: item.id, mediaSourceId: source.id, playSessionId: Self.newPlaySessionId(), playMethod: "DirectPlay"),
            trickplay: Self.trickplay(of: item, source: source, client: client),
            chapters: Self.chapters(of: item, playing: source, client: client)
        )
    }

    /// Has the server scale `source` down to `quality`, with the audio and subtitle streams
    /// burned or muxed into the stream.
    func transcode(item: JellyfinItem, source: MediaSource, quality: VideoQuality,
                   audioIndex: Int?, subtitleIndex: Int?, start: Double?) async throws -> ResolvedPlayback {
        guard let client = accounts.client, let account = accounts.account else { throw PlaybackError.notSignedIn }
        let info = try await client.playbackInfo(itemId: item.id, userId: account.userId, request: PlaybackInfoRequest(
            UserId: account.userId,
            MediaSourceId: source.id,
            MaxStreamingBitrate: quality.transcodeBitrate,
            StartTimeTicks: Int64((start ?? 0) * 10_000_000),
            AudioStreamIndex: audioIndex,
            SubtitleStreamIndex: subtitleIndex ?? -1,
            DeviceProfile: .transcoding(maxHeight: quality.maxHeight, maxBitrate: quality.transcodeBitrate)
        ))
        let served = info.mediaSources.first { $0.id == source.id } ?? info.mediaSources.first
        guard let path = served?.transcodingUrl, let url = client.absoluteURL(serverPath: path) else {
            throw PlaybackError.transcodeRefused(info.errorCode)
        }
        return ResolvedPlayback(
            url: url,
            title: item.titleWithYear,
            subtitle: Self.subtitle(item),
            item: item,
            mediaSource: source,
            startPosition: start,
            duration: item.runtimeSeconds,
            historyKey: item.id,
            reporting: .init(itemId: item.id, mediaSourceId: source.id,
                             playSessionId: info.playSessionId ?? Self.newPlaySessionId(), playMethod: "Transcode"),
            transcode: .init(quality: quality, audioIndex: audioIndex, subtitleIndex: subtitleIndex),
            // A transcode keeps the version's timeline, so its previews and chapters fit it.
            trickplay: Self.trickplay(of: item, source: source, client: client),
            chapters: Self.chapters(of: item, playing: source, client: client)
        )
    }

    /// The version's scrub previews on the server.
    private static func trickplay(of item: JellyfinItem, source: MediaSource, client: JellyfinClient) -> TrickplayTiles? {
        TrickplayTiles.of(item, sourceId: source.id) { info, index in
            client.trickplaySheetURL(itemId: item.id, mediaSourceId: source.id, width: info.width, index: index)
        }
    }

    /// The chapters of the version playing, with their pictures on the server, when it's the
    /// item's own. Another version's are its own item's, which the player asks for once it plays.
    static func chapters(of item: JellyfinItem, playing source: MediaSource, client: JellyfinClient) -> [ChapterMark] {
        guard source.versionItemId == item.id else { return [] }
        return ChapterMark.of(item) { index, chapter in
            chapter.imageTag.map { client.chapterImageURL(itemId: item.id, index: index, tag: $0, maxWidth: ChapterMark.imageWidth) }
        }
    }

    /// The chapters marked in the file itself, as the engine read them, for a playback the server
    /// gives none for, such as a file of this device's.
    nonisolated static func chapters(from marks: [ChapterInfo]) -> [ChapterMark] {
        marks.sorted { $0.startSeconds < $1.startSeconds }.enumerated().map { index, chapter in
            let name = chapter.name.trimmingCharacters(in: .whitespaces)
            return ChapterMark(index: index, start: chapter.startSeconds, name: name.isEmpty ? "Chapter \(index + 1)" : name, image: nil)
        }
    }

    /// A resume position, unless it's at or past the end of this version, which happens when the
    /// position was reached in a longer one: a title resumes where its version played last got to.
    static func resumable(_ start: Double?, length: Double?) -> Double? {
        guard let start, start > 0 else { return nil }
        guard let length, length > 0 else { return start }
        return start < length * WatchHistory.playedFraction ? start : nil
    }

    nonisolated static func subtitleFormat(for codec: String?) -> String {
        switch codec?.lowercased() {
        case "subrip", "srt", nil: "srt"
        case "ass": "ass"
        case "ssa": "ssa"
        case "webvtt", "vtt": "vtt"
        case "pgssub", "pgs", "sup": "sup"
        case let other?: other
        }
    }

    /// The audio stream the audio language and Audio Descriptions ask for, from the server's list
    /// of streams; nil leaves it to the version's default.
    static func preferredAudioIndex(in source: MediaSource, language: String) -> Int? {
        TrackChooser.audio(from: source.audioStreams.compactMap(TrackChooser.Candidate.init), language: language,
                           defaultId: source.defaultAudioStreamIndex, descriptions: AccessibleMedia.prefersAudioDescriptions)
    }

    /// The subtitle stream the subtitle setting and Closed Captions + SDH ask for, from the
    /// server's list of streams.
    static func preferredSubtitleIndex(in source: MediaSource, audioIndex: Int?, settings: AppSettings) -> Int? {
        let audio = source.audioStreams.first { $0.index == (audioIndex ?? source.defaultAudioStreamIndex) } ?? source.audioStreams.first
        return TrackChooser.subtitle(from: source.subtitleStreams.compactMap(TrackChooser.Candidate.init), audioLanguage: audio?.language,
                                     mode: settings.subtitleMode, language: settings.subtitleLanguage,
                                     captions: AccessibleMedia.prefersCaptions)
    }

    static func subtitle(_ item: JellyfinItem) -> String? {
        guard item.isEpisode else { return nil }
        return [item.seriesName, item.episodeCode].compactMap(\.self).joined(separator: " · ")
    }

    static func newPlaySessionId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// The audio and subtitles chosen in a playback, described so that another version of the
/// title, whose tracks are numbered differently, can choose the same.
struct TrackSelection {
    var audio: TrackChooser.Candidate?
    /// Nil when subtitles are off.
    var subtitle: TrackChooser.Candidate?
    /// The server's indexes of the chosen streams, in the version they were chosen in, which pick
    /// them out exactly there. Nil for a file of this device's.
    var streams: ServerStreams?

    struct ServerStreams {
        let mediaSourceId: String
        var audio: Int?
        var subtitle: Int?
    }

    /// The server's index of the chosen audio in `source`, when that's the version it was chosen in.
    func exactAudioIndex(in source: MediaSource?) -> Int? {
        guard let source, streams?.mediaSourceId == source.id, let index = streams?.audio,
              source.audioStreams.contains(where: { $0.index == index }) else { return nil }
        return index
    }

    /// The server's index of the chosen subtitles in `source`, when that's the version they were
    /// chosen in and they're on.
    func exactSubtitleIndex(in source: MediaSource?) -> Int? {
        guard subtitle != nil, let source, streams?.mediaSourceId == source.id, let index = streams?.subtitle,
              source.subtitleStreams.contains(where: { $0.index == index }) else { return nil }
        return index
    }

    /// The server's indexes in `source` of the same audio and subtitles, to ask a transcode for:
    /// the very streams in the version they were chosen in, the same language and kind in another,
    /// and what the language settings ask for when it has neither. Subtitles that were off stay off.
    func streamIndexes(in source: MediaSource, settings: AppSettings) -> (audio: Int?, subtitle: Int?) {
        let audioIndex = exactAudioIndex(in: source)
            ?? audio.flatMap { TrackChooser.same(as: $0, in: source.audioStreams.compactMap(TrackChooser.Candidate.init)) }
            ?? PlaybackResolver.preferredAudioIndex(in: source, language: settings.audioLanguage)
        guard let subtitle else { return (audioIndex, nil) }
        let subtitleIndex = exactSubtitleIndex(in: source)
            ?? TrackChooser.same(as: subtitle, in: source.subtitleStreams.compactMap(TrackChooser.Candidate.init))
            ?? PlaybackResolver.preferredSubtitleIndex(in: source, audioIndex: audioIndex, settings: settings)
        return (audioIndex, subtitleIndex)
    }
}

/// The audio and subtitles the viewer picked in the player, described by language and kind so
/// another episode of the show can find its own (`TrackChooser.same`). What wasn't picked stays
/// with the language settings: an episode with forced subtitles where the one before had none
/// still gets them, unless subtitles were turned off.
///
/// An episode's tracks come from, first to last: the streams another device asked for
/// (`PlaybackRequest.StartingPoint`), the tracks a stream of the same title had (`TrackSelection`),
/// the picks made in the show this session, those remembered from last time (`TrackMemory`), and
/// the language settings.
nonisolated struct TrackPicks: Codable, Equatable, Sendable {
    /// A track as picked, without its number, which other episodes' tracks don't share.
    struct Track: Codable, Equatable, Sendable {
        var language: String?
        var isForced = false
        var isHearingImpaired = false
        var name: String?
        var describesVideo = false

        init(_ candidate: TrackChooser.Candidate) {
            language = candidate.language
            isForced = candidate.isForced
            isHearingImpaired = candidate.isHearingImpaired
            name = candidate.name
            describesVideo = candidate.describesVideo
        }

        var candidate: TrackChooser.Candidate {
            TrackChooser.Candidate(id: -1, language: language, isForced: isForced, isHearingImpaired: isHearingImpaired,
                                   isDefault: false, name: name, describesVideo: describesVideo)
        }
    }

    enum Subtitles: Codable, Equatable, Sendable {
        case off
        case track(Track)
    }

    /// What the picks make of the subtitles among an episode's tracks.
    enum SubtitleChoice: Equatable {
        case off
        case track(Int)

        /// The track to turn on; nil turns them off.
        var trackId: Int? {
            if case .track(let id) = self { id } else { nil }
        }
    }

    var audio: Track?
    var subtitles: Subtitles?

    var isEmpty: Bool { audio == nil && subtitles == nil }

    /// These picks, and `fallback`'s where these have none.
    func over(_ fallback: TrackPicks?) -> TrackPicks {
        TrackPicks(audio: audio ?? fallback?.audio, subtitles: subtitles ?? fallback?.subtitles)
    }

    /// What an episode starts with: this session's picks in the show, and for what wasn't picked
    /// this session, those remembered. Nil with neither.
    static func starting(session: TrackPicks?, remembered: TrackPicks?) -> TrackPicks? {
        let picks = (session ?? TrackPicks()).over(remembered)
        return picks.isEmpty ? nil : picks
    }

    /// The audio among `candidates` that's the same as the one picked; nil when audio wasn't
    /// picked or none is, which leaves it to the language settings.
    func audio(in candidates: [TrackChooser.Candidate]) -> Int? {
        audio.flatMap { TrackChooser.same(as: $0.candidate, in: candidates) }
    }

    /// The subtitles among `candidates` the picks ask for: off, or the same track as the one
    /// picked. Nil when they weren't picked or none is the same, which leaves them to the
    /// subtitle setting.
    func subtitles(in candidates: [TrackChooser.Candidate]) -> SubtitleChoice? {
        switch subtitles {
        case nil: nil
        case .off: .off
        case .track(let track): TrackChooser.same(as: track.candidate, in: candidates).map(SubtitleChoice.track)
        }
    }
}

/// The picks made in one show during a player's session.
nonisolated struct ShowPicks: Equatable, Sendable {
    let seriesId: String
    var picks: TrackPicks
}

/// The last audio and subtitles the viewer picked in each show, which its episodes start with
/// next time, ahead of the language settings. Holds the `capacity` shows picked in most recently.
nonisolated struct TrackMemory: Codable, Equatable, Sendable {
    private struct Entry: Codable, Equatable, Sendable {
        let seriesId: String
        var picks: TrackPicks
    }

    /// Oldest first.
    private var entries: [Entry] = []

    static let capacity = 200

    func picks(forShow seriesId: String) -> TrackPicks? {
        entries.last { $0.seriesId == seriesId }?.picks
    }

    /// Keeps `picks` for the show, over what it had: picking subtitles keeps the audio picked
    /// before.
    mutating func remember(_ picks: TrackPicks, forShow seriesId: String) {
        let merged = picks.over(self.picks(forShow: seriesId))
        entries.removeAll { $0.seriesId == seriesId }
        entries.append(Entry(seriesId: seriesId, picks: merged))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
}

/// Picks audio and subtitle tracks for the language settings and the system's Accessibility
/// settings, and finds a track chosen in one version of a title among another's. Works on the
/// server's streams and on the player's tracks alike.
nonisolated enum TrackChooser {
    struct Candidate: Equatable, Sendable {
        let id: Int
        let language: String?
        let isForced: Bool
        let isHearingImpaired: Bool
        let isDefault: Bool
        /// The title the file gives the track, such as "Commentary".
        var name: String?
        /// An audio description, narrating what's on screen.
        var describesVideo = false

        /// Subtitles of only what isn't in the audio's language, such as signs and foreign
        /// dialogue: flagged so, or named so, unless named as full subtitles. Files often name such
        /// a track "Forced" without the flag, the subtitles a transcode carries never have it, and
        /// now and then a full "SDH" track has it.
        var showsOnlyForced: Bool { (isForced || TrackChooser.namesForced(name)) && !TrackChooser.namesFull(name) }

        /// Closed captions for the deaf and hard of hearing: flagged so, or named so, which far
        /// more of them are than flagged.
        var isCaptions: Bool { isHearingImpaired || TrackChooser.namesCaptions(name) }
    }

    /// Whether a track's title calls it forced subtitles: "Forced", "English (Forced)", "Foreign
    /// Parts Only".
    static func namesForced(_ title: String?) -> Bool {
        guard let title = title?.lowercased(), !title.isEmpty else { return false }
        return words(of: title).contains("forced") || title.contains("foreign parts")
    }

    /// Whether a track's title calls it closed captions: "SDH", "English CC", "Hearing Impaired".
    static func namesCaptions(_ title: String?) -> Bool {
        guard let title = title?.lowercased(), !title.isEmpty else { return false }
        let words = words(of: title)
        return words.contains("sdh") || words.contains("cc") || words.contains("hoh")
            || title.contains("hearing impaired") || title.contains("closed caption")
    }

    /// Whether a track's title calls it full subtitles, captions included.
    static func namesFull(_ title: String?) -> Bool {
        guard let title = title?.lowercased(), !title.isEmpty else { return false }
        let words = words(of: title)
        return namesCaptions(title) || words.contains("full") || words.contains("complete")
    }

    private static func words(of title: String) -> [Substring] {
        title.split { !$0.isLetter }
    }

    /// The candidate that is the same choice as `chosen`, made in another version of the title,
    /// whose tracks are numbered differently: the same language, of the same kind when there is
    /// one, by name when several are. Nil when the version has nothing in that language, or for
    /// forced subtitles, none forced: full subtitles would show everything they leave out.
    static func same(as chosen: Candidate, in candidates: [Candidate]) -> Int? {
        let sameLanguage = candidates.filter {
            AppSettings.sameLanguage($0.language, chosen.language) || (isUnknown($0.language) && isUnknown(chosen.language))
        }
        let sameForcedness = sameLanguage.filter { $0.showsOnlyForced == chosen.showsOnlyForced }
        let sameKind = sameForcedness.filter {
            $0.isCaptions == chosen.isCaptions && $0.describesVideo == chosen.describesVideo
        }
        let pool = sameKind.isEmpty ? sameForcedness : sameKind
        let sameName = chosen.name.flatMap { name in pool.first { $0.name?.caseInsensitiveCompare(name) == .orderedSame } }
        return (sameName ?? pool.first)?.id
    }

    private static func isUnknown(_ language: String?) -> Bool {
        language == nil || language == "und" || language?.isEmpty == true
    }

    /// The audio track to play. With `descriptions` (Audio Descriptions), an audio description in
    /// `language`, or with no language set, in the default track's; otherwise, or when there's
    /// none, the first track in `language` that isn't one. Nil leaves it to the default track.
    static func audio(from candidates: [Candidate], language: String, defaultId: Int?, descriptions: Bool) -> Int? {
        if descriptions {
            let spoken = language.isEmpty ? candidates.first { $0.id == defaultId }?.language : language
            let described = candidates.filter(\.describesVideo)
            if let match = described.first(where: { AppSettings.sameLanguage($0.language, spoken) })
                ?? (isUnknown(spoken) ? described.first : nil) {
                return match.id
            }
        }
        guard !language.isEmpty else { return nil }
        let inLanguage = candidates.filter { AppSettings.sameLanguage($0.language, language) }
        return (inLanguage.first { !$0.describesVideo } ?? inLanguage.first)?.id
    }

    /// The subtitle track `mode` asks for in `language`. With `captions` (Closed Captions + SDH)
    /// subtitles show whatever the mode: closed captions first, in `language`, else in the audio's.
    static func subtitle(from candidates: [Candidate], audioLanguage: String?, mode: AppSettings.SubtitleMode, language: String,
                         captions: Bool = false) -> Int? {
        let inLanguage = candidates.filter { AppSettings.sameLanguage($0.language, language) }
        let forced = inLanguage.first { $0.showsOnlyForced }
            ?? candidates.first { $0.showsOnlyForced && AppSettings.sameLanguage($0.language, audioLanguage) }
        let full = inLanguage.first { !$0.showsOnlyForced && !$0.isCaptions } ?? inLanguage.first { !$0.showsOnlyForced }
        if captions {
            for spoken in [language, audioLanguage] {
                let tracks = candidates.filter { !$0.showsOnlyForced && AppSettings.sameLanguage($0.language, spoken) }
                if let caption = tracks.first(where: \.isCaptions) ?? tracks.first { return caption.id }
            }
            return forced?.id
        }
        switch mode {
        case .off:
            return nil
        case .forcedOnly:
            return forced?.id
        case .smart:
            // Audio of unknown language is taken to be understood.
            let audioMatches = isUnknown(audioLanguage) || AppSettings.sameLanguage(audioLanguage, language)
            return audioMatches ? forced?.id : (full ?? forced)?.id
        case .always:
            return (full ?? forced)?.id
        }
    }
}

nonisolated extension TrackChooser.Candidate {
    /// One of the streams the server lists for a version. Nil for a stream without an index,
    /// which can't be asked for.
    init?(_ stream: MediaStream) {
        guard let index = stream.index else { return nil }
        self.init(id: index, language: stream.language, isForced: stream.isForced ?? false,
                  isHearingImpaired: stream.isHearingImpaired ?? false, isDefault: stream.isDefault ?? false,
                  name: stream.title, describesVideo: stream.isAudioDescription)
    }

    /// One of the player's tracks.
    init(_ track: TrackInfo) {
        let name = TrackChooser.ownName(of: track)
        self.init(id: track.id, language: track.language, isForced: track.isForced,
                  isHearingImpaired: track.isHearingImpaired, isDefault: track.isDefault,
                  name: name, describesVideo: track.isVisualImpaired || AccessibleMedia.namesAudioDescription(name))
    }
}

nonisolated extension TrackChooser {
    /// The title the file gives a track. Untitled streams get a made-up "ENG (srt)" or
    /// "Track 3 (srt)" from the engine, which only repeats the language and the format.
    static func ownName(of track: TrackInfo) -> String? {
        let name = track.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name.hasSuffix("(\(track.codec))") ? nil : name
    }
}

/// The episodes a playback goes through in an order of their own, as a show shuffled: Next,
/// Previous and the countdown to the next episode follow it, rather than the show's order. It
/// ends at its last episode.
nonisolated struct PlayOrder: Codable, Hashable, Sendable {
    let ids: [String]

    /// A show's `episodes` in the order `seed` shuffles them into (`ShuffleOrder`): those the player
    /// goes on to from one to the next, with no specials and nothing not out yet.
    static func shuffled(_ episodes: [JellyfinItem], seed: UInt64, now: Date) -> PlayOrder {
        PlayOrder(ids: ShuffleOrder.sorted(episodes.filter { UpNext.canGoOn(to: $0, now: now) }.map(\.id), seed: seed))
    }

    func contains(_ id: String) -> Bool {
        ids.contains(id)
    }

    /// The episode after `id`; nil after the last, or for an episode not in the order.
    func id(after id: String) -> String? {
        ids(after: id).first
    }

    /// The episodes after `id`; none for an episode not in the order.
    func ids(after id: String) -> ArraySlice<String> {
        guard let index = ids.firstIndex(of: id) else { return [] }
        return ids[(index + 1)...]
    }

    /// The episode before `id`; nil before the first, or for an episode not in the order.
    func id(before id: String) -> String? {
        guard let index = ids.firstIndex(of: id), index > 0 else { return nil }
        return ids[index - 1]
    }
}
