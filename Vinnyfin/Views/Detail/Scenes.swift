import SwiftUI

/// A title's chapters as its page's Scenes row has them: those of the version a play from the page
/// starts, as the player has them for it, each with a picture of where it starts, or else the scrub
/// preview of a moment into it. Chapters are a version's own, with timings that can differ from
/// another version's, so they're never shown for one version and played in another.
nonisolated struct TitleScenes: Equatable, Sendable {
    let chapters: [ChapterMark]
    /// The version's scrub previews, for chapters the server has no picture of.
    var previews: TrickplayTiles?
    /// The version's length, where the last chapter ends.
    var length: Double?

    /// How wide chapter pictures are asked for, in pixels: about twice a scene card's width.
    static var imageWidth: Int {
        #if os(tvOS)
        800
        #else
        640
        #endif
    }

    /// The chapters of a stream of `item`'s version `versionItem`, with their pictures on the
    /// server: the item itself for its own version, or for another, that version's own item,
    /// which has its chapters.
    static func streaming(_ item: JellyfinItem, versionItem: JellyfinItem, client: JellyfinClient) -> TitleScenes {
        let versionId = versionItem.id
        let source = item.mediaSources?.first { $0.id == versionId }
        let chapters = ChapterMark.of(versionItem) { index, chapter in
            chapter.imageTag.map { client.chapterImageURL(itemId: versionId, index: index, tag: $0, maxWidth: imageWidth) }
        }
        let previews = TrickplayTiles.of(item, sourceId: versionId) { info, index in
            client.trickplaySheetURL(itemId: item.id, mediaSourceId: versionId, width: info.width, index: index)
        }
        return TitleScenes(chapters: chapters, previews: previews, length: source?.runtimeSeconds ?? versionItem.runtimeSeconds)
    }

    /// The chapters of a download, which plays in place of a stream: with the pictures and previews
    /// saved with it, or for those it hasn't saved, the server's when there is one.
    static func downloaded(_ copy: PlaybackResolver.DownloadedCopy, client: JellyfinClient?) -> TitleScenes {
        guard let item = copy.item else { return TitleScenes(chapters: []) }
        let source = item.mediaSources?.first
        let versionId = source?.versionItemId ?? item.id
        let chapters = ChapterMark.of(item) { index, chapter in
            copy.chapterImages[index] ?? chapter.imageTag.flatMap { tag in
                client?.chapterImageURL(itemId: versionId, index: index, tag: tag, maxWidth: imageWidth)
            }
        }
        let previews = source.flatMap { source in
            TrickplayTiles.of(item, sourceId: source.id) { _, index in copy.trickplaySheets[index] }
        }
        return TitleScenes(chapters: chapters, previews: previews, length: source?.runtimeSeconds ?? item.runtimeSeconds)
    }

    /// Where `chapter` ends: where the next one starts, or the version's end.
    func end(of chapter: ChapterMark) -> Double? {
        chapters.first { $0.start > chapter.start }?.start ?? length
    }

    /// The moment whose scrub preview stands for a chapter without a picture: a tenth of the way
    /// in, up to 15 seconds, past the fade from black a chapter often opens on.
    func previewTime(of chapter: ChapterMark) -> Double {
        guard let end = end(of: chapter), end > chapter.start else { return chapter.start }
        return chapter.start + min(15, (end - chapter.start) / 10)
    }

    /// How far into `chapter` a resume at `position` starts, when it's in that chapter.
    func progress(of chapter: ChapterMark, resumingAt position: Double?) -> Double? {
        guard let position, ChapterMark.current(in: chapters, at: position) == chapter,
              let end = end(of: chapter), end > chapter.start else { return nil }
        return min(1, max(0, (position - chapter.start) / (end - chapter.start)))
    }

    /// Plays `item` from `chapter`, exactly there whatever its resume position, through the same
    /// request Play makes: in the version picked on the page, or with none picked, in the one the
    /// player would choose, as the chapters are.
    static func request(playing item: JellyfinItem, from chapter: ChapterMark, mediaSourceId: String?) -> PlaybackRequest {
        var request = PlaybackRequest.item(item, mediaSourceId: mediaSourceId, loaded: item)
        request.startingPoint = PlaybackRequest.StartingPoint(position: chapter.start)
        return request
    }

    /// "12:30", or past an hour "1:02:15".
    static func timeText(_ seconds: Double) -> String {
        let duration = Duration.seconds(max(0, seconds).rounded(.down))
        return seconds >= 3600 ? duration.formatted(.time(pattern: .hourMinuteSecond)) : duration.formatted(.time(pattern: .minuteSecond))
    }

    /// `timeText` as it's said: "from the start", "from 12 minutes, 30 seconds in".
    static func spokenTime(_ seconds: Double) -> String {
        guard seconds >= 1 else { return "From the start" }
        let duration = Duration.seconds(seconds.rounded(.down))
        return "From \(duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))) in"
    }
}

