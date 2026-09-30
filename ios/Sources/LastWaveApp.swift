import SwiftUI

@main struct LastWaveApp: App {
    @StateObject private var player = WavePlayer()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(player).preferredColorScheme(.dark) }
    }
}

private enum WaveTab: String, CaseIterable {
    case home = "Home", playlists = "Playlists", offline = "Offline", queue = "Queue"
    var icon: String {
        switch self { case .home: "house.fill"; case .playlists: "rectangle.stack.fill"; case .offline: "arrow.down.circle.fill"; case .queue: "music.note.list" }
    }
}

struct RootView: View {
    @EnvironmentObject var player: WavePlayer
    @State private var tab: WaveTab = .home
    @State private var showPlayer = false
    @State private var searchQuery = ""
    @State private var searchResults: [Track] = []
    @State private var searching = false
    var body: some View {
        ZStack {
            WaveBackdrop()
            Group {
                switch tab {
                case .home: SearchHomeView(query: $searchQuery, results: $searchResults, searching: $searching)
                case .playlists: PlaylistLibraryView()
                case .offline: TrackCollectionView(title: "Offline", subtitle: "Saved on this iPhone", tracks: player.downloads, isOffline: true)
                case .queue: TrackCollectionView(title: "Queue", subtitle: "\(player.queue.count) tracks waiting", tracks: player.queue)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            VStack(spacing: 10) {
                if let current = player.current { MiniPlayer(track: current) { showPlayer = true } }
                WaveTabBar(selection: $tab)
            }.padding(.horizontal, 18)
        }
        .sheet(isPresented: $showPlayer) { PlayerView().presentationDetents([.large]).presentationDragIndicator(.hidden) }
        .overlay(alignment: .top) {
            if let message = player.error {
                ErrorPill(message: message) { player.error = nil }
                    .padding(.horizontal, 20).padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity)).zIndex(20)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: player.error)
    }
}

private struct SearchHomeView: View {
    @EnvironmentObject var player: WavePlayer
    @Binding var query: String
    @Binding var results: [Track]
    @Binding var searching: Bool
    @FocusState private var focused: Bool
    @State private var lyricMode = false
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                header
                searchBar
                Picker("Search type", selection: $lyricMode) {
                    Text("Songs").tag(false); Text("Lyrics").tag(true)
                }.pickerStyle(.segmented)
                if searching {
                    HStack(spacing: 12) { ProgressView(); Text("Searching YouTube Music…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity).padding(28).waveGlass(radius: 24)
                } else if results.isEmpty {
                    discoveryHero
                    featureStrip
                } else {
                    sectionHeader
                    ForEach(results) { TrackCard(track: $0) }
                }
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 30)
        }.scrollIndicators(.hidden)
        .task(id: query) {
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await search(showSpinner: false)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("LastWave").font(.system(size: 42, weight: .black, design: .rounded))
                Text("Your music. Your current.").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { focused = true } label: { Image(systemName: "magnifyingglass").font(.title2.bold()).frame(width: 54, height: 54) }
                .buttonStyle(.plain).waveGlass(radius: 22)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.waveBlue)
            TextField("Search songs and artists", text: $query)
                .focused($focused).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                .onSubmit { Task { await search() } }
            if !query.isEmpty {
                Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
        }.font(.body.weight(.semibold)).padding(.horizontal, 18).frame(height: 58).waveGlass(radius: 22)
    }

