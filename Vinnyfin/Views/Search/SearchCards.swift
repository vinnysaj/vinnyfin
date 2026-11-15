import SwiftUI

/// The title a search most likely looked for, ahead of the rows: its picture, its name, and what
/// it is.
struct TopResultCard: View {
    let item: JellyfinItem
    @Environment(\.session) private var session
    @Environment(\.cardScale) private var cardScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            Artwork(url: session?.landscape(item), aspectRatio: 16.0 / 9.0, placeholder: item.isSeries ? "tv" : "film")
                .frame(width: Self.artworkWidth * cardScale)
                .liftsUnderFocus()
            VStack(alignment: .leading, spacing: 4) {
                Text("Top Result")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(item.name)
                    .font(.title3.weight(.bold))
                    .lineLimit(dynamicTypeSize.lineLimit(2))
                Text(Self.detail(of: item))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.lineLimit(1))
            }
            .multilineTextAlignment(.leading)
            .modifier(CardCaptionStyle())
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue("Top result, \(Self.detail(of: item))")
        .accessibilityIdentifier("search.topResult")
    }

    static var artworkWidth: CGFloat {
        #if os(tvOS)
        470
        #elseif os(macOS)
        240
        #elseif os(visionOS)
        260
        #else
        150
        #endif
    }

    /// What the title is, and from when or from what: "Movie · 2019", "Episode · Port Ellery · S1, E2".
    nonisolated static func detail(of item: JellyfinItem) -> String {
        let kind = switch item.type {
        case "Movie": "Movie"
        case "Series": "Show"
        case "Episode": "Episode"
        case "BoxSet": "Collection"
        case "Video": "Video"
        case "MusicVideo": "Music Video"
        default: item.type
        }
        let rest = item.isEpisode ? [item.seriesName, item.shortEpisodeCode] : [item.premiereYearText]
        return ([kind] + rest.compactMap(\.self)).joined(separator: " · ")
    }
}

/// Someone a search found: their picture in a circle and their name, leading to what they're in.
struct PersonCard: View {
    let person: Person
    @State private var artworkHeight: CGFloat = 0
    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static var width: CGFloat {
        #if os(tvOS)
        160
        #else
        88
        #endif
    }

    var body: some View {
        VStack(spacing: 6) {
            Artwork(url: session?.person(person), aspectRatio: 1, cornerRadius: 0, placeholder: "person.fill")
                .clipShape(.circle)
                #if os(tvOS)
                .contentShape(.hoverEffect, .circle)
                #endif
                .liftsUnderFocus()
                .measuresCardArtwork($artworkHeight)
            Text(person.name)
                .font(.caption.weight(.medium))
                .lineLimit(dynamicTypeSize.lineLimit(2))
                .modifier(CardCaptionStyle(artworkHeight: artworkHeight))
        }
        .multilineTextAlignment(.center)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(person.name)
        .accessibilityHint("Shows the movies and shows they're in")
        .accessibilityIdentifier("person.\(person.name)")
    }
}

/// A genre to browse: a backdrop of one of its best titles, darkened under its name, or until
/// that's in, or without one, a color of its own.
struct GenreTile: View {
    let genre: GenreTiles.Genre
    let artwork: JellyfinItem?
    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The narrowest a tile gets, as many fitting across as will.
    static var minimumWidth: CGFloat {
        #if os(tvOS)
        360
        #elseif os(macOS)
        200
        #elseif os(visionOS)
        220
        #else
        150
        #endif
    }

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Self.color(for: genre.name).gradient)
            .overlay {
                if let artwork, let url = session?.backdrop(artwork, width: 800) {
                    Artwork(url: url, aspectRatio: nil, cornerRadius: 0, placeholder: nil)
                }
            }
            .overlay {
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(genre.name)
                        .font(.headline.weight(.bold))
                        .lineLimit(dynamicTypeSize.lineLimit(2))
                    Text(Self.count(genre.count))
                        .font(.caption)
                        .opacity(0.85)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .padding(Metrics.overlayInset + 4)
            }
            .clipShape(.rect(cornerRadius: Metrics.cardRadius))
            .liftsUnderFocus()
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(genre.name)
            .accessibilityValue(Self.count(genre.count))
            .accessibilityHint("Shows its movies and shows")
            .accessibilityIdentifier("genre.\(genre.name)")
    }

    /// "1 title", "7 titles".
    nonisolated static func count(_ count: Int) -> String {
        count == 1 ? "1 title" : "\(count) titles"
    }

    /// A deep color for a genre without a picture, the same each time for the same name.
    static func color(for name: String) -> Color {
        let hue = Double(ShuffleOrder.key(for: name, seed: 0) % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.45)
    }
}
