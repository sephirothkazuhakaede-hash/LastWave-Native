import XCTest
@testable import CapyFlow

final class LocalizedRecordingTests: XCTestCase {
    private func fixture() throws -> (Track, [Track]) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "LocalizedRecording", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let album = Album(id: "MPREb_7fR7KsQj2hx", title: "Suzume (Motion Picture Soundtrack)", artist: "RADWIMPS", year: "2022", artworkURL: nil)
        let rows = try Catalog.parseAlbumTracks(root["albumRoot"]!, album: album)
        return (try XCTUnwrap(rows.first { $0.id == "Xs0Lxif1u9E" }), try Catalog.parseSongTracks(root["songsRoot"]!))
    }

    func testCapturedAlbumAndSongsMetadataReconcile() async throws {
        let (row, songs) = try fixture()
        let song = try XCTUnwrap(songs.first { $0.id == "9LW9DpmhrPE" })
        XCTAssertEqual(row.title, "Suzume (feat. Toaka)")
        XCTAssertEqual(song.title, "すずめ - Suzume (feat. Toaka)")
        XCTAssertEqual(row.artistID, song.artistID)
        XCTAssertEqual(row.duration, 239)
        XCTAssertEqual(song.duration, 237)
        XCTAssertEqual(row.musicVideoType, "MUSIC_VIDEO_TYPE_OMV")
        XCTAssertTrue(AlbumAudioIdentity.localizedTitleMatches(row, song))
        let resolver = CanonicalTrackResolver(defaults: nil)
        let resolved = try await resolver.resolve(row) { _ in songs }
        XCTAssertEqual(resolved.id, row.id)
        XCTAssertEqual(resolved.playableID, song.id)
        XCTAssertEqual(resolved.mediaCacheKey(quality: .automatic), song.mediaCacheKey(quality: .automatic))
        XCTAssertEqual(resolved.lyricsCacheKey, song.lyricsCacheKey)
        let again = try await resolver.resolve(row) { _ in XCTFail("Stored alias must not search again"); return [] }
        XCTAssertEqual(again.playableID, song.id)
    }

    func testSongsFirstAndPersistedAlbumAlias() async throws {
        let (row, songs) = try fixture()
        let name = "LocalizedRecording-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let resolver = CanonicalTrackResolver(defaults: defaults)
        _ = await resolver.registerSearch(songs)
        let resolved = try await resolver.resolve(row) { _ in XCTFail("Songs registration must heal album lookup"); return [] }
        XCTAssertEqual(resolved.playableID, "9LW9DpmhrPE")
        let reopened = CanonicalTrackResolver(defaults: defaults)
        let saved = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(row))
        let result = try await reopened.resolve(saved) { _ in XCTFail("Persisted alias must be reused"); return [] }
        XCTAssertEqual(result.playableID, resolved.playableID)
    }

    func testUnsafeLocalizedCandidatesAreRejected() throws {
        let (row, songs) = try fixture()
        let song = try XCTUnwrap(songs.first { $0.id == "9LW9DpmhrPE" })
        var wrong = song; wrong.artistID = "UC_cover_artist"
        XCTAssertNil(AlbumAudioIdentity.score(row, wrong))
        wrong = song; wrong.isExplicit = true
        XCTAssertNil(AlbumAudioIdentity.score(row, wrong))
        wrong = song; wrong.isExplicit = nil
        XCTAssertNil(AlbumAudioIdentity.score(row, wrong))
        wrong = song.withDuration(290)
        XCTAssertNil(AlbumAudioIdentity.score(row, wrong))
        wrong = song; wrong.musicVideoType = "MUSIC_VIDEO_TYPE_OMV"
        XCTAssertNil(AlbumAudioIdentity.score(row, wrong))
        for marker in ["Live", "Remix", "Cover", "Instrumental", "Acoustic", "English Version"] {
            wrong = song; wrong.title += " (\(marker))"
            XCTAssertNil(AlbumAudioIdentity.score(row, wrong), marker)
        }
        wrong = song; wrong.title = "Another Song - Suzume (feat. Toaka)"
        XCTAssertNil(AlbumAudioIdentity.score(row, wrong), "Arbitrary Latin prefix is not a translation")
        wrong = song; wrong.title = "すずめ - Suzume Again (feat. Toaka)"
        XCTAssertNil(AlbumAudioIdentity.score(row, wrong), "Require the complete alias, not a substring")
    }

    func testGeneralBilingualRuleAndAmbiguousRecordings() {
        var row = Track(id: "album-row", title: "Blue Sky", artist: "Example Artist", duration: 180)
        row.artistID = "UC_example"; row.isExplicit = false
        var song = Track(id: "audio", title: "青空 - Blue Sky", artist: "Example Artist", duration: 181)
        song.artistID = row.artistID; song.isExplicit = false; song.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
        XCTAssertNotNil(AlbumAudioIdentity.score(row, song))
        var alternative = Track(id: "different-audio", title: song.title, artist: song.artist, duration: song.duration)
        alternative.artistID = song.artistID; alternative.isExplicit = false; alternative.musicVideoType = song.musicVideoType
        XCTAssertNil(AlbumAudioIdentity.bestMatch(for: row, candidates: [song, alternative]))
        song.title = "Blue Sky - 青空"
        XCTAssertNotNil(AlbumAudioIdentity.score(row, song))
    }
    func testReleaseDiagnosticContainsActualValues() throws {
        let (row, songs) = try fixture()
        let report = CanonicalTrackResolver.failureReport(for: row, candidates: songs, failedSearches: 2)
        XCTAssertTrue(report.contains("Xs0Lxif1u9E"))
        XCTAssertTrue(report.contains("9LW9DpmhrPE"))
        XCTAssertTrue(report.contains("artistID=UCT418-ChE6rgGuQlqzFsKZA"))
        XCTAssertTrue(report.contains("searchFailures=2"))
        XCTAssertFalse(report.contains(#"\(track"#), "Diagnostic interpolation must execute")
    }

    func testActualAR2MissingMetadataResolvesColdAndSongsFirst() async throws {
        var row = Track(id: "Xs0Lxif1u9E", title: "Suzume (feat. Toaka)", artist: "RADWIMPS")
        row.albumID = "MPREb_7fR7KsQj2hx"; row.albumTitle = "Suzume (Motion Picture Soundtrack)"
        row.musicVideoType = "MUSIC_VIDEO_TYPE_OMV"; row.isExplicit = false
        var song = Track(id: "9LW9DpmhrPE", title: "すずめ - Suzume (feat. Toaka)", artist: "RADWIMPS", duration: 237)
        song.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"; song.isExplicit = false
        XCTAssertNil(row.artistID); XCTAssertNil(row.duration); XCTAssertNil(song.artistID)
        XCTAssertTrue(AlbumAudioIdentity.localizedTitleMatches(row, song))
        let cold = CanonicalTrackResolver(defaults: nil)
        let result = try await cold.resolve(row) { _ in [song] }
        XCTAssertEqual(result.playableID, song.id)
        XCTAssertEqual(result.duration, 237)
        let primed = CanonicalTrackResolver(defaults: nil)
        _ = await primed.registerSearch([song])
        let saved = try await primed.resolve(row) { _ in XCTFail("Songs-first must reuse the authoritative recording"); return [] }
        XCTAssertEqual(saved.playableID, song.id)
        XCTAssertEqual(saved.lyricsCacheKey, song.lyricsCacheKey)
        XCTAssertEqual(saved.mediaCacheKey(quality: .automatic), song.mediaCacheKey(quality: .automatic))
        var cover = song; cover.artist = "RADWIMPS Tribute"
        XCTAssertNil(AlbumAudioIdentity.score(row, cover))
        var differentFeature = song; differentFeature.title = "すずめ - Suzume (feat. Another Singer)"
        XCTAssertNil(AlbumAudioIdentity.score(row, differentFeature))
        var explicit = song; explicit.isExplicit = true
        XCTAssertNil(AlbumAudioIdentity.score(row, explicit))
        var remix = song; remix.title += " (Remix)"
        XCTAssertNil(AlbumAudioIdentity.score(row, remix))
        var ambiguous = Track(id: "another-edition", title: song.title, artist: song.artist, duration: 237)
        ambiguous.musicVideoType = song.musicVideoType; ambiguous.isExplicit = false
        XCTAssertNil(AlbumAudioIdentity.bestMatch(for: row, candidates: [song, ambiguous]))
    }

    func testAlbumDurationInFlexibleMobileColumn() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "LocalizedRecording", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try XCTUnwrap(root["albumRoot"] as? [[String: Any]])
        var renderer = try XCTUnwrap(rows.first?["musicResponsiveListItemRenderer"] as? [String: Any])
        renderer.removeValue(forKey: "fixedColumns")
        var columns = try XCTUnwrap(renderer["flexColumns"] as? [[String: Any]])
        columns.append(["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "3:59"]]]]])
        renderer["flexColumns"] = columns
        let album = Album(id: "MPREb_7fR7KsQj2hx", title: "Suzume (Motion Picture Soundtrack)", artist: "RADWIMPS", year: nil, artworkURL: nil)
        let parsed = try Catalog.parseAlbumTracks(["musicResponsiveListItemRenderer": renderer], album: album)
        XCTAssertEqual(parsed.first?.duration, 239)
    }

    func testExplicitMetadataOnAlbumAndSongsRows() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "LocalizedRecording", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try XCTUnwrap(root["albumRoot"] as? [[String: Any]])
        var renderer = try XCTUnwrap(rows.first?["musicResponsiveListItemRenderer"] as? [String: Any])
        renderer["badges"] = [
            ["musicInlineBadgeRenderer": ["icon": ["iconType": "OTHER_BADGE"]]],
            ["musicInlineBadgeRenderer": ["icon": ["iconType": "MUSIC_EXPLICIT_BADGE"]]]
        ]
        let album = Album(id: "fixture-album", title: "Fixture", artist: "RADWIMPS", year: nil, artworkURL: nil)
        let explicit = try XCTUnwrap(Catalog.parseAlbumTracks(["musicResponsiveListItemRenderer": renderer], album: album).first)
        XCTAssertEqual(explicit.isExplicit, true)
        XCTAssertEqual(try Catalog.parseSongTracks(["musicResponsiveListItemRenderer": renderer]).first?.isExplicit, true)
        let saved = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(explicit))
        XCTAssertEqual(saved.isExplicit, true)
        renderer.removeValue(forKey: "badges")
        XCTAssertEqual(try Catalog.parseAlbumTracks(["musicResponsiveListItemRenderer": renderer], album: album).first?.isExplicit, false)
    }

    func testOrdinaryRepeatedTitleIsNotCollapsedIntoAnotherSong() {
        var row = Track(id: "row", title: "Go Go", artist: "Example Artist", duration: 180)
        row.isExplicit = false
        var candidate = Track(id: "audio", title: "Go", artist: row.artist, duration: 180)
        candidate.isExplicit = false; candidate.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
        XCTAssertNil(AlbumAudioIdentity.score(row, candidate))
    }

}