    private var discoveryHero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color.waveBlue.opacity(0.42), Color.indigo.opacity(0.30), .black.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.10)).frame(width: 210).offset(x: 190, y: -80)
            Image(systemName: "waveform.path.ecg.rectangle.fill").font(.system(size: 94, weight: .thin)).foregroundStyle(.white.opacity(0.16)).offset(x: 205, y: -80)
            VStack(alignment: .leading, spacing: 10) {
                Text("DISCOVER").font(.caption.weight(.black)).tracking(3).foregroundStyle(Color.waveBlue)
                Text("Find your\nnext wave").font(.system(size: 38, weight: .black, design: .rounded)).lineSpacing(-4)
                Text("Millions of tracks. No premium account needed.").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.72))
                Button { focused = true } label: {
                    Label("Start searching", systemImage: "play.fill").font(.headline).padding(.horizontal, 20).frame(height: 50)
                }.buttonStyle(.plain).foregroundStyle(.black).background(Color.waveBlue, in: Capsule())
            }.padding(26)
        }
        .frame(height: 330).clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 0.8) }
        .shadow(color: Color.waveBlue.opacity(0.16), radius: 30, y: 18)
    }

    private var featureStrip: some View {
        HStack(spacing: 10) {
            FeatureChip(icon: "sparkles", text: "Smart mixes")
            FeatureChip(icon: "text.quote", text: "Synced lyrics")
            FeatureChip(icon: "arrow.down", text: "Offline")
        }
    }

    private var sectionHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Songs").font(.system(size: 31, weight: .black, design: .rounded))
                Text("YouTube Music results").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(results.count)").font(.headline).foregroundStyle(Color.waveBlue).padding(.horizontal, 14).padding(.vertical, 8).waveGlass(radius: 16)
        }
    }

    private func search(showSpinner: Bool = true) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if showSpinner { focused = false }; searching = true
        defer { searching = false }
        do { results = lyricMode ? try await player.lyricSearch(term) : try await player.catalog.search(term) }
        catch { player.error = error.localizedDescription }
    }
}

private struct PlaylistLibraryView: View {
    @EnvironmentObject var player: WavePlayer
    @State private var link = ""
    @State private var importing = false
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                HStack { Text("Playlists").font(.system(size: 40, weight: .black, design: .rounded)); Spacer() }
                HStack {
                    TextField("Paste a public YouTube playlist link", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { Task { importing = true; await player.importPlaylist(link); importing = false; if player.error == nil { link = "" } } } label: {
                        if importing { ProgressView() } else { Image(systemName: "plus") }
                    }.disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importing)
                }.padding(16).waveGlass(radius: 22)
                ForEach(player.playlists) { playlist in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading) { Text(playlist.name).font(.title3.bold()); Text("\(playlist.tracks.count) songs").foregroundStyle(.secondary) }
                            Spacer()
                            Button { Task { await player.downloadPlaylist(playlist) } } label: { Label("Download all", systemImage: "arrow.down.circle.fill") }
                                .buttonStyle(.borderedProminent).tint(Color.waveBlue).foregroundStyle(.black)
                        }
                        ForEach(playlist.tracks.prefix(8)) { TrackCard(track: $0) }
                        if playlist.tracks.count > 8 { Text("+ \(playlist.tracks.count - 8) more songs").font(.caption).foregroundStyle(.secondary) }
                    }.padding(16).waveGlass(radius: 26)
                }
            }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 30)
        }.scrollIndicators(.hidden)
    }
}

private struct TrackCollectionView: View {
    @EnvironmentObject var player: WavePlayer
    let title: String, subtitle: String
    let tracks: [Track]
    var isOffline = false
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(title).font(.system(size: 42, weight: .black, design: .rounded))
                        Text(subtitle).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isOffline ? "arrow.down.circle.fill" : "music.note.list")
                        .font(.title).foregroundStyle(Color.waveBlue).frame(width: 56, height: 56).waveGlass(radius: 22)
                }.padding(.bottom, 8)
                if tracks.isEmpty {
                    VStack(spacing: 18) {
                        Image(systemName: isOffline ? "internaldrive" : "music.note.list").font(.system(size: 52)).foregroundStyle(Color.waveBlue)
                        Text(isOffline ? "Nothing downloaded yet" : "Your queue is clear").font(.title3.bold())
                        Text(isOffline ? "Download any search result to listen without internet." : "Add songs from search and they’ll wait here.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 70).padding(.horizontal, 30).waveGlass(radius: 30)
                } else { ForEach(tracks) { TrackCard(track: $0, canDelete: isOffline) } }
            }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 30)
        }.scrollIndicators(.hidden)
    }
}

