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
    @Published var playlists: [ImportedPlaylist] = []
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
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var didReachExpectedEnd = false
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
        timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                let length = self.expectedDuration ?? self.player.currentItem?.duration.seconds ?? 0
                self.duration = length.isFinite ? length : 0
                self.playing = self.player.rate > 0
                self.publishNowPlaying()
                if let expected = self.expectedDuration, expected > 0,
                   self.elapsed >= expected - 0.35, !self.didReachExpectedEnd {
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
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(position.positionTime) }
            return .success
        }
    }

    func play(_ track: Track) async {
        let token = UUID(); generation = token
        loading = true; error = nil
        player.pause()
        current = track; elapsed = 0; duration = track.duration ?? 0; expectedDuration = track.duration
        didReachExpectedEnd = false; lyrics = []; nowPlayingArtwork = nil
        publishNowPlaying()
        Task { await loadLyrics(for: track, token: token) }
        Task { await loadArtwork(for: track, token: token) }
        do {
            let url: URL
            if FileManager.default.fileExists(atPath: localURL(track).path) { url = localURL(track) }
            else {
                let resolved = try await catalog.resolvedStream(for: track, quality: audioQuality)
                url = resolved.url; expectedDuration = resolved.duration
            }
            guard token == generation else { return }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let item = AVPlayerItem(url: url)
            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                if item.status == .readyToPlay {
                    Task { @MainActor in self?.loading = false; self?.player.play() }
                } else if item.status == .failed {
                    let message = item.error?.localizedDescription ?? "Playback failed."
                    Task { @MainActor in self?.error = message; self?.loading = false }
                }
            }
            player.replaceCurrentItem(with: item)
            player.play(); playing = true
            publishNowPlaying()
            if let nextTrack = queue.first { Task { _ = try? await catalog.resolvedStream(for: nextTrack, quality: audioQuality) } }
        } catch { if token == generation { self.error = error.localizedDescription } }
        if token == generation { loading = false }
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
        let candidates = Array(tracks.prefix(6))
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
    @discardableResult func download(_ track: Track) async -> Bool {
        if isDownloaded(track) { return true }
        guard !downloading.contains(track.id) else { return false }
        downloading.insert(track.id)
        downloadProgress[track.id] = 0
        error = nil
        defer { downloading.remove(track.id); downloadProgress.removeValue(forKey: track.id) }
        do {
            let url = try await catalog.stream(for: track, quality: audioQuality)
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
            let transfer = DownloadTransfer(identifier: "com.seph.capyflow.download.\(track.id).\(UUID().uuidString)") { [weak self] progress in
                Task { @MainActor in self?.downloadProgress[track.id] = progress }
            }
            let (temporary, response) = try await transfer.start(request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw WaveError.message("Download failed.") }
            let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 16_384 else { throw WaveError.message("The downloaded audio was incomplete. Please retry.") }
            let target = localURL(track)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
            downloads.append(track)
            try JSONEncoder().encode(downloads).write(to: index, options: .atomic)
            let lyricsService = self.lyricsService
            Task { _ = try? await lyricsService.lyrics(for: track) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func importPlaylist(_ input: String) async {
        do {
            let playlist = try await catalog.playlist(from: input)
            playlists.removeAll { $0.id == playlist.id }; playlists.append(playlist)
            if let data = try? JSONEncoder().encode(playlists) { UserDefaults.standard.set(data, forKey: "importedPlaylists") }
        } catch { self.error = error.localizedDescription }
    }
    func createPlaylist(named name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        playlists.append(ImportedPlaylist(id: UUID().uuidString, name: cleaned, tracks: []))
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
        var completed = 0
        for track in pending {
            var succeeded = false
            for attempt in 0..<4 {
                if await download(track) {
                    succeeded = true
                    break
                }
                if attempt < 3 {
                    let delay = UInt64(700_000_000 * (attempt + 1))
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
            if succeeded { completed += 1 } else { failures.append(track.title) }
            playlistDownloadProgress[playlist.id] = "\(completed)/\(pending.count)"
        }
        if failures.isEmpty {
            error = nil
        } else {
            error = "Couldn't download \(failures.count) song\(failures.count == 1 ? "" : "s"). Tap Download all to retry."
        }
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

private final class DownloadTransfer: NSObject, URLSessionDownloadDelegate {
    private let identifier: String
    private let progress: (Double) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    init(identifier: String, progress: @escaping (Double) -> Void) {
        self.identifier = identifier; self.progress = progress
    }
    func start(_ request: URLRequest) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            configuration.allowsCellularAccess = true
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: request).resume()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response else { return }
        let durable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: durable)
            continuation?.resume(returning: (durable, response))
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let continuation { continuation.resume(throwing: error); self.continuation = nil }
    }
}
