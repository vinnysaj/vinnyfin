import ImageIO
import OSLog
import SwiftUI
import WidgetKit

/// What to watch next on the signed-in server, as Home's Continue Watching row lists it.
struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration { upNextConfiguration(.continueWatching) }
}

/// The movies and shows added to the signed-in server last.
struct RecentlyAddedWidget: Widget {
    var body: some WidgetConfiguration { upNextConfiguration(.recentlyAdded) }
}

/// The signed-in user's favorite movies and shows, as Home's Favorites row lists them.
struct FavoritesWidget: Widget {
    var body: some WidgetConfiguration { upNextConfiguration(.favorites) }
}

/// A widget for a list of titles: each plays from where it was left, or opens its page, as the
/// row has it.
private func upNextConfiguration(_ row: UpNextWidgets.Row) -> some WidgetConfiguration {
    StaticConfiguration(kind: row.kind, provider: UpNextProvider(row: row)) { entry in
        UpNextView(entry: entry)
            .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName(row.title)
    .description(row.description)
    .supportedFamilies(upNextFamilies)
}

private var upNextFamilies: [WidgetFamily] {
    #if os(iOS)
    [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
    #else
    [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
    #endif
}

nonisolated struct UpNextEntry: TimelineEntry {
    var date = Date.now
    let row: UpNextWidgets.Row
    let content: UpNextWidgets.Content
}

/// One entry, the row as the server lists it now, with the pictures the widget draws: a widget
/// can't load anything once it's on screen. It asks again after a while, sooner after a failure,
/// and whenever the app has it reload.
nonisolated struct UpNextProvider: TimelineProvider {
    let row: UpNextWidgets.Row
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin.widgets", category: "UpNext")

    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(row: row, content: .tiles(Self.samples(of: row, count: UpNextWidgets.Layout(context.family).count)))
    }

    /// The gallery's preview shows the signed-in server's own titles when they come within
    /// `previewBudget`, and titles shaped like them otherwise, or when there are none to show.
    func getSnapshot(in context: Context, completion: @escaping @Sendable (UpNextEntry) -> Void) {
        let request = Request(context, row: row)
        guard context.isPreview else {
            Task { completion(await Self.entry(for: request)) }
            return
        }
        let samples = placeholder(in: context)
        Task {
            let entry = await withTaskGroup(of: UpNextEntry?.self) { group in
                group.addTask { await Self.entry(for: request) }
                group.addTask {
                    try? await Task.sleep(for: Self.previewBudget)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let entry, case .tiles(let tiles) = entry.content, !tiles.isEmpty else { return completion(samples) }
            completion(entry)
        }
    }

    static let previewBudget = Duration.seconds(2)

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<UpNextEntry>) -> Void) {
        let request = Request(context, row: row)
        Task {
            let entry = await Self.entry(for: request)
            let refresh = UpNextWidgets.refreshDate(for: entry.content, now: entry.date)
            completion(Timeline(entries: [entry], policy: refresh.map { .after($0) } ?? .never))
        }
    }

    /// What an entry is for: the row, and the widget's family and size.
    private struct Request: Sendable {
        let row: UpNextWidgets.Row
        let layout: UpNextWidgets.Layout
        /// How wide its pictures are drawn, in pixels; nil when it draws none.
        let pictureWidth: Int?

        init(_ context: TimelineProviderContext, row: UpNextWidgets.Row) {
            self.row = row
            layout = UpNextWidgets.Layout(context.family)
            // The sharpest screen the widget may be drawn on.
            #if os(macOS)
            let fallbackScale = 2.0
            #else
            let fallbackScale = 3.0
            #endif
            let scale = context.environmentVariants.displayScale?.max().map(Double.init) ?? fallbackScale
            pictureWidth = layout.pictureWidth(inWidgetWidth: Double(context.displaySize.width), scale: scale)
        }
    }

    private static func entry(for request: Request) async -> UpNextEntry {
        // The account store lives on the main actor, as it does in the app.
        let (session, problem) = await MainActor.run {
            let accounts = AccountStore()
            return (accounts.session, accounts.savedSignInProblem)
        }
        guard let session else {
            if let problem { log.error("Can't use the saved sign-in: \(problem, privacy: .public)") }
            return UpNextEntry(row: request.row, content: problem.map { .signInProblem($0) } ?? .signedOut)
        }
        do {
            let limit = request.layout.count
            let owner = AppLink.Owner(session.account)
            let items = try await session.client.page(of: request.row.source, userId: session.userId,
                                                      startIndex: 0, limit: limit).items
            var tiles = UpNextWidgets.tiles(from: items, limit: limit, for: request.row, owner: owner)
            var listed = items
            // The row's own titles show without the newest when those can't be had.
            if tiles.count < limit, UpNextWidgets.fills(request.row),
               let newest = try? await session.client.page(of: UpNextWidgets.Row.recentlyAdded.source, userId: session.userId,
                                                           startIndex: 0, limit: limit).items {
                tiles = UpNextWidgets.filling(tiles, from: newest, limit: limit, server: session.account.serverTitle, owner: owner)
                listed += newest
            }
            guard let width = request.pictureWidth else { return UpNextEntry(row: request.row, content: .tiles(tiles)) }
            let shown = Set(tiles.map(\.itemId))
            var picked = Set<String>()
            let pictures = await pictures(of: listed.filter { shown.contains($0.id) && picked.insert($0.id).inserted },
                                          width: width, session: session)
            return UpNextEntry(row: request.row, content: .tiles(UpNextWidgets.withArtwork(tiles, pictures: pictures)))
        } catch {
            log.error("Couldn't load \(request.row.title, privacy: .public) from \(session.client.serverURL, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return UpNextEntry(row: request.row, content: UpNextWidgets.content(for: error, server: session.account.serverTitle))
        }
    }

    /// Each title's wide picture, as Home's cards show it, asked for at the width drawn and kept
    /// as a small JPEG. A title whose picture can't be had goes without.
    private static func pictures(of items: [JellyfinItem], width: Int, session: ServerSession) async -> [String: Data] {
        await withTaskGroup(of: (String, Data?).self) { group in
            for item in items {
                guard let url = session.landscape(item, width: width) else { continue }
                group.addTask { (item.id, await picture(at: url, width: width)) }
            }
            var pictures: [String: Data] = [:]
            for await (itemId, picture) in group {
                pictures[itemId] = picture
            }
            return pictures
        }
    }

    private static func picture(at url: URL, width: Int) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.error("The server answered \(url, privacy: .public) with HTTP \(http.statusCode)")
                return nil
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let picture = WidgetArtwork.jpeg(from: source, maxPixelSize: width, quality: UpNextWidgets.artworkQuality)
            else {
                log.error("Couldn't read the picture at \(url, privacy: .public)")
                return nil
            }
            return picture
        } catch {
            log.error("Couldn't load the picture at \(url, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Titles shaped like the row's, for the widget gallery and while the widget first loads:
    /// episodes partway through, or movies and shows.
    private static func samples(of row: UpNextWidgets.Row, count: Int) -> [UpNextWidgets.Tile] {
        (1...count).map { number in
            guard row.plays else {
                var item = JellyfinItem(id: "placeholder-\(number)", name: number.isMultiple(of: 2) ? "A Show" : "A Movie",
                                        type: number.isMultiple(of: 2) ? "Series" : "Movie")
                item.productionYear = 2026
                return UpNextWidgets.Tile(item, plays: false)
            }
            var item = JellyfinItem(id: "placeholder-\(number)", name: "Episode \(number)", type: "Episode")
            item.seriesName = "A Show"
            item.parentIndexNumber = 1
            item.indexNumber = number
            // Partway through, as an episode the row resumes says how long it has left.
            if number.isMultiple(of: 2) {
                let minutes: Int64 = 45
                item.runTimeTicks = minutes * 60 * 10_000_000
                let watched = Double(20 + 15 * number) / 100
                item.userData = UserItemData(playbackPositionTicks: Int64(Double(item.runTimeTicks ?? 0) * min(0.9, watched)))
            }
            return UpNextWidgets.Tile(item)
        }
    }
}

// MARK: Views

private struct UpNextView: View {
    let entry: UpNextEntry

    var body: some View {
        switch entry.content {
        case .tiles(let tiles) where !tiles.isEmpty:
            TilesView(row: entry.row, tiles: tiles)
        case .tiles:
            Notice(symbol: "checkmark.circle", message: entry.row.emptyMessage)
        case .signedOut:
            Notice(symbol: "person.crop.circle", message: entry.row.signInMessage, short: "Sign in to vinnyfin")
        case .signInProblem(let problem):
            Notice(symbol: "person.crop.circle.badge.exclamationmark", message: "\(problem) Open vinnyfin to sign in.",
                   short: "Open vinnyfin to sign in")
        case .sessionEnded(let server):
            Notice(symbol: "person.crop.circle.badge.exclamationmark",
                   message: "Signed out of \(server). Open vinnyfin to sign in again.", short: "Signed out")
        case .unreachable(let server, let reason):
            Notice(symbol: "wifi.exclamationmark", message: "Can't reach \(server).", detail: reason, short: "Can't reach \(server)")
        }
    }
}

/// The titles: one with its picture in a small widget and side by side in the bigger ones, under
/// the row's name; text alone on the Lock Screen. A medium widget with one title gives it the
/// whole widget.
private struct TilesView: View {
    let row: UpNextWidgets.Row
    let tiles: [UpNextWidgets.Tile]
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular: CircularView(row: row, tile: tiles[0])
        case .accessoryRectangular: RectangularView(row: row, tile: tiles[0])
        case .accessoryInline:
            Label("\(tiles[0].title) · \(tiles[0].detail)", systemImage: row.symbol)
                .widgetURL(tiles[0].link)
        #endif
        case .systemSmall:
            TileView(tile: tiles[0], isLarge: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .widgetURL(tiles[0].link)
        case .systemMedium where tiles.count == 1:
            VStack(alignment: .leading, spacing: 8) {
                RowName(row: row)
                WideTileView(tile: tiles[0])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(tiles[0].link)
        default:
            grid
        }
    }

    private var grid: some View {
        let layout = UpNextWidgets.Layout(family)
        let rows = stride(from: 0, to: layout.count, by: layout.columns).map { start in
            (start..<start + layout.columns).map { $0 < tiles.count ? tiles[$0] : nil }
        }
        // One row of titles has the height left under the row's name, and its pictures give way.
        let isOneRow = rows.count == 1
        return VStack(alignment: .leading, spacing: isOneRow ? 6 : UpNextWidgets.Layout.spacing) {
            RowName(row: row)
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: UpNextWidgets.Layout.spacing) {
                    ForEach(rows[index].indices, id: \.self) { column in
                        if let tile = rows[index][column] {
                            Link(destination: tile.link) { TileView(tile: tile, isLarge: false, givesWay: isOneRow) }
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                }
            }
            if !isOneRow { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Which list the widget is, over its titles: Recently Added and Favorites look alike otherwise.
private struct RowName: View {
    let row: UpNextWidgets.Row

    var body: some View {
        Label(row.title, systemImage: row.symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// A title as Home's landscape cards show it: its picture with how far through it is, its name
/// and what's next of it. One that plays has a play button on its picture.
private struct TileView: View {
    let tile: UpNextWidgets.Tile
    /// Alone in a small widget, in bigger type.
    let isLarge: Bool
    /// The picture takes the height the name leaves, rather than its own.
    var givesWay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Artwork(data: tile.artwork, givesWay: givesWay)
                .overlay(alignment: .bottom) {
                    if let progress = tile.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 5)
                    }
                }
                .overlay {
                    if tile.plays { PlayButton(isLarge: isLarge) }
                }
            TileText(tile: tile, isLarge: isLarge)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One title across a medium widget: its picture beside its name.
private struct WideTileView: View {
    let tile: UpNextWidgets.Tile

    var body: some View {
        HStack(alignment: .center, spacing: UpNextWidgets.Layout.spacing) {
            Artwork(data: tile.artwork)
                .overlay(alignment: .bottom) {
                    if let progress = tile.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 5)
                    }
                }
                .overlay {
                    if tile.plays { PlayButton(isLarge: true) }
                }
                .frame(maxWidth: .infinity)
            TileText(tile: tile, isLarge: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct TileText: View {
    let tile: UpNextWidgets.Tile
    let isLarge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tile.title)
                .font(isLarge ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                .lineLimit(1)
            Text(tile.detail)
                .font(isLarge ? .caption : .caption2)
                .foregroundStyle(.secondary)
                .lineLimit(isLarge ? 2 : 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Says a tap plays the title, from where it was left.
private struct PlayButton: View {
    let isLarge: Bool

    var body: some View {
        Image(systemName: "play.fill")
            .font(isLarge ? .body : .caption)
            .foregroundStyle(.white)
            .frame(width: isLarge ? 36 : 28, height: isLarge ? 36 : 28)
            .background(.black.opacity(0.5), in: .circle)
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

/// A title's picture, 16:9, or a plain tile without one. One that gives way takes the room it's
/// given, and is cut to it.
private struct Artwork: View {
    let data: Data?
    var givesWay = false

    var body: some View {
        frame
            .background(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .widgetAccentedRenderingMode(.accentedDesaturated)
                        .scaledToFill()
                } else {
                    Image(systemName: "play.rectangle").foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
    }

    @ViewBuilder private var frame: some View {
        if givesWay {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
    }

    private var image: CGImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

#if os(iOS)
/// How far through the first title is, around the row's symbol.
private struct CircularView: View {
    let row: UpNextWidgets.Row
    let tile: UpNextWidgets.Tile

    var body: some View {
        Group {
            if let progress = tile.progress {
                Gauge(value: progress) {
                    Image(systemName: row.symbol)
                } currentValueLabel: {
                    Image(systemName: row.symbol)
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: row.symbol).font(.title3)
                }
            }
        }
        .widgetURL(tile.link)
        .accessibilityLabel("\(row.plays ? "Play" : "Open") \(tile.title), \(tile.detail)")
    }
}

private struct RectangularView: View {
    let row: UpNextWidgets.Row
    let tile: UpNextWidgets.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tile.title).font(.headline).lineLimit(1)
            Text(tile.detail).font(.caption).lineLimit(1)
            if let progress = tile.progress {
                ProgressView(value: progress).progressViewStyle(.linear)
            } else {
                Label(row.title, systemImage: row.symbol).font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(tile.link)
    }
}
#endif

/// Why there are no titles to show, in place of them. A tap opens the app.
private struct Notice: View {
    let symbol: String
    let message: String
    var detail: String?
    /// The message in a few words, for the Lock Screen.
    var short: String?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol).font(.title3)
            }
            .accessibilityLabel(short ?? message)
        case .accessoryRectangular:
            Label(short ?? message, systemImage: symbol)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label(short ?? message, systemImage: symbol)
        #endif
        default:
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2)
                Text(message).font(.caption)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
