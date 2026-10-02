import XCTest
@testable import CapyFlow

private actor FallbackSearch {
    let steps: [[Track]?]
    let timeoutFirst: Bool
    private(set) var queries: [String] = []
    init(_ steps: [[Track]?], timeoutFirst: Bool = false) { self.steps = steps; self.timeoutFirst = timeoutFirst }
    func search(_ query: String) throws -> [Track] {
        let offset = queries.count
        queries.append(query)
        if offset == 0 && timeoutFirst { throw URLError(.timedOut) }
        guard offset < steps.count else { return [] }
        guard let result = steps[offset] else {
            // This is the actual empty-response error emitted by normal Songs.
            return try Catalog.parseSongTracks(["contents": []])
        }
        return result
    }
}

final class AlbumFallbackTests: XCTestCase {
    private func album(_ title: String = "Fortnight (feat. Post Malone)", artist: String = "Taylor Swift", duration: Double = 229) -> Track {
        var row = Track(id: "album-video", title: title, artist: artist, duration: duration)
        row.albumID = "MPRE_album"; row.albumTitle = "THE TORTURED POETS DEPARTMENT"
        row.musicVideoType = "MUSIC_VIDEO_TYPE_OMV"
        return row
    }
    private func audio(_ title: String = "Fortnight (feat. Post Malone)", artist: String = "Taylor Swift", duration: Double = 229, id: String = "eXrmLd5mer4") -> Track {
        var song = Track(id: id, title: title, artist: artist, duration: duration)
        song.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
        song.albumID = "MPRE_album"; song.albumTitle = "THE TORTURED POETS DEPARTMENT"
        return song
    }

    func testEmptyFirstSearchAndWrongSecondCandidateRetryToNormalSongsIdentity() async throws {
        let row = album(), correct = audio()
        let wrong = audio("Fortnight (Acoustic Version) (feat. Post Malone)", id: "wrong-acoustic")
        let search = FallbackSearch([nil, [wrong], [wrong, correct]])
        let resolver = CanonicalTrackResolver(defaults: nil)
        let found = try await resolver.resolve(row) { try await search.search($0) }
        XCTAssertEqual(found.playableID, correct.id)
        let queries = await search.queries
        XCTAssertEqual(queries.count, 3)
        XCTAssertEqual(queries.first, "Taylor Swift Fortnight")
        XCTAssertTrue(queries[1].hasPrefix("Fortnight"))
        XCTAssertTrue(queries[2].contains("feat. Post Malone"))
        let songs = await resolver.registerSearch([correct])
        XCTAssertEqual(found.lyricsCacheKey, songs[0].lyricsCacheKey)
        XCTAssertEqual(found.mediaCacheKey(quality: .automatic), songs[0].mediaCacheKey(quality: .automatic))
        XCTAssertEqual(found.mediaCacheKey(quality: .dataSaver), songs[0].mediaCacheKey(quality: .dataSaver))
        let again = try await resolver.resolve(row) { _ in XCTFail("Reuse the canonical alias"); return [] }
        XCTAssertEqual(again.playableID, found.playableID)
    }

    func testCandidateRankingRejectsFirstAcousticVideoAndCoverBeforeChoosingOfficialAudio() async throws {
        let row = album(), correct = audio()
        var video = correct; video.mediaID = "music-video"; video.musicVideoType = "MUSIC_VIDEO_TYPE_OMV"
        let acoustic = audio("Fortnight (Acoustic Version) (feat. Post Malone)", id: "acoustic")
        let cover = audio(artist: "Taylor Swift Tribute", id: "cover")
        let search = FallbackSearch([[acoustic, video, cover, correct]])
        let found = try await CanonicalTrackResolver(defaults: nil).resolve(row) { try await search.search($0) }
        XCTAssertEqual(found.playableID, correct.id)
        let queries = await search.queries
        XCTAssertEqual(queries.count, 1, "Rank all candidates in the first response without delaying a strong match")
    }

