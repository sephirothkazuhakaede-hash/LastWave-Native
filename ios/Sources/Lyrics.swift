import Foundation

struct LyricLine: Identifiable, Equatable {
    let time: Double?
    let text: String
    var id: String { "\(time ?? -1)-\(text)" }
}

private struct LyricsRecord: Decodable {
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
}

actor LyricsService {
    private var cache: [String: [LyricLine]] = [:]

    func lyrics(for track: Track) async throws -> [LyricLine] {
        if let cached = cache[track.id] { return cached }
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: cleaned(track.title)),
            URLQueryItem(name: "artist_name", value: cleaned(track.artist))
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("LastWave-iOS/0.2 (https://github.com/sephirothkazuhakaede-hash/LastWave-Native)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WaveError.message("Lyrics service did not respond.") }
        if http.statusCode == 429 { throw WaveError.message("Lyrics are temporarily rate limited. Try again shortly.") }
        guard http.statusCode == 200 else { throw WaveError.message("Lyrics are not available for this song.") }
        let records = try JSONDecoder().decode([LyricsRecord].self, from: data)
        guard let record = records.first(where: { $0.syncedLyrics?.isEmpty == false }) ?? records.first else {
            throw WaveError.message("Lyrics are not available for this song.")
        }
        let lines: [LyricLine]
        if record.instrumental {
            lines = [LyricLine(time: nil, text: "Instrumental")]
        } else if let synced = record.syncedLyrics, !synced.isEmpty {
            lines = parseLRC(synced)
        } else if let plain = record.plainLyrics, !plain.isEmpty {
            lines = plain.split(whereSeparator: \.isNewline).map { LyricLine(time: nil, text: String($0)) }
        } else {
            throw WaveError.message("Lyrics are not available for this song.")
        }
        cache[track.id] = lines
        return lines
    }

    private func cleaned(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s*[\(\[].*?(official|video|audio|lyrics?|visuali[sz]er).*?[\)\]]"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseLRC(_ source: String) -> [LyricLine] {
        let pattern = #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var parsed: [LyricLine] = []
        for raw in source.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = regex.matches(in: line, range: range)
            let text = regex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            for match in matches where !text.isEmpty {
                guard let minuteRange = Range(match.range(at: 1), in: line),
                      let secondRange = Range(match.range(at: 2), in: line) else { continue }
                let minutes = Double(line[minuteRange]) ?? 0
                let seconds = Double(line[secondRange]) ?? 0
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound, let fractionRange = Range(match.range(at: 3), in: line) {
                    let digits = String(line[fractionRange])
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                parsed.append(LyricLine(time: minutes * 60 + seconds + fraction, text: text))
            }
        }
        return parsed.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
    }
}
