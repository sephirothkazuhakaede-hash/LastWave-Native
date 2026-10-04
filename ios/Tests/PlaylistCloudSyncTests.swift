import XCTest
@testable import CapyFlow

final class PlaylistCloudSyncTests: XCTestCase {
    func testSharedPlaylistRetainsSourceIdentityOnlyForOwner() throws {
        let track = Track(id: "abcdefghijk", title: "Collaborator song", artist: "Artist")
        let shared = try XCTUnwrap(SharedPlaylist(id: "shared-id", data: [
            "sourceID": "original-id", "name": "Together", "ownerID": "owner",
            "memberIDs": ["owner", "friend"], "tracks": [["id": track.id, "title": track.title, "artist": track.artist]]
        ]))
        let source = try XCTUnwrap(shared.sourcePlaylist(for: "owner"))
        XCTAssertEqual(source.id, "original-id")
        XCTAssertEqual(source.name, "Together")
        XCTAssertEqual(source.tracks.map(\.id), [track.id])
        XCTAssertEqual(shared.imported.id, "cloud:shared-id")
        XCTAssertNil(shared.sourcePlaylist(for: "friend"))
    }

    func testSharedRenameAndRemovalReplaceStaleSourceContents() throws {
        let shared = try XCTUnwrap(SharedPlaylist(id: "shared-id", data: [
            "sourceID": "original-id", "name": "Renamed together", "ownerID": "owner",
            "memberIDs": ["owner", "friend"], "tracks": [[String: Any]]()
        ]))
        let source = try XCTUnwrap(shared.sourcePlaylist(for: "owner"))
        XCTAssertEqual(source.name, "Renamed together")
        XCTAssertTrue(source.tracks.isEmpty)
        XCTAssertEqual(source.id, "original-id")
    }

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
