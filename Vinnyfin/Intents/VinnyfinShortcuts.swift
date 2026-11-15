import AppIntents

/// The intents as App Shortcuts, which work from Siri and Spotlight without setting anything up.
/// An app has at most ten, which these are; Apple TV, without downloads, has the first six. A
/// phrase with a title in it matches the titles the title's query suggests, which
/// `updateAppShortcutParameters()` hands the system. Pausing and resuming downloads share one,
/// whose phrase says which.
nonisolated struct VinnyfinShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueWatchingIntent(), phrases: [
            "Continue watching \(\.$show) in \(.applicationName)",
            "Keep watching \(\.$show) in \(.applicationName)",
            "Watch \(\.$show) in \(.applicationName)",
            "Play \(\.$show) in \(.applicationName)",
            "Continue watching in \(.applicationName)",
        ], shortTitle: "Continue Watching", systemImageName: "play.tv")
        AppShortcut(intent: PlayNextEpisodeIntent(), phrases: [
            "Play the next episode of \(\.$show) in \(.applicationName)",
            "Watch the next episode of \(\.$show) in \(.applicationName)",
            "Play the next episode in \(.applicationName)",
        ], shortTitle: "Play Next Episode", systemImageName: "forward.end")
        AppShortcut(intent: PlayMovieIntent(), phrases: [
            "Play the movie \(\.$movie) in \(.applicationName)",
            "Watch the movie \(\.$movie) in \(.applicationName)",
            "Play \(\.$movie) in \(.applicationName)",
            "Play a movie in \(.applicationName)",
        ], shortTitle: "Play Movie", systemImageName: "play.rectangle")
        AppShortcut(intent: OpenShowIntent(), phrases: [
            "Open \(\.$target) in \(.applicationName)",
            "Show me \(\.$target) in \(.applicationName)",
            "Open a show in \(.applicationName)",
        ], shortTitle: "Open Show", systemImageName: "tv")
        AppShortcut(intent: OpenMovieIntent(), phrases: [
            "Open the movie \(\.$target) in \(.applicationName)",
            "Show me the movie \(\.$target) in \(.applicationName)",
            "Open a movie in \(.applicationName)",
        ], shortTitle: "Open Movie", systemImageName: "film")
        AppShortcut(intent: SearchTitlesIntent(), phrases: [
            "Search \(.applicationName)",
            "Search in \(.applicationName)",
            "Find something in \(.applicationName)",
        ], shortTitle: "Search", systemImageName: "magnifyingglass")
        #if !os(tvOS)
        AppShortcut(intent: DownloadNextEpisodesIntent(), phrases: [
            "Download the next episodes of \(\.$show) in \(.applicationName)",
            "Download more \(\.$show) in \(.applicationName)",
            "Download the next episodes in \(.applicationName)",
        ], shortTitle: "Download Next Episodes", systemImageName: "arrow.down.circle")
        AppShortcut(intent: DownloadMovieIntent(), phrases: [
            "Download the movie \(\.$movie) in \(.applicationName)",
            "Download a movie in \(.applicationName)",
        ], shortTitle: "Download Movie", systemImageName: "arrow.down.to.line")
        AppShortcut(intent: PauseOrResumeDownloadsIntent(), phrases: [
            "\(\.$action) downloads in \(.applicationName)",
            "\(\.$action) my \(.applicationName) downloads",
            "Pause or resume downloads in \(.applicationName)",
        ], shortTitle: "Pause or Resume Downloads", systemImageName: "playpause.circle")
        AppShortcut(intent: DownloadStatusIntent(), phrases: [
            "What's downloading in \(.applicationName)",
            "Check my \(.applicationName) downloads",
        ], shortTitle: "What's Downloading", systemImageName: "arrow.down.circle.dotted")
        #endif
    }
}
