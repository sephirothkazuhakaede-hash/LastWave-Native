import Foundation
import YouTubeKit

struct Track: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let artist: String
    let duration: Double?
    let artworkURL: URL?
    init(id: String, title: String, artist: String, duration: Double? = nil, artworkURL: URL? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.duration = duration; self.artworkURL = artworkURL
    }
    var artwork: URL? {
        upgradedArtworkURL(artworkURL) ?? URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg")
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
    case automatic = "Automatic"
    case high = "High"
    var id: String { rawValue }
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
        let url: URL
        let duration: Double?
        let requestHeaders: [String: String]
        let downloadURL: URL?
        let usesBackend: Bool

        init(
            url: URL,
            duration: Double?,
            requestHeaders: [String: String] = [:],
            downloadURL: URL? = nil,
            usesBackend: Bool = false
        ) {
            self.url = url
            self.duration = duration
            self.requestHeaders = requestHeaders
            self.downloadURL = downloadURL
            self.usesBackend = usesBackend
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
    private var resolutionTasks: [String: Task<ResolvedStream, Error>] = [:]

    func search(_ query: String) async throws -> [Track] {
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
                        let artist = runs(columns[1]).first?["text"] as? String ?? "Unknown artist"
                        let duration = columns.flatMap(runs).compactMap { ($0["text"] as? String).flatMap(parseDuration) }.first
                        let thumbnail = ((renderer["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any]
                        let artwork = (thumbnail?["thumbnails"] as? [[String: Any]])?.last?["url"] as? String
                        results.append(Track(id: id, title: title, artist: artist, duration: duration, artworkURL: artwork.flatMap(URL.init(string:))))
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
        let root = try await browseResponse(id: album.id)
        var tracks: [Track] = []
        func renderedText(_ node: Any?) -> String? {
            guard let object = node as? [String: Any] else { return nil }
            if let simple = object["simpleText"] as? String { return simple }
            return (object["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        }
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if let renderer = object["musicResponsiveListItemRenderer"] as? [String: Any],
                   let item = renderer["playlistItemData"] as? [String: Any],
                   let id = item["videoId"] as? String,
                   let columns = renderer["flexColumns"] as? [[String: Any]],
                   !tracks.contains(where: { $0.id == id }) {
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
                    if let title = values.first {
                        tracks.append(Track(id: id, title: title, artist: album.artist, duration: duration, artworkURL: artwork.flatMap(URL.init(string:)) ?? album.artworkURL))
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
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private func loadClientConfig() async -> ClientConfig {
        do {
            var request = URLRequest(url: URL(string: "https://music.youtube.com/")!)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("SOCS=CAESEwgDEgk2ODE4NDk5NzAaAmVuIAEaBgiA_LyaBg; CONSENT=YES+cb.20210328-17-p0.en+FX+999", forHTTPHeaderField: "Cookie")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return ClientConfig(apiKey: fallbackKey, version: fallbackVersion, visitorData: nil)
            }
            let html = String(decoding: data, as: UTF8.self)
            return ClientConfig(
                apiKey: configValue("INNERTUBE_API_KEY", in: html) ?? fallbackKey,
                version: configValue("INNERTUBE_CONTEXT_CLIENT_VERSION", in: html)
                    ?? configValue("INNERTUBE_CLIENT_VERSION", in: html)
                    ?? fallbackVersion,
                visitorData: configValue("VISITOR_DATA", in: html)
            )
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

    func resolvedStream(for track: Track, quality: AudioQuality = .automatic, preferRemote: Bool = false) async throws -> ResolvedStream {
        let cacheKey = track.id + ":" + quality.rawValue + ":" + BackendConfiguration.cacheDiscriminator
        if let cached = streamCache[cacheKey], cacheIsUsable(cached) { return cached.0 }
        streamCache.removeValue(forKey: cacheKey)
        if let existing = resolutionTasks[cacheKey] { return try await existing.value }
        let task = Task { () throws -> ResolvedStream in
            if !preferRemote,
               let backend = await BackendClient.shared.resolveStream(
                    videoID: track.id,
                    quality: quality,
                    knownDuration: track.duration ?? self.durationCache[track.id]
               ) {
                return ResolvedStream(
                    url: backend.audioURL,
                    duration: backend.duration,
                    requestHeaders: backend.requestHeaders,
                    downloadURL: backend.downloadURL,
                    usesBackend: true
                )
            }
            do {
                // Local extraction normally starts faster because it avoids the
                // Cloudflare WebSocket round trip. The remote extractor remains a
                // fallback, and a failed AVPlayer item retries in the opposite order.
                let youtube: YouTube
                if preferRemote {
                    youtube = YouTube(videoID: track.id, methods: [.remote, .local])
                } else {
                    youtube = YouTube(videoID: track.id, methods: [.local, .remote])
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
                let knownDuration = track.duration.flatMap { $0 > 0 ? $0 : nil } ?? self.durationCache[track.id]
                return ResolvedStream(url: stream.url, duration: knownDuration)
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
        streamCache[cacheKey] = (resolved, Date())
        return resolved
    }

    func invalidateStream(for track: Track, quality: AudioQuality) {
        let key = track.id + ":" + quality.rawValue + ":" + BackendConfiguration.cacheDiscriminator
        streamCache.removeValue(forKey: key)
        resolutionTasks[key]?.cancel()
        resolutionTasks.removeValue(forKey: key)
    }

    private func cacheIsUsable(_ cached: (ResolvedStream, Date)) -> Bool {
        if let expiryText = URLComponents(url: cached.0.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "expire" })?.value,
           let expiry = TimeInterval(expiryText) {
            return Date(timeIntervalSince1970: expiry).timeIntervalSinceNow > 300
        }
        return Date().timeIntervalSince(cached.1) < 1_800
    }

    func duration(for track: Track) async -> Double? {
        if let duration = track.duration, duration > 0 {
            durationCache[track.id] = duration
            return duration
        }
        if let cached = durationCache[track.id] { return cached }
        do {
            var request = URLRequest(url: URL(string: "https://www.youtube.com/watch?v=\(track.id)")!)
            request.timeoutInterval = 8
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let html = String(decoding: data, as: UTF8.self)
            let patterns = ["\\\"lengthSeconds\\\"\\s*:\\s*\\\"([0-9]+)\\\"", "length_seconds=([0-9]+)"]
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: html, range: range),
                      let valueRange = Range(match.range(at: 1), in: html),
                      let value = Double(html[valueRange]), value > 0 else { continue }
                durationCache[track.id] = value
                return value
            }
        } catch { }
        return nil
    }
}

struct ImportedPlaylist: Identifiable, Codable {
    let id: String
    let name: String
    let tracks: [Track]
}
