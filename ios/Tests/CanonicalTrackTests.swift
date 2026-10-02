import XCTest
@testable import CapyFlow

private actor RecordingSearch {
    let results: [Track]
    private(set) var calls = 0
    init(_ results: [Track]) { self.results = results }
    func search(_ query: String) -> [Track] { calls += 1; return results }
}

final class CanonicalTrackTests: XCTestCase {
    private func albumTrack() -> Track {
        var track = Track(id: "album-video", title: "Snow On The Beach (feat. Lana Del Rey)", artist: "Taylor Swift", duration: 257)
        track.albumID = "MPRE_standard"
        track.albumTitle = "Midnights"
        track.trackNumber = 4
        track.musicVideoType = "MUSIC_VIDEO_TYPE_OMV"
        return track
    }
    private func songTrack() -> Track {
        var song = Track(id: "REsc54NTz1A", title: "Snow On The Beach (feat. Lana Del Rey)", artist: "Taylor Swift", duration: 257)
        song.albumID = "MPRE_3am"
        song.albumTitle = "Midnights (3am Edition)"
        song.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
        return song
    }

    func testColdAlbumConvergesWithSongsForPlaybackDownloadLyricsAndDuration() async throws {
        let resolver = CanonicalTrackResolver(defaults: nil)
        let source = albumTrack(), song = songTrack(), search = RecordingSearch([songTrack()])
        let canonical = try await resolver.resolve(source) { await search.search($0) }
        XCTAssertEqual(canonical.id, source.id, "Keep row IDs stable for playlist editing")
        XCTAssertEqual(canonical.playableID, song.id)
        XCTAssertEqual(canonical.title, song.title)
        XCTAssertEqual(canonical.artist, song.artist)
        XCTAssertEqual(canonical.duration, 257)
        XCTAssertEqual(canonical.trackNumber, 4)
        let config = BackendConfiguration(baseURL: URL(string: "http://127.0.0.1:8787")!)
        XCTAssertTrue(config.resolveURL(videoID: canonical.playableID, quality: .automatic).path.hasSuffix(song.id))
        XCTAssertTrue(config.audioURL(videoID: canonical.playableID, quality: .automatic).path.hasSuffix(song.id))
        XCTAssertTrue(config.downloadURL(videoID: canonical.playableID, quality: .automatic).path.hasSuffix(song.id))
        XCTAssertEqual(LyricsService.lookupURL(for: canonical), LyricsService.lookupURL(for: song))
        await resolver.recordDuration(256.18, track: canonical, mediaInfo: nil)
        let again = try await resolver.resolve(source) { await search.search($0) }
        let songs = await resolver.registerSearch([song])
        XCTAssertEqual(again.duration, 256.18)
        XCTAssertEqual(songs[0].duration, 256.18, "Catalog rounding must not overwrite measured duration")
        XCTAssertEqual(again.mediaCacheKey(quality: .automatic), songs[0].mediaCacheKey(quality: .automatic))
        XCTAssertEqual(again.lyricsCacheKey, songs[0].lyricsCacheKey)
        let calls = await search.calls
        XCTAssertEqual(calls, 1, "An album must resolve without manual Songs priming and cache the mapping")
    }

    func testSongsFirstAlbumReusesMappingWithoutAnotherSearch() async throws {
        let resolver = CanonicalTrackResolver(defaults: nil)
        let song = songTrack()
        let songs = await resolver.registerSearch([song])
        let source = albumTrack(), search = RecordingSearch([])
        let album = try await resolver.resolve(source) { await search.search($0) }
        XCTAssertEqual(album.playableID, songs[0].playableID)
        XCTAssertEqual(album.lyricsCacheKey, songs[0].lyricsCacheKey)
        let calls = await search.calls
        XCTAssertEqual(calls, 0)
    }

    func testRegisteredSongsAudioKeepsTheImmediatePathWithoutAnotherSearch() async throws {
        let resolver = CanonicalTrackResolver(defaults: nil), search = RecordingSearch([])
        let song = songTrack()
        _ = await resolver.registerSearch([song])
        let canonical = try await resolver.resolve(song) { await search.search($0) }
        XCTAssertEqual(canonical.playableID, song.id)
        XCTAssertEqual(canonical.title, song.title)
        XCTAssertEqual(canonical.artist, song.artist)
        XCTAssertEqual(canonical.lyricsCacheKey, song.lyricsCacheKey)
        let calls = await search.calls
        XCTAssertEqual(calls, 0, "A trustworthy audio ID must not wait for another catalog request")
    }

