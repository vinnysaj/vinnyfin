import AppIntents
import Foundation

// Playing needs the app in front. Each play intent starts in the background, where it works out
// what to play and Siri can say why there's nothing, then brings the app forward and hands the
// title to the root view as a vinnyfin://play link, which plays it the way the app's own Play
// buttons do: the version played last, from where it got to.

/// Plays a movie from where it was left.
struct PlayMovieIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Movie"
    static let description = IntentDescription("Plays a movie from where you left it, in the version you played last.")
    static let supportedModes: IntentModes = .foreground(.deferred)

    @Parameter(title: "Movie")
    var movie: MovieEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$movie)")
    }

    @Dependency private var accounts: AccountStore
    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try ServerTitles.session(accounts)
        try await continueInForeground(alwaysConfirm: false)
        links.open(AppLink(.play, movie.item))
        return .result()
    }
}

/// Plays an episode from where it was left.
struct PlayEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Episode"
    static let description = IntentDescription("Plays an episode from where you left it.")
    static let supportedModes: IntentModes = .foreground(.deferred)

    @Parameter(title: "Episode")
    var episode: EpisodeEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$episode)")
    }

    @Dependency private var accounts: AccountStore
    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try ServerTitles.session(accounts)
        try await continueInForeground(alwaysConfirm: false)
        links.open(AppLink(.play, episode.item))
        return .result()
    }
}

/// Picks a show up where it was left, as its page's Play button does.
struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Plays the episode of a show you're partway through from where you left it, or else the next one to watch.")
    static let supportedModes: IntentModes = .foreground(.deferred)

    @Parameter(title: "Show")
    var show: ShowEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Continue watching \(\.$show)")
    }

    @Dependency private var accounts: AccountStore
    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        let session = try ServerTitles.session(accounts)
        let episode = try await ShowEpisodes.upNext(of: show, session: session)
        try await continueInForeground(alwaysConfirm: false)
        links.open(AppLink(.play, episode))
        return .result()
    }
}

/// Moves on to a show's next episode.
struct PlayNextEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Next Episode"
    static let description = IntentDescription("Plays the episode after the one you're partway through, or the next one to watch when you're not partway through one.")
    static let supportedModes: IntentModes = .foreground(.deferred)

    @Parameter(title: "Show")
    var show: ShowEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play the next episode of \(\.$show)")
    }

    @Dependency private var accounts: AccountStore
    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        let session = try ServerTitles.session(accounts)
        let upNext = try await ShowEpisodes.upNext(of: show, session: session)
        let episode = try await ShowEpisodes.next(after: upNext, of: show, session: session)
        try await continueInForeground(alwaysConfirm: false)
        links.open(AppLink(.play, episode))
        return .result()
    }
}

/// The system's way to play a video by what someone calls it: "Play Severance in vinnyfin".
/// A movie plays from where it was left, a show from the episode it's up to.
struct PlayVideoByNameIntent: PlayVideoIntent {
    static let title: LocalizedStringResource = "Play by Name"
    static let description = IntentDescription("Finds a movie or show on your server by name and plays it: a movie from where you left it, a show from the episode you're up to.")
    static let supportedCategories: [VideoCategory] = [.movies, .tv]
    static let supportedModes: IntentModes = .foreground(.deferred)

    @Parameter(title: "Name")
    var term: String

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$term)")
    }

    @Dependency private var accounts: AccountStore
    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        let session = try ServerTitles.session(accounts)
        let found = try await ServerTitles.search(term, types: ["Movie", "Series"], session: session)
        guard let title = TitleMatch.best(for: term, among: found) else { throw TitleIntentError.notFound(term) }
        let item = title.isSeries
            ? try await ShowEpisodes.upNext(of: ShowEntity(title, session: session), session: session)
            : title
        try await continueInForeground(alwaysConfirm: false)
        links.open(AppLink(.play, item))
        return .result()
    }
}

// Spotlight opens a result through the open intent whose target is the result's entity type, so
// each type has one.

#if !os(tvOS)
@AppIntent(schema: .system.open)
#endif
struct OpenMovieIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Movie"
    static let description = IntentDescription("Shows a movie's page.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Movie")
    var target: MovieEntity

    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        links.open(AppLink(.open, target.item))
        return .result()
    }
}

#if !os(tvOS)
@AppIntent(schema: .system.open)
#endif
struct OpenShowIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Show"
    static let description = IntentDescription("Shows a show's page, with its seasons and episodes.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Show")
    var target: ShowEntity

    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        links.open(AppLink(.open, target.item))
        return .result()
    }
}

#if !os(tvOS)
@AppIntent(schema: .system.open)
#endif
struct OpenEpisodeIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Episode"
    static let description = IntentDescription("Shows an episode's page.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Episode")
    var target: EpisodeEntity

    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        links.open(AppLink(.open, target.item))
        return .result()
    }
}

