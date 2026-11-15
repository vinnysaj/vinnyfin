import AppIntents
import OSLog
import SwiftUI
import WidgetKit

/// A button for Control Center, the Lock Screen and the Action button that plays the first title
/// of Continue Watching from where it was left, the one the Continue Watching widget shows first,
/// and names it. Its intent runs in the app, which comes forward to play it.
struct ContinueWatchingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: UpNextWidgets.controlKind, provider: Provider()) { title in
            ControlWidgetButton(action: ResumeWatchingIntent()) {
                Label {
                    Text("Continue Watching")
                    if let title { Text(title) }
                } icon: {
                    Image(systemName: "play.fill")
                }
            }
        }
        .displayName("Continue Watching")
        .description("Plays what you're watching in vinnyfin from where you left it.")
    }

    /// The name of the title the button plays, as the widget's first tile names it; nil with
    /// nobody signed in, nothing to continue, or the server out of reach.
    struct Provider: ControlValueProvider {
        private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin.widgets", category: "ContinueWatchingControl")

        var previewValue: String? { nil }

        func currentValue() async throws -> String? {
            // The account store lives on the main actor, as it does in the app.
            guard let session = await MainActor.run(body: { AccountStore().session }) else { return nil }
            do {
                let items = try await session.client.page(of: UpNextWidgets.Row.continueWatching.source, userId: session.userId,
                                                          startIndex: 0, limit: 4).items
                return UpNextWidgets.tiles(from: items, limit: 1).first?.title
            } catch {
                Self.log.error("Couldn't load Continue Watching from \(session.client.serverURL, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }
}
