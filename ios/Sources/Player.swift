import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

enum DownloadStage: Equatable {
    case queued
    case preparing
    case downloading
    case saving
    case downloaded
    case failed
}

struct TrackDownloadState: Equatable {
    let stage: DownloadStage
    let progress: Double?
    let source: String?
    let attempt: Int
    let elapsedSeconds: TimeInterval
    let detail: String?

    var statusText: String {
        let retry = attempt > 1 ? "Retry \(attempt) · " : ""
        switch stage {
        case .queued: return attempt > 1 ? "Retry \(attempt) queued" : "Queued"
        case .preparing:
            return retry + "Preparing" + (detail.map { " · \($0)" } ?? "")
        case .downloading:
            let percent = progress.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
            return retry + (source ?? "Downloading") + percent
        case .saving: return "Saving"
        case .downloaded: return "Downloaded · \(Self.formatted(elapsedSeconds))"
        case .failed: return retry + "Failed" + (detail.map { ": \($0)" } ?? "")
        }
    }

    private static func formatted(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct DownloadBatchSummary: Equatable {
    let playlistID: String
    let total: Int
    var completed: Int
    var failed: Int
    var active: Int
    var queued: Int
    let startedAt: Date
    var finishedAt: Date?

    var statusText: String {
        if let finishedAt {
            let seconds = max(0, finishedAt.timeIntervalSince(startedAt))
            return "\(completed)/\(total) downloaded, \(failed) failed · \(Int(seconds.rounded()))s"
        }
        let handled = completed + failed
        return "Downloading \(handled) of \(total) · \(active) active · \(queued) queued" +
            (failed > 0 ? " · \(failed) failed" : "")
    }
}

@MainActor final class WavePlayer: ObservableObject {
    private enum DurationAuthority: Int {
        case estimate = 0
        case playerItem = 1
        case backend = 2
        case localFile = 3
    }
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
    @Published var downloadStates: [String: TrackDownloadState] = [:]
    @Published var downloadBatchSummary: DownloadBatchSummary?
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
    @Published private(set) var currentAudioInfo: AudioMediaInfo?
    let catalog = Catalog()
    private let lyricsService = LyricsService()
    private let player = AVPlayer()
    private var generation = UUID()
    private var expectedDuration: Double?
    private var playbackHistory: [Track] = []
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var didReachExpectedEnd = false
    private var durationIsAuthoritative = false
    private var durationAuthority = DurationAuthority.estimate
    private var playbackRetryCount = 0
    private var lastPersistedDuration: [String: Double] = [:]
    private var lastPersistedDurationAuthority: [String: DurationAuthority] = [:]
    private var timer: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    @Published private(set) var audioOutputName = "iPhone"
    private var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Offline", isDirectory: true)
    }
    private var index: URL { folder.appendingPathComponent("library.json") }
    private var playlistArtworkFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PlaylistArtwork", isDirectory: true)
    }
    func localURL(_ track: Track) -> URL {
        let suffix = track.downloadQuality.map { "." + $0 } ?? ""
        return folder.appendingPathComponent(track.playableID + suffix + ".m4a")
    }

    private func localCopy(for track: Track) -> Track? {
        downloads.first { ($0.id == track.id || $0.playableID == track.playableID) && (track.mediaID == nil || $0.playableID == track.playableID) && $0.downloadQuality == audioQuality.backendValue
            && FileManager.default.fileExists(atPath: localURL($0).path) }
    }

