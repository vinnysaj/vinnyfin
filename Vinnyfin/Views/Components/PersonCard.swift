import SwiftUI

/// Someone's picture in a circle, as wide as the card at any text size, with their name and, on a
/// title's page, what they were in it under it, which on Apple TV move out of the way of the
/// picture as focus lifts it. It leads to their page.
struct PersonCard: View {
    let person: Person
    /// The part they played, or the jobs they did.
    var detail: String?
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
            VStack(spacing: 2) {
                // Two lines for a name alone; one with what they did under it.
                Text(person.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(dynamicTypeSize.lineLimit(detail == nil ? 2 : 1))
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.lineLimit(1))
                }
            }
            .modifier(CardCaptionStyle(artworkHeight: artworkHeight))
        }
        .multilineTextAlignment(.center)
        .contentShape(.rect)
        #if os(macOS)
        .help([person.name, detail].compactMap(\.self).joined(separator: ", "))
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(person.name)
        .accessibilityValue(detail ?? "")
        .accessibilityHint("Shows their page")
        .accessibilityIdentifier("person.\(person.name)")
    }
}
