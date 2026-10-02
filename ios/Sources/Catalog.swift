import Foundation
import YouTubeKit

struct Track: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var title: String
    var artist: String
    let duration: Double?
    let artworkURL: URL?
    var downloadQuality: String? = nil
    var mediaInfo: AudioMediaInfo? = nil
    var albumID: String? = nil
    var musicVideoType: String? = nil
    var mediaID: String? = nil
    var albumTitle: String? = nil
    var trackNumber: Int? = nil
    var isExplicit: Bool? = nil
    var playableID: String { mediaID ?? id }
    var lyricsCacheKey: String { "recording-" + playableID }
    func mediaCacheKey(quality: AudioQuality) -> String {
        playableID + ":" + quality.rawValue + ":" + BackendConfiguration.cacheDiscriminator
    }
    init(id: String, title: String, artist: String, duration: Double? = nil, artworkURL: URL? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.duration = duration; self.artworkURL = artworkURL
    }
    var artwork: URL? {
        upgradedArtworkURL(artworkURL) ?? URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg")
    }

    func withDuration(_ correctedDuration: Double) -> Track {
        var copy = self
        copy = Track(id: id, title: title, artist: artist, duration: correctedDuration, artworkURL: artworkURL)
        copy.downloadQuality = downloadQuality
        copy.mediaInfo = mediaInfo
        copy.albumID = albumID
        copy.musicVideoType = musicVideoType
        copy.mediaID = mediaID
        copy.albumTitle = albumTitle
        copy.trackNumber = trackNumber
        copy.isExplicit = isExplicit
        return copy
    }

    /// Keep the originating row ID for UI/list edits, but every media consumer
    /// uses the canonical recording's ID and metadata.
    func adoptingRecording(_ song: Track) -> Track {
        // Album/playlist rows describe the recording the user selected. Preserve
        // that row's duration even when canonical resolution swaps the playable
        // media ID; stream/container metadata must not lengthen the song later.
        let preservedDuration = duration ?? song.duration
        var copy = Track(id: id, title: song.title, artist: song.artist,
                         duration: preservedDuration, artworkURL: song.artworkURL ?? artworkURL)
        copy.mediaID = song.playableID
        copy.musicVideoType = song.musicVideoType
        copy.albumID = albumID ?? song.albumID
        copy.albumTitle = albumTitle ?? song.albumTitle
        copy.trackNumber = trackNumber ?? song.trackNumber
        copy.isExplicit = song.isExplicit ?? isExplicit
        copy.downloadQuality = downloadQuality
        copy.mediaInfo = mediaInfo
        return copy
    }
}

struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let year: String?
    let artworkURL: URL?
    var artwork: URL? { upgradedArtworkURL(artworkURL) }
}

enum AudioQuality: String, CaseIterable, Identifiable, Sendable {
    case dataSaver = "Data Saver"
    case automatic = "Best Available"
    var id: String { rawValue }
    var backendValue: String { self == .dataSaver ? "dataSaver" : "automatic" }
}

private func upgradedArtworkURL(_ url: URL?) -> URL? {
    guard let url else { return nil }
    let value = url.absoluteString.replacingOccurrences(
        of: "=w[0-9]+-h[0-9]+",
        with: "=w1200-h1200",
        options: .regularExpression
    )
    return URL(string: value)
}

enum WaveError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

