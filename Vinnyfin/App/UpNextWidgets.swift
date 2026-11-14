#if os(iOS) || os(macOS)
import Foundation
import WidgetKit

/// The widgets of titles on iPhone, iPad and the Mac: Continue Watching, the first titles of
/// Home's row of that name, each playing from where it was left; Recently Added, the newest
/// movies and shows together; and Favorites, as Home's row of that name lists them, A to Z, each
/// of the last two opening its title's page. The widget extension asks the signed-in server for
/// them, with their pictures, each time a widget's timeline reloads; the app has them reload as a
/// playback stops and as the app leaves the foreground, since what was watched and who is signed
/// in may have changed.
nonisolated enum UpNextWidgets {
    /// Which list of titles a widget shows.
    enum Row: String, CaseIterable, Sendable {
        case continueWatching, recentlyAdded, favorites

        /// The widget's kind, by which the app has it reload.
        var kind: String { "net.vinnysaj.vinnyfin.\(rawValue)" }

        var title: String {
            switch self {
            case .continueWatching: "Continue Watching"
            case .recentlyAdded: "Recently Added"
            case .favorites: "Favorites"
            }
        }

        var description: String {
            switch self {
            case .continueWatching: "Movies you're partway through and the next episode of each show you're watching."
            case .recentlyAdded: "The movies and shows added to your server last, a show counting when an episode is."
            case .favorites: "The movies and shows you've marked as favorites."
            }
        }

        /// What the widget says with nothing in the row.
        var emptyMessage: String {
            switch self {
            case .continueWatching: "Nothing to continue."
            case .recentlyAdded: "Nothing has been added yet."
            case .favorites: "No favorites yet. Mark a movie or show as a favorite to see it here."
            }
        }

        /// What the widget says when nobody is signed in.
        var signInMessage: String {
            switch self {
            case .continueWatching: "Sign in to vinnyfin to see what's up next."
            case .recentlyAdded: "Sign in to vinnyfin to see what's new."
            case .favorites: "Sign in to vinnyfin to see your favorites."
            }
        }

        /// The symbol that stands for the row where there's no room for pictures.
        var symbol: String {
            switch self {
            case .continueWatching: "play.fill"
            case .recentlyAdded: "sparkles.tv"
            case .favorites: "star.fill"
            }
        }

        /// Whether a tile plays its title, from where it was left, rather than opening its page.
        var plays: Bool { self == .continueWatching }

        var source: JellyfinClient.ItemSource {
            switch self {
            case .continueWatching:
                return .upNext
            case .recentlyAdded:
                return .recentlyAdded
            case .favorites:
                var query = JellyfinClient.ItemQuery(types: ["Movie", "Series"])
                query.isFavorite = true
                query.fields = JellyfinClient.cardFields
                return .items(query)
            }
        }
    }

    /// Has the system ask the widgets for their titles again.
    static func reload() {
        for row in Row.allCases {
            WidgetCenter.shared.reloadTimelines(ofKind: row.kind)
        }
    }

    /// A title as a widget shows it, with where a tap on it goes.
    struct Tile: Identifiable, Equatable, Sendable {
        let itemId: String
        /// Its show, or the film's name.
        let title: String
        /// As a landscape card says it (`JellyfinItem.cardDetail`).
        let detail: String
        /// How far through it playback got, 0...1.
        let progress: Double?
        /// Plays it from where it was left, as the app's Resume does, or opens its page, as the
        /// row has it (`Row.plays`).
        let link: URL
        /// Its picture as a small JPEG, at the size the widget draws it. Nil without one.
        var artwork: Data?

        var id: String { itemId }

        init(_ item: JellyfinItem, plays: Bool = true) {
            itemId = item.id
            title = item.titleName
            detail = item.cardDetail
            progress = item.progress
            link = AppLink(plays ? .play : .open, item).url
        }
    }

    /// What a widget shows.
    enum Content: Equatable, Sendable {
        /// The row's first titles; none when it's empty.
        case tiles([Tile])
        /// Nobody is signed in.
        case signedOut
        /// The sign-in saved on this device can't be used, as the message says.
        case signInProblem(String)
        /// The server no longer takes the sign-in.
        case sessionEnded(server: String)
        /// The server couldn't be asked, for the reason given.
        case unreachable(server: String, reason: String)
    }

    /// The first `limit` of the row's titles: for a row whose tiles play them, those that play.
    static func tiles(from items: [JellyfinItem], limit: Int, for row: Row = .continueWatching) -> [Tile] {
        items.filter { !row.plays || $0.isPlayable }.prefix(limit).map { Tile($0, plays: row.plays) }
    }

    /// What a widget shows when asking the server failed.
    static func content(for error: any Error, server: String) -> Content {
        if case JellyfinError.http(status: 401, _) = error { return .sessionEnded(server: server) }
        return .unreachable(server: server, reason: error.localizedDescription)
    }

    /// How long a widget's titles stand before it asks again, without the app asking sooner: what
    /// was watched elsewhere shows within the hour.
    static let refreshInterval: TimeInterval = 30 * 60
    /// How soon a widget asks again after the server or the Keychain couldn't be asked.
    static let retryInterval: TimeInterval = 15 * 60

    /// When a widget showing `content` asks again by itself; nil when only the app can change
    /// what it shows, by signing in.
    static func refreshDate(for content: Content, now: Date) -> Date? {
        switch content {
        case .tiles: now.addingTimeInterval(refreshInterval)
        case .signInProblem, .unreachable: now.addingTimeInterval(retryInterval)
        case .signedOut, .sessionEnded: nil
        }
    }

    // MARK: Layout and pictures

    /// How a widget of one family lays its titles out.
    struct Layout: Equatable, Sendable {
        /// How many titles it shows.
        let count: Int
        /// How many side by side.
        let columns: Int
        /// Lock Screen widgets show no pictures.
        let showsPictures: Bool

        /// The space around the titles and between them, in points.
        static let margin: Double = 16
        static let spacing: Double = 12

        init(_ family: WidgetFamily) {
            let shape: (count: Int, columns: Int, showsPictures: Bool) = switch family {
            case .systemSmall: (1, 1, true)
            case .systemMedium: (2, 2, true)
            case .systemLarge: (4, 2, true)
            case .systemExtraLarge: (8, 4, true)
            default: (1, 1, false)
            }
            count = shape.count
            columns = shape.columns
            showsPictures = shape.showsPictures
        }

        /// How wide each title's picture is drawn, in pixels, in a widget `width` points wide on
        /// a screen of `scale`. Nil when it shows none.
        func pictureWidth(inWidgetWidth width: Double, scale: Double) -> Int? {
            guard showsPictures else { return nil }
            let points = (width - 2 * Self.margin - Double(columns - 1) * Self.spacing) / Double(columns)
            return Int((max(1, points) * scale).rounded(.up))
        }
    }

    /// The most bytes of pictures one widget's titles hold together, in its timeline entry.
    static let artworkBudget = 400_000
    static let artworkQuality = 0.75

    /// The tiles with their pictures, in order, as long as they fit `budget` bytes together; a
    /// picture past it is left out, and its tile shows a placeholder.
    static func withArtwork(_ tiles: [Tile], pictures: [String: Data], budget: Int = artworkBudget) -> [Tile] {
        var remaining = budget
        return tiles.map { tile in
            var tile = tile
            if let picture = pictures[tile.itemId], picture.count <= remaining {
                tile.artwork = picture
                remaining -= picture.count
            }
            return tile
        }
    }
}
#endif
