import XCTest
@testable import CapyFlow

final class PlaylistCloudSyncTests: XCTestCase {
    func testPlaylistAndCoverRoundTripRetainsPlayableIdentity() throws {
        let track = Track(id: "abcdefghijk", title: "Song", artist: "Artist")
        let playlist = ImportedPlaylist(id: "album:source/id", name: "Road trip", tracks: [track])
        let record = try AccountPlaylistRecord.capture(playlist, cover: Data([1, 2, 3]))
        let restored = try JSONDecoder().decode(AccountPlaylistRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record)
        XCTAssertEqual(restored.playlist?.name, playlist.name)
        XCTAssertEqual(restored.playlist?.tracks.first?.playableID, track.playableID)
        XCTAssertFalse(restored.deleted)
        XCTAssertEqual(AccountPlaylistRecord.documentID(playlist.id).count, 64)
        XCTAssertNotEqual(AccountPlaylistRecord.documentID("a/b"), AccountPlaylistRecord.documentID("a_b"))
    }
    func testDeletionHasNoPlaylistPayloadAndLargeBackupFailsExplicitly() throws {
        let deletion = AccountPlaylistRecord(id: "playlist", payload: nil, cover: nil)
        XCTAssertTrue(deletion.deleted)
        XCTAssertNil(deletion.playlist)
        let track = Track(id: "abcdefghijk", title: String(repeating: "x", count: 751000), artist: "Artist")
        XCTAssertThrowsError(try AccountPlaylistRecord.capture(ImportedPlaylist(id: "large", name: "Large", tracks: [track]), cover: nil))
    }
}
