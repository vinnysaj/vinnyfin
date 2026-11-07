import SwiftUI

/// The top of a detail screen: the backdrop full width, fading into the page, with the title
/// (as its logo when there is one), the facts line and the actions over it, or at the
/// accessibility sizes, the title over it and the rest under it.
struct DetailHero<Actions: View>: View {
    let item: JellyfinItem
    var eyebrow: String?
    var badgesSource: MediaSource?
    @ViewBuilder let actions: () -> Actions

    @Environment(\.session) private var session
    @Environment(\.topBarsHeight) private var topBarsHeight
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if let eyebrow {
                    Text(eyebrow).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                title
                if !isStacked { details }
            }
            .padding(.horizontal, Metrics.edge)
            .padding(.bottom, 8)
            .frame(maxWidth: 900, alignment: .leading)
            // Taller than the artwork's height when the title and actions need it, so none of them
            // goes under the bars over the page's top.
            .padding(.top, topBarsHeight)
            .frame(maxWidth: .infinity, minHeight: heroHeight, alignment: .bottomLeading)
            .background {
                Artwork(url: backdropURL, aspectRatio: nil, cornerRadius: 0, placeholder: item.isSeries ? "tv" : "film")
                    .clipped()
                    .overlay { Self.scrim(increased: contrast == .increased, from: 0.35, middle: 0.75, at: 0.7) }
                    // Past the safe area at the sides, under any bars there: clipped and faded first,
                    // so that part is too.
                    .ignoresSafeArea(edges: .horizontal)
            }
            if isStacked {
                VStack(alignment: .leading, spacing: 10) { details }
                    .padding(.horizontal, Metrics.edge)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
    }

