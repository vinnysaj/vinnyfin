import SwiftUI

/// Sizes that differ by how far away the screen is. Card widths are what a card aims for: rows
/// and grids fit their cards to the room they have around them (see `CardFit`), and a screen
/// regular in both directions makes them larger (see `EnvironmentValues.cardScale`).
nonisolated enum Metrics {
    #if os(tvOS)
    static let posterWidth: CGFloat = 230
    static let landscapeWidth: CGFloat = 470
    static let gridSpacing: CGFloat = 48
    static let edge: CGFloat = 80
    static let overlayInset: CGFloat = 10
    #elseif os(visionOS)
    static let posterWidth: CGFloat = 170
    static let landscapeWidth: CGFloat = 330
    static let gridSpacing: CGFloat = 24
    static let edge: CGFloat = 32
    static let overlayInset: CGFloat = 6
    #elseif os(macOS)
    static let posterWidth: CGFloat = 160
    static let landscapeWidth: CGFloat = 300
    static let gridSpacing: CGFloat = 20
    static let edge: CGFloat = 24
    static let overlayInset: CGFloat = 6
    #else
    /// Three columns of posters across a grid at least 340 points wide, as every iPhone's is in
    /// portrait without the A–Z index, and a row of three and a part of a fourth.
    static let posterWidth: CGFloat = 104
    static let landscapeWidth: CGFloat = 270
    static let gridSpacing: CGFloat = 14
    static let edge: CGFloat = 16
    static let overlayInset: CGFloat = 6
    #endif

    /// How much larger cards are on a screen regular in both directions: iPad at full screen or
    /// in a large window.
    static var regularScale: CGFloat {
        #if os(iOS)
        1.5
        #else
        1
        #endif
    }

    /// Between a page's sections: its rows, and the text and buttons around them.
    static let sectionSpacing: CGFloat = 30
    /// The corners of a card's artwork, and of what stands in for it.
    static let cardRadius: CGFloat = 10
    /// The corners of a notice on a page, such as why something couldn't load.
    static let noticeRadius: CGFloat = 16

    /// The player's controls from the screen's sides, inside the safe area. A TV's safe area is
    /// already its overscan margin.
    static var playerInset: CGFloat {
        #if os(tvOS)
        0
        #else
        edge
        #endif
    }
}

/// How wide cards are for the room they have. A grid fills its width with as many columns as
/// fit at a card's width or wider, so its margins stay even. A row fits a whole number of cards
/// near a card's width and a part of the next, which shows that the row goes on.
nonisolated enum CardFit {
    /// How much of the next card a row shows after its whole ones.
    static let peek: CGFloat = 0.3

    /// The columns, `spacing` apart, that fit across `width` at `minimum` wide or wider.
    static func columns(in width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard minimum > 0 else { return 1 }
        // A hair over, so a width that fits its columns exactly isn't a rounding error short.
        return max(1, Int((width + spacing) / (minimum + spacing) + 0.0001))
    }

    /// The width of a row's cards, `spacing` apart, with `room` from the first card's leading
    /// edge to the row's trailing one: whole cards near `target` wide, and `peek` of the next.
    /// Of the widths either side of the target, the wider one while it's at most a fifth over,
    /// or else whichever is nearer.
    static func rowCardWidth(room: CGFloat, target: CGFloat, spacing: CGFloat) -> CGFloat {
        guard room > 0, target > 0 else { return target }
        func width(showing whole: Int) -> CGFloat {
            (room - CGFloat(whole) * spacing) / (CGFloat(whole) + peek)
        }
        // As many whole cards as fit at the target width with a part of the next.
        let whole = max(1, Int(((room - peek * target) / (target + spacing)).rounded(.down)))
        let wider = width(showing: whole), narrower = width(showing: whole + 1)
        guard narrower > 0 else { return wider }
        return wider / target <= max(1.2, target / narrower) ? wider : narrower
    }
}

extension EnvironmentValues {
    /// How much larger cards are than `Metrics` has them: `Metrics.regularScale` on a screen
    /// regular in both directions, iPad at full screen or in a large window. A large iPhone in
    /// landscape is regular only across, and its rows are short enough as they are.
    var cardScale: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .regular && verticalSizeClass == .regular ? Metrics.regularScale : 1
        #else
        1
        #endif
    }
}

