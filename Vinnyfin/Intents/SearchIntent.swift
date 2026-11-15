import AppIntents

/// Searches vinnyfin, as Spotlight's Search in App and "Search vinnyfin for westerns" ask: the
/// Search tab opens on what was asked for, which it searches for as if it was typed.
#if !os(tvOS)
@AppIntent(schema: .system.searchInApp)
#endif
struct SearchTitlesIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search vinnyfin"
    static let description = IntentDescription("Searches your server's movies, shows, episodes, people and genres in vinnyfin.")
    static let searchScopes: [StringSearchScope] = [.general, .movies, .tv]

    @Parameter(title: "Search For")
    var criteria: StringSearchCriteria

    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        links.search(criteria.term)
        return .result()
    }
}
