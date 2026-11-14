import Foundation

/// A list to browse in full, in a grid: a library, everything a Home row samples, a collection.
nonisolated struct BrowseList: Hashable, Sendable {
    enum Style: Hashable, Sendable {
        /// Posters, for movies and shows.
        case poster
        /// 16:9 stills, for episodes, videos and what's in progress.
        case landscape
    }

    let title: String
    let source: JellyfinClient.ItemSource
    var style = Style.poster
    /// What the grid keeps this list's sort and filter under from one launch to the next, for
    /// each sign-in: set for the Movies and Shows tabs, nil for a list opened from another
    /// screen, which starts from its own each time.
    var refinementsKey: String?

    static let movies = BrowseList(title: "Movies", source: .items(.init(types: ["Movie"])), refinementsKey: "movies")
    static let shows = BrowseList(title: "Shows", source: .items(.init(types: ["Series"])), refinementsKey: "shows")

    /// The item types of videos that are neither movies nor episodes: home videos and music videos.
    static let videoTypes = ["Video", "MusicVideo"]

    /// What the server finds most like a title, or an episode's show.
    static func moreLike(_ item: JellyfinItem) -> BrowseList {
        BrowseList(title: "More Like \(item.titleName)", source: .similar(toItemId: item.titleId))
    }

    /// The movies and shows someone is in, the newest first.
    static func titles(with person: Person) -> BrowseList {
        var query = JellyfinClient.ItemQuery(types: ["Movie", "Series"])
        query.personIds = [person.id]
        query.sortBy = "PremiereDate"
        query.ascending = false
        return BrowseList(title: person.name, source: .items(query))
    }

    /// A collection's titles, oldest first.
    static func collection(_ item: JellyfinItem) -> BrowseList {
        var query = JellyfinClient.ItemQuery(types: ["Movie", "Series"])
        query.parentId = item.id
        query.sortBy = "PremiereDate"
        return BrowseList(title: item.name, source: .items(query))
    }

    /// A genre's movies and shows together, the best rated first, named for the genre. Leaving out
    /// `itemId`, it's the genre's other titles, as a title's page shows in place of the server's
    /// similar titles when it finds none.
    static func genre(_ name: String, excluding itemId: String? = nil) -> BrowseList {
        var query = JellyfinClient.ItemQuery(types: ["Movie", "Series"])
        query.genres = [name]
        query.sortBy = "CommunityRating"
        query.ascending = false
        query.fields = JellyfinClient.cardFields
        if let itemId { query.excludeIds = [itemId] }
        return BrowseList(title: name, source: .items(query))
    }

    /// Everything in one of the server's libraries, by name: its movies, shows or videos, or for a
    /// library of mixed content, all of those.
    static func library(_ library: JellyfinItem) -> BrowseList {
        var query = JellyfinClient.ItemQuery(types: types(inLibraryOf: library.collectionType))
        query.parentId = library.id
        query.fields = JellyfinClient.cardFields
        let holdsVideos = Set(query.types).isSubset(of: videoTypes)
        return BrowseList(title: library.name, source: .items(query), style: holdsVideos ? .landscape : .poster)
    }

    /// The item types a library of `collectionType` lists as its titles.
    static func types(inLibraryOf collectionType: String?) -> [String] {
        switch collectionType {
        case "movies": ["Movie"]
        case "tvshows": ["Series"]
        case "homevideos": ["Video"]
        case "musicvideos": ["MusicVideo"]
        default: ["Movie", "Series"] + videoTypes
        }
    }

    /// The SF Symbol for what the list holds.
    var symbol: String {
        guard case .items(let query) = source else { return style == .landscape ? "play.rectangle" : "film" }
        switch query.types {
        case ["Series"]: return "tv"
        case ["BoxSet"]: return "square.stack"
        case ["Video"]: return "video"
        case ["MusicVideo"]: return "music.note.tv"
        default: return query.genres.isEmpty ? "film" : "theatermasks"
        }
    }
}
