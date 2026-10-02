import XCTest
import AVFoundation
@testable import CapyFlow

final class MediaPolicyTests: XCTestCase {
    func testAlbumParserKeepsRecordingIdentityAndUsesAlbumArtistForEmptyColumns() throws {
        let column: (String) -> [String: Any] = { ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": $0]]]]] }
        let row: [String: Any] = [
            "index": ["runs": [["text": "1"]]],
            "playlistItemData": ["videoId": "h8DLofLM7No"],
            "flexColumns": [column("Lavender Haze"), ["musicResponsiveListItemFlexColumnRenderer": ["text": [:]]], column("178M plays")],
            "fixedColumns": [["musicResponsiveListItemFixedColumnRenderer": ["text": ["runs": [["text": "3:23"]]]]]],
            "navigationEndpoint": ["watchEndpoint": ["watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": "MUSIC_VIDEO_TYPE_OMV"]]]]
        ]
        var related = row; related.removeValue(forKey: "index")
        related["playlistItemData"] = ["videoId": "unrelated01"]
        let album = Album(id: "MPREb_z0ABWl3jaT0", title: "Midnights", artist: "Taylor Swift", year: nil, artworkURL: nil)
        let tracks = try Catalog.parseAlbumTracks(["contents": [["musicResponsiveListItemRenderer": row], ["musicResponsiveListItemRenderer": related]]], album: album)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].artist, "Taylor Swift")
        XCTAssertEqual(tracks[0].duration, 203)
        XCTAssertEqual(tracks[0].albumID, album.id)
        XCTAssertEqual(tracks[0].musicVideoType, "MUSIC_VIDEO_TYPE_OMV")
    }
    func testDurationParsingRejectsMalformedColumns() {
        XCTAssertEqual(MediaDuration.parse("3:23"), 203)
        XCTAssertEqual(MediaDuration.parse("1:03:23"), 3803)
        for value in ["3::23", "LIVE", "3:x:23", "3:99", "NaN:23", "-3:23"] {
            XCTAssertNil(MediaDuration.parse(value))
        }
    }
    func testMusicSessionAllowsSystemLongFormRouting() throws {
        let session = AVAudioSession.sharedInstance()
        try AudioRoutePolicy.configure(session)
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .default)
        XCTAssertEqual(session.routeSharingPolicy, .longFormAudio)
    }
    func testAlbumVideoMapsToItsExactAudioRecording() {
        var albumTrack = Track(id: "officialVideo", title: "Lavender Haze", artist: "Taylor Swift", duration: 203)
        albumTrack.albumID = "MPRE_album"
        var song = Track(id: "audioRecording", title: "Lavender Haze", artist: "Taylor Swift", duration: 203)
        song.albumID = "MPRE_album"
        song.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
        // A different browse ID alone is legitimate (regional/reissued albums).
        // Reject a different recording by duration and version instead.
        var wrongAlbum = song.withDuration(300); wrongAlbum.albumID = "MPRE_other"
        var wrongVersion = song
        wrongVersion = Track(id: "live", title: "Lavender Haze (Live)", artist: "Taylor Swift", duration: 203)
        wrongVersion.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
        XCTAssertEqual(AlbumAudioIdentity.bestMatch(for: albumTrack, candidates: [wrongAlbum, wrongVersion, song])?.id, song.id)
        XCTAssertNil(AlbumAudioIdentity.bestMatch(for: albumTrack, candidates: [wrongAlbum, wrongVersion]))
    }

    func testRouteSelectionKeepsPlayingExceptWhenAnOutputDisconnects() {
        XCTAssertTrue(AudioRoutePolicy.shouldPause(reason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue))
        for reason in [AVAudioSession.RouteChangeReason.newDeviceAvailable, .override, .routeConfigurationChange, .categoryChange] {
            XCTAssertFalse(AudioRoutePolicy.shouldPause(reason: reason.rawValue))
        }
        XCTAssertFalse(AudioRoutePolicy.shouldPause(reason: nil))
    }

    func testUnknownFormatDetailsAreNotInvented() throws {
        let info = try JSONDecoder().decode(AudioMediaInfo.self, from: Data("{}".utf8))
        XCTAssertEqual(info.description, "Media details unavailable")
        XCTAssertNil(info.bitrateKbps)
        XCTAssertEqual(AudioQuality.allCases.count, 2)
        XCTAssertEqual(AudioQuality.automatic.backendValue, "automatic")
    }
}
