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
    private static let storageKey = "capyflow.canonicalRecordings.v3"

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Index.self, from: data) {
            index = saved
            // Incomplete older Songs rows must refresh rather than permanently
            // priming every album/lyrics lookup with an unknown artist.
            index.needsMetadata.formUnion(index.recordings.filter { AlbumAudioIdentity.isMissingArtist($0.value.artist) }.map { $0.key })
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
        if let id = index.aliases[track.id], !index.needsMetadata.contains(id), let song = index.recordings[id],
           AlbumAudioIdentity.compatible(track, song) {
            return track.adoptingRecording(song)
        }
        if !index.needsMetadata.contains(track.playableID), let song = index.recordings[track.playableID],
           AlbumAudioIdentity.compatible(track, song) {
            return track.adoptingRecording(song)
        }
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
        // A Songs result's playable ID is authoritative. Do not collapse two
        // distinct YouTube Music recordings (notably clean/explicit editions)
        // merely because their title/artist/duration metadata matches.
        let selected = recording
        let id = recording.playableID
        // Keep an actual measured duration over a later rounded catalog value.
        var song = selected
        if AlbumAudioIdentity.isMissingArtist(song.artist) {
            if let previous = index.recordings[id], !AlbumAudioIdentity.isMissingArtist(previous.artist) {
                song.artist = previous.artist
            } else if !AlbumAudioIdentity.isMissingArtist(track.artist) { song.artist = track.artist }
        }
        if let duration = index.durations[id] {
            song = song.withDuration(duration)
            song.mediaInfo = index.recordings[id]?.mediaInfo
        }
        index.recordings[id] = song
        if AlbumAudioIdentity.isMissingArtist(song.artist) { index.needsMetadata.insert(id) }
        else { index.needsMetadata.remove(id) }
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
            // Keep every Songs result as its own recording. This is important
            // when YouTube Music returns clean and explicit editions with the
            // same visible title/artist/duration but different playable IDs.
            if track.musicVideoType == "MUSIC_VIDEO_TYPE_ATV" {
                return store(track, recording: track)
            }
            return track
        }
    }

    func resolve(_ requestedTrack: Track,
                 albumContext: (@Sendable (String) async throws -> AlbumRecordingContext)? = nil,
                 search: @escaping @Sendable (String) async throws -> [Track]) async throws -> Track {
        // Direct Songs results are already a concrete recording. Register them
        // before consulting aliases so a successful Songs play can heal a later
        // album lookup instead of inheriting an older album alias.
        if requestedTrack.albumID == nil, requestedTrack.albumTitle == nil,
           requestedTrack.musicVideoType == "MUSIC_VIDEO_TYPE_ATV" {
            return store(requestedTrack, recording: requestedTrack)
        }
        if let saved = cached(requestedTrack) { return saved }
        var track = requestedTrack
        if AlbumAudioIdentity.isMissingArtist(track.artist), let id = track.albumID,
           let albumContext, let context = try? await albumContext(id) {
            track.artist = context.artist
            track.albumTitle = context.title
        }

        // Album browse responses can already contain the exact YouTube Music
        // audio recording. Do not throw that authoritative ATV identity away
        // and then fail a second fuzzy Songs search for the same recording.
        // OMV/UGC/unknown album rows still go through the strict matcher below.
        if track.musicVideoType == "MUSIC_VIDEO_TYPE_ATV" {
            return store(track, recording: track)
        }

        let missingArtist = AlbumAudioIdentity.isMissingArtist(track.artist)
        if !missingArtist && track.mediaID != nil && track.albumID == nil && track.albumTitle == nil,
           !index.needsMetadata.contains(track.playableID) {
            var trusted = track
            trusted.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
            return store(track, recording: trusted)
        }
        // Unannotated Songs/legacy tracks keep the existing immediate path.
        guard track.albumID != nil || track.albumTitle != nil || track.musicVideoType == "MUSIC_VIDEO_TYPE_OMV" || missingArtist else { return track }
        if let task = pending[track.id] { return try await task.value }
        let task = Task { () throws -> Track in
            let queries = AlbumAudioIdentity.searchQueries(for: track)
            var candidates: [Track] = []
            for (attempt, query) in queries.enumerated() {
                try Task.checkCancellation()
                do {
                    let results = try await search(query)
                    for song in results {
                        if let position = candidates.firstIndex(where: { $0.playableID == song.playableID }) {
                            if (AlbumAudioIdentity.score(track, song) ?? -1) > (AlbumAudioIdentity.score(track, candidates[position]) ?? -1) {
                                candidates[position] = song
                            }
                        } else { candidates.append(song) }
                    }
                    #if DEBUG
                    print("[CanonicalSearch] row=\(track.id) attempt=\(attempt + 1)/\(queries.count) query=\(query) returned=\(results.count) pooled=\(candidates.count)")
                    for candidate in results.prefix(8) {
                        print("[CanonicalCandidate] media=\(candidate.playableID) score=\(AlbumAudioIdentity.score(track, candidate).map { String($0) } ?? "rejected") type=\(candidate.musicVideoType ?? "unknown") title=\(candidate.title) artist=\(candidate.artist) duration=\(candidate.duration ?? 0)")
                    }
                    #endif
                    if let match = AlbumAudioIdentity.bestMatch(for: track, candidates: candidates),
                       let score = AlbumAudioIdentity.score(track, match), score >= 185 {
                        #if DEBUG
                        print("[CanonicalSearch] selected=\(match.playableID) score=\(score) title=\(match.title) artist=\(match.artist) duration=\(match.duration ?? 0)")
                        #endif
                        return self.store(track, recording: match)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch let error as URLError where error.code == .cancelled { throw error }
                catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
                    // Keep previously verified downloaded identities usable
                    // offline; a failed refresh never becomes a cached match.
                    if track.mediaID != nil || track.musicVideoType == "MUSIC_VIDEO_TYPE_ATV" { return track }
                    if let id = self.index.aliases[track.id], let old = self.index.recordings[id] { return track.adoptingRecording(old) }
                    throw error
                } catch {
                    // Empty Songs responses and transient failures must not
                    // prevent the remaining query forms from being tried.
                    #if DEBUG
                    print("[CanonicalSearch] row=\(track.id) attempt=\(attempt + 1) failed=\(error.localizedDescription); trying next query")
                    #endif
                }
            }
            guard let song = AlbumAudioIdentity.bestMatch(for: track, candidates: candidates) else {
                // Exhaust the Songs fallbacks first. A primary album endpoint
                // explicitly marked as audio is still a valid final identity;
                // never use an album music-video ID as this fallback.
                if track.musicVideoType == "MUSIC_VIDEO_TYPE_ATV", !missingArtist {
                    return self.store(track, recording: track)
                }
                throw WaveError.message("Couldn’t find the correct recording after trying several Songs searches. Please try again later.")
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
