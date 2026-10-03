import XCTest
@testable import CapyFlow

final class OfflineDownloadRemovalTests: XCTestCase {
    func testCanonicalAliasRemovesAllQualitiesButKeepsOtherRecordingsAndEditions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var row = Track(id: "album-row", title: "Song", artist: "Artist"); row.isExplicit = false
        var normal = row; normal.mediaID = "canonical"; normal.downloadQuality = "normal"
        var high = Track(id: "songs-row", title: "Song", artist: "Artist"); high.mediaID = "canonical"; high.downloadQuality = "high"; high.isExplicit = false
        var explicit = high; explicit.isExplicit = true; explicit.downloadQuality = "explicit-fixture"
        let other = Track(id: "unrelated", title: "Other", artist: "Artist")
        let copies = [normal, high, explicit, other]
        func localURL(_ track: Track) -> URL { folder.appendingPathComponent(track.playableID + (track.downloadQuality ?? "") + ".m4a") }
        for copy in copies { try Data([1, 2, 3]).write(to: localURL(copy)) }
        let selected = OfflineDownloadRemoval.copies(for: [row], in: copies)
        XCTAssertEqual(selected.count, 2)
        try OfflineDownloadRemoval.removeFiles(selected, localURL: localURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL(normal).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL(high).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL(explicit).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL(other).path))
    }

    @MainActor func testDeleteDownloadImmediatelyClearsStateAndKeepsPlaylistEntries() throws {
        let player = WavePlayer()
        let media = UUID().uuidString
        var row = Track(id: "album-" + media, title: "Song", artist: "Artist"); row.isExplicit = false
        var copy = row; copy.mediaID = media; copy.downloadQuality = player.audioQuality.backendValue
        let file = player.localURL(copy)
        let index = file.deletingLastPathComponent().appendingPathComponent("library.json")
        let previousIndex = try? Data(contentsOf: index)
        defer {
            try? FileManager.default.removeItem(at: file)
            if let previousIndex { try? previousIndex.write(to: index) } else { try? FileManager.default.removeItem(at: index) }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: file)
        player.downloads = [copy]
        let playlist = ImportedPlaylist(id: "fixture", name: "Keep me", tracks: [row])
        player.playlists = [playlist]
        player.downloadStates[row.id] = TrackDownloadState(stage: .downloaded, progress: 1, source: "MSI cache hit", attempt: 1, elapsedSeconds: 9, detail: nil)
        player.downloadBatchSummary = DownloadBatchSummary(playlistID: playlist.id, total: 1, completed: 1, failed: 0, active: 0, queued: 0, startedAt: Date(), finishedAt: Date())
        XCTAssertTrue(player.isPlaylistDownloaded(playlist), "Album row alias must find the canonical offline file")
        player.delete(row)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(player.downloads.isEmpty)
        XCTAssertFalse(player.isPlaylistDownloaded(playlist))
        XCTAssertEqual(player.playlists.first?.tracks, playlist.tracks)
        XCTAssertNil(player.downloadStates[row.id])
        XCTAssertNil(player.downloadBatchSummary)
    }

    @MainActor func testDeletingPlaylistKeepsDownloadedAudio() throws {
        let previousPlaylists = UserDefaults.standard.data(forKey: "importedPlaylists")
        defer { if let previousPlaylists { UserDefaults.standard.set(previousPlaylists, forKey: "importedPlaylists") } else { UserDefaults.standard.removeObject(forKey: "importedPlaylists") } }
        let player = WavePlayer()
        var copy = Track(id: UUID().uuidString, title: "Song", artist: "Artist"); copy.downloadQuality = player.audioQuality.backendValue
        let file = player.localURL(copy)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        player.downloads = [copy]
        let playlist = ImportedPlaylist(id: UUID().uuidString, name: "Remove only playlist", tracks: [copy])
        player.playlists = [playlist]
        player.deletePlaylist(playlist.id)
        XCTAssertTrue(player.playlists.isEmpty)
        XCTAssertEqual(player.downloads, [copy])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testNormalDownloadStatusDoesNotExposeBackendOrTransferTiming() {
        let state = TrackDownloadState(stage: .downloaded, progress: 1, source: "MSI cache hit", attempt: 1, elapsedSeconds: 25, detail: "cache status")
        XCTAssertEqual(state.statusText, "Downloaded")
        let transfer = TrackDownloadState(stage: .downloading, progress: 0.5, source: "MSI new extraction", attempt: 1, elapsedSeconds: 25, detail: nil)
        XCTAssertEqual(transfer.statusText, "Downloading · 50%")
    }
}
