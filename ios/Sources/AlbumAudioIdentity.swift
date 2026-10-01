import Foundation

enum AlbumAudioIdentity {
    private static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func bestMatch(for track: Track, candidates: [Track]) -> Track? {
        let exact = candidates.filter {
            $0.musicVideoType == "MUSIC_VIDEO_TYPE_ATV" && key($0.title) == key(track.title)
                && key($0.artist) == key(track.artist)
                && (track.duration == nil || $0.duration == nil || abs($0.duration! - track.duration!) <= 3)
        }
        if let albumID = track.albumID, let sameAlbum = exact.first(where: { $0.albumID == albumID }) { return sameAlbum }
        // Do not substitute an alternate release or performance just because
        // a title matches. Album identity must agree whenever it is known.
        return track.albumID == nil ? exact.first : nil
    }
}
