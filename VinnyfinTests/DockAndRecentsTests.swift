#if !os(tvOS)
import Foundation
import Testing
@testable import vinnyfin

private func job(_ status: DownloadJob.Status, at offset: TimeInterval = 0) -> DownloadJob {
    var job = DownloadJob(item: Samples.movie, source: Samples.source, now: Date(timeIntervalSince1970: 1_000_000 + offset))
    job.status = status
    return job
}

/// The Mac's Dock icon counts the downloads to come, and its menu pauses or resumes them as
/// Downloads' Pause All and Resume All do.
struct DockTileTests {
    @Test func theBadgeCountsTheDownloadsToCome() {
        #expect(DockTile.badge(for: []) == nil)
        #expect(DockTile.badge(for: [job(.completed), job(.paused), job(.failed)]) == nil)
        #expect(DockTile.badge(for: [job(.active), job(.active, at: 1), job(.paused, at: 2), job(.completed, at: 3)]) == "2")
    }

    @Test func theMenuPausesWhileAnyDownloadIsToComeElseResumes() {
        #expect(DockTile.downloadsAction(for: [job(.active), job(.paused, at: 1)]) == .pause)
        #expect(DockTile.downloadsAction(for: [job(.paused), job(.completed, at: 1)]) == .resume)
        #expect(DockTile.downloadsAction(for: [job(.completed), job(.failed, at: 1)]) == nil)
        #expect(DockTile.downloadsAction(for: []) == nil)
        #expect(DockTile.DownloadsAction.pause.title == "Pause Downloads")
        #expect(DockTile.DownloadsAction.resume.title == "Resume Downloads")
    }
}

/// File › Open Recent lists the files opened last, and its Clear Menu forgets them.
@MainActor
struct OpenRecentTests {
    private func library(with count: Int) throws -> (LocalLibrary, URL) {
        let file = FileManager.default.temporaryDirectory.appending(path: "OpenRecent-\(UUID().uuidString).json")
        let recents = (0..<count).map { index in
            LocalLibrary.Recent(name: "Film \(index).mkv", bookmark: Data([UInt8(index)]), size: Int64(index),
                                openedAt: Date(timeIntervalSince1970: TimeInterval(1_000_000 - index)))
        }
        try JSONEncoder().encode(recents).write(to: file)
        return (LocalLibrary(file: file, folder: nil), file)
    }

    @Test func listsTheLastOpenedFirstUpToTheMacsLimit() throws {
        let (library, file) = try library(with: 12)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(library.openRecent.count == LocalLibrary.openRecentLimit)
        #expect(library.openRecent.first?.name == "Film 0.mkv")
        #expect(library.openRecent.last?.name == "Film 9.mkv")

        let (few, fewFile) = try self.library(with: 3)
        defer { try? FileManager.default.removeItem(at: fewFile) }
        #expect(few.openRecent.map(\.name) == ["Film 0.mkv", "Film 1.mkv", "Film 2.mkv"])
    }

    @Test func clearMenuForgetsThemForGood() throws {
        let (library, file) = try library(with: 4)
        defer { try? FileManager.default.removeItem(at: file) }
        library.clearRecents()
        #expect(library.openRecent.isEmpty)
        #expect(LocalLibrary(file: file, folder: nil).recents.isEmpty)
    }

    @Test func aRecentPlaysAsItsFileTitledByItsName() throws {
        let (library, file) = try library(with: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let request = try #require(library.openRecent.first).request
        #expect(request.title == "Film 0")
        guard case .file(let bookmark, let name) = request.source else {
            Issue.record("Not a file: \(request.source)")
            return
        }
        #expect(bookmark == Data([0]))
        #expect(name == "Film 0.mkv")
    }
}
#endif
