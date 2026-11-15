import SwiftUI
import WidgetKit

/// The app's widgets and controls. The Downloads widget and control only read the snapshot the
/// app writes to the app group (`DownloadsSnapshot`), and their buttons run their intent in the
/// app. The Continue Watching, Recently Added and Favorites widgets, and the Continue Watching
/// control, read the sign-in from the app group and ask the server themselves (`UpNextWidgets`);
/// the control's button plays in the app (`ResumeWatchingIntent`).
@main
struct DownloadsWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        RecentlyAddedWidget()
        FavoritesWidget()
        DownloadsWidget()
        DownloadsControl()
        ContinueWatchingControl()
    }
}
