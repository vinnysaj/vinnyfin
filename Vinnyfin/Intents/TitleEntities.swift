import AppIntents
import CoreTransferable
import Foundation
import UniformTypeIdentifiers
#if !os(tvOS)
import CoreSpotlight
#endif

// Each entity is the server's item as a list gave it, with the poster Siri, Shortcuts and
// Spotlight show. Its properties are the item's, which Shortcuts offers and Siri reasons with.
// Each goes elsewhere (Siri's "send this to…", the share sheet, another app's assistant) as a
// few lines about it with its Jellyfin web page, as that page's link, and as its poster.

/// A show on the signed-in server, for Siri, Shortcuts and Spotlight.
nonisolated struct ShowEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Show", numericFormat: "\(placeholder: .int) shows")
    static let defaultQuery = ShowQuery()

    /// The show as the server listed it; its page and the player load the rest.
    let item: JellyfinItem
    let poster: URL?
    /// Its page in the server's Jellyfin web app.
    var webpage: URL?

    var id: String { item.id }
    @ComputedProperty(title: "Name") var name: String { item.name }
    @ComputedProperty(title: "Year") var year: Int? { item.productionYear }
    @ComputedProperty(title: "Summary") var overview: String? { item.overview }
    @ComputedProperty(title: "Genres") var genres: [String] { item.genres ?? [] }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: year.map { "\(String($0))" }, image: poster.map { .init(url: $0) })
    }
}

/// A movie on the signed-in server, for Siri, Shortcuts and Spotlight.
nonisolated struct MovieEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Movie", numericFormat: "\(placeholder: .int) movies")
    static let defaultQuery = MovieQuery()

    let item: JellyfinItem
    let poster: URL?
    /// Its page in the server's Jellyfin web app.
    var webpage: URL?

    var id: String { item.id }
    @ComputedProperty(title: "Name") var name: String { item.name }
    @ComputedProperty(title: "Year") var year: Int? { item.productionYear }
    @ComputedProperty(title: "Summary") var overview: String? { item.overview }
    @ComputedProperty(title: "Genres") var genres: [String] { item.genres ?? [] }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: year.map { "\(String($0))" }, image: poster.map { .init(url: $0) })
    }
}

/// An episode of a show on the signed-in server, for Siri, Shortcuts and Spotlight.
nonisolated struct EpisodeEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Episode", numericFormat: "\(placeholder: .int) episodes")
    static let defaultQuery = EpisodeQuery()

    let item: JellyfinItem
    /// The show's, which says which show it is better than the episode's still.
    let poster: URL?
    /// Its page in the server's Jellyfin web app.
    var webpage: URL?

    var id: String { item.id }
    @ComputedProperty(title: "Name") var name: String { item.name }
    @ComputedProperty(title: "Show") var show: String { item.seriesName ?? "" }
    @ComputedProperty(title: "Season") var season: Int? { item.parentIndexNumber }
    @ComputedProperty(title: "Episode") var number: Int? { item.indexNumber }
    @ComputedProperty(title: "Summary") var overview: String? { item.overview }
    /// "S01E02", when the server numbers it.
    var code: String? { item.episodeCode }

    /// Its name, then which show and where in it: "Pilot", "Severance · S01E01".
    var displayRepresentation: DisplayRepresentation {
        let place = [show, code].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
        return DisplayRepresentation(title: "\(name)", subtitle: "\(place)", image: poster.map { .init(url: $0) })
    }
}

nonisolated extension EntityIdentifier {
    /// The entity of a movie, show or episode, for a page or the player to tell Siri what it
    /// shows. Nil for other items.
    static func title(_ item: JellyfinItem) -> EntityIdentifier? {
        switch item.type {
        case "Movie": EntityIdentifier(for: MovieEntity.self, identifier: item.id)
        case "Series": EntityIdentifier(for: ShowEntity.self, identifier: item.id)
        case "Episode": EntityIdentifier(for: EpisodeEntity.self, identifier: item.id)
        default: nil
        }
    }
}

nonisolated extension ShowEntity {
    init(_ item: JellyfinItem, session: ServerSession) {
        self.init(item: item, poster: session.poster(item, width: ServerTitles.posterWidth), webpage: ServerTitles.webpage(of: item, session: session))
    }
}

nonisolated extension MovieEntity {
    init(_ item: JellyfinItem, session: ServerSession) {
        self.init(item: item, poster: session.poster(item, width: ServerTitles.posterWidth), webpage: ServerTitles.webpage(of: item, session: session))
    }
}

