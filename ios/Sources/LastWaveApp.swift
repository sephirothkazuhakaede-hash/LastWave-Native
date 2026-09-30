import SwiftUI

@main struct LastWaveApp: App {
    @StateObject private var player = WavePlayer()
    var body: some Scene { WindowGroup { RootView().environmentObject(player).preferredColorScheme(.dark) } }
}

struct RootView: View {
    @EnvironmentObject var player: WavePlayer
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searching = false
    @State private var showPlayer = false
    var body: some View {
        TabView {
            NavigationStack {
                List {
                    if searching { ProgressView("Searching YouTube Music…") }
                    if results.isEmpty && !searching {
                        ContentUnavailableView("Find your next wave", systemImage: "waveform", description: Text("Search songs and artists. Downloads stay on this device."))
                    }
                    ForEach(results) { track in trackRow(track) }
                }
                .navigationTitle("LastWave")
                .searchable(text: $query, prompt: "Songs and artists")
                .onSubmit(of: .search) { Task { await search() } }
            }.tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack {
                List {
                    if player.downloads.isEmpty { ContentUnavailableView("Your offline library", systemImage: "arrow.down.circle", description: Text("Use Download from a song’s menu.")) }
                    ForEach(player.downloads) { track in trackRow(track).swipeActions { Button("Delete", role: .destructive) { player.delete(track) } } }
                }.navigationTitle("Downloads")
            }.tabItem { Label("Offline", systemImage: "arrow.down.circle") }
            NavigationStack {
                List { ForEach(Array(player.queue.enumerated()), id: \.offset) { _, track in trackRow(track) } }
                    .navigationTitle("Up Next")
            }.tabItem { Label("Queue", systemImage: "list.bullet") }
        }
        .tint(.cyan)
        .safeAreaInset(edge: .bottom) {
            if let current = player.current {
                HStack {
                    Button { showPlayer = true } label: {
                        VStack(alignment: .leading) { Text(current.title).lineLimit(1); Text(current.artist).font(.caption).foregroundStyle(.secondary) }
                    }.buttonStyle(.plain)
                    Spacer()
                    if player.loading { ProgressView() }
                    Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill") }
                    Button { Task { await player.next() } } label: { Image(systemName: "forward.end.fill") }
                }.padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal)
            }
        }
        .sheet(isPresented: $showPlayer) { PlayerView() }
        .alert("LastWave", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("OK") { player.error = nil }
        } message: { Text(player.error ?? "") }
    }
    private func trackRow(_ track: Track) -> some View {
        HStack {
            Button { Task { await player.play(track) } } label: {
                HStack {
                    AsyncImage(url: track.artwork) { image in image.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                        .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading) { Text(track.title).lineLimit(2); Text(track.artist).font(.caption).foregroundStyle(.secondary) }
                }
            }.buttonStyle(.plain)
            Spacer()
            if player.downloading.contains(track.id) { ProgressView() }
            Menu {
                Button("Play next") { player.queue.insert(track, at: 0) }
                Button("Add to queue") { player.queue.append(track) }
                Button("Download") { Task { await player.download(track) } }
            } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Song options")
        }
    }
    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searching = true
        defer { searching = false }
        do { results = try await player.catalog.search(term) } catch { player.error = error.localizedDescription }
    }
}

struct PlayerView: View {
    @EnvironmentObject var player: WavePlayer
    var body: some View {
        VStack(spacing: 24) {
            Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top)
            Spacer()
            AsyncImage(url: player.current?.artwork) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "waveform").font(.system(size: 100)) }
                .frame(maxHeight: 300).clipShape(RoundedRectangle(cornerRadius: 28))
            Text(player.current?.title ?? "LastWave").font(.title2.bold()).multilineTextAlignment(.center)
            Text(player.current?.artist ?? "").foregroundStyle(.secondary)
            Slider(value: Binding(get: { min(player.elapsed, max(player.duration, 1)) }, set: { player.seek($0) }), in: 0...max(player.duration, 1))
            HStack(spacing: 60) {
                Button { player.seek(max(0, player.elapsed - 10)) } label: { Image(systemName: "gobackward.10") }
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64)) }
                Button { Task { await player.next() } } label: { Image(systemName: "forward.end.fill") }
            }.font(.title)
            Spacer()
        }.padding(28).tint(.cyan).presentationDragIndicator(.hidden)
    }
}