/// A poster with its title, watch state and download state.
struct PosterCard: View {
    let item: JellyfinItem
    var showsTitle = true
    @State private var artworkHeight: CGFloat = 0
    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: session?.poster(item), aspectRatio: 2.0 / 3.0, placeholder: item.isSeries ? "tv" : "film")
                .overlay { NotYetAvailableOverlay(item: item) }
                .overlay(alignment: .topTrailing) { WatchBadge(item: item).padding(Metrics.overlayInset) }
                .overlay(alignment: .bottom) {
                    if let progress {
                        ProgressBar(fraction: progress).padding(Metrics.overlayInset)
                    }
                }
                #if !os(tvOS)
                .overlay(alignment: .bottomLeading) {
                    if progress == nil, downloads.isDownloaded(item.id) {
                        Image(systemName: "arrow.down.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .font(.callout)
                            .padding(Metrics.overlayInset)
                    }
                }
                #endif
                .liftsUnderFocus()
                .measuresCardArtwork($artworkHeight)
            if showsTitle {
                VStack(alignment: .leading, spacing: 1) {
                    // Two lines, kept even for a short title, so the years in a row line up.
                    Text(item.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(2...max(2, dynamicTypeSize.lineLimit(2)))
                    if let year = item.premiereYearText {
                        Text(year).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .modifier(CardCaptionStyle(artworkHeight: artworkHeight))
            }
        }
        .liftsArtworkIntoMenu(aspectRatio: 2.0 / 3.0)
        .contentShape(.interaction, .rect)
        #if os(macOS)
        // The whole title, which the caption may cut short.
        .help(item.name)
        #endif
        // The name, then what the badges show: "Dune, 2021, watched, downloaded".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(details)
        .accessibilityIdentifier("poster.\(item.name)")
    }

    /// How far into the title playback is. A show has none: its share of episodes watched is
    /// what its badge counts, and as a bar it's a stub that reads as nothing.
    private var progress: Double? {
        item.isSeries ? nil : item.progress
    }

    private var details: String {
        var parts = [item.premiereYearText, NotYetAvailableOverlay.spoken(item), WatchBadge.spokenState(of: item),
                     progress.map(ProgressBar.spoken)]
        #if !os(tvOS)
        if progress == nil, downloads.isDownloaded(item.id) { parts.append("downloaded") }
        #endif
        return parts.compactMap(\.self).joined(separator: ", ")
    }
}

/// The artwork at the top of a card, as wide as the card at `aspectRatio`, with its rounded
/// corners: the part of the card a long press lifts into its menu.
struct CardArtworkShape: Shape {
    let aspectRatio: CGFloat

    nonisolated func path(in rect: CGRect) -> Path {
        let artwork = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, rect.width / aspectRatio))
        return RoundedRectangle(cornerRadius: Metrics.cardRadius).path(in: artwork)
    }
}

extension View {
    /// Lifts a card's artwork alone into its long-press menu, leaving the caption behind, where
    /// it would overlap the captions beside it. The Mac's menus lift nothing.
    fileprivate func liftsArtworkIntoMenu(aspectRatio: CGFloat) -> some View {
        #if os(macOS)
        self
        #else
        contentShape(.contextMenuPreview, CardArtworkShape(aspectRatio: aspectRatio))
        #endif
    }
}

/// Watched, or for a show the episodes left to watch. White on dark glass, which reads on any
/// artwork and leaves color to the accent; on Apple TV, white on blue.
struct WatchBadge: View {
    let item: JellyfinItem
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if item.isSeries, let unplayed = item.userData?.unplayedItemCount, unplayed > 0 {
            Text(String(unplayed))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background { backing(.capsule) }
                .foregroundStyle(.white)
                .accessibilityLabel(Self.spokenState(of: item) ?? "")
        } else if item.isPlayed {
            #if os(tvOS)
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, fill)
                .font(.callout)
                .accessibilityLabel("Watched")
            #else
            Image(systemName: "checkmark")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
                .padding(5)
                .background { backing(.circle) }
                .accessibilityLabel("Watched")
            #endif
        }
    }

    @ViewBuilder private func backing(_ shape: some Shape) -> some View {
        #if os(tvOS)
        shape.fill(fill)
        #else
        if contrast == .increased {
            shape.fill(.black.opacity(0.85))
        } else {
            shape.fill(.black.opacity(0.35))
                .background(.ultraThinMaterial, in: shape)
                .environment(\.colorScheme, .dark)
        }
        #endif
    }

    #if os(tvOS)
    /// Blue, deep enough with Increase Contrast that white reads on it at 4.5 to 1 whatever blue
    /// the system has made it.
    private var fill: Color {
        contrast == .increased ? .blue.mix(with: .black, by: 0.4) : .blue
    }
    #endif

    /// What the badge shows, as VoiceOver says it: "watched", "3 unwatched episodes"; nil for none.
    static func spokenState(of item: JellyfinItem) -> String? {
        if item.isSeries, let unplayed = item.userData?.unplayedItemCount, unplayed > 0 {
            return unplayed == 1 ? "1 unwatched episode" : "\(unplayed) unwatched episodes"
        }
        return item.isPlayed ? "watched" : nil
    }
}

