import SwiftUI

/// When a title would end if it started now, from where Play starts it: from just before its
/// resume position (`PlaybackRequest.resumeLeadIn`), else from its start.
nonisolated enum EndTime {
    static func end(of item: JellyfinItem, now: Date) -> Date? {
        guard item.isPlayable, !item.isNotYetAvailable(now: now), let length = item.runtimeSeconds, length > 0 else { return nil }
        let start = item.resumeSeconds.map { max(0, $0 - PlaybackRequest.resumeLeadIn) } ?? 0
        guard start < length else { return nil }
        return now.addingTimeInterval(length - start)
    }

    /// "Ends at 3:12 PM"'s time, "3:12 PM", in the device's time zone and clock.
    static func text(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// The facts a title's Information section lists, each a label over its value.
nonisolated enum TitleFacts {
    struct Fact: Equatable, Identifiable, Sendable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// `item`'s facts, with `credits`' crew and the languages of `source`, the version that plays.
    /// `now` adds when the title would end if started then.
    static func facts(for item: JellyfinItem, source: MediaSource?, credits: Credits, now: Date?) -> [Fact] {
        var facts: [Fact] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { facts.append(Fact(label: label, value: value)) }
        }
        if item.isSeries {
            add("Aired", airedYears(of: item))
            add("Status", status(of: item))
        } else {
            add(item.isEpisode ? "Aired" : "Released", item.premiere.map(JellyfinDate.day))
            add("Run Time", item.runtimeText)
            add("Ends At", now.flatMap { EndTime.end(of: item, now: $0) }.map(EndTime.text))
        }
        add("Rated", item.officialRating)
        let studios = (item.studios ?? []).map(\.name)
        add(item.isSeries ? (studios.count == 1 ? "Network" : "Networks") : (studios.count == 1 ? "Studio" : "Studios"),
            studios.formatted(.list(type: .and)))
        for (job, label) in [("Creator", "Created By"), ("Director", "Directed By"), ("Writer", "Written By")] {
            add(label, credits.people(doing: job).map(\.name).formatted(.list(type: .and)))
        }
        if let source {
            add("Audio", languages(of: source.audioStreams))
            add("Subtitles", languages(of: source.subtitleStreams))
        }
        return facts
    }

    /// "2019–2023", "2019–Present" for a show still airing, or "2019" for one aired within a year.
    static func airedYears(of show: JellyfinItem) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let first = show.premiere.map({ calendar.component(.year, from: $0) }) ?? show.productionYear else { return nil }
        if let last = show.endDate.flatMap(JellyfinDate.parse).map({ calendar.component(.year, from: $0) }) {
            return last > first ? "\(first)–\(last)" : String(first)
        }
        return show.status == "Continuing" ? "\(first)–Present" : String(first)
    }

    /// Whether a show is still airing, as the server's metadata says.
    static func status(of show: JellyfinItem) -> String? {
        switch show.status {
        case "Continuing": "Continuing"
        case "Ended": "Ended"
        case "Unreleased": "Not Yet Aired"
        default: nil
        }
    }

    /// The languages of `streams`, each once, in their order: "English, French".
    static func languages(of streams: [MediaStream]) -> String? {
        var names: [String] = []
        for code in streams.compactMap(\.language) where !code.isEmpty && code != "und" {
            let name = AppSettings.displayName(for: code)
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? nil : names.formatted(.list(type: .and))
    }
}

/// A title's Information: when it came out and how long it runs, when it would end if started
/// now, its rating, who made it, and the languages it plays in, in columns as the width allows.
/// On Apple TV the section takes focus as a whole, so the remote can scroll down to it.
struct TitleInformation: View {
    let item: JellyfinItem
    /// The version that plays, whose audio and subtitle languages are listed.
    let source: MediaSource?
    let credits: Credits
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        // Each minute, for when the title would end.
        TimelineView(.everyMinute) { context in
            let facts = TitleFacts.facts(for: item, source: source, credits: credits, now: context.date)
            if !facts.isEmpty { section(facts) }
        }
    }

    private func section(_ facts: [TitleFacts.Fact]) -> some View {
        VStack(alignment: .leading, spacing: headerSpacing) {
            Text("Information")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: columnWidth), spacing: Metrics.gridSpacing, alignment: .topLeading)],
                      alignment: .leading, spacing: 16) {
                ForEach(facts) { fact in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.label)
                            .font(.subheadline.weight(.semibold))
                        Text(fact.value)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("info.\(fact.label)")
                }
            }
            #if os(tvOS)
            .padding(Self.highlightMargin)
            .background(.quaternary.opacity(isFocused ? 0.6 : 0), in: .rect(cornerRadius: Metrics.noticeRadius))
            .padding(-Self.highlightMargin)
            .focusable()
            .focused($isFocused)
            .animation(.easeOut(duration: 0.2), value: isFocused)
            #endif
        }
        .padding(.horizontal, Metrics.edge)
        .frame(maxWidth: 1400, alignment: .leading)
    }

    #if os(tvOS)
    /// How far the focus highlight reaches past the facts.
    private static let highlightMargin: CGFloat = 24
    #endif

    /// Room under the header, which on Apple TV clears the focus highlight too.
    private var headerSpacing: CGFloat {
        #if os(tvOS)
        12 + Self.highlightMargin
        #else
        12
        #endif
    }

    /// The narrowest a column gets, as many fitting across as will; one column at the
    /// accessibility text sizes.
    private var columnWidth: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 600 }
        #if os(tvOS)
        return 340
        #elseif os(iOS)
        return 150
        #else
        return 200
        #endif
    }
}
