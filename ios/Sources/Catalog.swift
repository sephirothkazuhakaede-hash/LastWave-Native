import Foundation
import YouTubeKit

struct Track: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let artist: String
    var artwork: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") }
}

enum WaveError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

actor Catalog {
    private struct ClientConfig {
        let apiKey: String
        let version: String
        let visitorData: String?
    }

    private let fallbackKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
    private let fallbackVersion = "1.20260707.12.00"
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"

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
                        results.append(Track(id: id, title: title, artist: artist))
                    }
                }
                for value in object.values { walk(value) }
            } else if let array = node as? [Any] { for value in array { walk(value) } }
        }
        walk(root)
        if results.isEmpty { throw WaveError.message("No songs were returned for that search.") }
        return results
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

    func stream(for track: Track) async throws -> URL {
        // Prefer on-device extraction, then use YouTubeKit's maintained fallback when
        // YouTube changes its player response before an app update can ship.
        let streams = try await YouTube(videoID: track.id, methods: [.local, .remote]).streams
        let audio = streams.filterAudioOnly().filter(\.isNativelyPlayable)
        guard let stream = audio.filter({ $0.fileExtension == .m4a }).highestAudioBitrateStream()
                ?? audio.highestAudioBitrateStream()
                ?? streams.filterVideoAndAudio().filter(\.isNativelyPlayable).highestAudioBitrateStream() else {
            throw WaveError.message("No compatible audio stream. YouTube may have changed its extractor requirements.")
        }
        return stream.url
    }
}
