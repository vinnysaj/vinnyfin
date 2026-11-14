#if !os(tvOS)
import SwiftUI

/// The ways to keep a show downloaded, as a menu: the next few episodes, or every unwatched one,
/// which first says how much space that takes; and a way to stop. `actions` go above them: one-off
/// downloads, or what to do with what's downloaded.
struct SmartDownloadMenu<Actions: View, MenuLabel: View>: View {
    let seriesId: String
    let seriesName: String
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var label: () -> MenuLabel

    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppSettings.self) private var settings
    @Environment(AppMessages.self) private var messages
    /// What keeping every unwatched episode would add, while it waits to be confirmed.
    @State private var estimate: DownloadEstimate?

    var body: some View {
        let rule = smartDownloads.rule(for: seriesId)
        Menu {
            actions()
            Section("Keep Downloaded") {
                SmartDownloadCounts(seriesId: seriesId, seriesName: seriesName)
                Button {
                    Task { await estimateEveryUnwatched() }
                } label: {
                    SmartDownloadChoice(title: "Every Unwatched Episode", isChosen: rule != nil && rule?.episodesAhead == nil)
                }
                .disabled(rule != nil && rule?.episodesAhead == nil)
            }
            if rule != nil {
                StopSmartDownloads(seriesId: seriesId)
            }
        } label: {
            label()
        }
        .confirmationDialog("Keep Every Unwatched Episode?",
                            isPresented: Binding(get: { estimate != nil }, set: { if !$0 { estimate = nil } }),
                            titleVisibility: .visible, presenting: estimate) { _ in
            Button("Keep Every Unwatched Episode") {
                smartDownloads.setRule(seriesId: seriesId, seriesName: seriesName, episodesAhead: nil)
            }
            .accessibilityIdentifier("smart.everyUnwatched.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { estimate in
            Text(message(for: estimate))
        }
    }

    private func estimateEveryUnwatched() async {
        do {
            estimate = try await smartDownloads.everyUnwatchedEstimate(seriesId: seriesId)
        } catch {
            messages.show("Couldn't work out what \(seriesName) would download: \(error.localizedDescription)")
        }
    }

    private func message(for estimate: DownloadEstimate) -> String {
        let deleting = settings.deleteWatchedEpisodes ? " and each is deleted once it's watched" : ""
        let ongoing = "New episodes download as they're added to the server\(deleting)."
        guard estimate.count > 0 else {
            return "Every unwatched episode of \(seriesName) is downloaded or on its way. \(ongoing)"
        }
        let size = "\(seriesName) has \(estimate.summary(noun: "unwatched episode", plural: "unwatched episodes")) to download."
        let space = downloads.spaceForNewDownloads()
        let room = estimate.shortfall(space: space) ?? space.map { "\(DownloadEstimate.text(max(0, $0))) is free for downloads." }
        return [size, room, ongoing].compactMap(\.self).joined(separator: " ")
    }
}

/// The counts of episodes ahead a show can be kept downloaded with, the one it's kept with
/// checked; for a menu. A count it was kept with that isn't among them is offered too, checked.
struct SmartDownloadCounts: View {
    let seriesId: String
    let seriesName: String
    @Environment(SmartDownloads.self) private var smartDownloads

    static let counts = [3, 5, 10, 20]

    /// The counts offered, given the one a show is kept with, if any: the standard ones, and the
    /// show's own among them in order.
    static func counts(keeping chosen: Int?) -> [Int] {
        guard let chosen, !counts.contains(chosen) else { return counts }
        return (counts + [chosen]).sorted()
    }

    var body: some View {
        let chosen = smartDownloads.rule(for: seriesId)?.episodesAhead
        ForEach(Self.counts(keeping: chosen), id: \.self) { count in
            Button {
                smartDownloads.setRule(seriesId: seriesId, seriesName: seriesName, episodesAhead: count)
            } label: {
                SmartDownloadChoice(title: "Next \(count) Episodes", isChosen: chosen == count)
            }
        }
    }
}

/// Stops keeping a show downloaded; what's downloaded stays.
struct StopSmartDownloads: View {
    let seriesId: String
    @Environment(SmartDownloads.self) private var smartDownloads

    var body: some View {
        Button("Stop Smart Downloads", systemImage: "xmark", role: .destructive) {
            smartDownloads.removeRule(seriesId: seriesId)
        }
    }
}

/// A choice in a menu, checked when it's the one made.
private struct SmartDownloadChoice: View {
    let title: String
    let isChosen: Bool

    var body: some View {
        if isChosen { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
#endif
