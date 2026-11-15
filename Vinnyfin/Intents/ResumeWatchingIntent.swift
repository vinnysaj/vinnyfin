#if os(iOS) || os(macOS)
import AppIntents

/// Finds what to resume and plays it, for the Continue Watching control. The app's
/// `ContinueWatchingResumer` is this; the widget extension, which compiles the control's intent
/// too, has none.
@MainActor
protocol WatchingResumer: AnyObject, Sendable {
    /// The first title of Continue Watching, as a link that plays it under the sign-in in use.
    /// Throws, for Siri to say why, when there's nothing to resume or nobody signed in.
    func titleToResume() async throws -> AppLink

    /// Plays the title as the app's own Resume does.
    func play(_ link: AppLink)
}

/// Plays the first title of Continue Watching from where it was left, the one the Continue
/// Watching widget shows first, for the control of that name in Control Center, on the Lock Screen
/// and on the Action button. The control shows in the widget extension, which only draws it: the
/// intent runs in the app, which works out what to play in the background, where Siri can say why
/// there's nothing, then comes forward to play it.
struct ResumeWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Watching"
    static let description = IntentDescription("Plays the first title of Continue Watching from where you left it.")
    static let isDiscoverable = false
    static let allowedExecutionTargets: IntentExecutionTargets = .main
    static let supportedModes: IntentModes = .foreground(.deferred)

    @Dependency private var resumer: any WatchingResumer

    @MainActor
    func perform() async throws -> some IntentResult {
        let link = try await resumer.titleToResume()
        try await continueInForeground(alwaysConfirm: false)
        resumer.play(link)
        return .result()
    }
}
#endif
