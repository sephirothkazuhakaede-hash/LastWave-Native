import Foundation

struct AlbumRecordingContext: Sendable {
    let title: String
    let artist: String
}

/// One persisted recording index for album rows, Songs results and saved tracks.
/// The row ID remains stable; mediaID and all playback/lyrics metadata converge.
actor CanonicalTrackResolver {
    private struct Index: Codable {
        var recordings: [String: Track] = [:]
        var aliases: [String: String] = [:]
        var durations: [String: Double] = [:]
        var needsMetadata: Set<String> = []
    }
    private var index: Index
    private let defaults: UserDefaults?
    private var pending: [String: Task<Track, Error>] = [:]
    private static let storageKey = "capyflow.canonicalRecordings.v2"

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Index.self, from: data) {
            index = saved
        } else {
            index = Index()
            // Reuse successful 0.4.3 album->audio mappings; failed lookups were
            // never persisted. Their metadata can be enriched by a Songs result.
            if let data = defaults?.data(forKey: "capyflow.albumAudioMappings.v1"),
               let old = try? JSONDecoder().decode([String: Track].self, from: data) {
                for (id, track) in old where track.mediaID != nil {
                    index.recordings[track.playableID] = track
                    index.aliases[id] = track.playableID
                    index.needsMetadata.insert(track.playableID)
                }
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(index) { defaults?.set(data, forKey: Self.storageKey) }
    }

    private func cached(_ track: Track) -> Track? {
        if let id = index.aliases[track.id], !index.needsMetadata.contains(id), let song = index.recordings[id] {
            return track.adoptingRecording(song)
        }
        if !index.needsMetadata.contains(track.playableID), let song = index.recordings[track.playableID] { return track.adoptingRecording(song) }
        if let song = AlbumAudioIdentity.bestMatch(for: track, candidates: index.recordings.keys.sorted().filter { !index.needsMetadata.contains($0) }.compactMap { index.recordings[$0] }) {
            index.aliases[track.id] = song.playableID
            persist()
            return track.adoptingRecording(song)
        }
        return nil
    }

    private func store(_ track: Track, recording: Track) -> Track {
        // Another entry point may have resolved this recording while our
        // catalog request was in flight. Keep that winner for both aliases.
        let existing = index.recordings[recording.playableID] == nil
            ? AlbumAudioIdentity.bestMatch(for: recording, candidates: index.recordings.keys.sorted().filter { !index.needsMetadata.contains($0) }.compactMap { index.recordings[$0] }) : nil
        let selected = existing ?? recording
        let id = selected.playableID
        // Keep an actual measured duration over a later rounded catalog value.
        var song = selected
        if let duration = index.durations[id] {
            song = song.withDuration(duration)
            song.mediaInfo = index.recordings[id]?.mediaInfo
        }
        index.recordings[id] = song
        index.needsMetadata.remove(id)
        index.aliases[track.id] = id
        index.aliases[recording.id] = id
        persist()
        let result = track.adoptingRecording(song)
        #if DEBUG
        print("[CanonicalTrack] row=\(track.id) media=\(result.playableID) albumID=\(track.albumID ?? "unknown") album=\(track.albumTitle ?? "unknown") originTitle=\(track.title) originArtist=\(track.artist) title=\(result.title) artist=\(result.artist) normalizedTitle=\(AlbumAudioIdentity.key(AlbumAudioIdentity.title(result.title))) normalizedArtist=\(AlbumAudioIdentity.key(AlbumAudioIdentity.artist(result.artist))) duration=\(result.duration ?? 0) source=https://www.youtube.com/watch?v=\(result.playableID) lyrics=\(result.lyricsCacheKey) mediaCache=\(result.mediaCacheKey(quality: .automatic))")
        #endif
        return result
    }

    func registerSearch(_ tracks: [Track]) -> [Track] {
        tracks.map { track in
            if let reused = cached(track) {
                // A search result for the selected media ID improves metadata
                // inherited from a legacy mapping without changing identity.
                if reused.playableID == track.playableID && track.musicVideoType == "MUSIC_VIDEO_TYPE_ATV" {
                    return store(track, recording: track)
                }
                return reused
            }
            return track.musicVideoType == "MUSIC_VIDEO_TYPE_ATV" ? store(track, recording: track) : track
        }
    }

    func resolve(_ requestedTrack: Track,
                 albumContext: (@Sendable (String) async throws -> AlbumRecordingContext)? = nil,
                 search: @escaping @Sendable (String) async throws -> [Track]) async throws -> Track {
        if let saved = cached(requestedTrack) { return saved }
        var track = requestedTrack
        if AlbumAudioIdentity.isMissingArtist(track.artist), let id = track.albumID,
           let albumContext, let context = try? await albumContext(id) {
            track.artist = context.artist
            track.albumTitle = context.title
        }
        let missingArtist = AlbumAudioIdentity.isMissingArtist(track.artist)
        if !missingArtist && (track.musicVideoType == "MUSIC_VIDEO_TYPE_ATV"
            || (track.mediaID != nil && track.albumID == nil && track.albumTitle == nil)),
           !index.needsMetadata.contains(track.playableID) {
            var trusted = track
            trusted.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
            return store(track, recording: trusted)
        }
        // Unannotated Songs/legacy tracks keep the existing immediate path.
        guard track.albumID != nil || track.albumTitle != nil || track.musicVideoType == "MUSIC_VIDEO_TYPE_OMV" || missingArtist else { return track }
        if let task = pending[track.id] { return try await task.value }
        let task = Task { () throws -> Track in
            let artist = AlbumAudioIdentity.artist(track.artist)
            let query = AlbumAudioIdentity.title(track.title) + " "
                + (AlbumAudioIdentity.isMissingArtist(artist) ? (track.albumTitle ?? "") : artist)
            let first: [Track]
            do { first = try await search(query) }
            catch let error as URLError {
                // Previously verified downloaded recordings must remain usable
                // offline. Retry metadata enrichment next time; don't persist
                // this as a fresh canonical result or cache a failed lookup.
                if track.mediaID != nil || track.musicVideoType == "MUSIC_VIDEO_TYPE_ATV" { return track }
                if let id = self.index.aliases[track.id], let old = self.index.recordings[id] { return track.adoptingRecording(old) }
                throw error
            }
            var candidates = first
            if AlbumAudioIdentity.bestMatch(for: track, candidates: candidates) == nil, let album = track.albumTitle {
                candidates += try await search(query + " " + album)
            }
            guard let song = AlbumAudioIdentity.bestMatch(for: track, candidates: candidates) else {
                throw WaveError.message("No matching audio recording was returned for this album track. Please retry when the catalog is available.")
            }
            return self.store(track, recording: song)
        }
        pending[track.id] = task
        defer { pending.removeValue(forKey: track.id) }
        return try await task.value
    }

    func recordDuration(_ duration: Double, track: Track, mediaInfo: AudioMediaInfo?) {
        guard duration.isFinite, duration > 0 else { return }
        var song = index.recordings[track.playableID] ?? track
        song = song.withDuration(duration)
        song.mediaInfo = mediaInfo ?? song.mediaInfo
        index.recordings[track.playableID] = song
        index.durations[track.playableID] = duration
        index.aliases[track.id] = track.playableID
        persist()
    }

    func recordDuration(_ duration: Double, rowID: String) {
        guard let id = index.aliases[rowID], let track = index.recordings[id] else { return }
        recordDuration(duration, track: track, mediaInfo: nil)
    }
}
