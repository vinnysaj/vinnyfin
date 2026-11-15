import SwiftUI

/// A trailer or an extra of a title: a video the server keeps beside the title's file, which plays
/// in the app, or a trailer on the web, which opens there.
nonisolated enum TitleExtra: Identifiable, Hashable, Sendable {
    case video(JellyfinItem)
    case web(RemoteTrailer)

    var id: String {
        switch self {
        case .video(let item): item.id
        case .web(let trailer): trailer.url
        }
    }

    var name: String {
        switch self {
        case .video(let item): item.name
        case .web(let trailer): if let name = trailer.name, !name.isEmpty { name } else { "Trailer" }
        }
    }

    /// What it is, "Trailer" or "Behind the Scenes", and how long, or where it plays: "Trailer · 2m",
    /// "Trailer · YouTube".
    var detail: String {
        switch self {
        case .video(let item):
            return [Self.kind(of: item.extraType), item.runtimeText].compactMap(\.self).joined(separator: " · ")
        case .web(let trailer):
            return ["Trailer", Self.site(of: trailer)].compactMap(\.self).joined(separator: " · ")
        }
    }

    /// An extra's kind in words, from the server's `ExtraType`.
    static func kind(of extraType: String?) -> String {
        switch extraType {
        case "Trailer": "Trailer"
        case "BehindTheScenes": "Behind the Scenes"
        case "DeletedScene": "Deleted Scene"
        case "Featurette": "Featurette"
        case "Interview": "Interview"
        case "Scene": "Scene"
        case "Short": "Short"
        case "Clip": "Clip"
        case "Sample": "Sample"
        default: "Extra"
        }
    }

    /// "YouTube", "Vimeo", or the site's address without its "www.".
    static func site(of trailer: RemoteTrailer) -> String? {
        guard let host = URL(string: trailer.url)?.host()?.lowercased() else { return nil }
        if host.hasSuffix("youtube.com") || host == "youtu.be" { return "YouTube" }
        if host.hasSuffix("vimeo.com") { return "Vimeo" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Whether `item` has any trailers or extras the row would list, as its details say: the server
    /// lists the videos beside its file only when asked for them.
    static func mayHave(_ item: JellyfinItem, opensWeb: Bool) -> Bool {
        (item.localTrailerCount ?? 0) > 0 || (item.specialFeatureCount ?? 0) > 0 || (opensWeb && !webTrailers(of: item).isEmpty)
    }

    /// The trailers on the web with an address a browser opens, each once.
    static func webTrailers(of item: JellyfinItem) -> [RemoteTrailer] {
        var seen = Set<String>()
        return (item.remoteTrailers ?? []).filter { trailer in
            guard let scheme = URL(string: trailer.url)?.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
            return seen.insert(trailer.url).inserted
        }
    }

    /// The row's videos in order: the trailers, the server's then the web's, then the other extras,
    /// kind by kind in the order `kinds` has them.
    static func list(of item: JellyfinItem, trailers: [JellyfinItem], features: [JellyfinItem], opensWeb: Bool) -> [TitleExtra] {
        let web = opensWeb ? webTrailers(of: item).map(TitleExtra.web) : []
        let sorted = features.enumerated().sorted { left, right in
            let leftRank = kinds.firstIndex(of: left.element.extraType ?? "") ?? kinds.count
            let rightRank = kinds.firstIndex(of: right.element.extraType ?? "") ?? kinds.count
            return leftRank != rightRank ? leftRank < rightRank : left.offset < right.offset
        }
        return trailers.map(TitleExtra.video) + web + sorted.map { .video($0.element) }
    }

    /// The order extras are listed in, by the server's `ExtraType`.
    static let kinds = ["BehindTheScenes", "Featurette", "Interview", "DeletedScene", "Scene", "Short", "Clip", "Sample"]
}

/// A title's Trailers & Extras: the trailers, which the server keeps beside its file or links to on
/// the web, and the other videos beside its file, as behind the scenes, deleted scenes and
/// interviews. The server's play here; the web's open in the browser, and so aren't on Apple TV,
/// which has none.
struct TitleExtrasShelf: View {
    let item: JellyfinItem
    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.openURL) private var openURL
    /// Nil while they load.
    @State private var extras: (itemId: String, list: [TitleExtra])?

    /// Trailers on the web open in a browser, which Apple TV hasn't.
    static var opensWeb: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    private struct Key: Equatable {
        let itemId: String
        let trailers: Int
        let features: Int
    }

    var body: some View {
        let shown = extras?.itemId == item.id ? extras?.list : nil
        if TitleExtra.mayHave(item, opensWeb: Self.opensWeb), shown.map({ !$0.isEmpty }) ?? true {
            Shelf(title: "Trailers & Extras", items: shown, cardWidth: Metrics.landscapeWidth, placeholderStyle: .landscape) { extra in
                card(extra)
            }
            .task(id: Key(itemId: item.id, trailers: item.localTrailerCount ?? 0, features: item.specialFeatureCount ?? 0)) {
                await load()
            }
        }
    }

    @ViewBuilder private func card(_ extra: TitleExtra) -> some View {
        let button = Button { open(extra) } label: { ExtraCard(extra: extra, title: item) }
            .buttonStyle(.artwork)
            .foregroundStyle(.primary)
            .accessibilityHint(isWeb(extra) ? "Opens in the browser" : "Plays it")
        switch extra {
        // The server's, even of a title that's downloaded, as downloads don't keep them.
        case .video(let video): button.playableOffline(video, dimming: true)
        case .web: button
        }
    }

    private func isWeb(_ extra: TitleExtra) -> Bool {
        if case .web = extra { true } else { false }
    }

    private func open(_ extra: TitleExtra) {
        switch extra {
        case .video(let video): player.play(.item(video))
        case .web(let trailer): if let url = URL(string: trailer.url) { openURL(url) }
        }
    }

    /// The videos beside the title's file, of the kinds it has. Without them, the web's trailers
    /// alone, rather than nothing.
    private func load() async {
        let itemId = item.id
        var trailers: [JellyfinItem] = []
        var features: [JellyfinItem] = []
        if let session {
            async let localTrailers = (item.localTrailerCount ?? 0) > 0
                ? session.client.localTrailers(itemId: itemId, userId: session.userId) : []
            async let specialFeatures = (item.specialFeatureCount ?? 0) > 0
                ? session.client.specialFeatures(itemId: itemId, userId: session.userId) : []
            trailers = (try? await localTrailers) ?? []
            features = (try? await specialFeatures) ?? []
        }
        guard !Task.isCancelled, itemId == item.id else { return }
        extras = (itemId, TitleExtra.list(of: item, trailers: trailers, features: features, opensWeb: Self.opensWeb))
    }
}

/// A trailer or extra: its own picture, or the title's backdrop, with its name, and what it is.
/// One on the web has a mark that it opens there.
private struct ExtraCard: View {
    let extra: TitleExtra
    /// The title it's of, whose backdrop stands in for a picture of its own.
    let title: JellyfinItem
    @State private var artworkHeight: CGFloat = 0
    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: pictureURL, aspectRatio: 16.0 / 9.0, placeholder: "film")
                .overlay {
                    Image(systemName: isWeb ? "arrow.up.right" : "play.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.35), in: .circle)
                        .background(.ultraThinMaterial, in: .circle)
                        .environment(\.colorScheme, .dark)
                        .accessibilityHidden(true)
                }
                .liftsUnderFocus()
                .measuresCardArtwork($artworkHeight)
            VStack(alignment: .leading, spacing: 1) {
                Text(extra.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(dynamicTypeSize.lineLimit(1))
                Text(extra.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.lineLimit(1))
            }
            .modifier(CardCaptionStyle(artworkHeight: artworkHeight))
        }
        .contentShape(.rect)
        #if os(macOS)
        .help(extra.name)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(extra.name)
        .accessibilityValue(extra.detail)
        .accessibilityIdentifier("extra.\(extra.name)")
    }

    private var isWeb: Bool {
        if case .web = extra { true } else { false }
    }

    private var pictureURL: URL? {
        if case .video(let video) = extra, let tag = video.primaryImageTag {
            return session?.client.imageURL(itemId: video.id, tag: tag, maxWidth: 800)
        }
        return session?.backdrop(title, width: 800) ?? session?.landscape(title)
    }
}