/// How far into a title playback is, across the bottom of its artwork: white on a light,
/// see-through track that shows on dark artwork, with a faint shadow that lifts it off light.
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(.white.opacity(0.35))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
        }
        .frame(height: 4)
        .shadow(color: .black.opacity(0.35), radius: 2)
        .accessibilityElement()
        .accessibilityLabel(Self.spoken(fraction))
    }

    /// "40% watched".
    static func spoken(_ fraction: Double) -> String {
        "\(min(1, max(0, fraction)).formatted(.percent.precision(.fractionLength(0)))) watched"
    }
}

/// A 16:9 card for Continue Watching and Next Up: the episode's still, its show and number.
/// Leading with the episode, as a search does that found it by its name, the episode's name
/// comes first, over its show's and its number: "The Night Ferry" over "Port Ellery · S1, E1".
struct LandscapeCard: View {
    let item: JellyfinItem
    var leadsWithEpisode = false
    @State private var artworkHeight: CGFloat = 0
    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: session?.landscape(item), aspectRatio: 16.0 / 9.0, placeholder: "play.rectangle")
                .overlay { NotYetAvailableOverlay(item: item) }
                .overlay(alignment: .bottom) {
                    if let progress = item.progress {
                        ProgressBar(fraction: progress).padding(Metrics.overlayInset)
                    }
                }
                .liftsUnderFocus()
                .measuresCardArtwork($artworkHeight)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(dynamicTypeSize.lineLimit(1))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.lineLimit(1))
            }
            .modifier(CardCaptionStyle(artworkHeight: artworkHeight))
        }
        .liftsArtworkIntoMenu(aspectRatio: 16.0 / 9.0)
        .contentShape(.interaction, .rect)
        #if os(macOS)
        .help([title, detail].filter { !$0.isEmpty }.joined(separator: ", "))
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([spokenDetail, NotYetAvailableOverlay.spoken(item), item.progress.map(ProgressBar.spoken)]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", "))
        .accessibilityIdentifier("card.\(item.name)")
    }

    private var isEpisodeFirst: Bool { leadsWithEpisode && item.isEpisode }

    private var title: String { isEpisodeFirst ? item.name : item.titleName }

    private var detail: String {
        guard isEpisodeFirst else { return item.cardDetail }
        return [item.seriesName, Self.shortCode(of: item)].compactMap(\.self).joined(separator: " · ")
    }

    private var spokenDetail: String {
        guard isEpisodeFirst else { return item.spokenCardDetail }
        return [item.seriesName, item.spokenEpisodeCode].compactMap(\.self).joined(separator: ", ")
    }

    /// An episode's number, short: "S1, E1", "S1, E2–3".
    nonisolated static func shortCode(of item: JellyfinItem) -> String? {
        guard let episode = item.indexNumber else { return nil }
        let end = item.indexNumberEnd.flatMap { $0 > episode ? "–\($0)" : nil } ?? ""
        return "S\(item.parentIndexNumber ?? 0), E\(episode)\(end)"
    }
}

/// Over the artwork of a title that isn't out yet (`JellyfinItem.isNotYetAvailable`): the
/// picture dimmed, and across it "Not Yet Available", with the day it comes out while that's ahead.
struct NotYetAvailableOverlay: View {
    let item: JellyfinItem