nonisolated extension EpisodeEntity {
    init(_ item: JellyfinItem, session: ServerSession) {
        self.init(item: item, poster: session.seriesPoster(item, width: ServerTitles.posterWidth),
                  webpage: ServerTitles.webpage(of: item, session: session))
    }
}

// MARK: Sharing

extension ShowEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { Data(TitleSharing.text(of: $0.item, page: $0.webpage).utf8) }
        ProxyRepresentation { try TitleSharing.page($0.webpage) }
            .exportingCondition { $0.webpage != nil }
        DataRepresentation(exportedContentType: .jpeg) { try await TitleSharing.picture($0.poster) }
            .exportingCondition { $0.poster != nil }
    }
}

extension MovieEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { Data(TitleSharing.text(of: $0.item, page: $0.webpage).utf8) }
        ProxyRepresentation { try TitleSharing.page($0.webpage) }
            .exportingCondition { $0.webpage != nil }
        DataRepresentation(exportedContentType: .jpeg) { try await TitleSharing.picture($0.poster) }
            .exportingCondition { $0.poster != nil }
    }
}

extension EpisodeEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { Data(TitleSharing.text(of: $0.item, page: $0.webpage).utf8) }
        ProxyRepresentation { try TitleSharing.page($0.webpage) }
            .exportingCondition { $0.webpage != nil }
        DataRepresentation(exportedContentType: .jpeg) { try await TitleSharing.picture($0.poster) }
            .exportingCondition { $0.poster != nil }
    }
}

/// What a title's entity hands elsewhere.
nonisolated enum TitleSharing {
    /// Its name, what it is, its summary and its web page, a line each: "Copperline (2019)",
    /// "Movie · Western, Drama", …; an episode's show and number come after its name.
    static func text(of item: JellyfinItem, page: URL?) -> String {
        let name: String
        let kind: String
        if item.isEpisode {
            name = [item.name, [item.seriesName, item.episodeCode].compactMap(\.self).joined(separator: " ")]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            kind = "Episode"
        } else {
            name = item.titleWithYear
            kind = item.isSeries ? "Show" : "Movie"
        }
        let facts = [kind, item.genres.map { $0.prefix(3).joined(separator: ", ") }].compactMap(\.self).filter { !$0.isEmpty }
        return [name, facts.joined(separator: " · "), item.overview, page?.absoluteString]
            .compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func page(_ page: URL?) throws -> URL {
        guard let page else { throw CocoaError(.fileNoSuchFile) }
        return page
    }

    /// The poster's bytes, from the server, or from the file a download saved.
    static func picture(_ poster: URL?) async throws -> Data {
        guard let poster else { throw CocoaError(.fileNoSuchFile) }
        if poster.isFileURL { return try Data(contentsOf: poster) }
        let (data, response) = try await URLSession.shared.data(from: poster)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

#if !os(tvOS)
/// What Spotlight searches besides the name: the summary, the genres and, for an episode, its
/// show. The name and the picture come from the display representation.
extension ShowEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = spotlightDescription(["Show", year.map(String.init), genres.first], overview: overview)
        attributes.keywords = genres + ["show", "TV"]
        attributes.genre = genres.first
        return attributes
    }
}

extension MovieEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = spotlightDescription(["Movie", year.map(String.init), genres.first], overview: overview)
        attributes.keywords = genres + ["movie", "film"]
        attributes.genre = genres.first
        return attributes
    }
}

extension EpisodeEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = spotlightDescription(["Episode", show, code], overview: overview)
        attributes.keywords = [show, code, "episode"].compactMap(\.self).filter { !$0.isEmpty }
        return attributes
    }
}

/// What a title is, "Movie · 2019 · Western", on the line before its summary: a result shows
/// the description in place of the display representation's subtitle, which would say the year.
nonisolated private func spotlightDescription(_ facts: [String?], overview: String?) -> String {
    let line = facts.compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
    return [line, overview].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n")
}
#endif

// MARK: Queries

// A query asks the server. While the server can't be reached, it finds what the sign-in in use
// downloaded instead (`OfflineTitles`), so a downloaded title's Spotlight result, or a shortcut
// that plays it, still opens its page or plays its file.