    func testMappingSurvivesRelaunchAndSavedAlbumPlaylistSelfHeals() async throws {
        let name = "CanonicalTrackTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let resolver = CanonicalTrackResolver(defaults: defaults)
        let track = albumTrack(), song = songTrack()
        _ = try await resolver.resolve(track) { _ in [song] }
        let legacy = ImportedPlaylist(id: "album:MPRE_standard", name: "Midnights", tracks: [track])
        let encoded = try JSONEncoder().encode(legacy)
        let restored = try JSONDecoder().decode(ImportedPlaylist.self, from: encoded)
        let reopened = CanonicalTrackResolver(defaults: defaults), search = RecordingSearch([])
        let repaired = try await reopened.resolve(restored.tracks[0]) { await search.search($0) }
        let saved = ImportedPlaylist(id: restored.id, name: restored.name, tracks: [repaired])
        let roundTrip = try JSONDecoder().decode(ImportedPlaylist.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(roundTrip.tracks[0].playableID, song.id)
        XCTAssertEqual(roundTrip.tracks[0].trackNumber, 4)
        XCTAssertEqual(roundTrip.tracks[0].albumTitle, "Midnights")
        let calls = await search.calls
        XCTAssertEqual(calls, 0)
    }

    func testLegacyMappingIsEnrichedWithCanonicalLyricsMetadata() async throws {
        let name = "LegacyCanonicalTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var old = albumTrack(); old.mediaID = songTrack().id
        defaults.set(try JSONEncoder().encode([old.id: old]), forKey: "capyflow.albumAudioMappings.v1")
        let resolver = CanonicalTrackResolver(defaults: defaults), song = songTrack()
        let repaired = try await resolver.resolve(old) { _ in [song] }
        XCTAssertEqual(repaired.playableID, song.id)
        XCTAssertEqual(repaired.title, song.title)
        XCTAssertEqual(LyricsService.lookupURL(for: repaired), LyricsService.lookupURL(for: song))
    }

    func testVerifiedSavedRecordingStillPlaysWhenMetadataRefreshIsOffline() async throws {
        var saved = albumTrack(); saved.mediaID = songTrack().id
        let resolver = CanonicalTrackResolver(defaults: nil)
        let result = try await resolver.resolve(saved) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(result.playableID, saved.playableID)
    }

    func testAudioAlbumRowAlsoObtainsCanonicalArtistInsteadOfNeedingSearchPriming() async throws {
        var album = albumTrack()
        album = Track(id: songTrack().id, title: album.title, artist: "Various Artists", duration: 257)
        album.albumID = songTrack().albumID
        album.albumTitle = songTrack().albumTitle
        album.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
        let resolver = CanonicalTrackResolver(defaults: nil), song = songTrack()
        let result = try await resolver.resolve(album) { _ in [song] }
        XCTAssertEqual(result.artist, "Taylor Swift")
        XCTAssertEqual(result.playableID, song.id)
    }

    func testRADWIMPSLegacyAlbumMetadataSelfHealsBeforeLyricsAreRequested() async throws {
        for (id, title, duration) in [("n89SKAymNfA", "Nandemonaiya - movie ver.", 345.0), ("MtLHwqbE1eI", "Dream lantern", 132.0)] {
            // A stale saved album row can lack the artist/origin fields; playing
            // Songs used to prime lyrics[id] and mask the bad album metadata.
            let stale = Track(id: id, title: title, artist: "223M plays", duration: duration)
            var song = Track(id: id, title: title, artist: "RADWIMPS", duration: duration)
            song.albumID = "MPREb_omNHm3qEN1U"; song.albumTitle = "Your Name."
            song.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
            let resolver = CanonicalTrackResolver(defaults: nil)
            let fixed = try await resolver.resolve(stale) { _ in [song] }
            XCTAssertEqual(fixed.playableID, song.id)
            XCTAssertEqual(fixed.artist, "RADWIMPS")
            XCTAssertEqual(LyricsService.lookupURL(for: fixed), LyricsService.lookupURL(for: song))
            XCTAssertEqual(fixed.lyricsCacheKey, song.lyricsCacheKey)
        }
    }

    func testSavedAlbumPlayCountArtistRecoversFromHeaderAndSongs() async throws {
        let header: [String: Any] = ["musicResponsiveHeaderRenderer": [
            "title": ["runs": [["text": "Your Name."]]],
            "straplineTextOne": ["runs": [["text": "RADWIMPS", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCT418-ChE6rgGuQlqzFsKZA"]]]]],
            "subtitle": ["runs": [["text": "Album"], ["text": " • "], ["text": "2016"]]]
        ]]
        let context = try Catalog.parseAlbumContext(header)
        XCTAssertEqual(context.artist, "RADWIMPS")
        XCTAssertEqual(context.title, "Your Name.")
        var stale = Track(id: "MtLHwqbE1eI", title: "Dream lantern", artist: "74M plays", duration: 132)
        stale.albumID = "MPREb_omNHm3qEN1U"
        stale.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
        let resolver = CanonicalTrackResolver(defaults: nil)
        var song = stale; song.artist = "RADWIMPS"; song.albumTitle = "Your Name."
        let search = RecordingSearch([song])
        let fixed = try await resolver.resolve(stale, albumContext: { _ in context }) { await search.search($0) }
        XCTAssertEqual(fixed.artist, "RADWIMPS")
        XCTAssertEqual(fixed.albumTitle, "Your Name.")
        XCTAssertEqual(fixed.playableID, stale.id)
        for bad in ["Unknown artist", "223M plays", "74M plays", "1.2B views", "953 plays"] {
            XCTAssertTrue(AlbumAudioIdentity.isMissingArtist(bad), bad)
        }
    }

    func testEquivalentFormattingMatchesButWrongVersionsAndExplicitnessDoNot() {
        XCTAssertEqual(AlbumAudioIdentity.title("Clean"), "Clean", "Do not erase a real Taylor Swift song title")
        var album = Track(id: "album", title: "Song (feat. Guest)", artist: "Singer", duration: 200)
        album.albumID = "MPRE_album"; album.isExplicit = true
        var audio = Track(id: "audio", title: "SONG — 2024 Remastered (Official Audio)", artist: "Singer - Topic", duration: 204)
        audio.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"; audio.albumID = "MPRE_regional"; audio.isExplicit = true
        XCTAssertEqual(AlbumAudioIdentity.bestMatch(for: album, candidates: [audio])?.id, "audio")
        for version in ["Live", "Acoustic", "Remix", "Cover", "Extended", "Sped Up", "Slowed", "Instrumental"] {
            var wrong = Track(id: version, title: "Song (feat. Guest) (\(version))", artist: "Singer", duration: 200)
            wrong.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"; wrong.albumID = album.albumID
            XCTAssertNil(AlbumAudioIdentity.bestMatch(for: album, candidates: [wrong]), version)
        }
        audio.isExplicit = false
        XCTAssertNil(AlbumAudioIdentity.bestMatch(for: album, candidates: [audio]))
        audio.isExplicit = true; audio = audio.withDuration(290)
        XCTAssertNil(AlbumAudioIdentity.bestMatch(for: album, candidates: [audio]))
    }

    func testRealCatalogAlbumRowsResolveWithoutPreviouslySearchingSongs() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CanonicalCatalog", withExtension: "json"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        let expected = ["GwNPBeWpI-0", "IHMySdortig", "REsc54NTz1A", "GgGarnL54Fw", "9U4-PgbN7eM", "hcnNvy_svTE", "Fb3j_yuFh1s", "n89SKAymNfA", "MtLHwqbE1eI"]
        XCTAssertEqual(cases.count, expected.count)
        for (offset, fixture) in cases.enumerated() {
            let details = fixture["album"] as! [String: String]
            let album = Album(id: details["id"]!, title: details["title"]!, artist: details["artist"]!, year: nil, artworkURL: nil)
            let row = try XCTUnwrap(Catalog.parseAlbumTracks(fixture["albumRoot"]!, album: album).first)
            let songs = try Catalog.parseSongTracks(fixture["songsRoot"]!)
            let resolver = CanonicalTrackResolver(defaults: nil), probe = RecordingSearch(songs)
            let canonical = try await resolver.resolve(row) { await probe.search($0) }
            XCTAssertEqual(canonical.playableID, expected[offset], row.title)
            XCTAssertEqual(canonical.artist, album.artist)
            let fromSongs = await resolver.registerSearch(songs)
            let equivalent = try XCTUnwrap(fromSongs.first { $0.id == expected[offset] })
            XCTAssertEqual(canonical.lyricsCacheKey, equivalent.lyricsCacheKey)
            XCTAssertEqual(canonical.mediaCacheKey(quality: .automatic), equivalent.mediaCacheKey(quality: .automatic))
            let calls = await probe.calls
            XCTAssertEqual(calls, 1, "Cold albums automatically reach Songs; cached playback needs no extra search")
        }
    }
}