    var body: some View {
        if item.isNotYetAvailable() {
            ZStack {
                Rectangle().fill(.black.opacity(0.55))
                VStack(spacing: 4) {
                    Image(systemName: "clock").font(.caption.weight(.semibold))
                    Text("Not Yet Available")
                        .font(.caption2.weight(.heavy))
                        .textCase(.uppercase)
                    if let day = Self.day(of: item) {
                        Text("\(item.isEpisode ? "Airs" : "Out") \(day)").font(.caption2.weight(.medium))
                    }
                }
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white)
                .padding(8)
            }
            .clipShape(.rect(cornerRadius: Metrics.cardRadius))
            // The card says it, in `spoken(_:)`.
            .accessibilityHidden(true)
        }
    }

    /// The day it comes out, "Dec 19, 2027", or this year "Nov 15"; nil once that has come, or
    /// when it isn't known.
    static func day(of item: JellyfinItem, now: Date = .now) -> String? {
        guard let premiere = item.premiere, premiere > now else { return nil }
        // Premieres are days, which the server gives as midnight in UTC.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if calendar.component(.year, from: premiere) != calendar.component(.year, from: now) { style = style.year() }
        style.timeZone = .gmt
        return premiere.formatted(style)
    }

    /// What the overlay shows, as VoiceOver says it; nil without one.
    static func spoken(_ item: JellyfinItem) -> String? {
        guard item.isNotYetAvailable() else { return nil }
        return ["not yet available", day(of: item).map { "\(item.isEpisode ? "airs" : "out") \($0)" }]
            .compactMap(\.self).joined(separator: ", ")
    }
}

extension BrowseList.Style {
    var cardWidth: CGFloat { self == .poster ? Metrics.posterWidth : Metrics.landscapeWidth }
}

/// The shape of a card while its title loads, the size of the card it stands for.
struct CardPlaceholder: View {
    let style: BrowseList.Style

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(style == .poster ? 2.0 / 3.0 : 16.0 / 9.0, contentMode: .fit)
                .background(.quaternary, in: .rect(cornerRadius: Metrics.cardRadius))
            VStack(alignment: .leading, spacing: 1) {
                // As tall as the card's caption: a poster's title takes two lines.
                Text("A Title Loading")
                    .font(style == .poster ? .caption.weight(.medium) : .subheadline.weight(.medium))
                    .lineLimit(style == .poster ? 2 : 1, reservesSpace: true)
                Text("2000").font(style == .poster ? .caption2 : .caption)
            }
            .redacted(reason: .placeholder)
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// A titled row of cards that scrolls sideways. With a list to see all of, its title leads
/// there; on Apple TV, where focus moves along the cards, a card at the row's end does. Until its
/// items are in, the shapes of their cards stand in, as tall as the row will be.
///
/// Off Apple TV the cards fit the row's width (see `CardFit`): a whole number of them, near
/// `cardWidth`, and a part of the next. On Apple TV, whose screen is always the same, they're
/// `cardWidth` wide, the row scrolls by whole cards (see `CardRowScrollBehavior`), and coming
/// back into it from above or below, focus goes to the card it was last on, scrolled as it was,
/// or the first.
struct Shelf<Item: Identifiable, Card: View>: View {
    let title: String
    var seeAll: BrowseList?
    /// Nil while they load.
    let items: [Item]?
    /// About how wide a card is on a phone; larger on a regular-width screen and at the
    /// accessibility text sizes.
    let cardWidth: CGFloat
    /// The shape of the cards that stand in while the items load.
    var placeholderStyle: BrowseList.Style = .poster
    @ViewBuilder let card: (Item) -> Card
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.cardScale) private var cardScale
    @Environment(\.accessibilityShowButtonShapes) private var showsButtonShapes
    #if os(tvOS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Focus?
    /// Where focus was in the row, kept by the page of rows the row is on, or else by the row.
    @Environment(\.rowFocusMemory) private var pageMemory
    @State private var ownMemory = RowFocusMemory()
    @State private var position = ScrollPosition()
    /// Bounds the row's default focus, so it's the row's to take when focus comes in.
    @Namespace private var focusScope

    private enum Focus: Hashable {
        case placeholder(Int), item(Item.ID), seeAll

        var isPlaceholder: Bool {
            if case .placeholder = self { true } else { false }
        }
    }
    #endif

    private static var placeholderCount: Int { 8 }

