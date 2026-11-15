import SwiftUI

/// Someone in the library: their picture, when and where they were born, their biography, and
/// what they're in: movies, shows, and the episodes of other shows they're in, by show.
struct PersonView: View {
    let person: Person

    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var details: JellyfinItem?
    @State private var filmography: Filmography?
    @State private var loadError: LoadFailure?
    #if os(tvOS)
    /// Where the page's rows are, for holding the focused one in place.
    @State private var rowLayout = RowPageLayout()
    #endif

    var body: some View {
        EdgeToEdgeScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                header
                if let loadError {
                    LoadFailureNotice(loadError) { Task { await load() } }
                        .padding(.horizontal, Metrics.edge)
                }
                if let filmography {
                    rows(filmography)
                } else if loadError == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, Metrics.edge)
            #if os(tvOS)
            .rowPageContent(rowLayout)
            #endif
        }
        #if os(tvOS)
        .rowPage(rowLayout)
        #endif
        .refreshable { await load() }
        .pageBackground()
        .screenTitle(person.name)
        .inlineNavigationTitle()
        .task(id: person.id) { await load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            AdaptiveStack(rowAlignment: .center, spacing: 20) {
                Artwork(url: photoURL, aspectRatio: 1, cornerRadius: 0, placeholder: "person.fill")
                    .clipShape(.circle)
                    .frame(width: photoSize)
                VStack(alignment: .leading, spacing: 4) {
                    Text(details?.name ?? person.name)
                        .font(.title.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(details.map(PersonLife.lines) ?? [], id: \.self) { line in
                        Text(line).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if let details, details.overview?.isEmpty == false {
                OverviewText(item: details)
            }
        }
        .padding(.horizontal, Metrics.edge)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private var photoURL: URL? {
        guard let session else { return nil }
        if let tag = details?.primaryImageTag {
            return session.client.imageURL(itemId: person.id, tag: tag, maxWidth: 600)
        }
        return session.person(person, width: 600)
    }

    private var photoSize: CGFloat {
        #if os(tvOS)
        240
        #elseif os(iOS)
        dynamicTypeSize.isAccessibilitySize ? 160 : 110
        #else
        150
        #endif
    }

    // MARK: Rows

    @ViewBuilder private func rows(_ filmography: Filmography) -> some View {
        if filmography.isEmpty {
            Text("Nothing in your library lists \(person.name).")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.edge)
        }
        if !filmography.movies.isEmpty {
            Shelf(title: "Movies", items: filmography.movies, cardWidth: Metrics.posterWidth) { poster($0) }
                #if os(tvOS)
                .pageRow(Row.movies, in: rowLayout, holding: hold(.movies, in: filmography))
                #endif
        }
        if !filmography.shows.isEmpty {
            Shelf(title: "Shows", items: filmography.shows, cardWidth: Metrics.posterWidth) { poster($0) }
                #if os(tvOS)
                .pageRow(Row.shows, in: rowLayout, holding: hold(.shows, in: filmography))
                #endif
        }
        if !filmography.episodes.isEmpty {
            Shelf(title: "Episodes", items: filmography.episodes, cardWidth: Metrics.landscapeWidth, placeholderStyle: .landscape) { episode in
                NavigationLink(value: episode) { LandscapeCard(item: episode, leadsWithEpisode: true) }
                    .buttonStyle(.artwork)
                    .titleMenu(episode, onChange: replace)
            }
            #if os(tvOS)
            .pageRow(Row.episodes, in: rowLayout, holding: hold(.episodes, in: filmography))
            #endif
        }
    }

    #if os(tvOS)
    private enum Row: CaseIterable {
        case movies, shows, episodes
    }

    /// Where a row sits with focus in it: the first scrolled only as far as it takes to show all
    /// of it, so the person's picture and name stay in view above it, as focus lands there first.
    private func hold(_ row: Row, in filmography: Filmography) -> RowHold {
        let first = Row.allCases.first { row in
            switch row {
            case .movies: !filmography.movies.isEmpty
            case .shows: !filmography.shows.isEmpty
            case .episodes: !filmography.episodes.isEmpty
            }
        }
        return row == first ? .whole : .top
    }
    #endif

    private func poster(_ item: JellyfinItem) -> some View {
        NavigationLink(value: item) { PosterCard(item: item) }
            .buttonStyle(.artwork)
            .titleMenu(item, onChange: replace)
    }

    /// Swaps in a title whose watch state changed from its menu.
    private func replace(_ updated: JellyfinItem) {
        guard var changed = filmography else { return }
        for path in [\Filmography.movies, \.shows, \.episodes] {
            if let index = changed[keyPath: path].firstIndex(where: { $0.id == updated.id }) { changed[keyPath: path][index] = updated }
        }
        filmography = changed
    }

    // MARK: Loading

    private func load() async {
        guard let session else { return }
        do {
            async let details = session.client.person(id: person.id, userId: session.userId)
            async let filmography = Filmography.load(personId: person.id, client: session.client, userId: session.userId)
            self.filmography = try await filmography
            self.details = try await details
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            loadError = LoadFailure("Couldn't Load \(person.name)", error: error)
        }
    }
}
