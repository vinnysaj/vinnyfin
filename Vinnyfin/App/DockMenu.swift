#if !os(tvOS)
import Foundation
#if os(macOS)
import AppKit
import OSLog
import SwiftUI
#endif

/// The Mac's Dock icon: a badge counting the downloads to come, and a menu of what's up next
/// with the app's quick actions, Open File…, pausing or resuming the downloads, and Portable TV.
nonisolated enum DockTile {
    /// The badge: how many downloads are under way or waiting their turn; none at none.
    static func badge(for jobs: [DownloadJob]) -> String? {
        let count = DownloadJob.queued(jobs).count
        return count > 0 ? "\(count)" : nil
    }

    /// What the menu's downloads item does, as Pause All and Resume All do in Downloads.
    enum DownloadsAction: Equatable {
        case pause, resume

        var title: String {
            switch self {
            case .pause: "Pause Downloads"
            case .resume: "Resume Downloads"
            }
        }
    }

    /// Pause while any download is to come, else resume while any is paused; with neither, nil
    /// and no item.
    static func downloadsAction(for jobs: [DownloadJob]) -> DownloadsAction? {
        let unfinished = jobs.filter { $0.status != .completed }
        if unfinished.contains(where: { $0.status == .active }) { return .pause }
        if unfinished.contains(where: { $0.status == .paused }) { return .resume }
        return nil
    }

    /// How many of Continue Watching's titles the menu lists.
    static let titleLimit = 5
}

#if os(macOS)
/// Keeps the Dock icon's badge and the titles its menu lists, and makes the menu as it's opened.
final class DockMenu: NSObject {
    private let accounts: AccountStore
    private let downloads: DownloadManager
    private let links: IncomingLinks
    private let openFile: () -> Void
    /// Continue Watching's first titles, as they were last asked for.
    private var titles: [UpNextWidgets.Tile] = []
    /// Opens Portable TV's window: SwiftUI's, which AppKit's menu can't reach by itself.
    var openWindow: OpenWindowAction?

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "dock")

    init(accounts: AccountStore, downloads: DownloadManager, links: IncomingLinks, openFile: @escaping () -> Void) {
        self.accounts = accounts
        self.downloads = downloads
        self.links = links
        self.openFile = openFile
    }

    /// Follows the downloads, for the badge, as long as the app runs.
    func followDownloads() async {
        let downloads = downloads
        for await badge in Observations({ DockTile.badge(for: downloads.jobs) }) {
            NSApp.dockTile.badgeLabel = badge
        }
    }

    /// Asks the server for what's up next, for the menu to list without waiting on it.
    func refreshTitles() async {
        guard let session = accounts.session else {
            titles = []
            return
        }
        do {
            let items = try await session.client.upNext(userId: session.userId, limit: DockTile.titleLimit * 2).items
            titles = UpNextWidgets.tiles(from: items, limit: DockTile.titleLimit)
        } catch {
            // The menu keeps the titles it had.
            Self.log.notice("Couldn't refresh the Dock menu's titles: \(error.localizedDescription, privacy: .public)")
        }
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        if !titles.isEmpty {
            menu.addItem(.sectionHeader(title: UpNextWidgets.Row.continueWatching.title))
            for tile in titles {
                let item = NSMenuItem(title: tile.title, action: #selector(play(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tile.link
                if !tile.detail.isEmpty { item.subtitle = tile.detail }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(item("Open File…", #selector(openFileChosen)))
        if let action = DockTile.downloadsAction(for: downloads.jobs) {
            menu.addItem(item(action.title, action == .pause ? #selector(pauseDownloads) : #selector(resumeDownloads)))
        }
        if openWindow != nil {
            menu.addItem(item("Portable TV", #selector(openPortableTV)))
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Plays the title from where it was left, in the library window, as the widget's tile does.
    @objc private func play(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? URL else { return }
        NSApp.activate()
        links.open(link)
    }

    @objc private func openFileChosen() {
        NSApp.activate()
        openFile()
    }

    @objc private func pauseDownloads() {
        downloads.pauseAll()
    }

    @objc private func resumeDownloads() {
        downloads.resumeAll()
    }

    @objc private func openPortableTV() {
        NSApp.activate()
        openWindow?(id: PortableTVWindow.id)
    }
}

/// Hands the Dock menu SwiftUI's action for opening windows, from the first window that shows.
struct DockMenuWindows: View {
    let dockMenu: DockMenu
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { dockMenu.openWindow = openWindow }
    }
}
#endif
#endif