    var body: some View {
        let cardWidth = dynamicTypeSize.cardWidth(cardWidth * cardScale)
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, Metrics.edge)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.gridSpacing) {
                    ForEach(items ?? []) { item in
                        card(item)
                            .modifier(ShelfCardWidth(target: cardWidth))
                            #if os(tvOS)
                            .focused($focus, equals: .item(item.id))
                            #endif
                    }
                    ForEach(placeholderSlots, id: \.self) { slot in
                        CardPlaceholder(style: placeholderStyle)
                            .modifier(ShelfCardWidth(target: cardWidth))
                            #if os(tvOS)
                            // Holds focus while the row loads, so focus moving down the page
                            // doesn't pass over the row or leave the page for the sidebar.
                            .focusable()
                            .focused($focus, equals: .placeholder(slot))
                            // Brightens, and lifts as a card does, to show focus is on it.
                            .brightness(focus == .placeholder(slot) ? 0.15 : 0)
                            .scaleEffect(focus == .placeholder(slot) && !reduceMotion ? 1.1 : 1)
                            .animation(.easeOut(duration: 0.15), value: focus == .placeholder(slot))
                            #endif
                    }
                    #if os(tvOS)
                    if let seeAll, items != nil {
                        NavigationLink(value: seeAll) { SeeAllCard(style: seeAll.style) }
                            .buttonStyle(.artwork)
                            .frame(width: cardWidth)
                            .focused($focus, equals: .seeAll)
                            .accessibilityIdentifier("shelf.\(title).all")
                    }
                    #endif
                }
                .scrollTargetLayout()
                #if os(tvOS)
                .padding(.horizontal, Metrics.edge)
                .padding(.vertical, 30)
                #endif
            }
            #if !os(tvOS)
            // Margins rather than padding, so a swipe stops with a card at the page's margin.
            .contentMargins(.horizontal, Metrics.edge, for: .scrollContent)
            #endif
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            #if os(tvOS)
            .scrollTargetBehavior(CardRowScrollBehavior(stride: cardWidth + Metrics.gridSpacing) { [memory] in memory.offset = $0 })
            .scrollPosition($position)
            // Made again by the page's lazy stack, scrolled as it was left.
            .onAppear { if memory.offset > 0 { position.scrollTo(x: memory.offset) } }
            .focusSection()
            .focusScope(focusScope)
            .defaultFocus($focus, memory.focus as? Focus ?? items?.first.map { .item($0.id) }, priority: .userInitiated)
            .onChange(of: focus) { _, focus in
                if let focus, !focus.isPlaceholder { memory.focus = focus }
            }
            .onChange(of: items == nil) { _, loading in
                if !loading { focusReplacement() }
            }
            #else
            .scrollTargetBehavior(.viewAligned)
            .scrollDisabled(items == nil)
            #endif
        }
    }

    /// The slots that hold a stand-in: all of them while the items load, and on Apple TV, once
    /// they're in, the one focus is on until it moves to the card that took its place. Taking
    /// the stand-in away under focus would send focus somewhere else on the page.
    private var placeholderSlots: [Int] {
        if items == nil { return Array(0..<Self.placeholderCount) }
        #if os(tvOS)
        if case .placeholder(let slot) = focus { return [slot] }
        #endif
        return []
    }

    #if os(tvOS)
    private var memory: RowFocusMemory { pageMemory ?? ownMemory }

    /// Moves focus from the stand-in it's on to the card that came in at its place, or the
    /// nearest; See All, or nowhere in the row, when no cards came.
    private func focusReplacement() {
        guard case .placeholder(let slot) = focus else { return }
        if let items, !items.isEmpty {
            focus = .item(items[min(slot, items.count - 1)].id)
        } else {
            focus = seeAll == nil ? nil : .seeAll
        }
    }
    #endif

    @ViewBuilder private var header: some View {
        let text = Text(title).font(.title3.weight(.semibold))
        #if os(tvOS)
        text
        #else
        if let seeAll {
            NavigationLink(value: seeAll) {
                HStack(spacing: 4) {
                    // Button Shapes marks the title as one, being plain text.
                    text.underline(showsButtonShapes)
                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.semibold))
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows all of them")
            .accessibilityIdentifier("shelf.\(title)")
        } else {
            text
        }
        #endif
    }
}

