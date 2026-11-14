import Foundation
import Observation

/// The genres Search's landing page offers to browse, each a tile with a backdrop of one of its
/// best rated titles. The genres load at once; a tile's picture loads as the tile comes on screen,
/// a few at a time.
@MainActor @Observable
final class GenreTiles {
    /// A genre with how many movies and shows have it.
    nonisolated struct Genre: Hashable, Sendable, Identifiable {
        let name: String
        let count: Int

        var id: String { name }
    }

    /// Requests at once for the tiles' titles.
    static let width = 3
    /// Titles asked for to find one with a backdrop that no other tile shows.
    static let candidates = 8

    /// The genres, A to Z, once loaded.
    private(set) var genres: [Genre]?
    /// Why the genres couldn't be loaded.
    private(set) var problem: String?
    /// The title each tile's picture is from, once found.
    private(set) var artwork: [String: JellyfinItem] = [:]

    @ObservationIgnored private var session: ServerSession?
    /// Genres whose titles were asked for, so a tile coming back on screen doesn't ask again.
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private lazy var queue = LoadQueue<String>(width: Self.width) { [weak self] genre in
        await self?.loadArtwork(for: genre)
    }

    /// Loads the genres, unless they're in: the landing page comes and goes as a search is typed
    /// and cleared, and they rarely change while the app is open.
    func load(session: ServerSession) async {
        guard genres == nil else { return }
        self.session = session
        do {
            let found = try await session.client.genres(userId: session.userId, types: ["Movie", "Series"], withCounts: true)
            genres = Self.genres(from: found)
            problem = nil
        } catch {
            if !error.isCancellation { problem = error.localizedDescription }
        }
    }

    /// The genres that have titles, with how many.
    nonisolated static func genres(from items: [JellyfinItem]) -> [Genre] {
        items.compactMap { genre in
            let count = (genre.movieCount ?? 0) + (genre.seriesCount ?? 0)
            return count > 0 ? Genre(name: genre.name, count: count) : nil
        }
    }

    /// A tile came on screen: its picture loads, if it hasn't.
    func show(_ genre: String) {
        guard !asked.contains(genre) else { return }
        queue.want([genre])
    }

    private func loadArtwork(for genre: String) async {
        guard let session, case .items(var query) = BrowseList.genre(genre).source else { return }
        query.limit = Self.candidates
        do {
            let titles = try await session.client.items(userId: session.userId, query).items
            asked.insert(genre)
            let taken = Set(artwork.values.map(\.id))
            if let pick = Self.pick(from: titles, taken: taken) { artwork[genre] = pick }
        } catch {
            // A tile without its picture still shows its genre and leads to it; it asks again
            // the next time it comes on screen.
        }
    }

    /// The best rated title with a backdrop that no other tile shows, else the best rated with
    /// one at all.
    nonisolated static func pick(from titles: [JellyfinItem], taken: Set<String>) -> JellyfinItem? {
        let pictured = titles.filter { $0.backdropImageTags?.isEmpty == false }
        return pictured.first { !taken.contains($0.id) } ?? pictured.first
    }
}
