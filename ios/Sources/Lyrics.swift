import Foundation

struct LyricLine: Identifiable, Equatable, Codable {
    let time: Double?
    let text: String
    var id: String { "\(time ?? -1)-\(text)" }
}

private struct LyricsRecord: Decodable {
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
    let trackName: String?
    let artistName: String?
    let duration: Double?
}

actor LyricsService {
    private var cache: [String: [LyricLine]] = [:]
    private var pending: [String: Task<[LyricLine], Error>] = [:]
    private let folder: URL
    private let session: URLSession

    init(session: URLSession = .shared, folder: URL? = nil) {
        self.session = session
        self.folder = folder ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineLyrics", isDirectory: true)
    }

    static func lookupURL(for track: Track) -> URL {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: AlbumAudioIdentity.title(track.title)),
            URLQueryItem(name: "artist_name", value: AlbumAudioIdentity.artist(track.artist))
        ]
        return components.url!
    }

    func lyrics(for track: Track) async throws -> [LyricLine] {
        let key = track.lyricsCacheKey
        if let saved = cache[key] { return saved }
        if let task = pending[key] { return try await task.value }
        let task = Task { try await self.fetchLyrics(for: track) }
        pending[key] = task
        defer { pending.removeValue(forKey: key) }
        return try await task.value
    }

    private func fetchLyrics(for track: Track) async throws -> [LyricLine] {
        let key = track.lyricsCacheKey
        if let cached = cache[key] { return cached }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(key + ".json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([LyricLine].self, from: data), !saved.isEmpty {
            cache[key] = saved; return saved
        }
        // Songs-search caches from previous builds already use the recording
        // ID. Reuse those files for album rows as well, then migrate the key.
        let legacy = folder.appendingPathComponent(track.playableID + ".json")
        if let data = try? Data(contentsOf: legacy), let saved = try? JSONDecoder().decode([LyricLine].self, from: data), !saved.isEmpty {
            cache[key] = saved
            try? data.write(to: file, options: .atomic)
            return saved
        }
        var request = URLRequest(url: Self.lookupURL(for: track))
        request.timeoutInterval = 15
        request.setValue("CapyFlow-iOS/0.2 (https://github.com/sephirothkazuhakaede-hash/LastWave-Native)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WaveError.message("Lyrics service did not respond.") }
        if http.statusCode == 429 { throw WaveError.message("Lyrics are temporarily rate limited. Try again shortly.") }
        guard http.statusCode == 200 else { throw WaveError.message("Lyrics are not available for this song.") }
        let records = try JSONDecoder().decode([LyricsRecord].self, from: data)
        let matching = records.filter { record in
            if let title = record.trackName, AlbumAudioIdentity.key(AlbumAudioIdentity.title(title)) != AlbumAudioIdentity.key(AlbumAudioIdentity.title(track.title)) { return false }
            if let artist = record.artistName, AlbumAudioIdentity.key(AlbumAudioIdentity.artist(artist)) != AlbumAudioIdentity.key(AlbumAudioIdentity.artist(track.artist)) { return false }
            if let duration = track.duration, let actual = record.duration, abs(duration - actual) > max(5, min(12, duration * 0.04)) { return false }
            return true
        }.sorted { lhs, rhs in
            func score(_ record: LyricsRecord) -> Double {
                let distance = abs((record.duration ?? track.duration ?? 0) - (track.duration ?? record.duration ?? 0))
                return (record.syncedLyrics?.isEmpty == false ? 20 : 0) - distance
            }
            return score(lhs) > score(rhs)
        }
        guard let record = matching.first(where: { $0.instrumental || $0.syncedLyrics?.isEmpty == false || $0.plainLyrics?.isEmpty == false }) else {
            throw WaveError.message("Lyrics are not available for this song.")
        }
        let lines: [LyricLine]
        if record.instrumental {
            lines = [LyricLine(time: nil, text: "Instrumental")]
        } else if let synced = record.syncedLyrics, !synced.isEmpty {
            let parsed = parseLRC(synced)
            lines = parsed.isEmpty ? (record.plainLyrics ?? "").split(whereSeparator: \.isNewline).map { LyricLine(time: nil, text: String($0)) } : parsed
        } else if let plain = record.plainLyrics, !plain.isEmpty {
            lines = plain.split(whereSeparator: \.isNewline).map { LyricLine(time: nil, text: String($0)) }
        } else {
            throw WaveError.message("Lyrics are not available for this song.")
        }
        guard !lines.isEmpty else { throw WaveError.message("Lyrics are not available for this song.") }
        cache[key] = lines
        if let data = try? JSONEncoder().encode(lines) { try? data.write(to: file, options: .atomic) }
        return lines
    }

    func matchingTracks(_ query: String) async throws -> [(String, String)] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!); request.timeoutInterval = 15
        request.setValue("CapyFlow-iOS/0.2 (https://github.com/sephirothkazuhakaede-hash/LastWave-Native)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let records = try JSONDecoder().decode([LyricsSearchRecord].self, from: data)
        return Array(records.prefix(5)).map { ($0.trackName, $0.artistName) }
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

private struct LyricsSearchRecord: Decodable {
    let trackName: String
    let artistName: String
}
