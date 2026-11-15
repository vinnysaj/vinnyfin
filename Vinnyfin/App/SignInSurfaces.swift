import AppIntents
import Foundation
import OSLog

/// What the system shows of the sign-in in use outside the app's windows: the title widgets and
/// the Continue Watching control on iPhone, iPad and the Mac, Apple TV's Top Shelf, the titles
/// Siri's phrases name (`VinnyfinShortcuts`), and what Siri has learned the person watches
/// (`PlaybackDonation`, and the playback's activity, `View.handoffPlayback`). All of it is brought
/// up to date as the sign-in in use changes, switched to, added or signed out of, so nothing of
/// one person's stays on show while another's is in use: on a Mac's desktop, beside an iPad's
/// window, or on a Lock Screen. Spotlight follows the sign-in itself (`SpotlightTitles`), and the
/// app delegate adds the Mac's Dock menu, which it keeps, to what each change refreshes.
enum SignInSurfaces {
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "surfaces")

    /// Brings them up to date with `refresh` each time the sign-in in use changes, for as long as
    /// the calling task lasts. The sign-in in use as it starts isn't a change.
    static func follow(_ accounts: AccountStore, refresh: @escaping @MainActor () async -> Void = SignInSurfaces.refresh) async {
        var previous: String??
        for await signIn in Observations({ accounts.account?.tokenKey }) {
            defer { previous = signIn }
            guard let last = previous, last != signIn else { continue }
            await refresh()
        }
    }

    static func refresh() async {
        #if os(tvOS)
        TopShelf.reload()
        #elseif os(iOS) || os(macOS)
        UpNextWidgets.reload()
        #endif
        VinnyfinShortcuts.updateAppShortcutParameters()
        await forgetWhatWasWatched()
    }

    /// What Siri learned of the last sign-in's watching: the intents given it as titles played,
    /// and the playbacks' activities it could suggest continuing.
    private static func forgetWhatWasWatched() async {
        for type in PlaybackDonation.types {
            do {
                try await IntentDonationManager.shared.deleteDonations(matching: .intentType(type))
            } catch {
                log.error("Couldn't delete what Siri learned of \(String(describing: type), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        #if !os(tvOS)
        await NSUserActivity.deleteAllSavedUserActivities()
        #endif
    }
}
