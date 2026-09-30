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
    func search(_ query: String) async throws -> [Track] {
        let (htmlData, _) = try await URLSession.shared.data(from: URL(string: "https://music.youtube.com")!)
        let html = String(decoding: htmlData, as: UTF8.self)
        guard let range = html.range(of: #""INNERTUBE_CLIENT_VERSION":"([^"]+)""#, options: .regularExpression) else {
            throw WaveError.message("YouTube client configuration unavailable. Try again later.")
        }
        let version = String(html[range]).components(separatedBy: "\"")[3]
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": version, "hl": "en", "gl": "PH"]],
            "query": query,
            "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WaveError.message("YouTube search request failed.") }
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
        return results
    }

    func stream(for track: Track) async throws -> URL {
        let streams = try await YouTube(videoID: track.id, methods: [.local]).streams
        guard let stream = streams.filterAudioOnly().filter({ $0.fileExtension == .m4a }).highestAudioBitrateStream() else {
            throw WaveError.message("No compatible audio stream. YouTube may have changed its extractor requirements.")
        }
        return stream.url
    }
}
