import SwiftUI

/// Genres as a row of small glass chips, each leading to its genre's movies and shows
/// (`BrowseList.genre(_:excluding:)`), for a navigation stack with `itemDestinations()`. Other
/// chips can lead the row, as a title's collections do.
struct GenreChips<Leading: View>: View {
    let genres: [String]
    let leading: Leading

    init(genres: [String], @ViewBuilder leading: () -> Leading) {
        self.genres = genres
        self.leading = leading()
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: chipSpacing) {
                leading
                ForEach(genres, id: \.self) { genre in
                    NavigationLink(value: BrowseList.genre(genre)) {
                        Text(genre)
                    }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.platformGlass)
                    .accessibilityHint("Shows its movies and shows")
                    .accessibilityIdentifier("genreChip.\(genre)")
                }
            }
            #if os(tvOS)
            // Room for a chip to grow under focus.
            .padding(.vertical, 20)
            #endif
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private var chipSpacing: CGFloat {
        #if os(tvOS)
        24
        #else
        8
        #endif
    }
}

extension GenreChips where Leading == EmptyView {
    init(genres: [String]) {
        self.init(genres: genres) { EmptyView() }
    }
}
