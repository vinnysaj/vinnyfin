import SwiftUI

/// What Search shows before anything is typed: what was searched for last, the libraries the
/// tabs don't reach (see `LibraryShortcuts`), and every genre as a tile. Its sections go in the
/// page's stack of rows.
struct SearchLanding: View {
    let recentSearches: [String]
    let libraries: [JellyfinItem]
    let genres: GenreTiles
    /// Searches for a recent search again.
    let search: (String) -> Void
    let forget: (String) -> Void
    let forgetAll: () -> Void
    #if os(tvOS)
    let rowLayout: RowPageLayout
    #endif
    /// The server answers, so its libraries and genres are there to browse.
    var browsesServer = true
    @Environment(\.session) private var session

    var body: some View {
        if !recentSearches.isEmpty {
            recents
        }
        if browsesServer {
            server
        }
    }

    /// The libraries the tabs don't reach, and the genres.
    @ViewBuilder private var server: some View {
        if !libraries.isEmpty {
            Shelf(title: "Libraries", items: libraries, cardWidth: Metrics.landscapeWidth) { library in
                NavigationLink(value: BrowseList.library(library)) { LandscapeCard(item: library) }
                    .buttonStyle(.artwork)
            }
            #if os(tvOS)
            .pageRow("libraries", in: rowLayout)
            #endif
        }
        genreTiles
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Searches")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear", action: forgetAll)
                    #if os(tvOS)
                    .buttonStyle(.platformGlass)
                    #endif
                    .accessibilityLabel("Clear Recent Searches")
                    .accessibilityIdentifier("search.clearRecents")
            }
            .padding(.horizontal, Metrics.edge)
            ScrollView(.horizontal) {
                HStack(spacing: chipSpacing) {
                    ForEach(recentSearches, id: \.self) { term in
                        Button {
                            search(term)
                        } label: {
                            Label(term, systemImage: "clock.arrow.circlepath")
                        }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.platformGlass)
                        .contextMenu {
                            Button("Remove", systemImage: "xmark", role: .destructive) { forget(term) }
                        }
                        .accessibilityHint("Searches for it again")
                        .accessibilityIdentifier("search.recent.\(term)")
                    }
                }
                #if os(tvOS)
                // Room for a chip to grow under focus.
                .padding(.vertical, 20)
                #endif
            }
            .contentMargins(.horizontal, Metrics.edge, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private var chipSpacing: CGFloat {
        #if os(tvOS)
        24
        #else
        8
        #endif
    }

    /// Every genre with titles, A to Z, in as many columns as fit.
    @ViewBuilder private var genreTiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Genres")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let found = genres.genres {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.gridSpacing) {
                    ForEach(found) { genre in
                        NavigationLink(value: BrowseList.genre(genre.name)) {
                            GenreTile(genre: genre, artwork: genres.artwork[genre.name])
                        }
                        .buttonStyle(.artwork)
                        .onAppear { genres.show(genre.name) }
                    }
                }
            } else if let problem = genres.problem {
                HStack(spacing: 12) {
                    Label("Genres couldn't load: \(problem)", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        guard let session else { return }
                        Task { await genres.load(session: session) }
                    }
                    .buttonStyle(.platformGlass)
                }
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.gridSpacing) {
                    ForEach(0..<6, id: \.self) { _ in
                        Color.clear
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .background(.quaternary, in: .rect(cornerRadius: Metrics.cardRadius))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading")
            }
        }
        .padding(.horizontal, Metrics.edge)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: GenreTile.minimumWidth), spacing: Metrics.gridSpacing, alignment: .top)]
    }
}
