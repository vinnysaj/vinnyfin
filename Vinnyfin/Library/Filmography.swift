import Foundation

/// What someone is in, in the library: the movies, the shows they're credited on as a whole, and
/// the episodes of other shows, as a guest star or a director or writer of an episode, grouped by
/// show. The server credits a guest only on the episodes they're in, not on the show.
nonisolated struct Filmography: Equatable, Sendable {
    /// The newest first.
    var movies: [JellyfinItem] = []
    /// The newest first.
    var shows: [JellyfinItem] = []
    /// The show with the newest of them first, each show's in its order.
    var episodes: [JellyfinItem] = []

    var isEmpty: Bool { movies.isEmpty && shows.isEmpty && episodes.isEmpty }

    /// Everything someone is credited on, the newest first.
    static func query(personId: String) -> JellyfinClient.ItemQuery {
        var query = JellyfinClient.ItemQuery(types: ["Movie", "Series", "Episode"])
        query.personIds = [personId]
        query.sortBy = "PremiereDate"
        query.ascending = false
        query.fields = "PrimaryImageAspectRatio"
        return query
    }

    /// Sorts what the server credits someone on, as `query(personId:)` lists it, newest first.
    /// An episode of a show they're credited on as a whole is that show's, and isn't listed on its own.
    init(credits items: [JellyfinItem]) {
        movies = items.filter(\.isMovie)
        shows = items.filter(\.isSeries)
        let showIds = Set(shows.map(\.id))
        let episodes = items.filter { $0.isEpisode && !showIds.contains($0.seriesId ?? $0.id) }
        // Shows in the order of their newest episode, which is the order they first come in.
        var order: [String] = []
        for episode in episodes where !order.contains(episode.seriesId ?? "") { order.append(episode.seriesId ?? "") }
        self.episodes = episodes.enumerated()
            .sorted { left, right in
                let leftShow = order.firstIndex(of: left.element.seriesId ?? "") ?? 0
                let rightShow = order.firstIndex(of: right.element.seriesId ?? "") ?? 0
                if leftShow != rightShow { return leftShow < rightShow }
                let leftNumber = (left.element.parentIndexNumber ?? 0, left.element.indexNumber ?? 0)
                let rightNumber = (right.element.parentIndexNumber ?? 0, right.element.indexNumber ?? 0)
                return leftNumber != rightNumber ? leftNumber < rightNumber : left.offset < right.offset
            }
            .map(\.element)
    }

    static func load(personId: String, client: JellyfinClient, userId: String) async throws -> Filmography {
        Filmography(credits: try await client.items(userId: userId, query(personId: personId)).items)
    }
}

/// What a person's page says of their life: "Born May 2, 1972 in Kingston, Jamaica", "Died June 1, 2020".
nonisolated enum PersonLife {
    static func lines(of person: JellyfinItem) -> [String] {
        var lines: [String] = []
        let place = person.productionLocations?.first { !$0.isEmpty }
        if let born = person.premiere {
            lines.append("Born \(JellyfinDate.day(born))" + (place.map { " in \($0)" } ?? ""))
        } else if let place {
            lines.append("Born in \(place)")
        }
        if let died = person.endDate.flatMap(JellyfinDate.parse) {
            lines.append("Died \(JellyfinDate.day(died))")
        }
        return lines
    }
}
