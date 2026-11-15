import SwiftUI

/// What a title's page leads to around it: titles like it, its genres and the collections it's
/// in. For an episode, those of its show.
nonisolated struct RelatedTitles: Equatable, Sendable {
    /// The movie or show they're of (`JellyfinItem.titleId`); nil until they've loaded.
    var titleId: String?
    /// The titles More Like This shows.
    var similar: [JellyfinItem] = []
    /// The whole list `similar` begins: the titles the server finds like it, or when it finds
    /// none, the best rated others of a genre of its.
    var similarList: BrowseList?
    /// The title's genres, or an episode's show's when it has none of its own, as they usually don't.
    var genres: [String] = []
    var collections: [JellyfinItem] = []

    /// The genres `item`'s page links to: its own, else those loaded for it.
    func genres(of item: JellyfinItem) -> [String] {
        if let own = item.genres, !own.isEmpty { return own }
        return titleId == item.titleId ? genres : []
    }

    /// Everything around `title`, with up to `length` titles like it: the server's, or when it
    /// finds none, the best rated others of the first of its genres that has any. A server that
    /// can't say which collections hold a title has it in none.
    static func load(for title: JellyfinItem, client: JellyfinClient, userId: String, length: Int) async throws -> RelatedTitles {
        let titleId = title.titleId
        async let similar = client.similar(to: titleId, userId: userId, limit: length)
        async let collections = collections(containing: titleId, client: client, userId: userId)
        async let genres = genres(of: title, client: client, userId: userId)
        var related = RelatedTitles(titleId: titleId, genres: await genres, collections: await collections)
        let found = try await similar
        if !found.isEmpty {
            related.similar = found
            related.similarList = .moreLike(title)
            return related
        }
        for genre in related.genres {
            let list = BrowseList.genre(genre, excluding: titleId)
            let page = try await client.page(of: list.source, userId: userId, startIndex: 0, limit: length)
            if !page.items.isEmpty {
                related.similar = page.items
                related.similarList = list
                break
            }
        }
        return related
    }

    private static func collections(containing titleId: String, client: JellyfinClient, userId: String) async -> [JellyfinItem] {
        (try? await client.collections(containing: titleId, userId: userId)) ?? []
    }

    /// `title`'s genres, or for an episode without any, its show's.
    private static func genres(of title: JellyfinItem, client: JellyfinClient, userId: String) async -> [String] {
        if let own = title.genres, !own.isEmpty { return own }
        guard title.isEpisode, let seriesId = title.seriesId else { return [] }
        var query = JellyfinClient.ItemQuery(types: ["Series"])
        query.ids = [seriesId]
        query.fields = "Genres"
        return (try? await client.items(userId: userId, query).items.first?.genres) ?? []
    }
}

/// A title's More Like This: the titles like it, as posters with the title's menu. See All, which
/// lists more of them, is there only when the row may not have them all: the server doesn't say how
/// many it finds like a title, so a row with as many as it asked for may not.
struct MoreLikeThisShelf: View {
    /// How many titles the row asks the server for.
    static let length = 16

    @Binding var related: RelatedTitles

    var body: some View {
        Shelf(title: "More Like This", seeAll: related.similar.count >= Self.length ? related.similarList : nil,
              items: related.similar, cardWidth: Metrics.posterWidth) { other in
            NavigationLink(value: other) { PosterCard(item: other) }
                .buttonStyle(.artwork)
                .titleMenu(other) { updated in
                    if let index = related.similar.firstIndex(where: { $0.id == updated.id }) { related.similar[index] = updated }
                }
        }
    }
}

/// A title's ways into the library around it, as a row of chips: the collections it's in, then
/// its genres.
struct TitleLinks: View {
    let genres: [String]
    let collections: [JellyfinItem]

    var body: some View {
        if !genres.isEmpty || !collections.isEmpty {
            GenreChips(genres: genres) {
                ForEach(collections) { collection in
                    NavigationLink(value: collection) {
                        Label(collection.name, systemImage: "square.stack")
                    }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.platformGlass)
                    .accessibilityLabel("Part of \(collection.name)")
                    .accessibilityHint("Shows the titles in it")
                    .accessibilityIdentifier("collectionChip.\(collection.name)")
                }
            }
            .contentMargins(.horizontal, Metrics.edge, for: .scrollContent)
        }
    }
}
