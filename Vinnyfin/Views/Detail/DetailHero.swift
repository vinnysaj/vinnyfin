import NukeUI
import SwiftUI

/// The top of a detail screen: the backdrop full width, fading into the page, with the title
/// (as its logo when there is one), the facts line and the actions over it, or at the
/// accessibility sizes, the title over it and the rest under it. An episode's backdrop is its
/// own still where that's sharp enough for it (`usesStill(width:)`), else its show's, and
/// another episode shown fades in over the last. Its show's logo, over its name, leads to the
/// show; without a logo, the show's name over the episode's does.
struct DetailHero<Actions: View>: View {
    let item: JellyfinItem
    /// The name over the title, such as an episode's show's, which its show's logo stands in for.
    var eyebrow: String?
    /// Where an episode's show's logo or name leads: its show. On Apple TV the page's buttons lead
    /// there instead, as a logo that took focus would be a stray stop above Play.
    var showLink: JellyfinItem?
    var badgesSource: MediaSource?
    @ViewBuilder let actions: () -> Actions

    @Environment(\.session) private var session
    @Environment(\.topBarsHeight) private var topBarsHeight
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif
    /// The height of the scroll view the page is in, which the hero takes at most a share of.
    @State private var visibleHeight: CGFloat = 0
    /// How wide each episode's still is, by the episode, once the server has said.
    @State private var stillWidths: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    if let eyebrow, !showsShowLogo { eyebrowView(eyebrow) }
                    title
                    if !isStacked { facts }
                }
                // The words go on the dark of the fade in either appearance.
                .environment(\.colorScheme, .dark)
                // The actions keep the page's appearance: the sheets and menus they open would
                // take the dark with them. Their glass takes on the dark behind it by itself, and
                // their captions go on it in the dark's colors.
                if !isStacked { actions().environment(\.actionsOverArtwork, true).padding(.top, 4) }
            }
            .heroWords()
            .padding(.horizontal, Metrics.edge)
            .padding(.bottom, 8 + HeroBackdrop.blendHeight(in: colorScheme) + HeroBackdrop.glassRoom)
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            // Taller than the artwork's height when the title and actions need it, so none of them
            // is squeezed, or goes under the bars over the page's top.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, topBarsHeight > 0 ? topBarsHeight + Self.clearance : 0)
            .frame(maxWidth: .infinity, minHeight: HeroBackdrop.height(Self.fullHeight, visible: visibleHeight), alignment: .bottomLeading)
            .background {
                HeroBackdrop(url: backdropURL, fillsEmpty: !isMeasuringStill, from: 0.35, middle: 0.75, at: 0.7)
            }
            // Again once the details come with the still, for a page opened from a link that
            // names only the episode.
            .task(id: [item.id, item.primaryImageTag]) { await measureStill() }
            if isStacked {
                VStack(alignment: .leading, spacing: 10) {
                    facts
                    actions().padding(.top, 4)
                }
                .padding(.horizontal, Metrics.edge)
                .padding(.bottom, 8)
                .frame(maxWidth: Self.columnWidth, alignment: .leading)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.bounds(of: .scrollView)?.height ?? 0 } action: { visibleHeight = $0 }
    }

    /// At the accessibility sizes the facts and actions go under the artwork rather than over it,
    /// where they would stretch it and run up past its fade into the page, onto the picture.
    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    @ViewBuilder private var facts: some View {
        FactsLine(item: item, showsEnd: true)
        if let badgesSource { MediaBadges(source: badgesSource) }
    }

    /// Between the bars over the page and the top of the words.
    private static var clearance: CGFloat { 14 }

    /// How wide the title, facts and actions run. On Apple TV, wide enough for Resume, Start Over,
    /// Watched and Favorite in one row.
    private static var columnWidth: CGFloat {
        #if os(tvOS)
        1300
        #else
        900
        #endif
    }

    /// The hero's height where the screen has room for it.
    private static var fullHeight: CGFloat {
        #if os(tvOS)
        760
        #elseif os(macOS) || os(visionOS)
        460
        #else
        440
        #endif
    }

    /// The narrowest an episode's still can be to fill the hero, in pixels: narrower, it's soft
    /// at the hero's size, and the show's backdrop stands in.
    static var heroStillWidth: Int { 1280 }

    /// Whether an episode's still `width` pixels wide fills the hero; nil until the server says.
    static func usesStill(width: Int?) -> Bool {
        (width ?? 0) >= heroStillWidth
    }

    private var backdropURL: URL? {
        #if !os(tvOS)
        if let saved = downloads.artworkURL(itemId: item.id, kind: .backdrop), session == nil || !downloads.isNetworkReachable {
            return saved
        }
        #endif
        if item.isEpisode, let tag = item.primaryImageTag, let session {
            // Until it's known whether the still will do, nothing new: the last episode's stays.
            guard let width = stillWidths[item.id] else { return nil }
            if Self.usesStill(width: width) {
                return session.client.imageURL(itemId: item.id, tag: tag, maxWidth: 1920)
            }
        }
        return session?.backdrop(item) ?? session?.landscape(item)
    }

    /// It isn't known yet whether the episode's still will do for the backdrop.
    private var isMeasuringStill: Bool {
        item.isEpisode && item.primaryImageTag != nil && session != nil && stillWidths[item.id] == nil
    }

    /// How wide the episode's still is, which decides whether it's the backdrop. Without an
    /// answer, it's taken as too narrow.
    private func measureStill() async {
        guard item.isEpisode, item.primaryImageTag != nil, stillWidths[item.id] == nil, let session else { return }
        let id = item.id
        let width = try? await session.client.images(itemId: id).first { $0.imageType == "Primary" }?.width
        guard !Task.isCancelled else { return }
        stillWidths[id] = width ?? 0
    }

    /// The episode's show has a logo, which stands for its name over the episode's.
    private var showsShowLogo: Bool {
        item.isEpisode && logoURL != nil
    }

    @ViewBuilder private func eyebrowView(_ eyebrow: String) -> some View {
        #if os(tvOS)
        Text(eyebrow).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        #else
        if let showLink {
            NavigationLink(value: showLink) {
                HStack(spacing: 4) {
                    Text(eyebrow)
                    Image(systemName: "chevron.right").imageScale(.small)
                }
                .font(.subheadline.weight(.semibold))
            }
            // Glass reads on any artwork, and looks like the button it is.
            .buttonStyle(.platformGlass)
            .controlSize(.small)
            .accessibilityHint("Opens \(eyebrow)")
            .accessibilityIdentifier("detail.eyebrow")
        } else {
            Text(eyebrow).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
        #endif
    }

    /// The server's, or offline the one saved with a download.
    private var logoURL: URL? {
        #if !os(tvOS)
        if let saved = downloads.artworkURL(itemId: item.id, kind: .logo), session == nil || !downloads.isNetworkReachable {
            return saved
        }
        #endif
        return session?.logo(item, width: TitleLogo.requestWidth)
    }

    @ViewBuilder private var title: some View {
        if item.isEpisode, let logo = logoURL {
            showLogo(logo)
            Text(item.name).font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
        } else {
            TitleLogo(url: logoURL, name: item.name)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// An episode's show's logo, which leads to the show off Apple TV.
    @ViewBuilder private func showLogo(_ logo: URL) -> some View {
        let name = item.seriesName ?? item.name
        #if os(tvOS)
        TitleLogo(url: logo, name: name)
        #else
        if let showLink {
            NavigationLink(value: showLink) {
                TitleLogo(url: logo, name: name, leadsOn: true)
            }
            .buttonStyle(.artwork)
            .accessibilityHint("Opens \(name)")
            .accessibilityIdentifier("detail.eyebrow")
        } else {
            TitleLogo(url: logo, name: name)
        }
        #endif
    }

    /// `FactsLine`'s facts as VoiceOver should say them: "Season 1, Episode 2, 2024, rated PG-13,
    /// 2 hours, 9 minutes, ends at 9:50 PM, rated 7.8 out of 10, Action, Drama". When it would end
    /// is said with `now`.
    static func spokenFacts(for item: JellyfinItem, now: Date? = nil) -> String {
        var parts: [String] = []
        if item.isEpisode, let code = item.spokenEpisodeCode { parts.append(code) }
        if let year = item.productionYear { parts.append(String(year)) }
        if let rating = item.officialRating { parts.append("rated \(rating)") }
        if item.isSeries, let count = item.childCount { parts.append(count == 1 ? "1 season" : "\(count) seasons") }
        if !item.isSeries, let runtime = item.spokenRuntime { parts.append(runtime) }
        if let end = now.flatMap({ EndTime.end(of: item, now: $0) }) { parts.append("ends at \(EndTime.text(end))") }
        if let score = item.communityRating {
            parts.append("rated \(score.formatted(.number.precision(.fractionLength(1)))) out of 10")
        }
        if let genres = item.genres?.prefix(3), !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

/// A picture that, given another, keeps the one before up until the next is in, and fades the next
/// in over it, rather than going blank between them. One that can't load goes, for the gray.
private struct CrossfadingPicture: View {
    let url: URL?
    /// Gray stands in while there's no picture; else the frame is left empty.
    let fillsEmpty: Bool
    /// The last picture that loaded, under the one asked for. The same one under itself once it's
    /// in, so nothing shows through it as it fades in.
    @State private var under: URL?

    var body: some View {
        Color.clear
            .overlay {
                if let under {
                    Artwork(url: under, aspectRatio: nil, cornerRadius: 0, placeholder: nil)
                }
            }
            .overlay {
                ServerImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if under == nil, fillsEmpty {
                        Rectangle().fill(.quaternary)
                    }
                } onCompletion: { result in
                    switch result {
                    case .success: under = url
                    case .failure: under = nil
                    }
                }
            }
            .accessibilityIgnoresInvertColors()
            .accessibilityHidden(true)
    }
}

/// A hero's picture, the page's width and the hero's height, under a fade that keeps the words
/// over it legible in either appearance: down into the dark the page has in dark appearance,
/// behind the title, facts and buttons. In light appearance that dark meets the page's own color
/// at the hero's foot, under the words, in the `blendHeight(in:)` the hero leaves there. On Apple
/// TV the dark holds behind the buttons and goes solid only in the `glassRoom` under them. On
/// Vision Pro the picture fades into the window's glass instead. Pulled down past the top of the
/// page, the picture stretches up from its foot to fill the space. Another picture fades in over it.
struct HeroBackdrop: View {
    let url: URL?
    /// Gray stands in, under the fade, for a picture that's loading or can't load; with no symbol
    /// on it, which would show between the words and buttons over it. Else the frame is empty.
    var fillsEmpty = true
    /// Where the fade starts, as a share of the height.
    var start: Double
    /// How dark it is at `location`, as a share of the height; at the foot it's solid. On Apple TV
    /// it stays this dark down to the `glassRoom`, which takes it to solid.
    var middle: Double
    var location: Double

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    init(url: URL?, fillsEmpty: Bool = true, from start: Double, middle: Double, at location: Double) {
        self.url = url
        self.fillsEmpty = fillsEmpty
        self.start = start
        self.middle = middle
        self.location = location
    }

    var body: some View {
        CrossfadingPicture(url: url, fillsEmpty: fillsEmpty)
            .clipped()
            #if os(visionOS)
            .mask { fade(Color.black).environment(\.colorScheme, .dark) }
            #else
            .overlay {
                VStack(spacing: 0) {
                    fade(Color.pageBackground).environment(\.colorScheme, .dark)
                    #if os(tvOS)
                    foot(Color.pageBackground).environment(\.colorScheme, .dark)
                        .frame(height: Self.glassRoom)
                    #endif
                    blend.frame(height: Self.blendHeight(in: colorScheme))
                }
            }
            #endif
            .visualEffect { content, geometry in
                // Pulled down past the top, the hero's top is below the scroll view's.
                let overscroll = max(0, geometry.frame(in: .scrollView).minY)
                return content.scaleEffect(geometry.size.height > 0 ? 1 + overscroll / geometry.size.height : 1, anchor: .bottom)
            }
            // Past the safe area at the sides, under any bars there: clipped and faded first,
            // so that part is too.
            .ignoresSafeArea(edges: .horizontal)
    }

    /// The dark easing into the page's color, with no edge where it starts or ends.
    private var blend: some View {
        Color.pageBackground
            .overlay {
                Color.pageBackground
                    .environment(\.colorScheme, .dark)
                    .mask(LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.75), location: 0.3),
                        .init(color: .black.opacity(0.35), location: 0.6),
                        .init(color: .black.opacity(0.1), location: 0.85),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom))
            }
    }

    /// Clear down to `start`, `middle` of `stage` at `location`, then `stage`; on Apple TV, still
    /// `middle` at the bottom, behind the buttons, for the `foot` under them to finish. With
    /// Increase Contrast it starts sooner and goes all but solid behind the words, so they read on
    /// the dark rather than on the picture. On Vision Pro the same shape fades the picture out.
    private func fade(_ stage: Color) -> LinearGradient {
        let stops: [Gradient.Stop]
        #if os(visionOS)
        stops = contrast == .increased ? [
            .init(color: stage, location: start * 0.6),
            .init(color: stage.opacity(0.08), location: start + 0.25),
            .init(color: .clear, location: 0.85),
        ] : [
            .init(color: stage, location: start),
            .init(color: stage.opacity(1 - middle), location: location),
            .init(color: .clear, location: 1),
        ]
        #else
        stops = contrast == .increased ? [
            .init(color: .clear, location: start * 0.6),
            .init(color: stage.opacity(0.92), location: start + 0.25),
            .init(color: stage, location: 0.85),
        ] : [
            .init(color: .clear, location: start),
            .init(color: stage.opacity(middle), location: location),
            .init(color: Self.glassRoom > 0 ? stage.opacity(middle) : stage, location: 1),
        ]
        #endif
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    #if os(tvOS)
    /// The `glassRoom`: the dark going on from where the fade leaves it to `stage`, which it
    /// already is with Increase Contrast.
    private func foot(_ stage: Color) -> some View {
        LinearGradient(colors: [stage.opacity(contrast == .increased ? 1 : middle), stage], startPoint: .top, endPoint: .bottom)
    }
    #endif

    /// The picture a hero leaves under its buttons on Apple TV, for their Liquid Glass to show
    /// through. With the buttons at the foot, on the solid dark the fade ends in, the glass has
    /// nothing to show and reads as a flat gray platter.
    static var glassRoom: CGFloat {
        #if os(tvOS)
        100
        #else
        0
        #endif
    }

    /// The room a hero leaves at its foot, under its words, for its dark to meet the page's color:
    /// none where the page is that dark already, in dark appearance, or on Vision Pro's glass.
    static func blendHeight(in colorScheme: ColorScheme) -> CGFloat {
        #if os(visionOS)
        0
        #else
        colorScheme == .dark ? 0 : 56
        #endif
    }

    /// A hero's height: `full`, or on a screen too short for it, as a phone held sideways or a
    /// short window, a share of the `visible` height, so what's under it shows too. The words
    /// over it make it taller when they need to be. Apple TV's screen is always the same.
    static func height(_ full: CGFloat, visible: CGFloat) -> CGFloat {
        #if os(tvOS)
        full
        #else
        visible > 0 ? min(full, (visible * 0.6).rounded()) : full
        #endif
    }
}

/// "S01E02 · 2024 · PG-13 · 52 min · ★ 7.8 · Drama", each fact whole on a line, and where the
/// line breaks no dot or comma at either end of it. On a narrow screen, only the first genre.
struct FactsLine: View {
    let item: JellyfinItem
    /// Says when the title would end if played now, after how long it runs: "Ends at 9:50 PM".
    var showsEnd = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if showsEnd {
            // Each minute, for when the title would end.
            TimelineView(.everyMinute) { context in line(now: context.date) }
        } else {
            line(now: nil)
        }
    }

    /// With `now`, when the title would end if played then.
    private func line(now: Date?) -> some View {
        let facts = Self.facts(for: item, genres: sizeClass == .compact ? 1 : 3, now: now)
        return FactsLayout {
            ForEach(facts.indices, id: \.self) { index in
                if index > 0 {
                    Group {
                        if facts[index].isGenre && facts[index - 1].isGenre {
                            Text(",").padding(.trailing, 4)
                        } else {
                            Text("·").padding(.horizontal, 5)
                        }
                    }
                    .layoutValue(key: FactSeparator.self, value: true)
                }
                Text(facts[index].text)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DetailHero<EmptyView>.spokenFacts(for: item, now: now))
    }

    struct Fact: Equatable {
        let text: String
        var isGenre = false
    }

    /// The facts, in order, with up to `genres` genres last; with `now`, when the title would end
    /// if played then, after how long it runs.
    static func facts(for item: JellyfinItem, genres: Int, now: Date? = nil) -> [Fact] {
        var facts: [Fact] = []
        if item.isEpisode, let code = item.episodeCode { facts.append(Fact(text: code)) }
        if let year = item.productionYear { facts.append(Fact(text: String(year))) }
        if let rating = item.officialRating { facts.append(Fact(text: rating)) }
        if item.isSeries, let count = item.childCount { facts.append(Fact(text: count == 1 ? "1 Season" : "\(count) Seasons")) }
        if !item.isSeries, let runtime = item.runtimeText { facts.append(Fact(text: runtime)) }
        if let end = now.flatMap({ EndTime.end(of: item, now: $0) }) { facts.append(Fact(text: "Ends at \(EndTime.text(end))")) }
        if let score = item.communityRating { facts.append(Fact(text: "★ \(score.formatted(.number.precision(.fractionLength(1))))")) }
        for genre in (item.genres ?? []).prefix(genres) { facts.append(Fact(text: genre, isGenre: true)) }
        return facts
    }
}

/// Marks a separator between two facts in a `FactsLayout`.
nonisolated private struct FactSeparator: LayoutValueKey {
    static let defaultValue = false
}

/// Facts in lines, each with the separator before it, which moves to the next line with it. A
/// separator that would start a line is put out of the way, past the leading edge, where the
/// line clips it.
private struct FactsLayout: Layout {
    var lineSpacing: CGFloat = 2

    /// A fact, with the separator before it when there is one.
    private struct Unit {
        var separator: Int?
        var fact: Int
    }

    private struct Line {
        var units: [Unit] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(fitting: proposal.width ?? .infinity, subviews)
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        // Broken as they were measured: the bounds are the measured width rounded to the pixel,
        // which can be a hair short of it, and would move the last fact to a line of its own.
        let width = proposal.width ?? .infinity
        for line in lines(fitting: width, subviews) {
            var x = bounds.minX
            for (position, unit) in line.units.enumerated() {
                if let separator = unit.separator {
                    let size = subviews[separator].sizeThatFits(.unspecified)
                    if position == 0 {
                        subviews[separator].place(at: CGPoint(x: bounds.minX - size.width - 1, y: y), proposal: .unspecified)
                    } else {
                        subviews[separator].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                        x += size.width
                    }
                }
                let size = factSize(subviews[unit.fact], width: width)
                subviews[unit.fact].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width
            }
            y += line.height + lineSpacing
        }
    }

    private func lines(fitting width: CGFloat, _ subviews: Subviews) -> [Line] {
        var units: [Unit] = []
        var separator: Int?
        for index in subviews.indices {
            if subviews[index][FactSeparator.self] {
                separator = index
            } else {
                units.append(Unit(separator: separator, fact: index))
                separator = nil
            }
        }
        var lines: [Line] = []
        var line = Line()
        for unit in units {
            let fact = factSize(subviews[unit.fact], width: width)
            let separator = unit.separator.map { subviews[$0].sizeThatFits(.unspecified) } ?? .zero
            if !line.units.isEmpty, line.width + separator.width + fact.width > width {
                lines.append(line)
                line = Line()
            }
            let lead = line.units.isEmpty ? 0 : separator.width
            line.units.append(unit)
            line.width += lead + fact.width
            line.height = max(line.height, fact.height, line.units.count > 1 ? separator.height : 0)
        }
        if !line.units.isEmpty { lines.append(line) }
        return lines
    }

    /// A fact's size on one line, or wrapped to `width` when even alone it's wider.
    private func factSize(_ fact: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = fact.sizeThatFits(.unspecified)
        guard ideal.width > width, width.isFinite else { return ideal }
        return fact.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}

extension Color {
    /// The page behind content, which hero artwork fades into: on Vision Pro, none, so the
    /// window's glass shows through.
    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #elseif os(tvOS)
        // Black like a theater in the dark, rather than the system's gray.
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
        #elseif os(visionOS)
        Color.clear
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

/// The overview, with the tagline above it. Four lines of it, ending in "more" when there's more,
/// until a tap shows the rest; on Apple TV, where text can't take focus, the rest opens over the
/// page when it's cut short.
struct OverviewText: View {
    let item: JellyfinItem
    @State private var expanded = false
    /// The four lines leave some of it out.
    @State private var isTruncated = false
    @State private var shownHeight: CGFloat = .infinity
    @State private var fullHeight: CGFloat = 0
    #if os(tvOS)
    @State private var showsAll = false
    #else
    /// The size of "more" or "less", which the end of the last line fades out under.
    @State private var toggleSize = CGSize.zero
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tagline = item.taglines?.first, !tagline.isEmpty {
                Text(tagline).font(.headline)
            }
            if let overview = item.overview, !overview.isEmpty {
                #if os(tvOS)
                if isTruncated {
                    Button { showsAll = true } label: { text(overview) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows all of it")
                        .sheet(isPresented: $showsAll) { FullOverview(item: item, overview: overview) }
                } else {
                    text(overview)
                }
                #else
                let toggles = isTruncated || expanded
                text(overview)
                    .mask {
                        if toggles { fadeUnderToggle } else { Rectangle() }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if toggles {
                            Text(expanded ? "less" : "more")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.tint)
                                .onGeometryChange(for: CGSize.self) { $0.size } action: { toggleSize = $0 }
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        guard toggles else { return }
                        withAnimation(.smooth) { expanded.toggle() }
                    }
                    // What a tap does, to VoiceOver, Voice Control and Switch Control, when it does something.
                    .accessibilityAddTraits(toggles ? .isButton : [])
                    .accessibilityHint(expanded ? "Shows less" : isTruncated ? "Shows all of it" : "")
                    .accessibilityInputLabels(toggles ? ["Overview", "More"] : [])
                #endif
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
    }

    #if !os(tvOS)
    /// All of the text but the end of its last line, which fades out where "more" or "less" goes.
    private var fadeUnderToggle: some View {
        VStack(spacing: 0) {
            Rectangle()
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 28)
                Color.clear.frame(width: toggleSize.width + 4)
            }
            .frame(height: toggleSize.height)
        }
    }
    #endif

    private func text(_ overview: String) -> some View {
        Text(overview)
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(expanded ? nil : 4)
            // Measured against all of it, laid out unseen behind.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                shownHeight = height
                isTruncated = !expanded && fullHeight > shownHeight + 1
            }
            .background {
                Text(overview)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        fullHeight = height
                        isTruncated = !expanded && fullHeight > shownHeight + 1
                    }
            }
    }
}

#if os(tvOS)
/// All of a title's overview, over its page.
private struct FullOverview: View {
    let item: JellyfinItem
    let overview: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(item.name).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(overview).font(.body)
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(Metrics.edge)
            // So the remote can scroll it, and VoiceOver read it.
            .focusable()
        }
    }
}
#endif

extension EnvironmentValues {
    /// The title's buttons are over its hero's artwork, which is dark behind them in either
    /// appearance, rather than under it on the page.
    @Entry var actionsOverArtwork = false
}