private struct TrackCard: View {
    @EnvironmentObject var player: WavePlayer
    let track: Track
    var canDelete = false
    var body: some View {
        HStack(spacing: 14) {
            Button { Task { await player.play(track) } } label: {
                HStack(spacing: 14) {
                    Artwork(track: track)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.headline.weight(.bold)).lineLimit(2)
                        Text(track.artist).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }.buttonStyle(.plain)
            Spacer(minLength: 6)
            if let progress = player.downloadProgress[track.id] {
                VStack(spacing: 2) {
                    ProgressView(value: progress).tint(Color.waveBlue).frame(width: 42)
                    Text("\(Int(progress * 100))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Menu {
                Button { Task { await player.play(track) } } label: { Label("Play now", systemImage: "play.fill") }
                Button { player.queue.insert(track, at: 0) } label: { Label("Play next", systemImage: "text.insert") }
                Button { player.queue.append(track) } label: { Label("Add to queue", systemImage: "text.append") }
                if canDelete { Button(role: .destructive) { player.delete(track) } label: { Label("Delete download", systemImage: "trash") } }
                else { Button { Task { await player.download(track) } } label: { Label("Download", systemImage: "arrow.down.circle") } }
            } label: { Image(systemName: "ellipsis").font(.title3.bold()).frame(width: 42, height: 42).background(.white.opacity(0.06), in: Circle()) }
        }.padding(12).waveGlass(radius: 22, highlighted: player.current?.id == track.id)
    }
}

private struct FeatureChip: View {
    let icon: String, text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color.waveBlue)
            Text(text).font(.caption2.weight(.bold)).lineLimit(1)
        }.frame(maxWidth: .infinity).padding(.vertical, 16).waveGlass(radius: 20)
    }
}

private struct MiniPlayer: View {
    @EnvironmentObject var player: WavePlayer
    let track: Track
    let expand: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: expand) {
                    HStack(spacing: 12) {
                        Artwork(track: track, size: 54, radius: 15)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.headline.weight(.bold)).lineLimit(1)
                            Text(track.artist).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }.buttonStyle(.plain)
                Spacer()
                if player.loading { ProgressView().tint(Color.waveBlue) }
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title3.bold()).frame(width: 48, height: 48)
                        .background(Color.waveBlue, in: RoundedRectangle(cornerRadius: 17, style: .continuous)).foregroundStyle(.black)
                }
                Button { Task { await player.next() } } label: { Image(systemName: "forward.end.fill").frame(width: 34, height: 44) }
            }.padding(9)
            GeometryReader { proxy in Capsule().fill(Color.waveBlue).frame(width: proxy.size.width * progress, height: 3) }
                .frame(height: 3).padding(.horizontal, 12)
        }.waveGlass(radius: 24, highlighted: true)
    }
    private var progress: CGFloat { player.duration > 0 ? CGFloat(min(1, player.elapsed / player.duration)) : 0 }
}

private struct WaveTabBar: View {
    @Binding var selection: WaveTab
    var body: some View {
        HStack(spacing: 4) {
            ForEach(WaveTab.allCases, id: \.self) { item in
                Button { selection = item } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                        if selection == item { Text(item.rawValue).font(.subheadline.weight(.bold)) }
                    }.frame(maxWidth: .infinity).frame(height: 54)
                        .background(selection == item ? Color.waveBlue.opacity(0.27) : .clear, in: Capsule())
                        .foregroundStyle(selection == item ? Color.waveBlue : .secondary)
                }.buttonStyle(.plain)
            }
        }.padding(6).waveGlass(radius: 28)
    }
}

private struct ErrorPill: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.subheadline.weight(.semibold)).lineLimit(3)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }.padding(16).waveGlass(radius: 20)
    }
}

