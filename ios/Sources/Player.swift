import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

@MainActor final class WavePlayer: ObservableObject {
    @Published var current: Track?
    @Published var queue: [Track] = []
    @Published var downloads: [Track] = []
    @Published var playing = false
    @Published var loading = false
    @Published var elapsed = 0.0
    @Published var duration = 0.0
    @Published var lyrics: [LyricLine] = []
    @Published var lyricsLoading = false
    @Published var error: String?
    @Published var downloading: Set<String> = []
    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloadFailures: [String: String] = [:]
    @Published var downloadDiagnostics: [String: String] = [:]
    @Published var playlists: [ImportedPlaylist] = []
    @Published private(set) var recentTracks: [Track] = []
    @Published var downloadingPlaylists: Set<String> = []
    @Published var playlistDownloadProgress: [String: String] = [:]
    @Published var autoplayLoading = false
    @Published var autoplayEnabled: Bool {
        didSet { UserDefaults.standard.set(autoplayEnabled, forKey: "autoplayEnabled") }
    }
    @Published var audioQuality: AudioQuality {
        didSet { UserDefaults.standard.set(audioQuality.rawValue, forKey: "audioQuality") }
    }
    let catalog = Catalog()
    private let lyricsService = LyricsService()
    private let player = AVPlayer()
    private var generation = UUID()
    private var expectedDuration: Double?
    private var playbackHistory: [Track] = []
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var didReachExpectedEnd = false
    private var durationIsAuthoritative = false
    private var playbackRetryCount = 0
    private var lastPersistedDuration: [String: Double] = [:]
    private var timer: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Offline", isDirectory: true)
    }
    private var index: URL { folder.appendingPathComponent("library.json") }
    private var playlistArtworkFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PlaylistArtwork", isDirectory: true)
    }
    func localURL(_ track: Track) -> URL { folder.appendingPathComponent(track.id + ".m4a") }

    init() {
        autoplayEnabled = UserDefaults.standard.object(forKey: "autoplayEnabled") as? Bool ?? true
        audioQuality = AudioQuality(rawValue: UserDefaults.standard.string(forKey: "audioQuality") ?? "") ?? .automatic
        player.automaticallyWaitsToMinimizeStalling = false
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: index), let tracks = try? JSONDecoder().decode([Track].self, from: data) {
            downloads = tracks.filter { FileManager.default.fileExists(atPath: localURL($0).path) }
        }
        if let data = UserDefaults.standard.data(forKey: "importedPlaylists"),
           let saved = try? JSONDecoder().decode([ImportedPlaylist].self, from: data) { playlists = saved }
        if let data = UserDefaults.standard.data(forKey: "recentTracks"),
           let saved = try? JSONDecoder().decode([Track].self, from: data) { recentTracks = Array(saved.prefix(20)) }
        timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let newElapsed = time.seconds.isFinite ? time.seconds : 0
                if abs(self.elapsed - newElapsed) > 0.05 { self.elapsed = newElapsed }
                let itemDuration = self.player.currentItem?.duration.seconds ?? 0
                if itemDuration.isFinite, itemDuration > 0 {
                    self.expectedDuration = itemDuration
                    self.durationIsAuthoritative = true
                    if let trackID = self.current?.id {
                        self.adoptAuthoritativeDuration(itemDuration, for: trackID)
                    }
                }
                let length = (itemDuration.isFinite && itemDuration > 0)
                    ? itemDuration
                    : (self.expectedDuration ?? 0)
                let newDuration = length.isFinite ? length : 0
                if abs(self.duration - newDuration) > 0.05 { self.duration = newDuration }
                let isPlaying = self.player.rate > 0
                if self.playing != isPlaying { self.playing = isPlaying }
                if self.durationIsAuthoritative,
                   let expected = self.expectedDuration, expected > 0,
                   newElapsed >= expected - 0.35, !self.didReachExpectedEnd {
                    self.didReachExpectedEnd = true
                    Task { await self.next() }
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                await self.next()
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                if type == AVAudioSession.InterruptionType.began.rawValue { self?.player.pause() }
            }
        }
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.play() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.pause() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.next() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.previous() }; return .success }
        commands.skipBackwardCommand.isEnabled = false
        commands.skipForwardCommand.isEnabled = false
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(position.positionTime) }
            return .success
        }
    }

    func play(_ track: Track, recordHistory: Bool = true, recovering: Bool = false) async {
        let token = UUID(); generation = token
        loading = true; error = nil
        player.pause()
        if !recovering { playbackRetryCount = 0 }
        if !recovering, recordHistory, let current, current.id != track.id {
            playbackHistory.append(current)
            if playbackHistory.count > 50 { playbackHistory.removeFirst(playbackHistory.count - 50) }
        }
        current = track; elapsed = 0; duration = track.duration ?? 0; expectedDuration = track.duration
        didReachExpectedEnd = false
        durationIsAuthoritative = false
        if !recovering {
            rememberRecentlyPlayed(track)
            lyrics = []; nowPlayingArtwork = nil
            publishNowPlaying()
            Task { await loadLyrics(for: track, token: token) }
            Task { await loadArtwork(for: track, token: token) }
        }
        do {
            let url: URL
            var resolvedHeaders: [String: String] = [:]
            var usedBackend = false
            let isLocal = FileManager.default.fileExists(atPath: localURL(track).path)
            if isLocal { url = localURL(track) }
            else {
                let resolved = try await catalog.resolvedStream(for: track, quality: audioQuality, preferRemote: recovering)
                url = resolved.url
                expectedDuration = resolved.duration
                if let resolvedDuration = resolved.duration, resolvedDuration > 0 {
                    duration = resolvedDuration
                    durationIsAuthoritative = resolved.durationIsAuthoritative
                    if resolved.durationIsAuthoritative {
                        adoptAuthoritativeDuration(resolvedDuration, for: track.id)
                    }
                }
                resolvedHeaders = resolved.requestHeaders
                usedBackend = resolved.usesBackend
            }
            guard token == generation else { return }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let item: AVPlayerItem
            if isLocal {
                item = AVPlayerItem(url: url)
            } else {
                var headers = [
                    "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
                    "Referer": "https://www.youtube.com/"
                ]
                resolvedHeaders.forEach { headers[$0.key] = $0.value }
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 2
            }
            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                if item.status == .readyToPlay {
                    Task { @MainActor in
                        guard let self, token == self.generation, item === self.player.currentItem else { return }
                        self.loading = false
                        self.player.playImmediately(atRate: 1)
                    }
                } else if item.status == .failed {
                    let message = item.error?.localizedDescription ?? "Playback failed."
                    Task { @MainActor in
                        await self?.recoverPlaybackIfPossible(
                            track,
                            token: token,
                            item: item,
                            wasLocal: isLocal,
                            usedBackend: usedBackend,
                            underlyingMessage: message
                        )
                    }
                }
            }
            player.replaceCurrentItem(with: item)
            player.playImmediately(atRate: 1); playing = true
            publishNowPlaying()
            if let nextTrack = queue.first { Task { _ = try? await catalog.resolvedStream(for: nextTrack, quality: audioQuality) } }
        } catch {
            if token == generation {
                self.error = error.localizedDescription
                self.playing = false
            }
        }
        if token == generation { loading = false }
    }

    private func recoverPlaybackIfPossible(
        _ track: Track,
        token: UUID,
        item: AVPlayerItem,
        wasLocal: Bool,
        usedBackend: Bool,
        underlyingMessage: String
    ) async {
        guard token == generation, item === player.currentItem else { return }
        if wasLocal {
            error = "The downloaded copy could not be played. Delete it and download the song again."
            loading = false; playing = false
            return
        }
        if playbackRetryCount == 0 {
            playbackRetryCount = 1
            loading = true
            if usedBackend { await BackendClient.shared.reportStreamFailure(underlyingMessage) }
            await catalog.invalidateStream(for: track, quality: audioQuality)
            await play(track, recordHistory: false, recovering: true)
            return
        }
        error = "YouTube returned an audio link that iOS rejected after a fresh retry. \(underlyingMessage)"
        loading = false; playing = false
    }
    func toggle() { if player.rate > 0 { player.pause() } else { player.play() }; playing = player.rate > 0 }
    func seek(_ value: Double) {
        guard value.isFinite else { return }
        let target = min(max(0, value), duration > 0 ? duration : value)
        elapsed = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        publishNowPlaying()
    }
    func next() async {
        if queue.isEmpty, autoplayEnabled, let seed = current {
            autoplayLoading = true
            let suggestions = (try? await catalog.search("\(seed.artist) songs")) ?? []
            queue = Array(suggestions.filter { $0.id != seed.id }.shuffled().prefix(12))
            autoplayLoading = false
        }
        if queue.isEmpty { player.pause(); playing = false; return }
        await play(queue.removeFirst())
    }
    func previous() async {
        if elapsed > 3 || playbackHistory.isEmpty {
            seek(0)
            return
        }
        let previous = playbackHistory.removeLast()
        await play(previous, recordHistory: false)
    }
    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
    }
    func moveQueueItem(from source: Int, to destination: Int) {
        guard queue.indices.contains(source), queue.indices.contains(destination), source != destination else { return }
        let track = queue.remove(at: source)
        queue.insert(track, at: destination)
    }
    func prewarm(_ tracks: [Track]) {
        let candidates = Array(tracks.prefix(3))
        let quality = audioQuality
        let catalog = self.catalog
        Task {
            await withTaskGroup(of: Void.self) { group in
                for track in candidates {
                    group.addTask { _ = try? await catalog.resolvedStream(for: track, quality: quality) }
                }
            }
        }
    }
    func isDownloaded(_ track: Track) -> Bool { downloads.contains { $0.id == track.id } }
    func isPlaylistDownloaded(_ playlist: ImportedPlaylist) -> Bool {
        !playlist.tracks.isEmpty && playlist.tracks.allSatisfy { isDownloaded($0) }
    }
    @discardableResult func download(
        _ track: Track,
        reportError: Bool = true,
        preferRemote: Bool = false,
        attemptNumber: Int = 1
    ) async -> Bool {
        if isDownloaded(track) { return true }
        if downloading.contains(track.id) {
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !downloading.contains(track.id) { return isDownloaded(track) }
            }
            return isDownloaded(track)
        }
        downloading.insert(track.id)
        downloadProgress[track.id] = 0
        downloadFailures.removeValue(forKey: track.id)
        let attemptPrefix = attemptNumber > 1 ? "Retry \(attemptNumber) • " : ""
        downloadDiagnostics[track.id] = attemptPrefix + (preferRemote ? "Trying direct fallback" : "Checking MSI cache")
        error = nil
        defer { downloading.remove(track.id); downloadProgress.removeValue(forKey: track.id) }
        var usedBackend = false
        do {
            let resolved = try await catalog.resolvedStream(for: track, quality: audioQuality, preferRemote: preferRemote)
            usedBackend = resolved.usesBackend
            switch resolved.source {
            case .msiCacheHit: downloadDiagnostics[track.id] = attemptPrefix + "MSI cache hit"
            case .msiNewExtraction: downloadDiagnostics[track.id] = attemptPrefix + "MSI new extraction"
            case .directFallback: downloadDiagnostics[track.id] = attemptPrefix + "Direct resolver fallback"
            }
            var request = URLRequest(url: resolved.downloadURL ?? resolved.url)
            request.timeoutInterval = 600
            request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148", forHTTPHeaderField: "User-Agent")
            resolved.requestHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let transfer = DownloadCoordinator.shared
            let (temporary, response) = try await transfer.start(request) { [weak self] progress in
                Task { @MainActor in self?.downloadProgress[track.id] = progress }
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporary)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw WaveError.message(code > 0 ? "The audio server refused this song (HTTP \(code))." : "The audio server did not return a downloadable file.")
            }
            if usedBackend, http.value(forHTTPHeaderField: "X-CapyFlow-Cache") == "HIT" {
                downloadDiagnostics[track.id] = attemptPrefix + (resolved.source == .msiNewExtraction ? "MSI new extraction" : "MSI cache hit")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 16_384 else {
                try? FileManager.default.removeItem(at: temporary)
                throw WaveError.message("The downloaded audio was incomplete. Please retry.")
            }
            let target = localURL(track)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
            let savedTrack: Track
            if let exact = resolved.duration, resolved.durationIsAuthoritative, exact > 0 {
                adoptAuthoritativeDuration(exact, for: track.id)
                savedTrack = track.withDuration(exact)
            } else {
                savedTrack = track
            }
            downloads.removeAll { $0.id == track.id }
            downloads.append(savedTrack)
            downloadFailures.removeValue(forKey: track.id)
            try JSONEncoder().encode(downloads).write(to: index, options: .atomic)
            // A completed offline download is not reported until its available
            // lyrics have also been written to the on-device cache.
            _ = try? await lyricsService.lyrics(for: savedTrack)
            return true
        } catch {
            let reason = error.localizedDescription
            if usedBackend { await BackendClient.shared.reportStreamFailure(reason) }
            await catalog.invalidateStream(for: track, quality: audioQuality)
            downloadFailures[track.id] = reason
            if reportError { self.error = reason }
            return false
        }
    }
    func importPlaylist(_ input: String) async {
        do {
            let playlist = try await catalog.playlist(from: input)
            playlists.removeAll { $0.id == playlist.id }; playlists.append(playlist)
            if let data = try? JSONEncoder().encode(playlists) { UserDefaults.standard.set(data, forKey: "importedPlaylists") }
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func createPlaylist(named name: String, artworkData: Data? = nil) throws -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw WaveError.message("Give the playlist a name first.") }
        let id = UUID().uuidString
        playlists.append(ImportedPlaylist(id: id, name: cleaned, tracks: []))
        savePlaylists()
        if let artworkData {
            do { try setPlaylistArtwork(artworkData, for: id) }
            catch {
                playlists.removeAll { $0.id == id }
                savePlaylists()
                throw error
            }
        }
        return id
    }
    func renamePlaylist(_ playlistID: String, to name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let playlist = playlists[index]
        playlists[index] = ImportedPlaylist(id: playlist.id, name: cleaned, tracks: playlist.tracks)
        savePlaylists()
    }
    func deletePlaylist(_ playlistID: String) {
        playlists.removeAll { $0.id == playlistID }
        let artwork = playlistArtworkFolder.appendingPathComponent(safePlaylistID(playlistID) + ".jpg")
        if FileManager.default.fileExists(atPath: artwork.path) { try? FileManager.default.removeItem(at: artwork) }
        savePlaylists()
    }
    func add(_ track: Track, to playlistID: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[index].tracks.contains(where: { $0.id == track.id }) else { return }
        var tracks = playlists[index].tracks; tracks.append(track)
        playlists[index] = ImportedPlaylist(id: playlists[index].id, name: playlists[index].name, tracks: tracks)
        savePlaylists()
    }
    func saveAlbum(_ album: Album, tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let id = "album:" + album.id
        playlists.removeAll { $0.id == id }
        playlists.insert(ImportedPlaylist(id: id, name: album.title, tracks: tracks), at: 0)
        savePlaylists()
    }
    func playlistArtworkURL(for playlistID: String) -> URL? {
        let url = playlistArtworkFolder.appendingPathComponent(safePlaylistID(playlistID) + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func setPlaylistArtwork(_ data: Data, for playlistID: String) throws {
        guard let image = UIImage(data: data), let jpeg = image.playlistCoverJPEG() else {
            throw WaveError.message("That image couldn't be used as a playlist photo.")
        }
        try FileManager.default.createDirectory(at: playlistArtworkFolder, withIntermediateDirectories: true)
        try jpeg.write(to: playlistArtworkFolder.appendingPathComponent(safePlaylistID(playlistID) + ".jpg"), options: .atomic)
        objectWillChange.send()
    }
    private func safePlaylistID(_ id: String) -> String {
        id.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
    }
    private func savePlaylists() {
        if let data = try? JSONEncoder().encode(playlists) { UserDefaults.standard.set(data, forKey: "importedPlaylists") }
    }
    func downloadPlaylist(_ playlist: ImportedPlaylist) async {
        guard !downloadingPlaylists.contains(playlist.id) else { return }
        downloadingPlaylists.insert(playlist.id)
        let pending = playlist.tracks.filter { !isDownloaded($0) }
        playlistDownloadProgress[playlist.id] = "0/\(pending.count)"
        defer {
            downloadingPlaylists.remove(playlist.id)
            playlistDownloadProgress.removeValue(forKey: playlist.id)
        }
        var failures: [String] = []
        var processed = 0
        var iterator = pending.makeIterator()
        let workerCount = min(3, pending.count)
        await withTaskGroup(of: (Track, Bool).self) { group in
            for _ in 0..<workerCount {
                guard let track = iterator.next() else { break }
                group.addTask { [weak self] in
                    guard let self else { return (track, false) }
                    return (track, await self.downloadWithRetries(track))
                }
            }
            while let (track, succeeded) = await group.next() {
                processed += 1
                if !succeeded { failures.append(track.title) }
                playlistDownloadProgress[playlist.id] = "\(processed)/\(pending.count)"
                if let nextTrack = iterator.next() {
                    group.addTask { [weak self] in
                        guard let self else { return (nextTrack, false) }
                        return (nextTrack, await self.downloadWithRetries(nextTrack))
                    }
                }
            }
        }
        if failures.isEmpty {
            error = nil
        } else {
            let sample = failures.prefix(3).joined(separator: ", ")
            error = "Couldn't download \(failures.count) song\(failures.count == 1 ? "" : "s"): \(sample). Tap its warning icon for the exact reason."
        }
    }
    private func downloadWithRetries(_ track: Track) async -> Bool {
        for attempt in 0..<5 {
            let directFallback = attempt >= 3
            if await download(
                track,
                reportError: false,
                preferRemote: directFallback,
                attemptNumber: attempt + 1
            ) { return true }
            if attempt < 4 { try? await Task.sleep(nanoseconds: UInt64(650_000_000 * (attempt + 1))) }
        }
        return false
    }
    func lyricSearch(_ query: String) async throws -> [Track] {
        let matches = try await lyricsService.matchingTracks(query)
        var found: [Track] = []
        for (title, artist) in matches.prefix(3) {
            if let track = try? await catalog.search("\(title) \(artist)").first,
               !found.contains(where: { $0.id == track.id }) { found.append(track) }
        }
        return found
    }
    private func loadArtwork(for track: Track, token: UUID) async {
        guard let url = track.artwork,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data), token == generation else { return }
        let artwork = image.centerSquareCropped()
        nowPlayingArtwork = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        publishNowPlaying()
    }
    private func loadLyrics(for track: Track, token: UUID) async {
        lyricsLoading = true
        defer { if token == generation { lyricsLoading = false } }
        do {
            let fetched = try await lyricsService.lyrics(for: track)
            if token == generation { lyrics = fetched }
        } catch {
            // Missing lyrics should not interrupt playback; the lyrics view owns its empty state.
            if token == generation { lyrics = [] }
        }
    }
    func delete(_ track: Track) {
        do {
            try FileManager.default.removeItem(at: localURL(track))
            downloads.removeAll { $0.id == track.id }
            try JSONEncoder().encode(downloads).write(to: index, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
    private func publishNowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate
        ]
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func rememberRecentlyPlayed(_ track: Track) {
        recentTracks.removeAll { $0.id == track.id }
        recentTracks.insert(track, at: 0)
        if recentTracks.count > 20 { recentTracks.removeLast(recentTracks.count - 20) }
        if let data = try? JSONEncoder().encode(recentTracks) {
            UserDefaults.standard.set(data, forKey: "recentTracks")
        }
    }

    /// Search and album durations are estimates. Once the backend or AVPlayer
    /// reports the playable media duration, replace every persisted copy so an
    /// old estimate cannot return through a saved album or playlist.
    private func adoptAuthoritativeDuration(_ seconds: Double, for trackID: String) {
        guard seconds.isFinite, seconds > 0 else { return }
        let corrected = (seconds * 100).rounded() / 100
        expectedDuration = corrected
        durationIsAuthoritative = true
        if current?.id == trackID {
            if abs(duration - corrected) > 0.05 { duration = corrected }
            if let current, abs((current.duration ?? 0) - corrected) > 0.05 {
                self.current = current.withDuration(corrected)
            }
        }

        let previous = lastPersistedDuration[trackID]
        guard previous == nil || abs((previous ?? 0) - corrected) > 0.75 else {
            publishNowPlaying()
            return
        }
        lastPersistedDuration[trackID] = corrected

        queue = queue.map { $0.id == trackID ? $0.withDuration(corrected) : $0 }
        playbackHistory = playbackHistory.map { $0.id == trackID ? $0.withDuration(corrected) : $0 }
        recentTracks = recentTracks.map { $0.id == trackID ? $0.withDuration(corrected) : $0 }
        if let data = try? JSONEncoder().encode(recentTracks) {
            UserDefaults.standard.set(data, forKey: "recentTracks")
        }

        var changedDownloads = false
        downloads = downloads.map {
            guard $0.id == trackID else { return $0 }
            changedDownloads = true
            return $0.withDuration(corrected)
        }
        if changedDownloads, let data = try? JSONEncoder().encode(downloads) {
            try? data.write(to: index, options: .atomic)
        }

        var changedPlaylists = false
        playlists = playlists.map { playlist in
            var changed = false
            let tracks = playlist.tracks.map { track -> Track in
                guard track.id == trackID else { return track }
                changed = true
                return track.withDuration(corrected)
            }
            guard changed else { return playlist }
            changedPlaylists = true
            return ImportedPlaylist(id: playlist.id, name: playlist.name, tracks: tracks)
        }
        if changedPlaylists { savePlaylists() }

        let catalog = self.catalog
        Task { await catalog.recordAuthoritativeDuration(corrected, for: trackID) }
        publishNowPlaying()
    }
}

private extension UIImage {
    func centerSquareCropped() -> UIImage {
        guard let cgImage else { return self }
        let side = min(cgImage.width, cgImage.height)
        let rect = CGRect(x: (cgImage.width - side) / 2, y: (cgImage.height - side) / 2, width: side, height: side)
        guard let cropped = cgImage.cropping(to: rect) else { return self }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }
    func playlistCoverJPEG() -> Data? {
        let square = centerSquareCropped()
        let side = min(1200, max(square.size.width, square.size.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            square.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return rendered.jpegData(compressionQuality: 0.9)
    }
}

private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = DownloadCoordinator()
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<(URL, URLResponse), Error>] = [:]
    private var progressHandlers: [Int: (Double) -> Void] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.seph.capyflow.downloads")
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 900
        let queue = OperationQueue()
        queue.name = "CapyFlow.DownloadCoordinator"
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    private override init() { super.init() }

    func start(_ request: URLRequest, progress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request)
            lock.lock()
            continuations[task.taskIdentifier] = continuation
            progressHandlers[task.taskIdentifier] = progress
            lock.unlock()
            task.resume()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let progress = progressHandlers[downloadTask.taskIdentifier]
        lock.unlock()
        progress?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response else {
            finish(taskID: downloadTask.taskIdentifier, result: .failure(WaveError.message("Download returned no response.")))
            return
        }
        let durable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: durable)
            finish(taskID: downloadTask.taskIdentifier, result: .success((durable, response)))
        } catch {
            finish(taskID: downloadTask.taskIdentifier, result: .failure(error))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(taskID: task.taskIdentifier, result: .failure(error)) }
    }
    private func finish(taskID: Int, result: Result<(URL, URLResponse), Error>) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: taskID)
        progressHandlers.removeValue(forKey: taskID)
        lock.unlock()
        guard let continuation else { return }
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