actor Catalog {
    struct ResolvedStream: Sendable {
        enum Source: Sendable {
            case msiCacheHit
            case msiNewExtraction
            case directFallback
        }

        let url: URL
        let duration: Double?
        let durationIsAuthoritative: Bool
        let requestHeaders: [String: String]
        let downloadURL: URL?
        let usesBackend: Bool
        let source: Source
        let mediaInfo: AudioMediaInfo?

        init(
            url: URL,
            duration: Double?,
            durationIsAuthoritative: Bool = false,
            requestHeaders: [String: String] = [:],
            downloadURL: URL? = nil,
            usesBackend: Bool = false,
            source: Source = .directFallback,
            mediaInfo: AudioMediaInfo? = nil
        ) {
            self.url = url
            self.duration = duration
            self.durationIsAuthoritative = durationIsAuthoritative
            self.requestHeaders = requestHeaders
            self.downloadURL = downloadURL
            self.usesBackend = usesBackend
            self.source = source
            self.mediaInfo = mediaInfo
        }
    }
    private struct ClientConfig {
        let apiKey: String
        let version: String
        let visitorData: String?
    }

    private let fallbackKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
    private let fallbackVersion = "1.20260707.12.00"
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
    private var streamCache: [String: (ResolvedStream, Date)] = [:]
    private var durationCache: [String: Double] = [:]
    private let recordings = CanonicalTrackResolver()
    private var albumContexts: [String: AlbumRecordingContext] = [:]
    private var albumContextTasks: [String: Task<AlbumRecordingContext, Error>] = [:]
    private var cachedClientConfig: (ClientConfig, Date)?
    private var resolutionTasks: [String: Task<ResolvedStream, Error>] = [:]

    func search(_ query: String) async throws -> [Track] {
        let songs = try await searchSongs(query)
        return await recordings.registerSearch(songs)
    }

    private func searchSongs(_ query: String) async throws -> [Track] {
        let config = await loadClientConfig()
        var components = URLComponents(string: "https://music.youtube.com/youtubei/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.apiKey),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(config.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        var client: [String: Any] = [
            "clientName": "WEB_REMIX", "clientVersion": config.version,
            "hl": "en", "gl": "PH"
        ]
        if let visitorData = config.visitorData { client["visitorData"] = visitorData }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": client],
            "query": query,
            "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WaveError.message("YouTube Music did not accept the search request.")
        }
        let root = try JSONSerialization.jsonObject(with: data)
        return try Self.parseSongTracks(root)
    }

    static func parseSongTracks(_ root: Any) throws -> [Track] {
        var results: [Track] = []
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if let renderer = object["musicResponsiveListItemRenderer"] as? [String: Any],
                   let columns = renderer["flexColumns"] as? [[String: Any]], columns.count >= 2 {
                    func runs(_ column: [String: Any]) -> [[String: Any]] {
                        let item = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
                        return (item?["text"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
                    }
                    let titleRuns = runs(columns[0])
                    let navigation = titleRuns.first?["navigationEndpoint"] as? [String: Any]
                    let watch = navigation?["watchEndpoint"] as? [String: Any]
                    let playlist = renderer["playlistItemData"] as? [String: Any]
                    if let id = (playlist?["videoId"] ?? watch?["videoId"]) as? String,
                       let title = titleRuns.first?["text"] as? String,
                       !results.contains(where: { $0.id == id }) {
                        let artist = Self.artistName(in: columns.dropFirst().flatMap(runs))
                            ?? runs(columns[1]).first?["text"] as? String ?? "Unknown artist"
                        let duration = columns.flatMap(runs).compactMap { ($0["text"] as? String).flatMap(MediaDuration.parse) }.first
                        let thumbnail = ((renderer["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any]
                        let artwork = (thumbnail?["thumbnails"] as? [[String: Any]])?.last?["url"] as? String
                        var track = Track(id: id, title: title, artist: artist, duration: duration, artworkURL: artwork.flatMap(URL.init(string:)))
                        track.musicVideoType = Self.primaryMusicVideoType(in: renderer)
                        track.albumID = columns.dropFirst().flatMap(runs).compactMap { run in
                            let endpoint = run["navigationEndpoint"] as? [String: Any]
                            let browse = endpoint?["browseEndpoint"] as? [String: Any]
                            return browse?["browseId"] as? String
                        }.first { $0.hasPrefix("MPRE") }
                        track.albumTitle = columns.dropFirst().flatMap(runs).first { run in
                            let endpoint = run["navigationEndpoint"] as? [String: Any]
                            let browse = endpoint?["browseEndpoint"] as? [String: Any]
                            return (browse?["browseId"] as? String)?.hasPrefix("MPRE") == true
                        }?["text"] as? String
                        track.isExplicit = Self.hasExplicitBadge(renderer)
                        results.append(track)
                    }
                }
                for value in object.values { walk(value) }
            } else if let array = node as? [Any] { for value in array { walk(value) } }
        }
        walk(root)
        if results.isEmpty { throw WaveError.message("No songs were returned for that search.") }
        return results
    }

    func searchAlbums(_ query: String) async throws -> [Album] {
        let root = try await searchResponse(query: query, params: "EgWKAQIYAWoKEAkQChAFEAMQBA==")
        var results: [Album] = []
        func textRuns(_ column: [String: Any]) -> [[String: Any]] {
            let item = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
            return (item?["text"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
        }
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if let renderer = object["musicResponsiveListItemRenderer"] as? [String: Any],
                   let navigation = renderer["navigationEndpoint"] as? [String: Any],
                   let browse = navigation["browseEndpoint"] as? [String: Any],
                   let id = browse["browseId"] as? String, id.hasPrefix("MPRE"),
                   let columns = renderer["flexColumns"] as? [[String: Any]],
                   let title = columns.first.flatMap({ textRuns($0).first?["text"] as? String }),
                   !results.contains(where: { $0.id == id }) {
                    let details = columns.dropFirst().flatMap(textRuns)
                    let artist = details.first(where: { run in
                        let endpoint = run["navigationEndpoint"] as? [String: Any]
                        let artistBrowse = endpoint?["browseEndpoint"] as? [String: Any]
                        return (artistBrowse?["browseId"] as? String)?.hasPrefix("UC") == true
                    })?["text"] as? String ?? details.compactMap { $0["text"] as? String }.first(where: { $0 != "Album" && $0 != "Single" && $0 != "EP" && $0 != " • " }) ?? "Unknown artist"
                    let year = details.compactMap { $0["text"] as? String }.first(where: { $0.range(of: "^[0-9]{4}$", options: .regularExpression) != nil })
                    let thumbnail = ((renderer["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any]
                    let artwork = (thumbnail?["thumbnails"] as? [[String: Any]])?.last?["url"] as? String
                    results.append(Album(id: id, title: title, artist: artist, year: year, artworkURL: artwork.flatMap(URL.init(string:))))
                }
                object.values.forEach(walk)
            } else if let array = node as? [Any] { array.forEach(walk) }
        }
        walk(root)
        if results.isEmpty { throw WaveError.message("No albums were returned for that search.") }
        return results
    }

    func albumTracks(for album: Album) async throws -> [Track] {
        if !AlbumAudioIdentity.isMissingArtist(album.artist) {
            albumContexts[album.id] = AlbumRecordingContext(title: album.title, artist: album.artist)
        }
        let root = try await browseResponse(id: album.id)
        return try Self.parseAlbumTracks(root, album: album)
    }

    nonisolated static func parseAlbumTracks(_ root: Any, album: Album) throws -> [Track] {
        var tracks: [Track] = []
        func renderedText(_ node: Any?) -> String? {
            guard let object = node as? [String: Any] else { return nil }
            if let simple = object["simpleText"] as? String { return simple }
            return (object["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        }
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if let renderer = object["musicResponsiveListItemRenderer"] as? [String: Any], renderer["index"] != nil,
                   let item = renderer["playlistItemData"] as? [String: Any],
                   let id = item["videoId"] as? String,
                   let columns = renderer["flexColumns"] as? [[String: Any]],
                   !tracks.contains(where: { $0.id == id }) {
                    // Preserve column positions. YouTube sends text:{} for an
                    // absent artist; compactMap shifted the play count into it.
                    let values = columns.map { column -> String in
                        let flex = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
                        return renderedText(flex?["text"]) ?? ""
                    }
                    let fixedColumns = renderer["fixedColumns"] as? [[String: Any]] ?? []
                    let duration = fixedColumns.compactMap { column -> Double? in
                        let fixed = column["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any]
                        return renderedText(fixed?["text"]).flatMap(MediaDuration.parse)
                    }.first
                    let thumbnail = ((renderer["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any]
                    let artwork = (thumbnail?["thumbnails"] as? [[String: Any]])?.last?["url"] as? String
                    if let title = values.first {
                        let artistRuns = columns.dropFirst().flatMap { column -> [[String: Any]] in
                            let flex = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
                            return (flex?["text"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
                        }
                        let artist = Self.artistName(in: artistRuns) ?? values.dropFirst().first.flatMap { value in
                            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                        } ?? album.artist
                        var track = Track(id: id, title: title, artist: artist, duration: duration, artworkURL: artwork.flatMap(URL.init(string:)) ?? album.artworkURL)
                        track.albumID = album.id
                        track.albumTitle = album.title
                        track.trackNumber = renderedText(renderer["index"]).flatMap(Int.init)
                        track.isExplicit = Self.hasExplicitBadge(renderer)
                        track.musicVideoType = Self.primaryMusicVideoType(in: renderer)
                        tracks.append(track)
                    }
                }
                object.values.forEach(walk)
            } else if let array = node as? [Any] { array.forEach(walk) }
        }
        walk(root)
        if tracks.isEmpty { throw WaveError.message("No playable songs were found in that album.") }
        return tracks
    }

    func playlist(from input: String) async throws -> ImportedPlaylist {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let listID = URLComponents(string: value)?.queryItems?.first(where: { $0.name == "list" })?.value ?? value
        guard !listID.isEmpty else { throw WaveError.message("Paste a valid public YouTube playlist link.") }
        let config = await loadClientConfig()
        var components = URLComponents(string: "https://music.youtube.com/youtubei/v1/browse")!
        components.queryItems = [URLQueryItem(name: "key", value: config.apiKey), URLQueryItem(name: "prettyPrint", value: "false")]
        var request = URLRequest(url: components.url!); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": config.version, "hl": "en", "gl": "PH"]],
            "browseId": listID.hasPrefix("VL") ? listID : "VL" + listID
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WaveError.message("That playlist could not be opened. Make sure it is public.") }
        let root = try JSONSerialization.jsonObject(with: data)
        var tracks: [Track] = []; var name = "YouTube Playlist"
        func renderedText(_ node: Any?) -> String? {
            guard let object = node as? [String: Any] else { return nil }
            if let simple = object["simpleText"] as? String { return simple }
            return (object["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        }
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if let header = object["musicDetailHeaderRenderer"] as? [String: Any], let title = renderedText(header["title"]) { name = title }
                if let renderer = object["musicResponsiveListItemRenderer"] as? [String: Any],
                   let item = renderer["playlistItemData"] as? [String: Any], let id = item["videoId"] as? String,
                   let columns = renderer["flexColumns"] as? [[String: Any]], !tracks.contains(where: { $0.id == id }) {
                    let values = columns.compactMap { column -> String? in
                        let flex = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
                        return renderedText(flex?["text"])
                    }
                    let fixedColumns = renderer["fixedColumns"] as? [[String: Any]] ?? []
                    let duration = fixedColumns.compactMap { column -> Double? in
                        let fixed = column["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any]
                        return renderedText(fixed?["text"]).flatMap(parseDuration)
                    }.first
                    let thumbnail = ((renderer["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any]
                    let artwork = (thumbnail?["thumbnails"] as? [[String: Any]])?.last?["url"] as? String
                    if let title = values.first { tracks.append(Track(id: id, title: title, artist: values.dropFirst().first ?? "Unknown artist", duration: duration, artworkURL: artwork.flatMap(URL.init(string:)))) }
                }
                object.values.forEach(walk)
            } else if let array = node as? [Any] { array.forEach(walk) }
        }
        walk(root)
        guard !tracks.isEmpty else { throw WaveError.message("No downloadable songs were found in that playlist.") }
        return ImportedPlaylist(id: listID, name: name, tracks: tracks)
    }

    private func searchResponse(query: String, params: String) async throws -> Any {
        let config = await loadClientConfig()
        var components = URLComponents(string: "https://music.youtube.com/youtubei/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.apiKey),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(config.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": config.version, "hl": "en", "gl": "PH"]
        if let visitorData = config.visitorData { client["visitorData"] = visitorData }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["context": ["client": client], "query": query, "params": params])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WaveError.message("YouTube Music did not accept the search request.") }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func browseResponse(id: String) async throws -> Any {
        let config = await loadClientConfig()
        var components = URLComponents(string: "https://music.youtube.com/youtubei/v1/browse")!
        components.queryItems = [URLQueryItem(name: "key", value: config.apiKey), URLQueryItem(name: "prettyPrint", value: "false")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": config.version, "hl": "en", "gl": "PH"]],
            "browseId": id
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WaveError.message("That album could not be opened.") }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func parseDuration(_ value: String) -> Double? {
        MediaDuration.parse(value)
    }

    private func loadClientConfig() async -> ClientConfig {
        if let cachedClientConfig, Date().timeIntervalSince(cachedClientConfig.1) < 300 {
            return cachedClientConfig.0
        }
        do {
            var request = URLRequest(url: URL(string: "https://music.youtube.com/")!)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("SOCS=CAESEwgDEgk2ODE4NDk5NzAaAmVuIAEaBgiA_LyaBg; CONSENT=YES+cb.20210328-17-p0.en+FX+999", forHTTPHeaderField: "Cookie")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return ClientConfig(apiKey: fallbackKey, version: fallbackVersion, visitorData: nil)
            }
            let html = String(decoding: data, as: UTF8.self)
            let config = ClientConfig(
                apiKey: configValue("INNERTUBE_API_KEY", in: html) ?? fallbackKey,
                version: configValue("INNERTUBE_CONTEXT_CLIENT_VERSION", in: html)
                    ?? configValue("INNERTUBE_CLIENT_VERSION", in: html)
                    ?? fallbackVersion,
                visitorData: configValue("VISITOR_DATA", in: html)
            )
            cachedClientConfig = (config, Date())
            return config
        } catch {
            return ClientConfig(apiKey: fallbackKey, version: fallbackVersion, visitorData: nil)
        }
    }

    private func configValue(_ key: String, in html: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let patterns = [
            "\\\"\(escapedKey)\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"",
            "\\\\\\\"\(escapedKey)\\\\\\\"\\s*:\\s*\\\\\\\"([^\\\\\\\"]+)\\\\\\\""
        ]
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: fullRange),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            return String(html[range])
                .replacingOccurrences(of: "\\u003d", with: "=")
                .replacingOccurrences(of: "\\x3d", with: "=")
                .replacingOccurrences(of: "\\/", with: "/")
        }
        return nil
    }

    func stream(for track: Track, quality: AudioQuality = .automatic, preferRemote: Bool = false) async throws -> URL {
        try await resolvedStream(for: track, quality: quality, preferRemote: preferRemote).url
    }

    private static func stringValue(_ key: String, in node: Any) -> String? {
        if let object = node as? [String: Any] {
            if let value = object[key] as? String { return value }
            for value in object.values { if let found = stringValue(key, in: value) { return found } }
        } else if let array = node as? [Any] {
            for value in array { if let found = stringValue(key, in: value) { return found } }
        }
        return nil
    }

    private static func primaryMusicVideoType(in renderer: [String: Any]) -> String? {
        // Menu commands can contain endpoints for another recording. Never let
        // dictionary traversal classify this row using one of those endpoints.
        let columns = renderer["flexColumns"] as? [[String: Any]] ?? []
        let first = columns.first?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
        let runs = (first?["text"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
        for run in runs {
            if let endpoint = run["navigationEndpoint"], let type = stringValue("musicVideoType", in: endpoint) { return type }
        }
        if let endpoint = renderer["navigationEndpoint"], let type = stringValue("musicVideoType", in: endpoint) { return type }
        if let overlay = renderer["overlay"], let type = stringValue("musicVideoType", in: overlay) { return type }
        return nil
    }

    private static func hasExplicitBadge(_ renderer: [String: Any]) -> Bool {
        stringValue("iconType", in: renderer["badges"] ?? []) == "MUSIC_EXPLICIT_BADGE"
    }

    private static func artistName(in runs: [[String: Any]]) -> String? {
        runs.first { run in
            let endpoint = run["navigationEndpoint"] as? [String: Any]
            let browse = endpoint?["browseEndpoint"] as? [String: Any]
            return (browse?["browseId"] as? String)?.hasPrefix("UC") == true
        }?["text"] as? String
    }

    func normalizedTrack(_ track: Track) async throws -> Track {
        try await recordings.resolve(track, albumContext: { id in
            try await self.albumContext(for: id)
        }) { query in try await self.searchSongs(query) }
    }

    private func albumContext(for id: String) async throws -> AlbumRecordingContext {
        if let context = albumContexts[id] { return context }
        if let task = albumContextTasks[id] { return try await task.value }
        let task = Task {
            let root = try await self.browseResponse(id: id)
            return try Self.parseAlbumContext(root)
        }
        albumContextTasks[id] = task
        defer { albumContextTasks.removeValue(forKey: id) }
        let context = try await task.value
        albumContexts[id] = context
        return context
    }

    static func parseAlbumContext(_ root: Any) throws -> AlbumRecordingContext {
        var result: AlbumRecordingContext?
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                for name in ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer"] {
                    if let header = object[name] as? [String: Any],
                       let titleText = header["title"] as? [String: Any] {
                        let title = titleText["simpleText"] as? String
                            ?? (titleText["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
                        let artistRuns = ["straplineTextOne", "straplineText", "subtitle"].flatMap { key -> [[String: Any]] in
                            (header[key] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
                        }
                        if let title, let artist = artistName(in: artistRuns), !AlbumAudioIdentity.isMissingArtist(artist) {
                            result = AlbumRecordingContext(title: title, artist: artist)
                            return
                        }
                    }
                }
                for value in object.values where result == nil { walk(value) }
            } else if let array = node as? [Any] { for value in array where result == nil { walk(value) } }
        }
        walk(root)
        guard let result else { throw WaveError.message("Album artist metadata is not available yet.") }
        return result
    }

    func resolvedStream(for requestedTrack: Track, quality: AudioQuality = .automatic, preferRemote: Bool = false) async throws -> ResolvedStream {
        let track = try await normalizedTrack(requestedTrack)
        let cacheKey = track.mediaCacheKey(quality: quality)
        if let cached = streamCache[cacheKey], cacheIsUsable(cached) { return cached.0 }
        streamCache.removeValue(forKey: cacheKey)
        if let existing = resolutionTasks[cacheKey] { return try await existing.value }
        let task = Task { () throws -> ResolvedStream in
            if !preferRemote,
               let backend = await BackendClient.shared.resolveStream(
                    videoID: track.playableID,
                    quality: quality,
                    knownDuration: self.durationCache[track.playableID] ?? track.duration
               ) {
                return ResolvedStream(
                    url: backend.audioURL,
                    duration: backend.duration,
                    durationIsAuthoritative: backend.durationIsAuthoritative,
                    requestHeaders: backend.requestHeaders,
                    downloadURL: backend.downloadURL,
                    usesBackend: true,
                    source: backend.source == .cacheHit ? .msiCacheHit : .msiNewExtraction,
                    mediaInfo: backend.mediaInfo
                )
            }
            do {
                // Local extraction normally starts faster because it avoids the
                // Cloudflare WebSocket round trip. The remote extractor remains a
                // fallback, and a failed AVPlayer item retries in the opposite order.
                let youtube: YouTube
                if preferRemote {
                    youtube = YouTube(videoID: track.playableID, methods: [.remote, .local])
                } else {
                    youtube = YouTube(videoID: track.playableID, methods: [.local, .remote])
                }
                let streams = try await youtube.streams
                let audio = streams.filterAudioOnly().filter(\.isNativelyPlayable)
                let preferred = audio.filter { $0.fileExtension == .m4a }
                let selected = quality == .dataSaver
                    ? (preferred.lowestAudioBitrateStream() ?? audio.lowestAudioBitrateStream())
                    : (preferred.highestAudioBitrateStream() ?? audio.highestAudioBitrateStream())
                guard let stream = selected
                        ?? streams.filterVideoAndAudio().filter(\.isNativelyPlayable).highestAudioBitrateStream() else {
                    throw WaveError.message("This upload has no iPhone-compatible audio stream.")
                }
                // Do not block first audio on a second metadata request. If the
                // search result had no duration, WavePlayer fills it in later.
                let authoritativeDuration = self.durationCache[track.playableID]
                let knownDuration = authoritativeDuration
                    ?? track.duration.flatMap { $0 > 0 ? $0 : nil }
                let usable = preferred.isEmpty ? audio : preferred
                let bitrateChoices = Set(usable.compactMap { $0.averageBitrate ?? $0.bitrate }.filter { $0 > 0 })
                let receivedBitrate = stream.videoCodec == nil ? (stream.averageBitrate ?? stream.bitrate) : nil
                return ResolvedStream(
                    url: stream.url,
                    duration: knownDuration,
                    durationIsAuthoritative: authoritativeDuration != nil,
                    source: .directFallback,
                    mediaInfo: AudioMediaInfo(
                        container: stream.fileExtension.rawValue,
                        codec: stream.audioCodec.map { codec in
                            switch codec {
                            case .mp4a(let version): return version.isEmpty ? "mp4a" : "mp4a.\(version)"
                            case .opus: return "opus"
                            case .ec3: return "ec-3"
                            case .ac3: return "ac-3"
                            case .unknown(let value): return value
                            }
                        },
                        bitrateKbps: receivedBitrate.map { Double($0) / 1000 },
                        sampleRateHz: nil,
                        formatId: nil,
                        selectedMode: quality.backendValue,
                        effectiveMode: bitrateChoices.count == 1 ? "automatic" : quality.backendValue,
                        availableQualityCount: bitrateChoices.isEmpty ? nil : bitrateChoices.count
                    )
                )
            } catch let error as YouTubeKitError {
                switch error {
                case .videoPrivate:
                    throw WaveError.message("This YouTube upload is private.")
                case .videoAgeRestricted:
                    throw WaveError.message("This upload is age-restricted and cannot be played without YouTube sign-in.")
                case .membersOnly:
                    throw WaveError.message("This upload is only available to channel members.")
                case .videoRegionBlocked:
                    throw WaveError.message("This upload is not available in your region.")
                case .videoUnavailable:
                    throw WaveError.message("This YouTube upload is unavailable.")
                case .liveStreamError:
                    throw WaveError.message("Live streams are not supported in CapyFlow yet.")
                default:
                    throw WaveError.message("YouTube could not create a playable audio link. Please retry in a moment.")
                }
            }
        }
        resolutionTasks[cacheKey] = task
        defer { resolutionTasks.removeValue(forKey: cacheKey) }
        let resolved = try await task.value
        if resolved.durationIsAuthoritative, let duration = resolved.duration {
            durationCache[track.playableID] = duration
            await recordings.recordDuration(duration, track: track, mediaInfo: resolved.mediaInfo)
        }
        streamCache[cacheKey] = (resolved, Date())
        return resolved
    }

    func invalidateStream(for track: Track, quality: AudioQuality) {
        let suffix = ":" + quality.rawValue + ":" + BackendConfiguration.cacheDiscriminator
        let keys = Set(streamCache.keys).union(resolutionTasks.keys).filter {
            $0.hasPrefix(track.playableID + ":") && $0.hasSuffix(suffix)
        }
        for key in keys {
            streamCache.removeValue(forKey: key)
            resolutionTasks[key]?.cancel()
            resolutionTasks.removeValue(forKey: key)
        }
    }

    private func cacheIsUsable(_ cached: (ResolvedStream, Date)) -> Bool {
        if let expiryText = URLComponents(url: cached.0.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "expire" })?.value,
           let expiry = TimeInterval(expiryText) {
            return Date(timeIntervalSince1970: expiry).timeIntervalSinceNow > 300
        }
        return Date().timeIntervalSince(cached.1) < 1_800
    }

    func recordAuthoritativeDuration(_ duration: Double, for trackID: String) async {
        guard duration.isFinite, duration > 0 else { return }
        durationCache[trackID] = duration
        await recordings.recordDuration(duration, rowID: trackID)
    }
}

struct ImportedPlaylist: Identifiable, Codable {
    let id: String
    let name: String
    let tracks: [Track]
}
