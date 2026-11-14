import SwiftUI
import WidgetKit

/// The app's widgets and control. The Downloads widget and control only read the snapshot the
/// app writes to the app group (`DownloadsSnapshot`), and the control's switch runs its intent in
/// the app. The Continue Watching widget reads the sign-in from the app group and asks the server
/// itself (`UpNextWidgets`).
@main
struct DownloadsWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        DownloadsWidget()
        DownloadsControl()
    }
}
