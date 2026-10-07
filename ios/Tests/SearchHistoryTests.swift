import XCTest
import ImageIO
@testable import CapyFlow

final class SearchHistoryTests: XCTestCase {
    func testSongHistoryRetainsRecordingAndArtworkAfterReload() {
        var song = Track(id: "row", title: "Song", artist: "Artist", duration: 180, artworkURL: URL(string: "https://example.com/art.jpg"))
        song.mediaID = "recording"
        song.isExplicit = true
        let restored = SearchSelectionHistory.songs(SearchSelectionHistory.encode([song]))
        XCTAssertEqual(restored, [song])
        XCTAssertEqual(restored.first?.playableID, "recording")
    }

    func testAlbumsRetainBrowseIdentityAfterReloadAndRemoval() {
        let album = Album(id: "browse", title: "Album", artist: "Artist", year: "2026", artworkURL: nil)
        XCTAssertEqual(SearchSelectionHistory.albums(SearchSelectionHistory.encode([album])), [album])
        XCTAssertTrue(SearchSelectionHistory.albums(SearchSelectionHistory.encode([Album]())).isEmpty)
    }

    func testHistoryMovesSelectionToFrontAndBoundsStorage() {
        let songs = (0..<25).map { Track(id: "song-\($0)", title: "Song \($0)", artist: "Artist") }
        let moved = SearchSelectionHistory.remembering(songs[8], in: songs)
        XCTAssertEqual(moved.count, 20)
        XCTAssertEqual(moved.first?.id, "song-8")
        XCTAssertEqual(moved.filter { $0.id == "song-8" }.count, 1)
    }

    func testInvalidEntryDoesNotDiscardValidSelections() {
        let valid = Track(id: "good", title: "Song", artist: "Artist")
        let json = SearchSelectionHistory.encode([valid])
        let raw = "[{}, " + String(json.dropFirst().dropLast()) + "]"
        XCTAssertEqual(SearchSelectionHistory.songs(raw), [valid])
        XCTAssertTrue(SearchSelectionHistory.songs("invalid").isEmpty)
    }

    func testHomeAnimationIsBundledAndContainsMultipleFrames() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "capy-welcome", withExtension: "gif"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 80)
        XCTAssertNotNil(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 128
        ] as CFDictionary))
    }
}
