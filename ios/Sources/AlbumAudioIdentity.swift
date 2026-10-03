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

    static func isMissingArtist(_ value: String) -> Bool {
        ["", "unknown artist", "various artists"].contains(key(artist(value)))
            || value.range(of: #"^\s*\d+([.,]\d+)?\s*[KMB]?\s*(plays|views)\s*$"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func comparisonTitle(_ value: String) -> String {
        key(title(value)).replacingOccurrences(of: #"\bmovie ver\b"#, with: "movie version", options: .regularExpression)
            .replacingOccurrences(of: #"\bmovie edited version\b"#, with: "movie edit", options: .regularExpression)
    }

    /// Read annotations, not ordinary words in titles such as Live Forever.
    static func versionMarkers(_ value: String) -> Set<String> {
        let pattern = #"[\(\[]([^\)\]]+)[\)\]]|\s[-–—]\s(.+)$|\b(live|cover|karaoke|instrumental|remix|slowed|sped up|nightcore|extended|acoustic)(\s+(version|ver\.?|edit))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let text = value as NSString
        var markers: Set<String> = []
        for match in regex.matches(in: value, range: NSRange(location: 0, length: text.length)) {
            let annotation = key(text.substring(with: match.range))
            if annotation.hasPrefix("feat ") || annotation.hasPrefix("ft ") || annotation.hasPrefix("featuring ") { continue }
            for marker in ["live", "cover", "karaoke", "instrumental", "remix", "slowed", "sped up", "nightcore", "extended", "acoustic", "english", "japanese"] {
                if (" " + annotation + " ").contains(" " + marker + " ") { markers.insert(marker) }
            }
            if (" " + annotation + " ").contains(" mix ") { markers.insert("remix") }
            if annotation.contains("movie edit") { markers.insert("movie edit") }
            else if annotation.contains("movie ver") { markers.insert("movie version") }
            if annotation.contains("music video") { markers.insert("music video") }
        }
        return markers
    }

    private static func artistAgreement(_ lhs: String, _ rhs: String) -> Double {
        let a = key(artist(lhs)), b = key(artist(rhs))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 50 }
        // Credits may move between title and artist; never match a substring
        // such as Radiohead Tribute to the actual artist.
        let parts: (String) -> Set<String> = { value in Set(artist(value).components(separatedBy: " & ").map { key($0) }) }
        return parts(rhs).contains(a) || parts(lhs).contains(b) ? 45 : 0
    }

    private static func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = comparisonTitle(lhs), b = comparisonTitle(rhs)
        if a == b || a.replacingOccurrences(of: " ", with: "") == b.replacingOccurrences(of: " ", with: "") { return 1 }
        let withoutArticle: (String) -> String = { $0.hasPrefix("the ") ? String($0.dropFirst(4)) : $0 }
        if withoutArticle(a) == withoutArticle(b) { return 0.97 }
        let left = Array(a), right = Array(b)
        guard min(left.count, right.count) >= 8 else { return 0 }
        var previous = Array(0...right.count)
        for (i, character) in left.enumerated() {
            var current = [i + 1]
            for (j, other) in right.enumerated() {
                current.append(min(current[j] + 1, min(previous[j + 1] + 1, previous[j] + (character == other ? 0 : 1))))
            }
            previous = current
        }
        return 1 - Double(previous[right.count]) / Double(max(left.count, right.count))
    }

    /// A bilingual display title is not a different recording. Only reconcile
    /// complete, dash-separated Latin/non-Latin aliases with independent identity
    /// evidence. Never strip arbitrary prefixes, subtitles or version suffixes.
    static func localizedTitleMatches(_ track: Track, _ candidate: Track) -> Bool {
        guard candidate.musicVideoType == "MUSIC_VIDEO_TYPE_ATV",
              let artistID = track.artistID, artistID == candidate.artistID,
              let explicit = track.isExplicit, candidate.isExplicit == explicit,
              let duration = track.duration, let other = candidate.duration,
              duration.isFinite, other.isFinite, duration > 0, other > 0,
              abs(duration - other) <= max(5, min(12, duration * 0.04)),
              versionMarkers(track.title).union(versionMarkers(track.albumTitle ?? ""))
                == versionMarkers(candidate.title).union(versionMarkers(candidate.albumTitle ?? "")) else { return false }
        func aliases(_ value: String) -> Set<String> {
            let normalized = title(value)
            let parts = normalized.components(separatedBy: CharacterSet(charactersIn: "-–—"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return [] }
            func latin(_ part: String) -> Bool {
                part.range(of: #"\p{Latin}"#, options: .regularExpression) != nil
            }
            func otherScript(_ part: String) -> Bool {
                part.unicodeScalars.contains { CharacterSet.letters.contains($0) }
                    && !latin(part)
            }
            guard (latin(parts[0]) && otherScript(parts[1]))
                || (otherScript(parts[0]) && latin(parts[1])) else { return [] }
            return Set(parts.map(key))
        }
        return aliases(candidate.title).contains(key(title(track.title)))
            || aliases(track.title).contains(key(title(candidate.title)))
    }

    /// One eligibility/ranking policy for cold searches and cached recordings.
    static func score(_ track: Track, _ candidate: Track) -> Double? {
        let audio = candidate.musicVideoType == "MUSIC_VIDEO_TYPE_ATV"
        let requestedVersions = versionMarkers(track.title).union(versionMarkers(track.albumTitle ?? ""))
        let candidateVersions = versionMarkers(candidate.title).union(versionMarkers(candidate.albumTitle ?? ""))
        if candidate.musicVideoType == "MUSIC_VIDEO_TYPE_OMV", !requestedVersions.contains("music video") { return nil }
        guard audio || candidate.musicVideoType == nil || candidate.musicVideoType == "MUSIC_VIDEO_TYPE_UGC"
                || requestedVersions.contains("music video") else { return nil }
        if candidate.playableID == track.playableID { return 1000 }
        let sameAlbum = track.albumID != nil && track.albumID == candidate.albumID
        let namedAlbum = track.albumTitle != nil && candidate.albumTitle != nil
            && key(title(track.albumTitle!)) == key(title(candidate.albumTitle!))
        let missingArtist = isMissingArtist(track.artist)
        let artistScore = artistAgreement(track.artist, candidate.artist)
        if !missingArtist && artistScore == 0 { return nil }
        if let explicit = track.isExplicit, let other = candidate.isExplicit, explicit != other { return nil }
        var durationScore = 0.0, closeDuration = false
        if let duration = track.duration, let other = candidate.duration,
           duration.isFinite, other.isFinite, duration > 0, other > 0 {
            let delta = abs(duration - other), tolerance = max(5, min(12, duration * 0.04))
            closeDuration = delta <= tolerance
            // Video intros/outros justify a bounded difference only with an
            // exact title/artist and album, never a wrong version.
            let videoPadding = track.musicVideoType == "MUSIC_VIDEO_TYPE_OMV" && (sameAlbum || namedAlbum)
                && comparisonTitle(track.title) == comparisonTitle(candidate.title)
            let limit = videoPadding ? max(tolerance, min(40, duration * 0.15)) : tolerance
            if delta > limit { return nil }
            durationScore = 30 - min(15, delta / limit * 15)
        }
        var similarity = titleSimilarity(track.title, candidate.title)
        if similarity < 0.92 && localizedTitleMatches(track, candidate) { similarity = 1 }
        if requestedVersions != candidateVersions {
            // A Songs title can omit a movie annotation. Exact album/duration
            // corroboration is required; movie edit and movie version stay distinct.
            let movieOnly = !requestedVersions.isEmpty && requestedVersions.isSubset(of: ["movie edit", "movie version"])
            guard movieOnly, candidateVersions.isEmpty, audio, artistScore > 0,
                  (sameAlbum || namedAlbum), closeDuration else { return nil }
            let base = comparisonTitle(track.title).replacingOccurrences(of: #"\s+movie (version|edit)$"#, with: "", options: .regularExpression)
            guard base == comparisonTitle(candidate.title) else { return nil }
            similarity = 0.95
        }
        guard similarity >= 0.92, !comparisonTitle(track.title).isEmpty else { return nil }
        if similarity < 1 && !closeDuration && !sameAlbum && !namedAlbum { return nil }
        if missingArtist && (!(sameAlbum || namedAlbum) || !closeDuration) { return nil }
        if !audio && (artistScore == 0 || similarity < 1 || !closeDuration) { return nil }
        var value = similarity * 100 + (missingArtist ? 15 : artistScore) + durationScore + (audio ? 20 : 0)
        if sameAlbum { value += 40 } else if namedAlbum { value += 30 }
        if track.isExplicit != nil && candidate.isExplicit == track.isExplicit { value += 8 }
        if candidate.artist.range(of: #"[-–—]\s*Topic$"#, options: [.regularExpression, .caseInsensitive]) != nil { value += 5 }
        if candidate.title.range(of: "official audio", options: .caseInsensitive) != nil { value += 3 }
        return value >= 170 ? value : nil
    }

    static func compatible(_ track: Track, _ candidate: Track) -> Bool { score(track, candidate) != nil }

    static func bestMatch(for track: Track, candidates: [Track]) -> Track? {
        // A bilingual alias must identify one recording, never choose arbitrarily
        // between multiple localized editions with equally plausible metadata.
        let localizedIDs = Set(candidates.filter { localizedTitleMatches(track, $0) && score(track, $0) != nil }.map(\.playableID))
        return candidates.enumerated().compactMap { offset, candidate -> (Track, Double)? in
            if localizedIDs.count > 1 && localizedTitleMatches(track, candidate) { return nil }
            score(track, candidate).map { (candidate, $0 - Double(offset) * 0.001) }
        }.max { $0.1 < $1.1 }?.0
    }

    static func searchQueries(for track: Track) -> [String] {
        let performer = isMissingArtist(track.artist) ? "" : artist(track.artist)
        let normalized = title(track.title), original = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = title(track.albumTitle ?? "")
        let base = normalized.replacingOccurrences(of: #"\s*[-–—]\s*movie (ver\.?|version|edit\.?)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let join: ([String]) -> String = { $0.filter { !$0.isEmpty }.joined(separator: " ") }
        // Include the same title-only searches a user can make from the Songs tab.
        // Album metadata can contain a soundtrack/credited artist that causes every
        // artist-qualified query to miss the recording even though a plain Songs
        // search returns the correct ATV item immediately.
        // Search the visible album title first, then progressively add
        // artist/album context. This mirrors the Songs tab for releases where
        // YouTube Music localizes the album row (for example "Suzume") but the
        // canonical Songs recording includes a native-script prefix.
        let alternatives = [normalized, original,
                            join([performer, normalized]), join([original, performer]), join([performer, original]),
                            join([normalized, performer]),
                            join([performer, normalized, album]), join([normalized, album, performer]),
                            join([performer, key(normalized), album]), join([performer, base, album]), base]
        var seen: Set<String> = []
        return alternatives.filter { query in
            !query.isEmpty && seen.insert(query.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)).inserted
        }
    }
}