    /// At the accessibility sizes the facts and actions go under the artwork rather than over it,
    /// where they would stretch it and run up past its fade into the page, onto the picture.
    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    @ViewBuilder private var details: some View {
        Text(Self.facts(for: item))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Self.spokenFacts(for: item))
        if let badgesSource { MediaBadges(source: badgesSource) }
        actions()
            .padding(.top, 4)
    }

    /// The fade from the artwork into the page under the words over it: clear down to `start` of
    /// the way, `middle` of the page's color at `at`, then the page. With Increase Contrast it
    /// starts sooner and goes all but solid behind the words, so they read on the page's color
    /// rather than on the picture.
    static func scrim(increased: Bool, from start: Double, middle: Double, at location: Double) -> LinearGradient {
        let page = Color.pageBackground
        let stops: [Gradient.Stop] = increased ? [
            .init(color: .clear, location: start * 0.6),
            .init(color: page.opacity(0.92), location: start + 0.25),
            .init(color: page, location: 0.85),
        ] : [
            .init(color: .clear, location: start),
            .init(color: page.opacity(middle), location: location),
            .init(color: page, location: 1),
        ]
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    private var heroHeight: CGFloat {
        #if os(tvOS)
        760
        #elseif os(macOS) || os(visionOS)
        460
        #else
        440
        #endif
    }

    private var backdropURL: URL? {
        #if !os(tvOS)
        if let saved = downloads.artworkURL(itemId: item.id, kind: .backdrop), session == nil || !downloads.isNetworkReachable {
            return saved
        }
        #endif
        return session?.backdrop(item) ?? session?.landscape(item)
    }

    /// The server's, or offline the one saved with a download.
    private var logoURL: URL? {
        #if !os(tvOS)
        if let saved = downloads.artworkURL(itemId: item.id, kind: .logo), session == nil || !downloads.isNetworkReachable {
            return saved
        }
        #endif
        return session?.logo(item, width: 900)
    }

    @ViewBuilder private var title: some View {
        if let logo = logoURL {
            Artwork(url: logo, aspectRatio: nil, cornerRadius: 0, placeholder: "", contentMode: .fit,
                    label: item.isEpisode ? (item.seriesName ?? item.name) : item.name)
                .frame(maxWidth: logoWidth, maxHeight: logoHeight, alignment: .leading)
                .accessibilityAddTraits(item.isEpisode ? [] : .isHeader)
            if item.isEpisode {
                Text(item.name).font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
            }
        } else {
            Text(item.name)
                .font(.largeTitle.weight(.bold))
                .lineLimit(dynamicTypeSize.lineLimit(3))
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var logoWidth: CGFloat {
        #if os(tvOS)
        620
        #else
        320
        #endif
    }

    private var logoHeight: CGFloat {
        #if os(tvOS)
        200
        #else
        110
        #endif
    }

    /// "2024 · PG-13 · 2h 9m · ★ 7.8 · Action, Drama"
    static func facts(for item: JellyfinItem) -> String {
        var parts: [String] = []
        if item.isEpisode, let code = item.episodeCode { parts.append(code) }
        if let year = item.productionYear { parts.append(String(year)) }
        if let rating = item.officialRating { parts.append(rating) }
        if item.isSeries, let count = item.childCount { parts.append(count == 1 ? "1 Season" : "\(count) Seasons") }
        if !item.isSeries, let runtime = item.runtimeText { parts.append(runtime) }
        if let score = item.communityRating { parts.append("★ \(score.formatted(.number.precision(.fractionLength(1))))") }
        if let genres = item.genres?.prefix(3), !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// `facts` as VoiceOver should say them: "Season 1, Episode 2, 2024, rated PG-13, 2 hours,
    /// 9 minutes, rated 7.8 out of 10, Action, Drama".
    static func spokenFacts(for item: JellyfinItem) -> String {
        var parts: [String] = []
        if item.isEpisode, let code = item.spokenEpisodeCode { parts.append(code) }
        if let year = item.productionYear { parts.append(String(year)) }
        if let rating = item.officialRating { parts.append("rated \(rating)") }
        if item.isSeries, let count = item.childCount { parts.append(count == 1 ? "1 season" : "\(count) seasons") }
        if !item.isSeries, let runtime = item.spokenRuntime { parts.append(runtime) }
        if let score = item.communityRating {
            parts.append("rated \(score.formatted(.number.precision(.fractionLength(1)))) out of 10")
        }
        if let genres = item.genres?.prefix(3), !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

extension Color {
    /// The page behind content, which hero artwork fades into.
    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #elseif os(tvOS)
        // Black like a theater in the dark, rather than the system's gray.
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
        #elseif os(visionOS)
        Color.black
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

/// The overview, with the tagline above it. Four lines of it, until a tap shows the rest; on
/// Apple TV, where text can't take focus, the rest opens over the page when it's cut short.
struct OverviewText: View {
    let item: JellyfinItem
    @State private var expanded = false
    /// The four lines leave some of it out.
    @State private var isTruncated = false
    @State private var shownHeight: CGFloat = .infinity
    @State private var fullHeight: CGFloat = 0
    #if os(tvOS)
    @State private var showsAll = false
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
                text(overview)
                    .onTapGesture { withAnimation { expanded.toggle() } }
                    // What a tap does, to VoiceOver, Voice Control and Switch Control, when it does something.
                    .accessibilityAddTraits(isTruncated || expanded ? .isButton : [])
                    .accessibilityHint(expanded ? "Shows less" : isTruncated ? "Shows all of it" : "")
                    .accessibilityInputLabels(isTruncated || expanded ? ["Overview", "More"] : [])
                #endif
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
    }

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

/// The cast, with their pictures.
struct CastShelf: View {
    let people: [Person]
    @Environment(\.session) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let cast = people.filter { $0.type == "Actor" || $0.type == "GuestStar" }.prefix(20)
        if !cast.isEmpty {
            Shelf(title: "Cast", items: Array(cast), cardWidth: castWidth) { person in
                VStack(spacing: 6) {
                    Artwork(url: session?.person(person), aspectRatio: 1, cornerRadius: castWidth / 2, placeholder: "person.fill")
                    Text(person.name).font(.caption.weight(.medium)).lineLimit(dynamicTypeSize.lineLimit(1))
                    if let role = person.role, !role.isEmpty {
                        Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.lineLimit(1))
                    }
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                #if os(tvOS)
                .focusable()
                #endif
            }
        }
    }

    private var castWidth: CGFloat {
        #if os(tvOS)
        160
        #else
        88
        #endif
    }
}