/// Finds shows by name and by id, and suggests the ones being watched.
struct ShowQuery: EntityStringQuery {
    @Dependency private var accounts: AccountStore
    #if !os(tvOS)
    @Dependency private var spotlight: SpotlightTitles
    @Dependency private var downloads: DownloadManager
    #endif

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ShowEntity] {
        let session = try ServerTitles.session(accounts)
        do {
            return try await ServerTitles.items(ids: identifiers, type: "Series", session: session).map { ShowEntity($0, session: session) }
        } catch where ServerTitles.isUnreachable(error) {
            #if os(tvOS)
            throw error
            #else
            return OfflineTitles.items(ids: identifiers, type: "Series", in: downloads.jobs, of: session.account)
                .map { ShowEntity(item: $0, poster: downloads.artworkURL(itemId: $0.id, kind: .primary), webpage: ServerTitles.webpage(of: $0, session: session)) }
            #endif
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ShowEntity] {
        let session = try ServerTitles.session(accounts)
        return try await ServerTitles.search(string, type: "Series", session: session).map { ShowEntity($0, session: session) }
    }

    /// The shows with a next episode to watch, else the newest.
    @MainActor
    func suggestedEntities() async throws -> [ShowEntity] {
        let session = try ServerTitles.session(accounts)
        var seriesIds: [String] = []
        for episode in try await session.client.upNext(userId: session.userId, limit: ServerTitles.suggestionLimit).items {
            if let seriesId = episode.seriesId, !seriesIds.contains(seriesId) { seriesIds.append(seriesId) }
        }
        let shows = seriesIds.isEmpty
            ? try await ServerTitles.newest(.recentlyAddedShows, session: session)
            : try await ServerTitles.items(ids: seriesIds, type: "Series", session: session)
        return shows.map { ShowEntity($0, session: session) }
    }
}

/// Finds movies by name and by id, and suggests the newest.
struct MovieQuery: EntityStringQuery {
    @Dependency private var accounts: AccountStore
    #if !os(tvOS)
    @Dependency private var spotlight: SpotlightTitles
    @Dependency private var downloads: DownloadManager
    #endif

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MovieEntity] {
        let session = try ServerTitles.session(accounts)
        do {
            return try await ServerTitles.items(ids: identifiers, type: "Movie", session: session).map { MovieEntity($0, session: session) }
        } catch where ServerTitles.isUnreachable(error) {
            #if os(tvOS)
            throw error
            #else
            return OfflineTitles.items(ids: identifiers, type: "Movie", in: downloads.jobs, of: session.account)
                .map { MovieEntity(item: $0, poster: downloads.artworkURL(itemId: $0.id, kind: .primary), webpage: ServerTitles.webpage(of: $0, session: session)) }
            #endif
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MovieEntity] {
        let session = try ServerTitles.session(accounts)
        return try await ServerTitles.search(string, type: "Movie", session: session).map { MovieEntity($0, session: session) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MovieEntity] {
        let session = try ServerTitles.session(accounts)
        return try await ServerTitles.newest(.recentlyAddedMovies, session: session).map { MovieEntity($0, session: session) }
    }
}

/// Finds episodes by name and by id, and suggests the next ones to watch.
struct EpisodeQuery: EntityStringQuery {
    @Dependency private var accounts: AccountStore
    #if !os(tvOS)
    @Dependency private var spotlight: SpotlightTitles
    @Dependency private var downloads: DownloadManager
    #endif

    @MainActor
    func entities(for identifiers: [String]) async throws -> [EpisodeEntity] {
        let session = try ServerTitles.session(accounts)
        do {
            return try await ServerTitles.items(ids: identifiers, type: "Episode", session: session).map { EpisodeEntity($0, session: session) }
        } catch where ServerTitles.isUnreachable(error) {
            #if os(tvOS)
            throw error
            #else
            return OfflineTitles.items(ids: identifiers, type: "Episode", in: downloads.jobs, of: session.account).map { episode in
                let poster = episode.seriesId.flatMap { downloads.artworkURL(itemId: $0, kind: .primary) }
                    ?? downloads.artworkURL(itemId: episode.id, kind: .primary)
                return EpisodeEntity(item: episode, poster: poster, webpage: ServerTitles.webpage(of: episode, session: session))
            }
            #endif
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [EpisodeEntity] {
        let session = try ServerTitles.session(accounts)
        return try await ServerTitles.search(string, type: "Episode", session: session).map { EpisodeEntity($0, session: session) }
    }

    @MainActor
    func suggestedEntities() async throws -> [EpisodeEntity] {
        let session = try ServerTitles.session(accounts)
        return try await session.client.upNext(userId: session.userId, limit: ServerTitles.suggestionLimit).items
            .filter(\.isEpisode).map { EpisodeEntity($0, session: session) }
    }
}

#if !os(tvOS)
// Spotlight asks for a kind's entries again when it lost them. There is one index, so which one
// it names doesn't matter, and the description, which can't go to the main actor, stays here.

extension ShowQuery: IndexedEntityQuery {
    nonisolated func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        try await reindex(identifiers)
    }

    nonisolated func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await reindex(nil)
    }

    private func reindex(_ ids: [String]?) async throws {
        try await spotlight.reindex(.show, ids: ids)
    }
}

extension MovieQuery: IndexedEntityQuery {
    nonisolated func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        try await reindex(identifiers)
    }

    nonisolated func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await reindex(nil)
    }

    private func reindex(_ ids: [String]?) async throws {
        try await spotlight.reindex(.movie, ids: ids)
    }
}