/// A card's width in a `Shelf`. Off Apple TV, fitted to the row it's in (see
/// `CardFit.rowCardWidth`), whose scroll view gives its width less its margins; on Apple TV,
/// `target`.
private struct ShelfCardWidth: ViewModifier {
    let target: CGFloat

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.frame(width: target)
        #else
        content.containerRelativeFrame(.horizontal, alignment: .leading) { [target] length, _ in
            // From the first card to the row's trailing edge: the trailing margin's in it.
            CardFit.rowCardWidth(room: length + Metrics.edge, target: target, spacing: Metrics.gridSpacing)
        }
        #endif
    }
}

#if os(tvOS)
/// The end of an Apple TV row: opens the whole list.
private struct SeeAllCard: View {
    let style: BrowseList.Style
    @State private var artworkHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(style == .poster ? 2.0 / 3.0 : 16.0 / 9.0, contentMode: .fit)
                .background(.quaternary, in: .rect(cornerRadius: Metrics.cardRadius))
                .overlay {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                }
                .liftsUnderFocus()
                .measuresCardArtwork($artworkHeight)
            Text("See All").font(.caption.weight(.medium)).modifier(CardCaptionStyle(artworkHeight: artworkHeight))
        }
        .contentShape(.rect)
    }
}
#endif

/// What a version offers: 4K, HDR, Dolby Vision, Atmos, surround, subtitles (SDH when they're
/// for the deaf and hard of hearing) and audio description.
struct MediaBadges: View {
    let source: MediaSource

    struct Badge: Hashable {
        /// As it shows: "SDH".
        let text: String
        /// As VoiceOver says it, when that's not the text: "Subtitles for the deaf and hard of hearing".
        var spoken: String?
    }

    var body: some View {
        let badges = Self.badges(for: source)
        if !badges.isEmpty {
            HStack(spacing: 6) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge.text)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary, lineWidth: 1))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(badge.spoken ?? badge.text)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    static func badges(for source: MediaSource) -> [Badge] {
        var badges: [Badge] = []
        switch VersionTraits(source).resolutionClass {
        case let height? where height >= 2160: badges.append(Badge(text: "4K"))
        case let height? where height >= 1080: badges.append(Badge(text: "HD"))
        default: break
        }
        let range = source.videoStream?.videoRangeType?.uppercased() ?? ""
        let name = (source.name ?? "").uppercased()
        if range.hasPrefix("DOVI") || name.contains("DOLBY VISION") || name.contains(" DV") {
            badges.append(Badge(text: "Dolby Vision"))
        } else if range.contains("HDR10PLUS") || name.contains("HDR10+") {
            badges.append(Badge(text: "HDR10+", spoken: "HDR 10 plus"))
        } else if range.contains("HDR") || name.contains("HDR") {
            badges.append(Badge(text: "HDR"))
        } else if range.contains("HLG") {
            badges.append(Badge(text: "HLG"))
        }
        let audio = source.audioStreams.first
        let audioText = [audio?.audioSpatialFormat, audio?.profile, audio?.displayTitle, source.name].compactMap(\.self).joined(separator: " ").lowercased()
        if audioText.contains("atmos") {
            badges.append(Badge(text: "Atmos", spoken: "Dolby Atmos"))
        } else if audioText.contains("dts:x") || audioText.contains("dtsx") {
            badges.append(Badge(text: "DTS:X", spoken: "DTS X"))
        }
        if let channels = audio?.channels, channels >= 6 {
            badges.append(channels >= 8 ? Badge(text: "7.1", spoken: "7.1 surround") : Badge(text: "5.1", spoken: "5.1 surround"))
        }
        let subtitles = source.subtitleStreams.filter { $0.isForced != true }
        let languages = Set(subtitles.compactMap(\.language).map { AppSettings.displayName(for: $0) }).sorted().formatted(.list(type: .and))
        let inLanguages = languages.isEmpty ? "" : ", in \(languages)"
        if subtitles.contains(where: { $0.isHearingImpaired == true }) {
            badges.append(Badge(text: "SDH", spoken: "Subtitles for the deaf and hard of hearing\(inLanguages)"))
        } else if !subtitles.isEmpty {
            badges.append(Badge(text: "CC", spoken: "Subtitles\(inLanguages)"))
        }
        if source.audioStreams.contains(where: \.isAudioDescription) {
            badges.append(Badge(text: "AD", spoken: "Audio description"))
        }
        return badges
    }
}
