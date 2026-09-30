import SwiftUI
import PhotosUI
import UIKit
import FirebaseCore
import GoogleSignIn

@main struct CapyFlowApp: App {
    @StateObject private var player = WavePlayer()
    @StateObject private var auth: AuthSession
    init() {
        FirebaseApp.configure()
        _auth = StateObject(wrappedValue: AuthSession())
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(auth)
                .preferredColorScheme(.dark)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
    }
}

private enum WaveTab: String, CaseIterable {
    case home = "Home", playlists = "Playlists"
    var icon: String {
        switch self { case .home: "house.fill"; case .playlists: "rectangle.stack.fill" }
    }
}

struct RootView: View {
    @EnvironmentObject var player: WavePlayer
    @State private var tab: WaveTab = .home
    @State private var showPlayer = false
    @State private var searchQuery = ""
    @State private var searchResults: [Track] = []
    @State private var albumResults: [Album] = []
    @State private var searching = false
    @State private var searchMode: SearchMode = .songs
    @State private var lastSearchSignature = ""
    var body: some View {
        ZStack {
            WaveBackdrop()
            Group {
                switch tab {
                case .home: SearchHomeView(query: $searchQuery, results: $searchResults, albums: $albumResults, searching: $searching, mode: $searchMode, lastSearchSignature: $lastSearchSignature)
                case .playlists: PlaylistLibraryView()
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
    @EnvironmentObject var auth: AuthSession
    @Binding var query: String
    @Binding var results: [Track]
    @Binding var albums: [Album]
    @Binding var searching: Bool
    @Binding var mode: SearchMode
    @Binding var lastSearchSignature: String
    @FocusState private var focused: Bool
    @State private var showAccount = false
    var body: some View {
      NavigationStack {
        ScrollView {
            LazyVStack(spacing: 18) {
                header
                searchBar
                Picker("Search type", selection: $mode) {
                    ForEach(SearchMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if searching {
                    HStack(spacing: 12) { ProgressView(); Text("Searching YouTube Music…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity).padding(28).waveGlass(radius: 24)
                } else if results.isEmpty && albums.isEmpty {
                    discoveryHero
                    featureStrip
                } else if mode == .albums {
                    albumSectionHeader
                    ForEach(albums) { album in
                        NavigationLink { AlbumDetailView(album: album) } label: { AlbumResultRow(album: album) }
                            .buttonStyle(.plain)
                    }
                } else {
                    sectionHeader
                    ForEach(results) { TrackCard(track: $0) }
                }
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 30)
        }.scrollIndicators(.hidden).toolbar(.hidden, for: .navigationBar)
        .task(id: query) {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let signature = mode.rawValue + "|" + term
            guard term.count >= 2, signature != lastSearchSignature else { return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await search(showSpinner: false)
        }
        .onChange(of: mode) { _ in
            if query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 { Task { await search(showSpinner: false) } }
        }
      }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("CapyFlow").font(.system(size: 42, weight: .black, design: .rounded))
                Text("Your music. Your current.").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showAccount = true } label: {
                Group {
                    if let url = auth.user?.photoURL {
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle") }
                    } else {
                        Image(systemName: "person.crop.circle")
                    }
                }
                .font(.title2.bold()).frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain).waveGlass(radius: 22)
            Button { focused = true } label: { Image(systemName: "magnifyingglass").font(.title2.bold()).frame(width: 54, height: 54) }
                .buttonStyle(.plain).waveGlass(radius: 22)
        }
        .sheet(isPresented: $showAccount) { AccountSheet() }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.waveBlue)
            TextField(mode == .albums ? "Search albums and artists" : "Search songs and artists", text: $query)
                .focused($focused).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                .onSubmit { Task { await search() } }
            if !query.isEmpty {
                Button { query = ""; results = []; albums = []; lastSearchSignature = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
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
        do {
            switch mode {
            case .songs:
                results = try await player.catalog.search(term); albums = []; player.prewarm(results)
            case .albums:
                albums = try await player.catalog.searchAlbums(term); results = []
            }
            lastSearchSignature = mode.rawValue + "|" + term
        }
        catch {
            let code = (error as NSError).code
            if !Task.isCancelled && code != NSURLErrorCancelled { player.error = error.localizedDescription }
        }
    }

    private var albumSectionHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Albums").font(.system(size: 31, weight: .black, design: .rounded))
                Text("Tap an album to see every song").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(albums.count)").font(.headline).foregroundStyle(Color.waveBlue).padding(.horizontal, 14).padding(.vertical, 8).waveGlass(radius: 16)
        }
    }
}

private enum SearchMode: String, CaseIterable, Identifiable {
    case songs = "Songs", albums = "Albums"
    var id: String { rawValue }
}

private struct AccountSheet: View {
    @EnvironmentObject var auth: AuthSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                WaveBackdrop()
                VStack(spacing: 20) {
                    Group {
                        if let url = auth.user?.photoURL {
                            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { ProgressView() }
                        } else {
                            Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(Color.waveBlue)
                        }
                    }
                    .frame(width: 104, height: 104).clipShape(Circle())
                    if let user = auth.user {
                        VStack(spacing: 5) {
                            Text(user.displayName ?? "CapyFlow listener").font(.title2.bold())
                            Text(user.email ?? "Signed in with Google").foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) { auth.signOut() } label: {
                            Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                                .frame(maxWidth: .infinity).frame(height: 52).contentShape(Rectangle())
                        }.buttonStyle(.bordered)
                    } else {
                        VStack(spacing: 6) {
                            Text("Sign in to CapyFlow").font(.title2.bold())
                            Text("Use your Google account now; shared profiles and playlists can build on this account next.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        Button { Task { await auth.signInWithGoogle() } } label: {
                            Group { if auth.working { ProgressView() } else { Label("Continue with Google", systemImage: "person.badge.key.fill") } }
                                .frame(maxWidth: .infinity).frame(height: 52).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderedProminent).tint(Color.waveBlue).foregroundStyle(.black).disabled(auth.working)
                    }
                    if let error = auth.error {
                        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    Spacer()
                }.padding(28)
            }
            .navigationTitle("Account").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

private struct AlbumResultRow: View {
    let album: Album
    var body: some View {
        HStack(spacing: 15) {
            AlbumArtwork(album: album, size: 84, radius: 16)
            VStack(alignment: .leading, spacing: 5) {
                Text(album.title).font(.headline.weight(.bold)).lineLimit(2)
                Text([album.artist, album.year].compactMap { $0 }.joined(separator: " • "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text("Album").font(.caption.weight(.bold)).foregroundStyle(Color.waveBlue)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding(12).contentShape(Rectangle()).waveGlass(radius: 22)
    }
}

private struct AlbumDetailView: View {
    @EnvironmentObject var player: WavePlayer
    let album: Album
    @State private var tracks: [Track] = []
    @State private var loading = true
    private var downloadableAlbum: ImportedPlaylist { ImportedPlaylist(id: "album:" + album.id, name: album.title, tracks: tracks) }
    var body: some View {
        ZStack {
            WaveBackdrop()
            ScrollView {
                LazyVStack(spacing: 14) {
                    AlbumArtwork(album: album, size: 260, radius: 24)
                        .shadow(color: Color.waveBlue.opacity(0.18), radius: 30, y: 16)
                    VStack(spacing: 5) {
                        Text(album.title).font(.system(size: 32, weight: .black, design: .rounded)).multilineTextAlignment(.center)
                        Text(album.artist).font(.title3.weight(.semibold)).foregroundStyle(Color.waveBlue)
                        Text(["Album", album.year].compactMap { $0 }.joined(separator: " • ")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if loading {
                        HStack { ProgressView(); Text("Loading album…") }.padding(30)
                    } else {
                        HStack(spacing: 10) {
                            Button { player.queue = Array(tracks.dropFirst()); if let first = tracks.first { Task { await player.play(first) } } } label: {
                                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity).frame(height: 50).contentShape(Rectangle())
                            }.buttonStyle(.borderedProminent).tint(Color.waveBlue).foregroundStyle(.black).disabled(tracks.isEmpty)
                            Button { Task { await player.downloadPlaylist(downloadableAlbum) } } label: {
                                Image(systemName: player.isPlaylistDownloaded(downloadableAlbum) ? "arrow.down.circle.fill" : "arrow.down.circle").frame(width: 52, height: 50)
                            }.buttonStyle(.bordered).disabled(tracks.isEmpty || player.downloadingPlaylists.contains(downloadableAlbum.id))
                            Button { player.saveAlbum(album, tracks: tracks) } label: {
                                Image(systemName: "plus.rectangle.on.folder").frame(width: 52, height: 50)
                            }.buttonStyle(.bordered).disabled(tracks.isEmpty)
                        }
                        ForEach(tracks) { TrackCard(track: $0) }
                    }
                }.padding(18).padding(.bottom, 120)
            }.scrollIndicators(.hidden)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { tracks = try await player.catalog.albumTracks(for: album); player.prewarm(tracks) }
            catch { player.error = error.localizedDescription }
            loading = false
        }
    }
}

private struct PlaylistLibraryView: View {
    @EnvironmentObject var player: WavePlayer
    @State private var showCreator = false
    @State private var playlistToRename: ImportedPlaylist?
    var body: some View {
      NavigationStack {
       ScrollView {
            LazyVStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Library").font(.system(size: 40, weight: .black, design: .rounded))
                        Text("Playlists you made and imported").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showCreator = true } label: {
                        Image(systemName: "plus").font(.title2.bold()).frame(width: 54, height: 54).contentShape(Rectangle())
                    }.buttonStyle(.plain).waveGlass(radius: 22)
                }.padding(.bottom, 4)
                HStack(spacing: 8) {
                    Label("Playlists", systemImage: "rectangle.stack.fill")
                    Spacer()
                    Text("\(player.playlists.count)").foregroundStyle(.secondary)
                }.font(.subheadline.weight(.bold)).padding(.horizontal, 16).frame(height: 44).waveGlass(radius: 20)
                if player.playlists.isEmpty {
                    VStack(spacing: 15) {
                        Image(systemName: "music.note.list").font(.system(size: 46)).foregroundStyle(Color.waveBlue)
                        Text("Make your first playlist").font(.title3.bold())
                        Text("Create one here, then add songs from any search result.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Create playlist") { showCreator = true }.buttonStyle(.borderedProminent).tint(Color.waveBlue).foregroundStyle(.black)
                    }.frame(maxWidth: .infinity).padding(34).waveGlass(radius: 28)
                } else {
                    ForEach(player.playlists) { playlist in
                        NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: { PlaylistLibraryRow(playlist: playlist) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { playlistToRename = playlist } label: { Label("Rename", systemImage: "pencil") }
                                Button(role: .destructive) { player.deletePlaylist(playlist.id) } label: { Label("Delete playlist", systemImage: "trash") }
                            }
                    }
                }
            }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 30)
        }.scrollIndicators(.hidden)
       .toolbar(.hidden, for: .navigationBar)
       .sheet(isPresented: $showCreator) { NewPlaylistSheet() }
       .sheet(item: $playlistToRename) { RenamePlaylistSheet(playlistID: $0.id, currentName: $0.name) }
      }
    }
}

private struct NewPlaylistSheet: View {
    @EnvironmentObject var player: WavePlayer
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var link = ""
    @State private var importing = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?
    var body: some View {
        NavigationStack {
            ZStack {
                WaveBackdrop()
                ScrollView {
                    VStack(spacing: 18) {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Group {
                                if let photoData, let image = UIImage(data: photoData) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    VStack(spacing: 7) {
                                        Image(systemName: "photo.badge.plus").font(.system(size: 35))
                                        Text("Add photo").font(.caption.bold())
                                    }.foregroundStyle(Color.waveBlue)
                                }
                            }
                            .frame(width: 150, height: 150).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                            .waveGlass(radius: 30)
                        }.buttonStyle(.plain)
                        Text("Give your playlist a name").font(.title2.bold())
                        TextField("Playlist name", text: $name).font(.title3.weight(.semibold)).multilineTextAlignment(.center).padding(16).waveGlass(radius: 20)
                        Button {
                            do { try player.createPlaylist(named: name, artworkData: photoData); dismiss() }
                            catch { player.error = error.localizedDescription }
                        } label: {
                            Text("Create playlist").frame(maxWidth: .infinity).frame(height: 50).contentShape(Rectangle())
                        }.buttonStyle(.borderedProminent).tint(Color.waveBlue).foregroundStyle(.black)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        HStack { Rectangle().frame(height: 1); Text("OR IMPORT").font(.caption.bold()); Rectangle().frame(height: 1) }.foregroundStyle(.secondary.opacity(0.5)).padding(.vertical, 8)
                        Text("Public YouTube playlist").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        TextField("Paste playlist link", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().padding(16).waveGlass(radius: 20)
                        Button {
                            Task {
                                importing = true
                                await player.importPlaylist(link)
                                importing = false
                                if player.error == nil { dismiss() }
                            }
                        } label: {
                            Group { if importing { ProgressView() } else { Label("Import playlist", systemImage: "square.and.arrow.down") } }
                                .frame(maxWidth: .infinity).frame(height: 50).contentShape(Rectangle())
                        }.buttonStyle(.bordered).disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importing)
                    }.padding(24)
                }
            }
            .navigationTitle("New Playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: selectedPhoto) { item in
                guard let item else { return }
                Task { photoData = try? await item.loadTransferable(type: Data.self) }
            }
        }
        .presentationDetents([.large])
    }
}

private struct PlaylistLibraryRow: View {
    @EnvironmentObject var player: WavePlayer
    let playlist: ImportedPlaylist
    var body: some View {
        HStack(spacing: 14) {
            PlaylistCover(playlist: playlist, size: 72, radius: 14)
            VStack(alignment: .leading, spacing: 5) {
                Text(playlist.name).font(.title3.bold()).lineLimit(1)
                Text("\(playlist.tracks.count) songs").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if player.isPlaylistDownloaded(playlist) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.waveBlue) }
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }.padding(12).contentShape(Rectangle()).waveGlass(radius: 24)
    }
}

private struct PlaylistCover: View {
    @EnvironmentObject var player: WavePlayer
    let playlist: ImportedPlaylist
    var size: CGFloat
    var radius: CGFloat
    var body: some View {
        Group {
            if let customURL = player.playlistArtworkURL(for: playlist.id), let image = UIImage(contentsOfFile: customURL.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if playlist.tracks.isEmpty {
                ZStack { Color.waveBlue.opacity(0.18); Image(systemName: "music.note.list").font(.title).foregroundStyle(Color.waveBlue) }
            } else if playlist.tracks.count == 1, let first = playlist.tracks.first {
                Artwork(track: first, size: size, radius: 0)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
                    ForEach(Array(playlist.tracks.prefix(4))) { track in
                        Artwork(track: track, size: (size - 1) / 2, radius: 0)
                    }
                }
            }
        }
        .frame(width: size, height: size).clipped()
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct PlaylistDetailView: View {
    @EnvironmentObject var player: WavePlayer
    @Environment(\.dismiss) private var dismiss
    let playlistID: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showRename = false
    private var playlist: ImportedPlaylist? { player.playlists.first { $0.id == playlistID } }
    var body: some View {
        ZStack {
            WaveBackdrop()
            ScrollView {
                LazyVStack(spacing: 14) {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 48, height: 48).contentShape(Rectangle()) }.waveGlass(radius: 19)
                        Spacer()
                        if let playlist {
                            Menu {
                                Button { showRename = true } label: { Label("Rename playlist", systemImage: "pencil") }
                                Button(role: .destructive) { player.deletePlaylist(playlist.id); dismiss() } label: { Label("Delete playlist", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 48, height: 48).contentShape(Rectangle())
                            }.waveGlass(radius: 19)
                        }
                    }
                    if let playlist {
                        PlaylistCover(playlist: playlist, size: 230, radius: 22)
                            .shadow(color: Color.waveBlue.opacity(0.16), radius: 28, y: 14)
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Choose playlist photo", systemImage: "photo.badge.plus").frame(height: 44).padding(.horizontal, 16).contentShape(Rectangle())
                        }.buttonStyle(.bordered)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(playlist.name).font(.system(size: 38, weight: .black, design: .rounded))
                            Text("\(playlist.tracks.count) songs").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Button { player.queue = Array(playlist.tracks.dropFirst()); if let first = playlist.tracks.first { Task { await player.play(first) } } } label: {
                                Label("Play all", systemImage: "play.fill").frame(maxWidth: .infinity).frame(height: 50).contentShape(Rectangle())
                            }.buttonStyle(.borderedProminent).tint(Color.waveBlue).foregroundStyle(.black)
                            Button { Task { await player.downloadPlaylist(playlist) } } label: {
                                Label(player.playlistDownloadProgress[playlist.id].map { "Downloading \($0)" } ?? "Download all", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity).frame(height: 50).contentShape(Rectangle())
                            }.buttonStyle(.bordered).disabled(player.downloadingPlaylists.contains(playlist.id))
                        }
                        ForEach(playlist.tracks) { TrackCard(track: $0) }
                    }
                }.padding(18).padding(.bottom, 120)
            }.scrollIndicators(.hidden)
        }.navigationBarBackButtonHidden()
        .sheet(isPresented: $showRename) {
            if let playlist { RenamePlaylistSheet(playlistID: playlist.id, currentName: playlist.name) }
        }
        .task { if let playlist { player.prewarm(playlist.tracks) } }
        .onChange(of: selectedPhoto) { item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                do { try player.setPlaylistArtwork(data, for: playlistID) }
                catch { player.error = error.localizedDescription }
            }
        }
    }
}

private struct RenamePlaylistSheet: View {
    @EnvironmentObject var player: WavePlayer
    @Environment(\.dismiss) private var dismiss
    let playlistID: String
    @State private var name: String
    init(playlistID: String, currentName: String) {
        self.playlistID = playlistID
        _name = State(initialValue: currentName)
    }
    var body: some View {
        NavigationStack {
            ZStack {
                WaveBackdrop()
                VStack(spacing: 18) {
                    TextField("Playlist name", text: $name)
                        .font(.title3.weight(.semibold)).padding(16).waveGlass(radius: 20)
                    Button {
                        player.renamePlaylist(playlistID, to: name)
                        dismiss()
                    } label: {
                        Text("Save name").frame(maxWidth: .infinity).frame(height: 50).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent).tint(Color.waveBlue).foregroundStyle(.black)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }.padding(24)
            }
            .navigationTitle("Rename Playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.medium])
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
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Spacer(minLength: 6)
            if let progress = player.downloadProgress[track.id] {
                VStack(spacing: 2) {
                    ProgressView(value: progress).tint(Color.waveBlue).frame(width: 42)
                    Text("\(Int(progress * 100))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            } else if player.isDownloaded(track) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.waveBlue).accessibilityLabel("Downloaded")
            }
            Menu {
                Button { Task { await player.play(track) } } label: { Label("Play now", systemImage: "play.fill") }
                Button { player.queue.insert(track, at: 0) } label: { Label("Play next", systemImage: "text.insert") }
                Button { player.queue.append(track) } label: { Label("Add to queue", systemImage: "text.append") }
                if !player.playlists.isEmpty {
                    Menu("Add to playlist", systemImage: "rectangle.stack.badge.plus") {
                        ForEach(player.playlists) { playlist in
                            Button(playlist.name) { player.add(track, to: playlist.id) }
                        }
                    }
                }
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
                    }.contentShape(Rectangle())
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
        GeometryReader { geometry in
            HStack(spacing: 4) {
                ForEach(WaveTab.allCases, id: \.self) { item in
                    Button { selection = item } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.icon)
                            if selection == item { Text(item.rawValue).font(.caption.weight(.bold)).lineLimit(1) }
                        }.frame(maxWidth: .infinity).frame(height: 54).contentShape(Rectangle())
                            .background(selection == item ? Color.waveBlue.opacity(0.27) : .clear, in: Capsule())
                            .foregroundStyle(selection == item ? Color.waveBlue : .secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(6).waveGlass(radius: 28)
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { value in
                let count = WaveTab.allCases.count
                let x = min(max(0, value.location.x - 6), max(1, geometry.size.width - 12))
                let index = min(count - 1, Int(x / max(1, (geometry.size.width - 12) / CGFloat(count))))
                withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.86)) { selection = WaveTab.allCases[index] }
            })
        }.frame(height: 66)
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
    @State private var showQueue = false
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
                ScrollView {
                  VStack(spacing: 14) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3.bold()).frame(width: 50, height: 50) }.waveGlass(radius: 20)
                    Spacer()
                    VStack(spacing: 2) { Text("NOW PLAYING").font(.caption.weight(.black)).tracking(2); Text("CAPYFLOW").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Menu {
                        Picker("Audio quality", selection: $player.audioQuality) {
                            ForEach(AudioQuality.allCases) { quality in Text(quality.rawValue).tag(quality) }
                        }
                        Toggle("Autoplay", isOn: $player.autoplayEnabled)
                        Divider()
                        Button("Clear queue", role: .destructive) { player.queue.removeAll() }
                    } label: { Image(systemName: "ellipsis").font(.title3.bold()).frame(width: 50, height: 50) }.waveGlass(radius: 20)
                }
                if let track = player.current {
                        Artwork(track: track, size: min(geometry.size.width - 48, geometry.size.height * 0.38, 390), radius: 34)
                            .shadow(color: Color.waveBlue.opacity(0.20), radius: 38, y: 20)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(player.current?.title ?? "CapyFlow").font(.system(size: 31, weight: .black, design: .rounded)).lineLimit(2)
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
                    Button { Task { await player.previous() } } label: { Image(systemName: "backward.end.fill").frame(width: 58, height: 58) }.waveGlass(radius: 23)
                    Button { player.toggle() } label: {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 30, weight: .bold)).frame(width: 82, height: 82)
                            .background(Color.waveBlue, in: RoundedRectangle(cornerRadius: 31, style: .continuous)).foregroundStyle(.black)
                    }
                    Button { Task { await player.next() } } label: { Image(systemName: "forward.end.fill").frame(width: 58, height: 58) }.waveGlass(radius: 23)
                }
                HStack(spacing: 10) {
                    Button { withAnimation(.spring(response: 0.35)) { showLyrics.toggle() } } label: {
                        Label(showLyrics ? "Hide lyrics" : "Lyrics", systemImage: "quote.bubble.fill")
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .waveGlass(radius: 20, highlighted: showLyrics)
                    }.buttonStyle(.plain)
                    Button { if let track = player.current { Task { await player.download(track) } } } label: { Image(systemName: "arrow.down.circle.fill").frame(width: 54, height: 50) }.waveGlass(radius: 20)
                    Button { showQueue = true } label: { Image(systemName: "list.bullet").frame(width: 54, height: 50) }.waveGlass(radius: 20)
                }.font(.subheadline.weight(.bold))
                if showLyrics { LyricsPanel().id(player.current?.id).frame(height: min(geometry.size.height * 0.55, 420)) }
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, max(18, geometry.safeAreaInsets.leading + 18))
                .padding(.top, max(8, geometry.safeAreaInsets.top))
                .padding(.bottom, max(12, geometry.safeAreaInsets.bottom))
                .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
        .tint(Color.waveBlue)
        .onAppear { scrubPosition = player.elapsed }
        .onChange(of: player.elapsed) { value in if !isScrubbing { scrubPosition = value } }
        .sheet(isPresented: $showQueue) { QueueSheet().presentationDetents([.medium, .large]) }
    }
    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private struct QueueSheet: View {
    @EnvironmentObject var player: WavePlayer
    var body: some View {
        NavigationStack {
            List {
                if let current = player.current {
                    Section("Now playing") { TrackCard(track: current) }
                }
                Section("Next") {
                    if player.autoplayLoading { HStack { ProgressView(); Text("Finding related songs…") } }
                    else if player.queue.isEmpty { Text(player.autoplayEnabled ? "Related songs will play automatically." : "The queue is empty.").foregroundStyle(.secondary) }
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                        TrackCard(track: track)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { player.removeFromQueue(at: index) } label: { Label("Remove", systemImage: "trash") }
                                if index < player.queue.count - 1 {
                                    Button { player.moveQueueItem(from: index, to: index + 1) } label: { Label("Move down", systemImage: "arrow.down") }.tint(.indigo)
                                }
                                if index > 0 {
                                    Button { player.moveQueueItem(from: index, to: index - 1) } label: { Label("Move up", systemImage: "arrow.up") }.tint(Color.waveBlue)
                                }
                            }
                    }
                }
                Section {
                    Toggle(isOn: $player.autoplayEnabled) { Label("Autoplay related songs", systemImage: "infinity") }
                } footer: {
                    Text("When your queue ends, CapyFlow finds more music based on the current artist.")
                }
            }
            .scrollContentBackground(.hidden).background(WaveBackdrop())
            .navigationTitle("Queue")
        }
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
