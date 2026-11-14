import SwiftUI

/// Sizes that differ by how far away the screen is.
enum Metrics {
    #if os(tvOS)
    static let posterWidth: CGFloat = 230
    static let landscapeWidth: CGFloat = 470
    static let gridSpacing: CGFloat = 48
    static let edge: CGFloat = 80
    #elseif os(visionOS)
    static let posterWidth: CGFloat = 170
    static let landscapeWidth: CGFloat = 330
    static let gridSpacing: CGFloat = 24
    static let edge: CGFloat = 32
    #elseif os(macOS)
    static let posterWidth: CGFloat = 160
    static let landscapeWidth: CGFloat = 300
    static let gridSpacing: CGFloat = 20
    static let edge: CGFloat = 24
    #else
    static let posterWidth: CGFloat = 116
    static let landscapeWidth: CGFloat = 270
    static let gridSpacing: CGFloat = 14
    static let edge: CGFloat = 16
    #endif

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
                .overlay(alignment: .topTrailing) { WatchBadge(item: item).padding(6) }
                .overlay(alignment: .bottom) {
                    if let progress = item.progress {
                        ProgressBar(fraction: progress).padding(6)
                    }
                }
                #if !os(tvOS)
                .overlay(alignment: .bottomLeading) {
                    if item.progress == nil, downloads.isDownloaded(item.id) {
                        Image(systemName: "arrow.down.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .font(.callout)
                            .padding(6)
                    }
                }
                #endif
                .liftsUnderFocus()
                .measuresCardArtwork($artworkHeight)
            if showsTitle {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.caption.weight(.medium)).lineLimit(dynamicTypeSize.lineLimit(1))
                    if let year = item.premiereYearText {
                        Text(year).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .modifier(CardCaptionStyle(artworkHeight: artworkHeight))
            }
        }
        .contentShape(.rect)
        // The name, then what the badges show: "Dune, 2021, watched, downloaded".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(details)
        .accessibilityIdentifier("poster.\(item.name)")
    }

    private var details: String {
        var parts = [item.premiereYearText, WatchBadge.spokenState(of: item), item.progress.map(ProgressBar.spoken)]
        #if !os(tvOS)
        if item.progress == nil, downloads.isDownloaded(item.id) { parts.append("downloaded") }
        #endif
        return parts.compactMap(\.self).joined(separator: ", ")
    }
}

/// Watched, or for a show the episodes left to watch: white on blue, the tint elsewhere. Apple
/// TV's tint and accent color are white, which hid the badge's white text and checkmark.
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
                .background(fill, in: .capsule)
                .foregroundStyle(.white)
                .accessibilityLabel(Self.spokenState(of: item) ?? "")
        } else if item.isPlayed {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, fill)
                .font(.callout)
                .accessibilityLabel("Watched")
        }
    }

    /// Blue, deep enough with Increase Contrast that white reads on it at 4.5 to 1 whatever blue
    /// the system has made it.
    private var fill: Color {
        contrast == .increased ? .blue.mix(with: .black, by: 0.4) : .blue
    }

    /// What the badge shows, as VoiceOver says it: "watched", "3 unwatched episodes"; nil for none.
    static func spokenState(of item: JellyfinItem) -> String? {
        if item.isSeries, let unplayed = item.userData?.unplayedItemCount, unplayed > 0 {
            return unplayed == 1 ? "1 unwatched episode" : "\(unplayed) unwatched episodes"
        }
        return item.isPlayed ? "watched" : nil
    }
}

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(.black.opacity(0.45))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel(Self.spoken(fraction))
    }

    /// "40% watched".
    static func spoken(_ fraction: Double) -> String {
        "\(min(1, max(0, fraction)).formatted(.percent.precision(.fractionLength(0)))) watched"
    }
}

/// A 16:9 card for Continue Watching and Next Up: the episode's still, its show and number.
struct LandscapeCard: View {
    let item: JellyfinItem
    @State private var artworkHeight: CGFloat = 0
    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: session?.landscape(item), aspectRatio: 16.0 / 9.0, placeholder: "play.rectangle")
                .overlay(alignment: .bottom) {
                    if let progress = item.progress {
                        ProgressBar(fraction: progress).padding(8)
                    }
                }
                .liftsUnderFocus()
                .measuresCardArtwork($artworkHeight)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.titleName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(dynamicTypeSize.lineLimit(1))
                Text(item.cardDetail).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.lineLimit(1))
            }
            .modifier(CardCaptionStyle(artworkHeight: artworkHeight))
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.titleName)
        .accessibilityValue([item.spokenCardDetail, item.progress.map(ProgressBar.spoken)].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", "))
        .accessibilityIdentifier("card.\(item.name)")
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
                .background(.quaternary, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("A Title Loading").font(style == .poster ? .caption.weight(.medium) : .subheadline.weight(.medium))
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
/// On Apple TV the row scrolls by whole cards (see `CardRowScrollBehavior`), and coming back
/// into it from above or below, focus goes to the card it was last on, scrolled as it was.
struct Shelf<Item: Identifiable, Card: View>: View {
    let title: String
    var seeAll: BrowseList?
    /// Nil while they load.
    let items: [Item]?
    let cardWidth: CGFloat
    /// The shape of the cards that stand in while the items load.
    var placeholderStyle: BrowseList.Style = .poster
    @ViewBuilder let card: (Item) -> Card
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        let cardWidth = dynamicTypeSize.cardWidth(cardWidth)
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, Metrics.edge)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.gridSpacing) {
                    ForEach(items ?? []) { item in
                        card(item)
                            .frame(width: cardWidth)
                            #if os(tvOS)
                            .focused($focus, equals: .item(item.id))
                            #endif
                    }
                    ForEach(placeholderSlots, id: \.self) { slot in
                        CardPlaceholder(style: placeholderStyle)
                            .frame(width: cardWidth)
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
                .padding(.horizontal, Metrics.edge)
                #if os(tvOS)
                .padding(.vertical, 30)
                #endif
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            #if os(tvOS)
            .scrollTargetBehavior(CardRowScrollBehavior(stride: cardWidth + Metrics.gridSpacing) { [memory] in memory.offset = $0 })
            .scrollPosition($position)
            // Made again by the page's lazy stack, scrolled as it was left.
            .onAppear { if memory.offset > 0 { position.scrollTo(x: memory.offset) } }
            .focusSection()
            .focusScope(focusScope)
            .defaultFocus($focus, memory.focus as? Focus, priority: .userInitiated)
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

#if os(tvOS)
/// The end of an Apple TV row: opens the whole list.
private struct SeeAllCard: View {
    let style: BrowseList.Style
    @State private var artworkHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(style == .poster ? 2.0 / 3.0 : 16.0 / 9.0, contentMode: .fit)
                .background(.quaternary, in: .rect(cornerRadius: 10))
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
