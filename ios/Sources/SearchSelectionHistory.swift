import Foundation

enum SearchSelectionHistory {
    static let limit = 20

    static func songs(_ raw: String) -> [Track] {
        var seen = Set<String>()
        return Array(decode(Track.self, raw).filter { seen.insert($0.playableID).inserted }.prefix(limit))
    }

    static func albums(_ raw: String) -> [Album] {
        var seen = Set<String>()
        return Array(decode(Album.self, raw).filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    static func remembering(_ track: Track, in values: [Track]) -> [Track] {
        Array(([track] + values.filter { $0.playableID != track.playableID }).prefix(limit))
    }

    static func remembering(_ album: Album, in values: [Album]) -> [Album] {
        Array(([album] + values.filter { $0.id != album.id }).prefix(limit))
    }

    static func encode<T: Encodable>(_ values: [T]) -> String {
        guard let data = try? JSONEncoder().encode(Array(values.prefix(limit))) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ raw: String) -> [T] {
        guard let data = raw.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return entries.compactMap { entry in
            guard JSONSerialization.isValidJSONObject(entry),
                  let data = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
    }
}
