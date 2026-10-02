import XCTest
@testable import CapyFlow

private final class FixtureLyricsProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let body = Self.body
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CanonicalLyricsTests: XCTestCase {
    private func service(body: String, folder: URL) -> LyricsService {
        FixtureLyricsProtocol.lock.lock()
        FixtureLyricsProtocol.requests = []
        FixtureLyricsProtocol.body = Data(body.utf8)
        FixtureLyricsProtocol.lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureLyricsProtocol.self]
        return LyricsService(session: URLSession(configuration: config), folder: folder)
    }
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func tracks() -> (Track, Track) {
        var song = Track(id: "audio-id", title: "Song (feat. Guest)", artist: "Singer", duration: 200)
        song.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
        var album = Track(id: "album-video", title: "Song (feat. Guest)", artist: "Singer", duration: 200)
        album.albumID = "MPRE_album"
        album = album.adoptingRecording(song)
        return (album, song)
    }
    func testColdAlbumFetchesSyncedLyricsAndSongsUsesSameMemoryAndDiskEntry() async throws {
        let path = folder()
        defer { try? FileManager.default.removeItem(at: path) }
        let service = service(body: #"[{"instrumental":false,"trackName":"Song","artistName":"Singer","duration":200,"syncedLyrics":"[00:01.00]Fixture line","plainLyrics":null}]"#, folder: path)
        let (album, song) = tracks()
        let first = try await service.lyrics(for: album)
        let second = try await service.lyrics(for: song)
        XCTAssertEqual(first, [LyricLine(time: 1, text: "Fixture line")])
        XCTAssertEqual(second, first)
        XCTAssertEqual(FixtureLyricsProtocol.requests.count, 1, "Album lyrics must work before Songs search")
        let requested = try XCTUnwrap(FixtureLyricsProtocol.requests.first?.url)
        XCTAssertEqual(requested, LyricsService.lookupURL(for: song))
        let reopened = LyricsService(folder: path)
        let offline = try await reopened.lyrics(for: album)
        XCTAssertEqual(offline, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent(song.lyricsCacheKey + ".json").path))
    }
    func testSongsFirstAlbumUsesTheSamePlainLyricsCache() async throws {
        let path = folder()
        defer { try? FileManager.default.removeItem(at: path) }
        let service = service(body: #"[{"instrumental":false,"trackName":"Song","artistName":"Singer","duration":200,"syncedLyrics":null,"plainLyrics":"Plain fixture line"}]"#, folder: path)
        let (album, song) = tracks()
        let first = try await service.lyrics(for: song)
        let second = try await service.lyrics(for: album)
        XCTAssertEqual(first, [LyricLine(time: nil, text: "Plain fixture line")])
        XCTAssertEqual(second, first)
        XCTAssertEqual(FixtureLyricsProtocol.requests.count, 1)
    }
    func testWrongDurationAndArtistAreNotChosenJustBecauseTheyHaveSyncedLyrics() async throws {
        let path = folder()
        defer { try? FileManager.default.removeItem(at: path) }
        let service = service(body: #"[{"instrumental":false,"trackName":"Song","artistName":"Singer","duration":400,"syncedLyrics":"[00:01]Wrong long version","plainLyrics":null},{"instrumental":false,"trackName":"Song","artistName":"Cover Artist","duration":200,"syncedLyrics":"[00:01]Wrong cover","plainLyrics":null},{"instrumental":false,"trackName":"Song","artistName":"Singer","duration":200,"syncedLyrics":null,"plainLyrics":"Correct plain fixture"}]"#, folder: path)
        let lines = try await service.lyrics(for: tracks().0)
        XCTAssertEqual(lines, [LyricLine(time: nil, text: "Correct plain fixture")])
    }
    func testExistingSongsLyricsFileMigratesToCanonicalAlbumKeyWithoutNetwork() async throws {
        let path = folder()
        defer { try? FileManager.default.removeItem(at: path) }
        let (album, song) = tracks()
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let lines = [LyricLine(time: 2, text: "Existing fixture")]
        try JSONEncoder().encode(lines).write(to: path.appendingPathComponent(song.id + ".json"))
        let service = service(body: "[]", folder: path)
        let result = try await service.lyrics(for: album)
        XCTAssertEqual(result, lines)
        XCTAssertEqual(FixtureLyricsProtocol.requests.count, 0)
    }
}
