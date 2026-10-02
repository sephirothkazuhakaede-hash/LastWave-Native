import Foundation

enum AlbumAudioIdentity {
    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func title(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s*[\(\[]\s*(feat\.?|featuring|ft\.?)\s+[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+\b(feat\.?|featuring|ft\.?)\s+[^\(\[]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*[\(\[]\s*(official\s+(audio|music\s+video|video)|lyrics?\s+video|visuali[sz]er|explicit|clean|\d{4}\s+remaster(ed)?|remaster(ed)?(\s+\d{4})?)\s*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*[-–—]\s*(official\s+(audio|music\s+video|video)|lyrics?\s+video|visuali[sz]er|\d{4}\s+remaster(ed)?|remaster(ed)?(\s+\d{4})?)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func artist(_ value: String) -> String {
        title(value).replacingOccurrences(of: #"\s*[-–—]\s*Topic\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func compatible(_ track: Track, _ candidate: Track) -> Bool {
        guard candidate.musicVideoType == "MUSIC_VIDEO_TYPE_ATV" else { return false }
        // The same media ID is direct evidence of the same recording, including
        // localized title/artist metadata or stale Unknown artist saved rows.
        if candidate.playableID == track.playableID { return true }
        guard
              !key(title(track.title)).isEmpty,
              key(title(track.title)) == key(title(candidate.title)) else { return false }
        let artistKey = key(artist(track.artist))
        let missingArtist = ["", "unknown artist", "various artists"].contains(artistKey)
        if !missingArtist && artistKey != key(artist(candidate.artist)) { return false }
        // Version words remain in the title: Live, Remix, Acoustic, Cover,
        // Extended, Sped Up and Slowed must agree. Explicitness is separate.
        if let explicit = track.isExplicit, let other = candidate.isExplicit, explicit != other { return false }
        if let duration = track.duration, let other = candidate.duration, duration > 0, other > 0 {
            if abs(duration - other) > max(5, min(12, duration * 0.04)) { return false }
        }
        let sameAlbum = track.albumID != nil && track.albumID == candidate.albumID
        let namedAlbum = track.albumTitle != nil && candidate.albumTitle != nil
            && key(title(track.albumTitle!)) == key(title(candidate.albumTitle!))
        if missingArtist { return (sameAlbum || namedAlbum) && track.duration != nil && candidate.duration != nil }
        // YouTube assigns different browse IDs to explicit/clean, regional and
        // reissued album listings. A different ID is not a different recording.
        // Without album agreement require duration corroboration.
        return sameAlbum || namedAlbum || (track.duration != nil && candidate.duration != nil)
            || (track.albumID == nil && track.albumTitle == nil)
    }

    static func bestMatch(for track: Track, candidates: [Track]) -> Track? {
        candidates.enumerated().filter { compatible(track, $0.element) }.max { lhs, rhs in
            func score(_ item: (offset: Int, element: Track)) -> Double {
                let song = item.element
                var value = Double(-item.offset) * 0.001
                if song.playableID == track.playableID { value += 200 }
                if track.albumID != nil && song.albumID == track.albumID { value += 100 }
                if let album = track.albumTitle, let other = song.albumTitle, key(title(album)) == key(title(other)) { value += 30 }
                if let duration = track.duration, let other = song.duration { value += max(0, 15 - abs(duration - other)) }
                if track.isExplicit != nil && song.isExplicit == track.isExplicit { value += 10 }
                return value
            }
            return score(lhs) < score(rhs)
        }?.element
    }
}
