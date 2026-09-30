import Foundation
import AVFoundation
import MediaPlayer
import Combine

@MainActor final class WavePlayer: ObservableObject {
    @Published var current: Track?
    @Published var queue: [Track] = []
    @Published var downloads: [Track] = []
    @Published var playing = false
    @Published var loading = false
    @Published var elapsed = 0.0
    @Published var duration = 0.0
    @Published var error: String?
    @Published var downloading: Set<String> = []
    let catalog = Catalog()
    private let player = AVPlayer()
    private var generation = UUID()
    private var timer: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Offline", isDirectory: true)
    }
    private var index: URL { folder.appendingPathComponent("library.json") }
    func localURL(_ track: Track) -> URL { folder.appendingPathComponent(track.id + ".m4a") }

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: index), let tracks = try? JSONDecoder().decode([Track].self, from: data) {
            downloads = tracks.filter { FileManager.default.fileExists(atPath: localURL($0).path) }
        }
        timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                let length = self.player.currentItem?.duration.seconds ?? 0
                self.duration = length.isFinite ? length : 0
                self.playing = self.player.rate > 0
                self.publishNowPlaying()
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
        do {
            let url: URL
            if FileManager.default.fileExists(atPath: localURL(track).path) { url = localURL(track) }
            else { url = try await catalog.stream(for: track) }
            guard token == generation else { return }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let item = AVPlayerItem(url: url)
            statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed {
                    let message = item.error?.localizedDescription ?? "Playback failed."
                    Task { @MainActor in self?.error = message; self?.loading = false }
                }
            }
            player.replaceCurrentItem(with: item)
            current = track; elapsed = 0; duration = 0
            player.play(); playing = true
            publishNowPlaying()
        } catch { if token == generation { self.error = error.localizedDescription } }
        if token == generation { loading = false }
    }
    func toggle() { if player.rate > 0 { player.pause() } else { player.play() }; playing = player.rate > 0 }
    func seek(_ value: Double) { player.seek(to: CMTime(seconds: value, preferredTimescale: 600)) }
    func next() async {
        if queue.isEmpty { player.pause(); playing = false; return }
        await play(queue.removeFirst())
    }
    func download(_ track: Track) async {
        guard !downloading.contains(track.id), !downloads.contains(track) else { return }
        downloading.insert(track.id)
        defer { downloading.remove(track.id) }
        do {
            let url = try await catalog.stream(for: track)
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WaveError.message("Download failed.") }
            let target = localURL(track)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
            downloads.append(track)
            try JSONEncoder().encode(downloads).write(to: index, options: .atomic)
        } catch { self.error = error.localizedDescription }
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate
        ]
    }
}