    func testAllQueryFormsAreExhaustedAndFailureIsNotCached() async throws {
        let row = album(), resolver = CanonicalTrackResolver(defaults: nil), search = FallbackSearch([nil])
        do {
            _ = try await resolver.resolve(row) { try await search.search($0) }
            XCTFail("No candidate should succeed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("several Songs searches"))
        }
        let queries = await search.queries
        XCTAssertEqual(queries, AlbumAudioIdentity.searchQueries(for: row))
        XCTAssertTrue(queries.contains { $0.contains("THE TORTURED POETS DEPARTMENT") })
        let correct = audio()
        let retried = try await resolver.resolve(row) { _ in [correct] }
        XCTAssertEqual(retried.playableID, correct.id)
    }

    func testLaterQueryCanRepairMetadataForTheSameCandidateID() async throws {
        let row = album(), correct = audio()
        let incomplete = audio(artist: "Unknown artist")
        let search = FallbackSearch([[incomplete], [correct]])
        let found = try await CanonicalTrackResolver(defaults: nil).resolve(row) { try await search.search($0) }
        XCTAssertEqual(found.playableID, correct.id)
        XCTAssertEqual(found.artist, "Taylor Swift")
        let queries = await search.queries
        XCTAssertEqual(queries.count, 2)
    }

    func testIncompleteSongsMetadataCannotOverwriteKnownCanonicalArtist() async throws {
        let resolver = CanonicalTrackResolver(defaults: nil), correct = audio()
        _ = await resolver.registerSearch([correct])
        let incomplete = audio(artist: "Unknown artist")
        let result = await resolver.registerSearch([incomplete])
        XCTAssertEqual(result[0].artist, "Taylor Swift")
        let found = try await resolver.resolve(album()) { _ in XCTFail("The existing valid mapping must remain reusable"); return [] }
        XCTAssertEqual(found.artist, "Taylor Swift")
        XCTAssertEqual(LyricsService.lookupURL(for: found), LyricsService.lookupURL(for: correct))
    }

    func testTransientQueryFailureDoesNotPreventTheNextQuery() async throws {
        let correct = audio(), search = FallbackSearch([[], [audio()]], timeoutFirst: true)
        let found = try await CanonicalTrackResolver(defaults: nil).resolve(album()) { try await search.search($0) }
        XCTAssertEqual(found.playableID, correct.id)
        let queries = await search.queries
        XCTAssertEqual(queries.count, 2)
    }

    func testPrimaryAlbumAudioRemainsAValidFinalFallbackAfterSongsExhaustion() async throws {
        var row = album("Date 2", artist: "RADWIMPS", duration: 130)
        row.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"; row.albumTitle = "Your Name."
        let search = FallbackSearch([])
        let found = try await CanonicalTrackResolver(defaults: nil).resolve(row) { try await search.search($0) }
        XCTAssertEqual(found.playableID, row.id)
        let queries = await search.queries
        XCTAssertEqual(queries, AlbumAudioIdentity.searchQueries(for: row))
    }

    func testMovieEditMovieVersionAndOtherVersionsStayDistinct() {
        var edit = album("Nandemonaiya - movie edit.", artist: "RADWIMPS", duration: 197)
        edit.albumTitle = "Your Name."
        var version = audio("Nandemonaiya - movie ver.", artist: "RADWIMPS", duration: 197, id: "wrong-version")
        version.albumTitle = "Your Name."
        XCTAssertNil(AlbumAudioIdentity.bestMatch(for: edit, candidates: [version]))
        var movie = album("Sparkle - movie ver.", artist: "RADWIMPS", duration: 538)
        movie.albumTitle = "Your Name."
        var same = audio("Sparkle (Movie Version)", artist: "RADWIMPS", duration: 538, id: "movie-audio")
        same.albumTitle = "Your Name."
        XCTAssertEqual(AlbumAudioIdentity.bestMatch(for: movie, candidates: [same])?.id, same.id)
        for marker in ["Live", "Cover", "Karaoke", "Instrumental", "Remix", "Slowed", "Sped Up", "Nightcore", "Extended", "Acoustic", "Official Music Video"] {
            let wrong = audio("Fortnight (\(marker))", id: marker)
            XCTAssertNil(AlbumAudioIdentity.bestMatch(for: album(), candidates: [wrong]), marker)
        }
        let ordinary = album("Live Forever", artist: "Oasis", duration: 276)
        let studio = audio("Live Forever", artist: "Oasis", duration: 276)
        let live = audio("Live Forever (Live)", artist: "Oasis", duration: 276, id: "live")
        XCTAssertEqual(AlbumAudioIdentity.bestMatch(for: ordinary, candidates: [live, studio])?.id, studio.id)
    }

    func testPunctuationSpacingCreditsAndOrdinaryRadioheadTitles() {
        for (a, b) in [("Katawaredoki", "Kataware Doki"), ("Exit Music (For A Film)", "Exit Music [For a Film]"),
                       ("Who’s Afraid of Little Old Me?", "Who's Afraid of Little Old Me"), ("Electioneering", "Electioneering")] {
            let row = album(a, artist: "Radiohead", duration: 231), song = audio(b, artist: "Radiohead - Topic", duration: 231)
            XCTAssertEqual(AlbumAudioIdentity.bestMatch(for: row, candidates: [song])?.id, song.id, a)
        }
        XCTAssertNotNil(AlbumAudioIdentity.score(album(), audio("Fortnight", artist: "Taylor Swift & Post Malone")))
        XCTAssertNil(AlbumAudioIdentity.score(album("Date 2", artist: "RADWIMPS", duration: 130), audio("Date", artist: "RADWIMPS", duration: 130)))
    }

    func testMissingVideoTypeNeedsStrongAudioEvidenceAndPrimaryEndpointWinsOverMenu() throws {
        let correct = audio()
        var missing = correct; missing.musicVideoType = nil
        XCTAssertNotNil(AlbumAudioIdentity.score(album(), missing))
        missing = missing.withDuration(400)
        XCTAssertNil(AlbumAudioIdentity.score(album(), missing))
        let text: (String) -> [String: Any] = { ["text": $0] }
        let row: [String: Any] = ["playlistItemData": ["videoId": correct.id], "flexColumns": [
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": correct.title,
                "navigationEndpoint": ["watchEndpoint": ["videoId": correct.id, "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": "MUSIC_VIDEO_TYPE_ATV"]]]]]]]]],
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [text(correct.artist), text("3:49")]]]]
        ], "menu": ["watchEndpointMusicConfig": ["musicVideoType": "MUSIC_VIDEO_TYPE_OMV"]]]
        let parsed = try Catalog.parseSongTracks(["musicResponsiveListItemRenderer": row])
        XCTAssertEqual(parsed[0].musicVideoType, "MUSIC_VIDEO_TYPE_ATV")
    }

    func testRealReportedAlbumsResolveAndConvergeWithNormalSongsSearch() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "AlbumFallbackCatalog", withExtension: "json"))
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        let expected = ["xAj3Ru5sOBI", "-J9FuvPmMoI", "mhpRipG9Zss", "dMJc6kalUCM", "eXrmLd5mer4", "HHiddAj-Dqc", "ZVgHPSyEIqk", "3DtgWrFTtQk"]
        XCTAssertEqual(fixtures.count, expected.count)
        for (position, fixture) in fixtures.enumerated() {
            let details = fixture["album"] as! [String: String]
            let origin = Album(id: details["id"]!, title: details["title"]!, artist: details["artist"]!, year: nil, artworkURL: nil)
            let row = try XCTUnwrap(Catalog.parseAlbumTracks(fixture["albumRoot"]!, album: origin).first)
            let responses = fixture["queries"] as! [String: Any]
            var byQuery: [String: [Track]] = [:]
            for (query, root) in responses { byQuery[query] = try Catalog.parseSongTracks(root) }
            let captured = byQuery
            let resolver = CanonicalTrackResolver(defaults: nil)
            let found = try await resolver.resolve(row) { captured[$0] ?? [] }
            XCTAssertEqual(found.playableID, expected[position], row.title)
            let normalQuery = row.artist + " " + AlbumAudioIdentity.title(row.title)
            let normalSongs = await resolver.registerSearch(try XCTUnwrap(captured[normalQuery]))
            let equivalent = try XCTUnwrap(normalSongs.first { $0.playableID == found.playableID })
            XCTAssertEqual(found.lyricsCacheKey, equivalent.lyricsCacheKey)
            XCTAssertEqual(found.duration, equivalent.duration)
            XCTAssertEqual(found.mediaCacheKey(quality: .automatic), equivalent.mediaCacheKey(quality: .automatic))
            XCTAssertEqual(found.mediaCacheKey(quality: .dataSaver), equivalent.mediaCacheKey(quality: .dataSaver))
            _ = try await resolver.resolve(row) { _ in XCTFail("Second album play must reuse the canonical identity"); return [] }
        }
    }
    func testEveryTTPDTrackResolvesWithoutManualSongsSearch() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TTPDFullAlbum", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let details = fixture["album"] as! [String: String]
        let album = Album(id: details["id"]!, title: details["title"]!, artist: details["artist"]!, year: nil, artworkURL: nil)
        let rows = try Catalog.parseAlbumTracks(fixture["albumRoot"]!, album: album)
        let expected = fixture["expectedMediaIDs"] as! [String]
        XCTAssertEqual(rows.count, 16)
        XCTAssertEqual(expected.count, rows.count)
        var byQuery: [String: [Track]] = [:]
        for (query, root) in fixture["queries"] as! [String: Any] { byQuery[query] = try Catalog.parseSongTracks(root) }
        let captured = byQuery
        for (index, row) in rows.enumerated() {
            let resolver = CanonicalTrackResolver(defaults: nil)
            let found = try await resolver.resolve(row) { captured[$0] ?? [] }
            XCTAssertEqual(found.playableID, expected[index], row.title)
            XCTAssertEqual(found.id, row.id)
            let songs = await resolver.registerSearch(captured[row.artist + " " + AlbumAudioIdentity.title(row.title)] ?? [])
            let equivalent = try XCTUnwrap(songs.first { $0.playableID == found.playableID }, row.title)
            XCTAssertEqual(found.lyricsCacheKey, equivalent.lyricsCacheKey)
            XCTAssertEqual(found.duration, equivalent.duration)
            XCTAssertEqual(found.mediaCacheKey(quality: .automatic), equivalent.mediaCacheKey(quality: .automatic))
        }
    }

}