extension EpisodeQuery: IndexedEntityQuery {
    nonisolated func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        try await reindex(identifiers)
    }

    nonisolated func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await reindex(nil)
    }

    private func reindex(_ ids: [String]?) async throws {
        try await spotlight.reindex(.episode, ids: ids)
    }
}

/// The titles the sign-in in use downloaded, as the queries find them while the server can't be
/// reached: a movie or an episode as its download saved it, and a show as its downloaded
/// episodes name it. Another sign-in's downloads are never among them.
nonisolated enum OfflineTitles {
    /// Those of `ids` that are of `type` ("Movie", "Series" or "Episode"), in the order asked for.
    static func items(ids: [String], type: String, in jobs: [DownloadJob], of account: AccountStore.Account) -> [JellyfinItem] {
        let saved = jobs.filter { $0.belongs(to: account) }.compactMap(\.item)
        return ids.compactMap { id in
            guard type == "Series" else { return saved.first { $0.id == id && $0.type == type } }
            guard let episode = saved.first(where: { $0.seriesId == id }) else { return nil }
            var show = JellyfinItem(id: id, name: episode.seriesName ?? "", type: "Series")
            show.imageTags = episode.seriesPrimaryImageTag.map { ["Primary": $0] }
            return show
        }
    }
}
#endif

/// The signed-in server's titles, as the entity queries ask for them.
enum ServerTitles {
    static let searchLimit = 25
    static let suggestionLimit = 20
    /// Small enough for Siri's and Shortcuts' lists.
    nonisolated static let posterWidth = 200

    static func session(_ accounts: AccountStore) throws -> ServerSession {
        guard let session = accounts.session else { throw PlaybackError.notSignedIn }
        return session
    }

    /// The item's page in the server's Jellyfin web app.
    nonisolated static func webpage(of item: JellyfinItem, session: ServerSession) -> URL? {
        Handoff.webpageURL(itemId: item.id, serverId: session.account.serverId, address: session.account.serverURL)
    }

    /// The server couldn't be reached: this device is offline, or the server is off or on another
    /// network. A server that answered with an error isn't out of reach.
    nonisolated static func isUnreachable(_ error: any Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                .timedOut, .internationalRoamingOff, .dataNotAllowed, .callIsActive].contains(code)
    }

    static func items(ids: [String], type: String, session: ServerSession) async throws -> [JellyfinItem] {
        guard !ids.isEmpty else { return [] }
        var query = JellyfinClient.ItemQuery(types: [type])
        query.ids = ids
        return try await session.client.items(userId: session.userId, query).items
    }

    /// The newest titles of a kind, as many as a list of suggestions shows.
    static func newest(_ query: JellyfinClient.ItemQuery, session: ServerSession) async throws -> [JellyfinItem] {
        var query = query
        query.limit = suggestionLimit
        return try await session.client.items(userId: session.userId, query).items
    }

    static func search(_ term: String, type: String, session: ServerSession) async throws -> [JellyfinItem] {
        try await search(term, types: [type], session: session)
    }

    static func search(_ term: String, types: [String], session: ServerSession) async throws -> [JellyfinItem] {
        var query = JellyfinClient.ItemQuery(types: types)
        query.searchTerm = term
        query.limit = searchLimit
        return try await session.client.items(userId: session.userId, query).items
    }
}
