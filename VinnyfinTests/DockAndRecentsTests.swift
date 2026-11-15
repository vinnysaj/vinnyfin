#if !os(tvOS)
import Foundation
import Testing
@testable import vinnyfin

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