struct PlayerView: View {
    @EnvironmentObject var player: WavePlayer
    @Environment(\.dismiss) private var dismiss
    @State private var scrubPosition = 0.0
    @State private var isScrubbing = false
    @State private var showLyrics = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                if let track = player.current {
                    AsyncImage(url: track.artwork) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .blur(radius: 75).opacity(0.28).scaleEffect(1.25)
                }
                LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.72), .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                VStack(spacing: 14) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3.bold()).frame(width: 50, height: 50) }.waveGlass(radius: 20)
                    Spacer()
                    VStack(spacing: 2) { Text("NOW PLAYING").font(.caption.weight(.black)).tracking(2); Text("LASTWAVE").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Menu { Button("Clear queue", role: .destructive) { player.queue.removeAll() } } label: { Image(systemName: "ellipsis").font(.title3.bold()).frame(width: 50, height: 50) }.waveGlass(radius: 20)
                }
                VStack(spacing: 12) {
                    if let track = player.current {
                        Artwork(track: track, size: min(geometry.size.width - 48, geometry.size.height * (showLyrics ? 0.22 : 0.38), showLyrics ? 220 : 390), radius: 34)
                            .shadow(color: Color.waveBlue.opacity(0.20), radius: 38, y: 20)
                    }
                    if showLyrics { LyricsPanel() }
                }
                .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 7) {
                    Text(player.current?.title ?? "LastWave").font(.system(size: 31, weight: .black, design: .rounded)).lineLimit(2)
                    Text(player.current?.artist ?? "").font(.title3.weight(.semibold)).foregroundStyle(Color.waveBlue)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 8) {
                    Slider(value: $scrubPosition, in: 0...max(player.duration, 1), onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing { player.seek(scrubPosition) }
                    }).tint(Color.waveBlue).accessibilityLabel("Playback position")
                    HStack { Text(time(isScrubbing ? scrubPosition : player.elapsed)); Spacer(); Text("−" + time(max(0, player.duration - (isScrubbing ? scrubPosition : player.elapsed)))) }
                        .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                }
                HStack(spacing: 32) {
                    Button { player.seek(max(0, player.elapsed - 10)) } label: { Image(systemName: "gobackward.10").frame(width: 58, height: 58) }.waveGlass(radius: 23)
                    Button { player.toggle() } label: {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 30, weight: .bold)).frame(width: 82, height: 82)
                            .background(Color.waveBlue, in: RoundedRectangle(cornerRadius: 31, style: .continuous)).foregroundStyle(.black)
                    }
                    Button { Task { await player.next() } } label: { Image(systemName: "forward.end.fill").frame(width: 58, height: 58) }.waveGlass(radius: 23)
                }
                HStack(spacing: 10) {
                    Button { withAnimation(.spring(response: 0.35)) { showLyrics.toggle() } } label: {
                        Label(showLyrics ? "Hide lyrics" : "Lyrics", systemImage: "quote.bubble.fill").frame(maxWidth: .infinity).padding(.vertical, 15)
                    }.buttonStyle(.plain).waveGlass(radius: 20, highlighted: showLyrics)
                    Button { if let track = player.current { Task { await player.download(track) } } } label: { Image(systemName: "arrow.down.circle.fill").frame(width: 54, height: 50) }.waveGlass(radius: 20)
                }.font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, max(18, geometry.safeAreaInsets.leading + 18))
                .padding(.top, max(8, geometry.safeAreaInsets.top))
                .padding(.bottom, max(12, geometry.safeAreaInsets.bottom))
                .frame(maxWidth: .infinity)
            }
        }
        .tint(Color.waveBlue)
        .onAppear { scrubPosition = player.elapsed }
        .onChange(of: player.elapsed) { value in if !isScrubbing { scrubPosition = value } }
    }
    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private struct LyricsPanel: View {
    @EnvironmentObject var player: WavePlayer
    private var activeIndex: Int? {
        player.lyrics.lastIndex { ($0.time ?? .greatestFiniteMagnitude) <= player.elapsed }
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
              VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Lyrics").font(.title2.weight(.black))
                    Spacer()
                    if player.lyricsLoading { ProgressView().tint(Color.waveBlue) }
                }
                if !player.lyricsLoading && player.lyrics.isEmpty {
                    Text("Lyrics aren’t available for this track yet.").foregroundStyle(.secondary).padding(.vertical, 20)
                } else {
                    ForEach(Array(player.lyrics.enumerated()), id: \.element.id) { index, line in
                        Button { if let time = line.time { player.seek(time) } } label: {
                            Text(line.text)
                                .font(.title3.weight(index == activeIndex ? .bold : .semibold))
                                .foregroundStyle(index == activeIndex ? Color.waveBlue : .white)
                                .opacity(lineOpacity(index))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                        }.buttonStyle(.plain).id(index)
                    }
                }
              }
              .padding(20)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.center)
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.10),
                .init(color: .black, location: 0.88), .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom))
            .waveGlass(radius: 26)
            .onChange(of: activeIndex) { index in
                guard let index else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }
    private func lineOpacity(_ index: Int) -> Double {
        guard let activeIndex else { return 0.48 }
        if index == activeIndex { return 1 }
        if index < activeIndex { return max(0.10, 0.34 - Double(activeIndex - index) * 0.06) }
        return max(0.32, 0.64 - Double(index - activeIndex) * 0.04)
    }
}
