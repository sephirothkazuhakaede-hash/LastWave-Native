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
    private var durationIsAuthoritati…7039 tokens truncated…gress[track.id],
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
    }
    func saveAlbum(_ album: Album, tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let id = "album:" + album.id
        playlists.removeAll { $0.id == id }
        playlists.insert(ImportedPlaylist(id: id, name: album.title, tracks: tracks.map(canonicalized)), at: 0)
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