    init() {
        autoplayEnabled = UserDefaults.standard.object(forKey: "autoplayEnabled") as? Bool ?? true
        audioQuality = AudioQuality(rawValue: UserDefaults.standard.string(forKey: "audioQuality") ?? "") ?? .automatic
        if let data = UserDefaults.standard.data(forKey: "authoritativeDurations"),
           let saved = try? JSONDecoder().decode([String: Double].self, from: data) {
            lastPersistedDuration = saved.filter { $0.value.isFinite && $0.value > 0 }
        }
        if let data = UserDefaults.standard.data(forKey: "authoritativeDurationSources"),
           let saved = try? JSONDecoder().decode([String: Int].self, from: data) {
            lastPersistedDurationAuthority = saved.reduce(into: [String: DurationAuthority]()) { result, entry in
                if let authority = DurationAuthority(rawValue: entry.value) {
                    result[entry.key] = authority
                }
            }
        }
        player.automaticallyWaitsToMinimizeStalling = false
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: index), let tracks = try? JSONDecoder().decode([Track].self, from: data) {
            downloads = tracks
                .filter { FileManager.default.fileExists(atPath: localURL($0).path) }
                .map(canonicalized)
        }
        if let data = UserDefaults.standard.data(forKey: "importedPlaylists"),
           let saved = try? JSONDecoder().decode([ImportedPlaylist].self, from: data) {
            playlists = saved.map {
                let albumID = $0.id.hasPrefix("album:") ? String($0.id.dropFirst(6)) : nil
                let tracks = $0.tracks.map { original -> Track in
                    var track = original
                    if track.albumID == nil { track.albumID = albumID }
                    return canonicalized(track)
                }
                return ImportedPlaylist(id: $0.id, name: $0.name, tracks: tracks)
            }
        }
        if let data = UserDefaults.standard.data(forKey: "recentTracks"),
           let saved = try? JSONDecoder().decode([Track].self, from: data) { recentTracks = Array(saved.prefix(20)) }
        timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let newElapsed = time.seconds.isFinite ? time.seconds : 0
                if abs(self.elapsed - newElapsed) > 0.05 { self.elapsed = newElapsed }
                let itemDuration = self.player.currentItem?.duration.seconds ?? 0
                if itemDuration.isFinite, itemDuration > 0 {
                    if let trackID = self.current?.id {
                        // Some YouTube adaptive streams advertise a much longer
                        // container timeline than the song itself. Album and
                        // playlist rows carry YouTube Music's track duration, so
                        // keep that shorter value when the two disagree by more
                        // than normal rounding/encoder padding.
                        let playableDuration = self.durationCappedByKnownTrack(
                            itemDuration,
                            knownDuration: self.expectedDuration
                        )
                        self.adoptAuthoritativeDuration(playableDuration, for: trackID, source: .playerItem)
                    }
                }
                let playerLength = (itemDuration.isFinite && itemDuration > 0)
                    ? self.durationCappedByKnownTrack(itemDuration, knownDuration: self.expectedDuration)
                    : nil
                let length = self.durationIsAuthoritative
                    ? (self.expectedDuration ?? playerLength ?? 0)
                    : (playerLength ?? self.expectedDuration ?? 0)
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
                let endedAt = item.currentTime().seconds
                if let trackID = self.current?.id, endedAt.isFinite, endedAt > 0 {
                    self.adoptAuthoritativeDuration(endedAt, for: trackID, source: .playerItem)
                }
                await self.next()
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                if type == AVAudioSession.InterruptionType.began.rawValue { self?.player.pause() }
            }
        }
        audioOutputName = Self.outputName()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            Task { @MainActor in
                guard let self else { return }
                self.audioOutputName = Self.outputName()
                if AudioRoutePolicy.shouldPause(reason: reason) {
                    self.player.pause()
                    self.playing = false
                    self.publishNowPlaying()
                }
                // iOS reroutes the existing player. Do not replace its item,
                // resolve a stream, or seek when selecting another output.
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

    func play(_ requestedTrack: Track, recordHistory: Bool = true, recovering: Bool = false) async {
        let token = UUID(); generation = token
        loading = true; error = nil
        player.pause()
        let track: Track
        do { track = try await catalog.normalizedTrack(requestedTrack) }
        catch { if token == generation { loading = false; self.error = error.localizedDescription }; return }
        guard token == generation else { return }
        healSavedIdentity(track)
        if track.playableID != requestedTrack.playableID {
            lastPersistedDuration.removeValue(forKey: track.id)
            lastPersistedDurationAuthority.removeValue(forKey: track.id)
        }
        if !recovering { playbackRetryCount = 0 }
        if !recovering, recordHistory, let current, current.id != track.id {
            playbackHistory.append(current)
            if playbackHistory.count > 50 { playbackHistory.removeFirst(playbackHistory.count - 50) }
        }
        let canonicalTrack = canonicalized(track)
        current = canonicalTrack
        elapsed = 0
        duration = canonicalTrack.duration ?? 0
        expectedDuration = canonicalTrack.duration
        didReachExpectedEnd = false
        durationIsAuthoritative = false
        durationAuthority = .estimate
        if let persisted = lastPersistedDuration[track.id] {
            // Duration values written by older builds did not save their source.
            // Treat those as player observations so a fresh backend/local value
            // can repair a previously persisted long adaptive-container tail.
            let persistedAuthority = lastPersistedDurationAuthority[track.id] ?? .playerItem
            let playableDuration = durationCappedByKnownTrack(persisted, knownDuration: track.duration)
            adoptAuthoritativeDuration(playableDuration, for: track.id, source: persistedAuthority)
        }
        if !recovering {
            rememberRecentlyPlayed(track)
            lyrics = []; nowPlayingArtwork = nil
            publishNowPlaying()
            Task { await loadArtwork(for: track, token: token) }
        }
        do {
            let url: URL
            var resolvedHeaders: [String: String] = [:]
            var usedBackend = false
            let saved = localCopy(for: track)
            let isLocal = saved != nil
            currentAudioInfo = nil
            if let saved { url = localURL(saved); currentAudioInfo = saved.mediaInfo }
            else {
                let resolved = try await catalog.resolvedStream(for: track, quality: audioQuality, preferRemote: recovering)
                guard token == generation else { return }
                url = resolved.url
                currentAudioInfo = resolved.mediaInfo
                if let resolvedDuration = resolved.duration, resolvedDuration > 0 {
                    let playableDuration = durationCappedByKnownTrack(
                        resolvedDuration,
                        knownDuration: canonicalTrack.duration
                    )
                    expectedDuration = playableDuration
                    duration = playableDuration
                    durationIsAuthoritative = resolved.durationIsAuthoritative
                    if resolved.durationIsAuthoritative {
                        adoptAuthoritativeDuration(playableDuration, for: track.id, source: .backend)
                    }
                }
                resolvedHeaders = resolved.requestHeaders
                usedBackend = resolved.usesBackend
            }
            guard token == generation else { return }
            if !recovering {
                let lyricTrack = current ?? track
                Task { await loadLyrics(for: lyricTrack, token: token) }
            }
            try AudioRoutePolicy.configure(AVAudioSession.sharedInstance())
            try AVAudioSession.sharedInstance().setActive(true)
            audioOutputName = Self.outputName()
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
    func isDownloaded(_ track: Track) -> Bool { localCopy(for: track) != nil }
    func isPlaylistDownloaded(_ playlist: ImportedPlaylist) -> Bool {
        !playlist.tracks.isEmpty && playlist.tracks.allSatisfy { isDownloaded($0) }
    }
    @discardableResult func download(
        _ requestedTrack: Track,
        reportError: Bool = true,
        preferRemote: Bool = false,
        attemptNumber: Int = 1,
        startedAt: Date = Date()
    ) async -> Bool {
        let track: Track
        do { track = try await catalog.normalizedTrack(requestedTrack) }
        catch { if reportError { self.error = error.localizedDescription }; return false }
        healSavedIdentity(track)
        if isDownloaded(track) {
            downloadStates[track.id] = TrackDownloadState(
                stage: .downloaded, progress: 1, source: "Offline copy", attempt: attemptNumber,
                elapsedSeconds: Date().timeIntervalSince(startedAt), detail: nil
            )
            return true
        }
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
        let queuedSeconds = max(0, Date().timeIntervalSince(startedAt))
        let queuedText = queuedSeconds >= 1 ? "queued \(Int(queuedSeconds.rounded()))s" : nil
        downloadStates[track.id] = TrackDownloadState(
            stage: .preparing, progress: nil, source: nil, attempt: attemptNumber,
            elapsedSeconds: queuedSeconds, detail: queuedText
        )
        error = nil
        defer { downloading.remove(track.id); downloadProgress.removeValue(forKey: track.id) }
        var usedBackend = false
        let downloadQuality = audioQuality
        do {
            let resolved = try await catalog.resolvedStream(for: track, quality: downloadQuality, preferRemote: preferRemote)
            usedBackend = resolved.usesBackend
            var sourceLabel: String
            switch resolved.source {
            case .msiCacheHit: sourceLabel = "MSI cache hit"
            case .msiNewExtraction: sourceLabel = "MSI new extraction"
            case .directFallback: sourceLabel = "Direct resolver fallback"
            }
            downloadDiagnostics[track.id] = attemptPrefix +
                (queuedText.map { "\($0) · " } ?? "") + sourceLabel
            downloadStates[track.id] = TrackDownloadState(
                stage: .downloading, progress: 0, source: sourceLabel, attempt: attemptNumber,
                elapsedSeconds: Date().timeIntervalSince(startedAt), detail: nil
            )
            var request = URLRequest(url: resolved.downloadURL ?? resolved.url)
            request.timeoutInterval = 600
            request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148", forHTTPHeaderField: "User-Agent")
            resolved.requestHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let transfer = DownloadCoordinator.shared
            let progressSource = sourceLabel
            let transferResult = try await transfer.start(request) { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloadProgress[track.id] = progress
                    self.downloadStates[track.id] = TrackDownloadState(
                        stage: .downloading, progress: progress, source: progressSource,
                        attempt: attemptNumber, elapsedSeconds: Date().timeIntervalSince(startedAt), detail: nil
                    )
                }
            }
            let temporary = transferResult.location
            defer { try? FileManager.default.removeItem(at: temporary) }
            let response = transferResult.response
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporary)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw WaveError.message(code > 0 ? "The audio server refused this song (HTTP \(code))." : "The audio server did not return a downloadable file.")
            }
            if usedBackend {
                switch http.value(forHTTPHeaderField: "X-CapyFlow-Cache")?.uppercased() {
                case "HIT": sourceLabel = "MSI cache hit"
                case "MISS": sourceLabel = "MSI new extraction"
                default: break
                }
                let serverTiming = http.value(forHTTPHeaderField: "Server-Timing")
                downloadDiagnostics[track.id] = attemptPrefix + sourceLabel + (serverTiming.map { " · \($0)" } ?? "")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 16_384 else {
                try? FileManager.default.removeItem(at: temporary)
                throw WaveError.message("The downloaded audio was incomplete. Please retry.")
            }
            var downloadTrack = track
            downloadTrack.downloadQuality = downloadQuality.backendValue
            downloadTrack.mediaInfo = resolved.mediaInfo
            if let value = http.value(forHTTPHeaderField: "X-CapyFlow-Media-Info"),
               let data = value.data(using: .utf8) {
                downloadTrack.mediaInfo = try? JSONDecoder().decode(AudioMediaInfo.self, from: data)
            }
            let target = localURL(downloadTrack)
            downloadStates[track.id] = TrackDownloadState(
                stage: .saving, progress: 1, source: sourceLabel, attempt: attemptNumber,
                elapsedSeconds: Date().timeIntervalSince(startedAt), detail: nil
            )
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
            let headerDuration = http.value(forHTTPHeaderField: "X-CapyFlow-Duration").flatMap(Double.init)
            let localAssetDuration = try? await AVURLAsset(url: target).load(.duration)
            let localSeconds = localAssetDuration?.seconds
            // Prefer a consensus over AVAsset alone. A malformed adaptive file
            // can report several minutes of empty tail; the backend header and
            // YouTube Music row duration let us reject that high outlier.
            let exactDuration = [headerDuration, resolved.durationIsAuthoritative ? resolved.duration : nil, localSeconds]
                .compactMap { $0 }.first { $0.isFinite && $0 > 0 }
            let savedTrack: Track
            if let exact = exactDuration {
                adoptAuthoritativeDuration(exact, for: track.id, source: .localFile)
                savedTrack = downloadTrack.withDuration(exact)
            } else {
                savedTrack = downloadTrack
            }
            for previous in downloads where previous.id == track.id && localURL(previous) != target {
                try? FileManager.default.removeItem(at: localURL(previous))
            }
            downloads.removeAll { $0.id == track.id }
            downloads.append(savedTrack)
            downloadFailures.removeValue(forKey: track.id)
            try JSONEncoder().encode(downloads).write(to: index, options: .atomic)
            // A completed offline download is not reported until its available
            // lyrics have also been written to the on-device cache.
            _ = try? await lyricsService.lyrics(for: savedTrack)
            downloadStates[track.id] = TrackDownloadState(
                stage: .downloaded, progress: 1, source: sourceLabel, attempt: attemptNumber,
                elapsedSeconds: Date().timeIntervalSince(startedAt), detail: nil
            )
            let total = Date().timeIntervalSince(startedAt)
            let timingText = total < 1 ? "<1s" : "\(Int(total.rounded()))s"
            let firstByteText = transferResult.firstByteLatency.map {
                $0 < 1 ? "first byte <1s" : "first byte \(Int($0.rounded()))s"
            }
            let transferText = transferResult.transferDuration < 1
                ? "transfer <1s"
                : "transfer \(Int(transferResult.transferDuration.rounded()))s"
            downloadDiagnostics[track.id] = [
                downloadDiagnostics[track.id] ?? sourceLabel,
                firstByteText,
                transferText,
                "total \(timingText)"
            ].compactMap { $0 }.joined(separator: " · ")
            return true
        } catch {
            let reason = error.localizedDescription
            if usedBackend { await BackendClient.shared.reportStreamFailure(reason) }
            await catalog.invalidateStream(for: track, quality: audioQuality)
            downloadFailures[track.id] = reason
            downloadStates[track.id] = TrackDownloadState(
                stage: .failed, progress: downloadProgress[track.id],
                source: downloadDiagnostics[track.id], attempt: attemptNumber,
                elapsedSeconds: Date().timeIntervalSince(startedAt), detail: reason
            )
            if reportError { self.error = reason }
            return false
        }
    }
    func importPlaylist(_ input: String) async {
        do {
            let imported = try await catalog.playlist(from: input)
            let playlist = ImportedPlaylist(
                id: imported.id,
                name: imported.name,
                tracks: imported.tracks.map(canonicalized)
            )
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
        var tracks = playlists[index].tracks; tracks.append(canonicalized(track))
        playlists[index] = ImportedPlaylist(id: playlists[index].id, name: playlists[index].name, tracks: tracks)
        savePlaylists()
        scheduleIdentityRepair([track])
    }
    func saveAlbum(_ album: Album, tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let id = "album:" + album.id
        playlists.removeAll { $0.id == id }
        playlists.insert(ImportedPlaylist(id: id, name: album.title, tracks: tracks.map(canonicalized)), at: 0)
        savePlaylists()
        scheduleIdentityRepair(tracks)
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
        let batchStartedAt = Date()
        for track in playlist.tracks {
            downloadStates[track.id] = TrackDownloadState(
                stage: isDownloaded(track) ? .downloaded : .queued,
                progress: isDownloaded(track) ? 1 : nil,
                source: isDownloaded(track) ? "Offline copy" : nil,
                attempt: 0,
                elapsedSeconds: 0,
                detail: nil
            )
        }
        downloadBatchSummary = DownloadBatchSummary(
            playlistID: playlist.id,
            total: pending.count,
            completed: 0,
            failed: 0,
            active: 0,
            queued: pending.count,
            startedAt: batchStartedAt,
            finishedAt: pending.isEmpty ? batchStartedAt : nil
        )
        playlistDownloadProgress[playlist.id] = "0/\(pending.count)"
        defer {
            downloadingPlaylists.remove(playlist.id)
            playlistDownloadProgress.removeValue(forKey: playlist.id)
        }
        var failures: [String] = []
        var processed = 0
        var iterator = pending.makeIterator()
        let workerCount = min(3, pending.count)
        if var summary = downloadBatchSummary, summary.playlistID == playlist.id {
            summary.active = workerCount
            summary.queued = max(0, pending.count - workerCount)
            downloadBatchSummary = summary
        }
        await withTaskGroup(of: (Track, Bool).self) { group in
            for _ in 0..<workerCount {
                guard let track = iterator.next() else { break }
                group.addTask { [weak self] in
                    guard let self else { return (track, false) }
                    return (track, await self.downloadWithRetries(track, queuedAt: batchStartedAt))
                }
            }
            while let (track, succeeded) = await group.next() {
                processed += 1
                if !succeeded { failures.append(track.title) }
                if var summary = downloadBatchSummary, summary.playlistID == playlist.id {
                    if succeeded { summary.completed += 1 } else { summary.failed += 1 }
                    summary.active = max(0, summary.active - 1)
                    downloadBatchSummary = summary
                }
                playlistDownloadProgress[playlist.id] = "\(processed)/\(pending.count)"
                if let nextTrack = iterator.next() {
                    if var summary = downloadBatchSummary, summary.playlistID == playlist.id {
                        summary.active += 1
                        summary.queued = max(0, summary.queued - 1)
                        downloadBatchSummary = summary
                    }
                    group.addTask { [weak self] in
                        guard let self else { return (nextTrack, false) }
                        return (nextTrack, await self.downloadWithRetries(nextTrack, queuedAt: batchStartedAt))
                    }
                }
            }
        }
        if var summary = downloadBatchSummary, summary.playlistID == playlist.id {
            summary.active = 0
            summary.queued = 0
            summary.finishedAt = Date()
            downloadBatchSummary = summary
        }
        if failures.isEmpty {
            error = nil
        } else {
            let sample = failures.prefix(3).joined(separator: ", ")
            error = "Couldn't download \(failures.count) song\(failures.count == 1 ? "" : "s"): \(sample). Tap its warning icon for the exact reason."
        }
    }
    private func downloadWithRetries(_ track: Track, queuedAt: Date = Date()) async -> Bool {
        let startedAt = queuedAt
        for attempt in 0..<5 {
            let directFallback = attempt >= 3
            if await download(
                track,
                reportError: false,
                preferRemote: directFallback,
                attemptNumber: attempt + 1,
                startedAt: startedAt
            ) { return true }
            if attempt < 4 {
                downloadStates[track.id] = TrackDownloadState(
                    stage: .queued, progress: nil,
                    source: "Retry \(attempt + 2) after failure",
                    attempt: attempt + 2,
                    elapsedSeconds: Date().timeIntervalSince(startedAt),
                    detail: downloadFailures[track.id]
                )
                try? await Task.sleep(nanoseconds: UInt64(650_000_000 * (attempt + 1)))
            }
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
            let url = localURL(track)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            downloads.removeAll { $0.id == track.id }
            downloading.remove(track.id)
            downloadProgress.removeValue(forKey: track.id)
            downloadFailures.removeValue(forKey: track.id)
            downloadStates.removeValue(forKey: track.id)
            downloadDiagnostics.removeValue(forKey: track.id)
            lastPersistedDuration.removeValue(forKey: track.id)
            lastPersistedDurationAuthority.removeValue(forKey: track.id)
            persistAuthoritativeDurations()
            try JSONEncoder().encode(downloads).write(to: index, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
    private static func outputName() -> String {
        let names = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName)
        return names.isEmpty ? "iPhone" : names.joined(separator: ", ")
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
        recentTracks.insert(canonicalized(track), at: 0)
        if recentTracks.count > 20 { recentTracks.removeLast(recentTracks.count - 20) }
        if let data = try? JSONEncoder().encode(recentTracks) {
            UserDefaults.standard.set(data, forKey: "recentTracks")
        }
    }

    /// Search and album durations are estimates. Once the backend or AVPlayer
    /// reports the playable media duration, replace every persisted copy so an
    /// old estimate cannot return through a saved album or playlist.
    private func adoptAuthoritativeDuration(
        _ seconds: Double,
        for trackID: String,
        source: DurationAuthority
    ) {
        guard seconds.isFinite, seconds > 0 else { return }
        let corrected = (seconds * 100).rounded() / 100
        if current?.id == trackID {
            guard source.rawValue >= durationAuthority.rawValue else { return }
            durationAuthority = source
            expectedDuration = corrected
            durationIsAuthoritative = true
            if abs(duration - corrected) > 0.05 { duration = corrected }
            if let current, abs((current.duration ?? 0) - corrected) > 0.05 {
                self.current = current.withDuration(corrected)
            }
        } else if let persistedAuthority = lastPersistedDurationAuthority[trackID],
                  source.rawValue < persistedAuthority.rawValue {
            return
        }

        lastPersistedDuration[trackID] = corrected
        lastPersistedDurationAuthority[trackID] = source
        persistAuthoritativeDurations()

        func needsCorrection(_ track: Track) -> Bool {
            track.id == trackID && abs((track.duration ?? 0) - corrected) > 0.05
        }
        queue = queue.map { needsCorrection($0) ? $0.withDuration(corrected) : $0 }
        playbackHistory = playbackHistory.map { needsCorrection($0) ? $0.withDuration(corrected) : $0 }
        let recentChanged = recentTracks.contains(where: needsCorrection)
        recentTracks = recentTracks.map { needsCorrection($0) ? $0.withDuration(corrected) : $0 }
        if recentChanged, let data = try? JSONEncoder().encode(recentTracks) {
            UserDefaults.standard.set(data, forKey: "recentTracks")
        }

        var changedDownloads = false
        downloads = downloads.map {
            guard needsCorrection($0) else { return $0 }
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
                guard needsCorrection(track) else { return track }
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

    private func canonicalized(_ track: Track) -> Track {
        guard let corrected = lastPersistedDuration[track.id], corrected.isFinite, corrected > 0 else {
            return track
        }
        return track.withDuration(durationCappedByKnownTrack(corrected, knownDuration: track.duration))
    }

    /// Repair persisted album rows after the shared resolver learns their
    /// recording. Existing files retain their identity unless it already agrees.
    private func healSavedIdentity(_ canonical: Track) {
        func repaired(_ track: Track) -> Track {
            track.id == canonical.id || track.playableID == canonical.playableID
                ? track.adoptingRecording(canonical) : track
        }
        let repairedQueue = queue.map(repaired)
        if queue != repairedQueue { queue = repairedQueue }
        playbackHistory = playbackHistory.map(repaired)
        let repairedRecent = recentTracks.map(repaired)
        if recentTracks != repairedRecent {
            recentTracks = repairedRecent
            if let data = try? JSONEncoder().encode(recentTracks) { UserDefaults.standard.set(data, forKey: "recentTracks") }
        }
        var changedPlaylists = false
        let repairedPlaylists = playlists.map { playlist -> ImportedPlaylist in
            let tracks = playlist.tracks.map(repaired)
            if tracks != playlist.tracks { changedPlaylists = true }
            return ImportedPlaylist(id: playlist.id, name: playlist.name, tracks: tracks)
        }
        if changedPlaylists { playlists = repairedPlaylists; savePlaylists() }
        let repairedDownloads = downloads.map { $0.playableID == canonical.playableID ? repaired($0) : $0 }
        if downloads != repairedDownloads {
            downloads = repairedDownloads
            if let data = try? JSONEncoder().encode(downloads) { try? data.write(to: index, options: .atomic) }
        }
    }

    private func scheduleIdentityRepair(_ tracks: [Track]) {
        Task { [weak self] in
            guard let self else { return }
            for track in tracks {
                if let canonical = try? await self.catalog.normalizedTrack(track) {
                    self.healSavedIdentity(canonical)
                }
            }
        }
    }

    private func persistAuthoritativeDurations() {
        if let data = try? JSONEncoder().encode(lastPersistedDuration) {
            UserDefaults.standard.set(data, forKey: "authoritativeDurations")
        }
        let sources = lastPersistedDurationAuthority.mapValues { $0.rawValue }
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: "authoritativeDurationSources")
        }
    }

    /// Never disguise a mismatched recording by clamping its actual duration.
    /// Album source identity is corrected before resolving or downloading it.
    private func durationCappedByKnownTrack(_ measured: Double, knownDuration: Double?) -> Double {
        measured.isFinite && measured > 0 ? measured : (knownDuration ?? 0)
    }

    /// Selects the lower median so a single implausibly long container duration
    /// cannot overwrite the backend/catalog values used by saved album tracks.
    private func consensusDuration(_ candidates: [Double?]) -> Double? {
        let values = candidates.compactMap { value -> Double? in
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }.sorted()
        guard !values.isEmpty else { return nil }
        return values[(values.count - 1) / 2]
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

private struct DownloadTransferResult {
    let location: URL
    let response: URLResponse
    let firstByteLatency: TimeInterval?
    let transferDuration: TimeInterval
}

private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = DownloadCoordinator()
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<DownloadTransferResult, Error>] = [:]
    private var progressHandlers: [Int: (Double) -> Void] = [:]
    private var startedAt: [Int: Date] = [:]
    private var firstByteAt: [Int: Date] = [:]
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

    func start(_ request: URLRequest, progress: @escaping (Double) -> Void) async throws -> DownloadTransferResult {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request)
            lock.lock()
            continuations[task.taskIdentifier] = continuation
            progressHandlers[task.taskIdentifier] = progress
            startedAt[task.taskIdentifier] = Date()
            lock.unlock()
            task.resume()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        if firstByteAt[downloadTask.taskIdentifier] == nil {
            firstByteAt[downloadTask.taskIdentifier] = Date()
        }
        let progress = progressHandlers[downloadTask.taskIdentifier]
        lock.unlock()
        guard totalBytesExpectedToWrite > 0 else { return }
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
            lock.lock()
            let started = startedAt[downloadTask.taskIdentifier] ?? Date()
            let firstByte = firstByteAt[downloadTask.taskIdentifier]
            lock.unlock()
            let completed = Date()
            finish(
                taskID: downloadTask.taskIdentifier,
                result: .success(DownloadTransferResult(
                    location: durable,
                    response: response,
                    firstByteLatency: firstByte.map { max(0, $0.timeIntervalSince(started)) },
                    transferDuration: max(0, completed.timeIntervalSince(started))
                ))
            )
        } catch {
            finish(taskID: downloadTask.taskIdentifier, result: .failure(error))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(taskID: task.taskIdentifier, result: .failure(error)) }
    }
    private func finish(taskID: Int, result: Result<DownloadTransferResult, Error>) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: taskID)
        progressHandlers.removeValue(forKey: taskID)
        startedAt.removeValue(forKey: taskID)
        firstByteAt.removeValue(forKey: taskID)
        lock.unlock()
        guard let continuation else { return }
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