/// A title's Scenes: its chapters as pictures of where each starts, with their names and times,
/// each playing the title from there. The chapter the title would resume in shows how far into it
/// that is.
///
/// The chapters are those of the version a play from the page starts, as the player picks it: the
/// version picked on the page, else a download of the title, else the one the quality settings
/// choose. Another version's chapters, and a download's saved pictures, come after a moment.
struct ScenesShelf: View {
    /// The title, with its details.
    let item: JellyfinItem
    /// The version picked on the page; nil leaves the choice to the player, as Play does.
    let pickedSourceId: String?
    /// The version a stream from the page plays: the one picked, or the one the quality settings choose.
    let streamingSource: MediaSource?

    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif
    /// The scenes that took a moment to find, with what they're the scenes of.
    @State private var found: (key: Key, scenes: TitleScenes)?

    /// What the scenes shown depend on.
    private struct Key: Equatable {
        let itemId: String
        let versionId: String?
        let playsDownload: Bool
        let chapters: [Chapter]?
    }

    /// The scene cards' width, about two thirds of a landscape card's.
    static var cardWidth: CGFloat {
        #if os(tvOS)
        350
        #else
        Metrics.landscapeWidth * 0.75
        #endif
    }

    var body: some View {
        let key = key
        let scenes = immediateScenes(for: key) ?? (found?.key == key ? found?.scenes : nil)
        // Nothing while the item lists no chapters, and nothing once the version turns out to have none.
        if !(item.chapters ?? []).isEmpty, scenes.map({ !$0.chapters.isEmpty }) ?? true {
            Shelf(title: "Scenes", items: scenes?.chapters, cardWidth: Self.cardWidth, placeholderStyle: .landscape) { chapter in
                if let scenes { card(chapter, in: scenes) }
            }
            .task(id: key) {
                guard immediateScenes(for: key) == nil else { return }
                let loaded = await load(key)
                if let loaded, !Task.isCancelled { found = (key, loaded) }
            }
        }
    }

    private func card(_ chapter: ChapterMark, in scenes: TitleScenes) -> some View {
        Button {
            player.play(TitleScenes.request(playing: item, from: chapter, mediaSourceId: pickedSourceId))
        } label: {
            SceneCard(chapter: chapter, previews: scenes.previews, previewTime: scenes.previewTime(of: chapter),
                      progress: scenes.progress(of: chapter, resumingAt: item.resumeSeconds))
        }
        .buttonStyle(.artwork)
        .foregroundStyle(.primary)
        .accessibilityHint("Plays from here")
        .accessibilityIdentifier("scene.\(chapter.index)")
        // Plays from the download while the server is out of reach, as Play does.
        .playableOffline(item, mediaSourceId: pickedSourceId, dimming: true)
    }

    private var key: Key {
        #if os(tvOS)
        let playsDownload = false
        #else
        let playsDownload = downloads.jobs(forItem: item.id)
            .contains { $0.status == .completed && (pickedSourceId == nil || $0.mediaSourceId == pickedSourceId) }
        #endif
        return Key(itemId: item.id, versionId: streamingSource?.id, playsDownload: playsDownload, chapters: item.chapters)
    }

    /// The scenes, when they're the item's own: a stream of its own version, with nothing to wait for.
    private func immediateScenes(for key: Key) -> TitleScenes? {
        guard !key.playsDownload, key.versionId == nil || key.versionId == item.id, let client = session?.client else { return nil }
        return TitleScenes.streaming(item, versionItem: item, client: client)
    }

    /// The scenes of a download, or of another version, which its own item has the chapters of.
    private func load(_ key: Key) async -> TitleScenes? {
        #if !os(tvOS)
        if key.playsDownload, let copy = downloads.playableFile(itemId: item.id, mediaSourceId: pickedSourceId) {
            return TitleScenes.downloaded(copy, client: session?.client)
        }
        #endif
        guard let session, let versionId = key.versionId else { return nil }
        do {
            let version = try await session.client.item(id: versionId, userId: session.userId)
            return TitleScenes.streaming(item, versionItem: version, client: session.client)
        } catch {
            // Without the version's chapters, no scenes: the item's own could start at other times.
            return error.isCancellation ? nil : TitleScenes(chapters: [])
        }
    }
}

/// A chapter: the picture of where it starts, or a scrub preview of it, with its name and the
/// time it starts at, and when the title resumes in it, how far into it that is.
private struct SceneCard: View {
    let chapter: ChapterMark
    let previews: TrickplayTiles?
    let previewTime: Double
    let progress: Double?
    @State private var artworkHeight: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            picture
                .overlay(alignment: .bottom) {
                    if let progress { ProgressBar(fraction: progress).padding(Metrics.overlayInset) }
                }
                .liftsUnderFocus()
                .measuresCardArtwork($artworkHeight)
            VStack(alignment: .leading, spacing: 1) {
                Text(chapter.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(dynamicTypeSize.lineLimit(1))
                Text(TitleScenes.timeText(chapter.start))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .modifier(CardCaptionStyle(artworkHeight: artworkHeight))
        }
        .contentShape(.rect)
        #if os(macOS)
        .help(chapter.name)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chapter.name)
        .accessibilityValue([TitleScenes.spokenTime(chapter.start), progress.map { _ in "resumes here" }]
            .compactMap(\.self).joined(separator: ", "))
    }

    @ViewBuilder private var picture: some View {
        if chapter.image == nil, let previews {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { TrickplayThumbnail(tiles: previews, time: previewTime).scaledToFill() }
                .clipShape(.rect(cornerRadius: Metrics.cardRadius))
        } else {
            Artwork(url: chapter.image, aspectRatio: 16.0 / 9.0, placeholder: "film")
        }
    }
}