/// Which of a show's episodes the playback intents play.
enum ShowEpisodes {
    /// The episode partway through and played last, else the next one to watch: what the show's
    /// page offers to play.
    static func upNext(of show: ShowEntity, session: ServerSession) async throws -> JellyfinItem {
        guard let episode = try await session.client.upNext(seriesId: show.id, userId: session.userId) else {
            throw TitleIntentError.caughtUp(show.name)
        }
        return episode
    }

    /// The episode to move on to from `upNext`: the one after it when it's partway through, else
    /// `upNext` itself, which nothing of has been watched.
    static func next(after upNext: JellyfinItem, of show: ShowEntity, session: ServerSession) async throws -> JellyfinItem {
        guard isPartway(upNext) else { return upNext }
        guard let next = try await session.client.episode(after: upNext.id, seriesId: show.id, userId: session.userId) else {
            throw TitleIntentError.nothingAfter(show: show.name, episode: upNext.episodeCode ?? upNext.name)
        }
        return next
    }

    nonisolated static func isPartway(_ episode: JellyfinItem) -> Bool {
        episode.resumeSeconds != nil
    }
}

/// Picks the title someone named from the server's search results.
nonisolated enum TitleMatch {
    /// The title named exactly, ignoring case and accents, with or without its year; else the
    /// shortest name that contains what was said; else the server's first.
    static func best(for term: String, among titles: [JellyfinItem]) -> JellyfinItem? {
        let said = normalized(term)
        if let exact = titles.first(where: { normalized($0.name) == said || normalized($0.titleWithYear) == said }) {
            return exact
        }
        let containing = titles.filter { normalized($0.name).contains(said) }
        return containing.min { $0.name.count < $1.name.count } ?? titles.first
    }

    private static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

/// Why a playback intent has nothing to play, for Siri to say.
nonisolated enum TitleIntentError: LocalizedError {
    /// Nothing to watch comes after the last episode watched (see `UpNext`).
    case caughtUp(String)
    case nothingAfter(show: String, episode: String)
    case notFound(String)
    /// Continue Watching is empty.
    case nothingToContinue

    var errorDescription: String? {
        switch self {
        case .caughtUp(let show): "You're caught up on \(show): there's no episode after the last one you watched."
        case .nothingAfter(let show, let episode): "\(show) has no episode after \(episode)."
        case .notFound(let term): "There's nothing called \(term) on your server."
        case .nothingToContinue: "There's nothing to continue: nothing on your server is partway through or up next."
        }
    }
}

/// The intent that plays a title again, which Siri is given as the title starts to play, so it
/// learns what the person watches and when, and suggests it in Spotlight, on the Lock Screen and
/// in the Smart Stack: an episode continues its show, and a movie plays. Other titles teach it
/// nothing. `SignInSurfaces` forgets them when the sign-in in use changes.
nonisolated enum PlaybackDonation {
    static func intent(for item: JellyfinItem, session: ServerSession) -> (any AppIntent)? {
        switch item.type {
        case "Movie":
            let intent = PlayMovieIntent()
            intent.movie = MovieEntity(item, session: session)
            return intent
        case "Episode":
            guard let seriesId = item.seriesId else { return nil }
            var show = JellyfinItem(id: seriesId, name: item.seriesName ?? "", type: "Series")
            show.imageTags = item.seriesPrimaryImageTag.map { ["Primary": $0] }
            let intent = ContinueWatchingIntent()
            intent.show = ShowEntity(show, session: session)
            return intent
        default:
            return nil
        }
    }

    /// The intents donated, which the sign-in in use's change deletes.
    static let types: [any AppIntent.Type] = [PlayMovieIntent.self, ContinueWatchingIntent.self]

    @MainActor
    static func donate(_ item: JellyfinItem, session: ServerSession) {
        guard let intent = intent(for: item, session: session) else { return }
        IntentDonationManager.shared.donate(intent: intent)
    }
}

#if os(iOS) || os(macOS)
/// The first title of Continue Watching, for the Continue Watching control: the one the Continue
/// Watching widget shows first.
final class ContinueWatchingResumer: WatchingResumer {
    private let accounts: AccountStore
    private let links: IncomingLinks

    init(accounts: AccountStore, links: IncomingLinks) {
        self.accounts = accounts
        self.links = links
    }

    func titleToResume() async throws -> AppLink {
        let session = try ServerTitles.session(accounts)
        let items = try await session.client.page(of: UpNextWidgets.Row.continueWatching.source, userId: session.userId,
                                                  startIndex: 0, limit: ServerTitles.suggestionLimit).items
        guard let tile = UpNextWidgets.tiles(from: items, limit: 1, owner: AppLink.Owner(session.account)).first,
              let link = AppLink(tile.link) else { throw TitleIntentError.nothingToContinue }
        return link
    }

    func play(_ link: AppLink) {
        links.open(link)
    }
}
#endif
