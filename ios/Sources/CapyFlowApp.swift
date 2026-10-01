import SwiftUI
import PhotosUI
import UIKit
import FirebaseCore
import GoogleSignIn

@main struct CapyFlowApp: App {
    @StateObject private var player = WavePlayer()
    @StateObject private var auth: AuthSession
    @StateObject private var social: SocialStore
    init() {
        FirebaseApp.configure()
        _auth = StateObject(wrappedValue: AuthSession())
        _social = StateObject(wrappedValue: SocialStore())
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(auth)
                .environmentObject(social)
                .preferredColorScheme(.dark)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
    }
}

private enum WaveTab: String, CaseIterable {
    case home = "Home", search = "Search", library = "Library"
    var icon: String {
        switch self {
        case .home: "house.fill"
        case .search: "magnifyingglass"
        case .library: "square.stack.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var player: WavePlayer
    @EnvironmentObject var auth: AuthSession
    @EnvironmentObject var social: SocialStore
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
            HomeDashboardView(selection: $tab)
                .opacity(tab == .home ? 1 : 0)
                .allowsHitTesting(tab == .home)
                .accessibilityHidden(tab != .home)
            SearchHomeView(query: $searchQuery, results: $searchResults, albums: $albumResults, searching: $searching, mode: $searchMode, lastSearchSignature: $lastSearchSignature)
                .opacity(tab == .search ? 1 : 0)
                .allowsHitTesting(tab == .search)
                .accessibilityHidden(tab != .search)
            PlaylistLibraryView()
                .opacity(tab == .library ? 1 : 0)
                .allowsHitTesting(tab == .library)
                .accessibilityHidden(tab != .library)
        }
        .safeAreaInset(edge: .bottom, spacing: 5) {
            CapyDock(selection: $tab) { showPlayer = true }
                .padding(.horizontal, 12)
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(30)
                .presentationBackground(.clear)
        }
        .overlay(alignment: .top) {
            if let message = player.error {
                ErrorPill(message: message) { player.error = nil }
                    .padding(.horizontal, 20).padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity)).zIndex(20)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: player.error)
        .task(id: auth.user?.uid) { social.bind(to: auth.user) }
    }
}

private struct HomeDashboardView: View {
    @EnvironmentObject private var player: WavePlayer
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var social: SocialStore
    @Binding var selection: WaveTab
    @State private var showAccount = false

    var body: some View {
        NavigationStack {
            ZStack {
                CapyAmbientBackdrop(
                    seed: player.current?.id ?? "capyflow-home",
                    artworkURL: player.current?.artwork,
                    intensity: player.current == nil ? 0.7 : 1
                )
                ScrollView {
                    CapyScreenContainer {
                        LazyVStack(alignment: .leading, spacing: CapySpacing.section) {
                            homeHeader
                            flowHero
                            if !player.recentTracks.isEmpty { recentlyPlayed }
                            libraryShelf
                            if auth.user != nil { friendsShelf }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 30)
                    }
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAccount) { AccountSheet() }
        }
    }

    private var homeHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting).font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                Text("CapyFlow").font(.capyHero)
            }
            Spacer()
            Button { showAccount = true; CapyHaptics.selection() } label: {
                Group {
                    if let url = auth.user?.photoURL {
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.fill") }
                    } else {
                        Image(systemName: "person.fill")
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .waveGlass(radius: 24)
            .accessibilityLabel("Account and friends")
        }
    }

    @ViewBuilder private var flowHero: some View {
        if let track = player.current {
            HStack(spacing: 18) {
                Artwork(track: track, size: 132, radius: 24)
                VStack(alignment: .leading, spacing: 8) {
                    Text(player.playing ? "IN YOUR FLOW" : "READY WHEN YOU ARE")
                        .font(.caption2.weight(.black)).tracking(1.8).foregroundStyle(CapyColor.accent)
                    Text(track.title).font(.capyTitle).lineLimit(2)
                    Text(track.artist).font(.capyBody).foregroundStyle(CapyColor.secondaryText).lineLimit(1)
                    Button { player.toggle(); CapyHaptics.impact(.medium) } label: {
                        Label(player.playing ? "Pause" : "Keep listening", systemImage: player.playing ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(CapyPrimaryButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .waveSurface(radius: 28, highlighted: true)
        } else {
            ZStack(alignment: .bottomLeading) {
                CapyAmbientBackdrop(seed: "find-your-flow", intensity: 1.25)
                VStack(alignment: .leading, spacing: 10) {
                    Text("YOUR NEXT FAVORITE").font(.caption.weight(.black)).tracking(2).foregroundStyle(CapyColor.accent)
                    Text("Find your flow.").font(.system(size: 34, weight: .black, design: .rounded))
                    Text("Search songs and complete albums, then keep them together in your library.")
                        .font(.capyBody).foregroundStyle(CapyColor.secondaryText)
                    Button { selection = .search; CapyHaptics.selection() } label: {
                        Label("Explore music", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(CapyPrimaryButtonStyle())
                    .frame(maxWidth: 220)
                }
                .padding(24)
            }
            .frame(height: 250)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(CapyColor.surfaceStroke) }
        }
    }

    private var recentlyPlayed: some View {
        VStack(alignment: .leading, spacing: 14) {
            CapySectionHeader("Recently played", subtitle: "Pick up without searching again")
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(player.recentTracks.prefix(12)) { track in
                        Button { Task { await player.play(track) }; CapyHaptics.selection() } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Artwork(track: track, size: 142, radius: 20)
                                Text(track.title).font(.capyCallout).lineLimit(1)
                                Text(track.artist).font(.capyCaption).foregroundStyle(CapyColor.secondaryText).lineLimit(1)
                            }
                            .frame(width: 142, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var libraryShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            CapySectionHeader("Made yours", subtitle: "Playlists and music saved on this iPhone") {
                Button("See all") { selection = .library; CapyHaptics.selection() }
                    .font(.capyCaption).foregroundStyle(CapyColor.accent)
            }
            HStack(spacing: 12) {
                Button { selection = .library; CapyHaptics.selection() } label: {
                    quickTile(icon: "rectangle.stack.fill", value: "\(player.playlists.count)", label: "Playlists")
                }.buttonStyle(.plain)
                Button { selection = .library; CapyHaptics.selection() } label: {
                    quickTile(icon: "arrow.down.circle.fill", value: "\(player.downloads.count)", label: "Downloaded")
                }.buttonStyle(.plain)
            }
        }
    }

    private var friendsShelf: some View {
        NavigationLink { SocialHubView() } label: {
            HStack(spacing: 14) {
                Image(systemName: social.connectionState == .ready ? "person.2.fill" : social.connectionState.systemImage)
                    .font(.title2).foregroundStyle(CapyColor.accent).frame(width: 48, height: 48)
                    .background(CapyColor.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Friends & shared playlists").font(.capySection)
                    Text(social.connectionState.detail).font(.capyCaption).foregroundStyle(CapyColor.secondaryText).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(CapyColor.tertiaryText)
            }
            .padding(16).contentShape(Rectangle()).waveSurface(radius: 22)
        }
        .buttonStyle(.plain)
    }

    private func quickTile(icon: String, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(CapyColor.accent)
            Text(value).font(.title.bold().monospacedDigit())
            Text(label).font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17).waveSurface(radius: 22)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "GOOD MORNING" }
        if hour < 18 { return "GOOD AFTERNOON" }
        return "GOOD EVENING"
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
                    if !artistSuggestions.isEmpty { artistSection }
                    if !matchingPlaylists.isEmpty { localPlaylistSection }
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
            CapyScreenTitle(title: "Search", subtitle: "Songs, artists, albums and your playlists")
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
            CapyAmbientBackdrop(seed: "capyflow-search", intensity: 1.15)
            Image(systemName: "waveform.path.ecg.rectangle.fill").font(.system(size: 90, weight: .thin)).foregroundStyle(.white.opacity(0.12)).offset(x: 205, y: -70)
            VStack(alignment: .leading, spacing: 10) {
                Text("DISCOVER").font(.caption.weight(.black)).tracking(3).foregroundStyle(CapyColor.accent)
                Text("Music, not menus.").font(.system(size: 34, weight: .black, design: .rounded))
                Text("Search a title or artist. Switch to Albums to open the complete track list.").font(.capyBody).foregroundStyle(CapyColor.secondaryText)
                Button { focused = true } label: {
                    Label("Start searching", systemImage: "magnifyingglass")
                }.buttonStyle(CapyPrimaryButtonStyle()).frame(maxWidth: 210)
            }.padding(26)
        }
        .frame(height: 270).clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(CapyColor.surfaceStroke, lineWidth: 0.8) }
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

    private var artistSuggestions: [String] {
        var seen = Set<String>()
        return results.compactMap { track in
            let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, seen.insert(artist.lowercased()).inserted else { return nil }
            return artist
        }.prefix(8).map { $0 }
    }

    private var matchingPlaylists: [ImportedPlaylist] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return [] }
        return player.playlists.filter { $0.name.localizedCaseInsensitiveContains(term) }.prefix(4).map { $0 }
    }

    private var artistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapySectionHeader("Artists", subtitle: "Related to your search")
            ScrollView(.horizontal) {
                LazyHStack(spacing: 9) {
                    ForEach(artistSuggestions, id: \.self) { artist in
                        NavigationLink { ArtistDetailView(artist: artist) } label: {
                            Label(artist, systemImage: "person.wave.2.fill")
                                .font(.capyCaption).padding(.horizontal, 15).frame(height: 44)
                                .background(CapyColor.surfaceStrong, in: Capsule()).contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }

    private var localPlaylistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapySectionHeader("Your playlists", subtitle: "Matches in your library")
            ForEach(matchingPlaylists) { playlist in
                NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                    PlaylistLibraryRow(playlist: playlist)
                }.buttonStyle(.plain)
            }
        }
    }
}

private enum SearchMode: String, CaseIterable, Identifiable {
    case songs = "Songs", albums = "Albums"
    var id: String { rawValue }
}

private struct AccountSheet: View {
    @EnvironmentObject var auth: AuthSession
    @EnvironmentObject var social: SocialStore
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
                            if let profile = social.profile {
                                Text("@" + profile.username).font(.subheadline.weight(.semibold)).foregroundStyle(Color.waveBlue)
                                Text("\(social.followerCount) followers  •  \(social.followingCount) following")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(user.email ?? "Signed in with Google").foregroundStyle(.secondary)
                        }
                        NavigationLink {
                            SocialHubView()
                        } label: {
                            Label("Profile, friends & shared playlists", systemImage: "person.2.fill")
                                .frame(maxWidth: .infinity).frame(height: 52).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderedProminent).tint(Color.waveBlue).foregroundStyle(.black)
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
                    NavigationLink {
                        BackendSettingsView()
                    } label: {
                        Label("Streaming server", systemImage: "bolt.horizontal.circle.fill")
                            .frame(maxWidth: .infinity).frame(height: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    if let error = auth.error {
                        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    if auth.user != nil, social.connectionState != .ready {
                        HStack(spacing: 10) {
                            Image(systemName: social.connectionState.systemImage).foregroundStyle(CapyColor.warning)
                            Text(social.error ?? social.connectionState.detail).font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                            Spacer()
                            if social.connectionState.canRetry {
                                Button("Retry") { social.retryConnection() }.font(.capyCaption).foregroundStyle(CapyColor.accent)
                            }
                        }.padding(13).waveSurface(radius: 18)
                    }
                    Spacer()
                }.padding(28)
            }
            .navigationTitle("Account").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
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
        .padding(12).contentShape(Rectangle()).waveSurface(radius: 22)
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
            CapyAmbientBackdrop(seed: album.id, artworkURL: album.artwork)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .bottom, spacing: 18) {
                        AlbumArtwork(album: album, size: 168, radius: 24)
                            .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ALBUM").font(.caption2.weight(.black)).tracking(2).foregroundStyle(CapyColor.accent)
                            Text(album.title).font(.system(size: 30, weight: .black, design: .rounded)).lineLimit(3)
                            Text(album.artist).font(.capyBody).foregroundStyle(CapyColor.accent).lineLimit(2)
                            Text([album.year, tracks.isEmpty ? nil : "\(tracks.count) songs"].compactMap { $0 }.joined(separator: " • "))
                                .font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                        }
                    }
                    if loading {
                        CapyScreenState(kind: .loading, title: "Loading album", message: "Bringing in the complete track list…")
                    } else {
                        HStack(spacing: 10) {
                            Button { play(tracks) } label: { Label("Play", systemImage: "play.fill") }
                                .buttonStyle(CapyPrimaryButtonStyle()).disabled(tracks.isEmpty)
                            Button { play(tracks.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }
                                .buttonStyle(CapySecondaryButtonStyle()).disabled(tracks.isEmpty)
                        }
                        HStack(spacing: 18) {
                            Button { Task { await player.downloadPlaylist(downloadableAlbum) }; CapyHaptics.impact() } label: {
                                Label(player.playlistDownloadProgress[downloadableAlbum.id].map { "Downloading \($0)" } ?? (player.isPlaylistDownloaded(downloadableAlbum) ? "Downloaded" : "Download"), systemImage: player.isPlaylistDownloaded(downloadableAlbum) ? "arrow.down.circle.fill" : "arrow.down.circle")
                                    .frame(minHeight: 48).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).foregroundStyle(CapyColor.accent)
                            .disabled(tracks.isEmpty || player.downloadingPlaylists.contains(downloadableAlbum.id))
                            Button { player.saveAlbum(album, tracks: tracks); CapyHaptics.notification(.success) } label: {
                                Label("Save album", systemImage: "plus.rectangle.on.folder").frame(minHeight: 48).contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(.white).disabled(tracks.isEmpty)
                            Spacer()
                        }.font(.capyCallout)
                        CapySectionHeader("Track list", subtitle: "Actual playback time replaces catalog estimates")
                        ForEach(tracks) { TrackCard(track: $0) }
                    }
                }.padding(18).padding(.bottom, 120)
            }.scrollIndicators(.hidden)
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { tracks = try await player.catalog.albumTracks(for: album); player.prewarm(tracks) }
            catch { player.error = error.localizedDescription }
            loading = false
        }
    }

    private func play(_ ordered: [Track]) {
        player.queue = Array(ordered.dropFirst())
        if let first = ordered.first { Task { await player.play(first) } }
        CapyHaptics.impact(.medium)
    }
}

private struct ArtistDetailView: View {
    @EnvironmentObject private var player: WavePlayer
    let artist: String
    @State private var tracks: [Track] = []
    @State private var loading = true

    var body: some View {
        ZStack {
            CapyAmbientBackdrop(seed: artist, artworkURL: tracks.first?.artwork)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 18) {
                        if let first = tracks.first {
                            Artwork(track: first, size: 126, radius: 63)
                        } else {
                            Image(systemName: "person.wave.2.fill").font(.system(size: 46))
                                .frame(width: 126, height: 126).background(CapyColor.surfaceStrong, in: Circle())
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ARTIST").font(.caption2.weight(.black)).tracking(2).foregroundStyle(CapyColor.accent)
                            Text(artist).font(.system(size: 32, weight: .black, design: .rounded)).lineLimit(3)
                            Text("Top matching songs").font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                        }
                    }
                    if loading {
                        CapyScreenState(kind: .loading, title: "Finding music", message: "Loading songs by \(artist)…")
                    } else if tracks.isEmpty {
                        CapyScreenState(kind: .empty, title: "No songs found", message: "Try searching the artist name from Search.")
                    } else {
                        Button {
                            let ordered = tracks
                            player.queue = Array(ordered.dropFirst())
                            if let first = ordered.first { Task { await player.play(first) } }
                            CapyHaptics.impact(.medium)
                        } label: { Label("Play artist mix", systemImage: "play.fill") }
                            .buttonStyle(CapyPrimaryButtonStyle())
                        ForEach(tracks) { TrackCard(track: $0) }
                    }
                }
                .padding(18).padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(artist)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { tracks = try await player.catalog.search("\(artist) songs"); player.prewarm(tracks) }
            catch { player.error = error.localizedDescription }
            loading = false
        }
    }
}

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All", playlists = "Playlists", albums = "Albums", downloads = "Downloaded", shared = "Shared"
    var id: String { rawValue }
}

private enum LibrarySort: String, CaseIterable, Identifiable {
    case recent = "Recently added", name = "Name"
    var id: String { rawValue }
}

private struct PlaylistLibraryView: View {
    @EnvironmentObject var player: WavePlayer
    @EnvironmentObject var social: SocialStore
    @State private var showCreator = false
    @State private var playlistToRename: ImportedPlaylist?
    @State private var filter: LibraryFilter = .all
    @State private var sort: LibrarySort = .recent
    var body: some View {
      NavigationStack {
       ZStack {
        CapyAmbientBackdrop(seed: "capyflow-library", artworkURL: visiblePlaylists.first?.tracks.first?.artwork, intensity: 0.78)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack {
                    CapyScreenTitle(title: "Library", subtitle: "Everything you made yours")
                    Spacer()
                    Menu {
                        Picker("Sort library", selection: $sort) {
                            ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 48, height: 48) }
                        .buttonStyle(CapyIconButtonStyle())
                    Button { showCreator = true; CapyHaptics.impact() } label: { Image(systemName: "plus") }
                        .buttonStyle(CapyIconButtonStyle(prominent: true))
                        .accessibilityLabel("Create playlist")
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(LibraryFilter.allCases) { item in
                            Button { filter = item; CapyHaptics.selection() } label: {
                                Text(item.rawValue).font(.capyCaption).padding(.horizontal, 15).frame(height: 40)
                                    .foregroundStyle(filter == item ? CapyColor.background : .white)
                                    .background(filter == item ? CapyColor.accent : CapyColor.surfaceStrong, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }.scrollIndicators(.hidden)

                if filter == .downloads {
                    downloadsSection
                } else if filter == .shared {
                    sharedSection
                } else if visiblePlaylists.isEmpty {
                    CapyScreenState(kind: .empty, title: emptyTitle, message: emptyMessage) {
                        Button("Create playlist") { showCreator = true }.buttonStyle(CapyPrimaryButtonStyle()).frame(maxWidth: 220)
                    }
                } else {
                    CapySectionHeader(filter == .albums ? "Saved albums" : "Your collection", subtitle: "\(visiblePlaylists.count) saved")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 230), spacing: 14)], spacing: 18) {
                        ForEach(visiblePlaylists) { playlist in
                            NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: { PlaylistGridCard(playlist: playlist) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { playlistToRename = playlist } label: { Label("Rename", systemImage: "pencil") }
                                    Button(role: .destructive) { player.deletePlaylist(playlist.id) } label: { Label("Delete playlist", systemImage: "trash") }
                                }
                        }
                    }
                    if filter == .all {
                        downloadsPreview
                        sharedSection
                    }
                }
            }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 30)
        }.scrollIndicators(.hidden)
       }
       .toolbar(.hidden, for: .navigationBar)
       .sheet(isPresented: $showCreator) { NewPlaylistSheet() }
       .sheet(item: $playlistToRename) { RenamePlaylistSheet(playlistID: $0.id, currentName: $0.name) }
      }
    }

    private var visiblePlaylists: [ImportedPlaylist] {
        let base: [ImportedPlaylist]
        switch filter {
        case .albums: base = player.playlists.filter { $0.id.hasPrefix("album:") }
        case .playlists: base = player.playlists.filter { !$0.id.hasPrefix("album:") }
        case .all: base = player.playlists
        case .downloads, .shared: base = []
        }
        switch sort {
        case .recent: return base
        case .name: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private var downloadsPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            CapySectionHeader("Downloaded", subtitle: "\(player.downloads.count) available offline")
            NavigationLink { TrackCollectionView(title: "Downloads", subtitle: "Available without internet", tracks: player.downloads, isOffline: true) } label: {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(CapyColor.accent)
                        .frame(width: 52, height: 52).background(CapyColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Offline music").font(.capySection)
                        Text(player.downloads.isEmpty ? "Download songs to listen anywhere" : "Ready wherever you go")
                            .font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                    }
                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(CapyColor.tertiaryText)
                }.padding(13).contentShape(Rectangle()).waveSurface(radius: 20)
            }.buttonStyle(.plain)
        }
    }

    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            CapySectionHeader("Downloaded music", subtitle: "Stored on this iPhone")
            if player.downloads.isEmpty {
                CapyScreenState(kind: .empty, title: "Nothing offline yet", message: "Download a song, album or playlist and it will appear here with its lyrics.")
            } else {
                ForEach(player.downloads) { TrackCard(track: $0, canDelete: true) }
            }
        }
    }

    @ViewBuilder private var sharedSection: some View {
        if !social.sharedPlaylists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                CapySectionHeader("Shared with you", subtitle: "Playlists you can build together")
                ForEach(social.sharedPlaylists) { playlist in
                    NavigationLink { SharedPlaylistDetailView(playlistID: playlist.id) } label: { SharedPlaylistRow(playlist: playlist) }
                        .buttonStyle(.plain)
                }
            }
        } else if filter == .shared {
            CapyScreenState(kind: .empty, title: "Nothing shared yet", message: "Sign in, follow a friend and invite them from a playlist.")
        }
    }

    private var emptyTitle: String { filter == .albums ? "No saved albums" : "Make your first playlist" }
    private var emptyMessage: String { filter == .albums ? "Open an album from Search and save it to your library." : "Create one, choose its artwork, then add songs from Search." }
}

private struct PlaylistGridCard: View {
    @EnvironmentObject var player: WavePlayer
    let playlist: ImportedPlaylist
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geometry in
                PlaylistCover(playlist: playlist, size: geometry.size.width, radius: 20)
                    .overlay(alignment: .bottomTrailing) {
                        if player.isPlaylistDownloaded(playlist) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2).foregroundStyle(Color.waveBlue)
                                .padding(9).background(.black.opacity(0.65), in: Circle()).padding(8)
                        }
                    }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(playlist.name).font(.headline.weight(.bold)).lineLimit(1)
            Text("\(playlist.tracks.count) songs").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
        }.padding(12).contentShape(Rectangle()).waveSurface(radius: 24)
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
    @EnvironmentObject var auth: AuthSession
    @Environment(\.dismiss) private var dismiss
    let playlistID: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showRename = false
    @State private var showCollaborate = false
    private var playlist: ImportedPlaylist? { player.playlists.first { $0.id == playlistID } }
    var body: some View {
        ZStack {
            CapyAmbientBackdrop(seed: playlistID, artworkURL: playlist?.tracks.first?.artwork)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let playlist {
                        HStack(alignment: .bottom, spacing: 18) {
                            PlaylistCover(playlist: playlist, size: 168, radius: 24)
                                .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(playlist.id.hasPrefix("album:") ? "SAVED ALBUM" : "PLAYLIST")
                                    .font(.caption2.weight(.black)).tracking(2).foregroundStyle(CapyColor.accent)
                                Text(playlist.name).font(.system(size: 30, weight: .black, design: .rounded)).lineLimit(4)
                                Text(auth.user?.displayName.map { "By \($0)" } ?? "Made on this iPhone")
                                    .font(.capyCaption).foregroundStyle(CapyColor.secondaryText).lineLimit(1)
                                Text("\(playlist.tracks.count) songs")
                                    .font(.capyCaption).foregroundStyle(CapyColor.tertiaryText)
                            }
                        }
                        HStack(spacing: 10) {
                            Button { play(playlist.tracks) } label: { Label("Play", systemImage: "play.fill") }
                                .buttonStyle(CapyPrimaryButtonStyle()).disabled(playlist.tracks.isEmpty)
                            Button { play(playlist.tracks.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }
                                .buttonStyle(CapySecondaryButtonStyle()).disabled(playlist.tracks.isEmpty)
                        }
                        HStack(spacing: 8) {
                            compactAction(
                                player.isPlaylistDownloaded(playlist) ? "Downloaded" : "Download",
                                icon: player.isPlaylistDownloaded(playlist) ? "arrow.down.circle.fill" : "arrow.down.circle"
                            ) {
                                Task { await player.downloadPlaylist(playlist) }
                                CapyHaptics.impact()
                            }
                            .disabled(player.downloadingPlaylists.contains(playlist.id) || playlist.tracks.isEmpty)
                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                Label("Artwork", systemImage: "photo.badge.plus").frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).font(.capyCaption).foregroundStyle(.white)
                            if auth.user != nil {
                                compactAction("Collaborate", icon: "person.2.badge.plus") { showCollaborate = true }
                            }
                        }
                        if let progress = player.playlistDownloadProgress[playlist.id] {
                            HStack(spacing: 10) {
                                ProgressView().tint(CapyColor.accent)
                                Text("Downloading \(progress) to this iPhone").font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(13).waveSurface(radius: 18)
                        } else if let failed = playlist.tracks.first(where: { player.downloadFailures[$0.id] != nil }) {
                            Label("Some downloads need attention: \(failed.title)", systemImage: "exclamationmark.triangle.fill")
                                .font(.capyCaption).foregroundStyle(CapyColor.warning)
                        }
                        CapySectionHeader("Songs", subtitle: playlist.tracks.isEmpty ? "Add music from Search" : "Tap a row to play")
                        if playlist.tracks.isEmpty {
                            CapyScreenState(kind: .empty, title: "This playlist is ready", message: "Find a song in Search, open its menu, then choose Add to playlist.")
                        } else {
                            ForEach(playlist.tracks) { TrackCard(track: $0) }
                        }
                    }
                }.padding(18).padding(.bottom, 120)
            }.scrollIndicators(.hidden)
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let playlist {
                    Menu {
                        Button { showRename = true } label: { Label("Rename playlist", systemImage: "pencil") }
                        Button(role: .destructive) { player.deletePlaylist(playlist.id); dismiss() } label: { Label("Delete playlist", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle()) }
                }
            }
        }
        .sheet(isPresented: $showRename) {
            if let playlist { RenamePlaylistSheet(playlistID: playlist.id, currentName: playlist.name) }
        }
        .sheet(isPresented: $showCollaborate) {
            if let playlist { CollaborateSheet(playlist: playlist) }
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

    private func play(_ ordered: [Track]) {
        player.queue = Array(ordered.dropFirst())
        if let first = ordered.first { Task { await player.play(first) } }
        CapyHaptics.impact(.medium)
    }

    private func compactAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.capyCaption).frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
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
    @EnvironmentObject var social: SocialStore
    let track: Track
    var canDelete = false
    var body: some View {
        HStack(spacing: 14) {
            Button { Task { await player.play(track) } } label: {
                HStack(spacing: 14) {
                    Artwork(track: track)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.headline.weight(.bold)).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(track.artist).lineLimit(1)
                            if let duration = track.duration, duration > 0 {
                                Text("•"); Text(shortTime(duration)).monospacedDigit()
                            }
                        }.font(.caption.weight(.semibold)).foregroundStyle(CapyColor.secondaryText)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Spacer(minLength: 6)
            if let progress = player.downloadProgress[track.id] {
                VStack(spacing: 2) {
                    if progress > 0 {
                        ProgressView(value: progress).tint(CapyColor.accent).frame(width: 48)
                        Text("\(Int(progress * 100))%").font(.caption2.monospacedDigit())
                    } else {
                        ProgressView().tint(CapyColor.accent)
                        Text("MSI").font(.caption2.weight(.bold))
                    }
                }
                .foregroundStyle(CapyColor.secondaryText)
                .accessibilityLabel(player.downloadDiagnostics[track.id] ?? "Preparing download")
            } else if player.isDownloaded(track) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.waveBlue).accessibilityLabel("Downloaded")
            } else if let reason = player.downloadFailures[track.id] {
                Button {
                    player.error = "\(track.title): \(reason)"
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Download failed. \(reason)")
            }
            Menu {
                if let diagnostic = player.downloadDiagnostics[track.id] {
                    Text(diagnostic)
                }
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
                if !social.sharedPlaylists.isEmpty {
                    Menu("Add to shared playlist", systemImage: "person.2.badge.plus") {
                        ForEach(social.sharedPlaylists) { playlist in
                            Button(playlist.name) { Task { await social.add(track, to: playlist) } }
                        }
                    }
                }
                if canDelete { Button(role: .destructive) { player.delete(track) } label: { Label("Delete download", systemImage: "trash") } }
                else { Button { Task { await player.download(track) } } label: { Label("Download", systemImage: "arrow.down.circle") } }
            } label: { Image(systemName: "ellipsis").font(.title3.bold()).frame(width: 42, height: 42).background(.white.opacity(0.06), in: Circle()) }
        }.padding(12).waveSurface(radius: 22, highlighted: player.current?.id == track.id)
    }

    private func shortTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
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

private struct CapyDock: View {
    @EnvironmentObject var player: WavePlayer
    @Binding var selection: WaveTab
    let expand: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let track = player.current {
                HStack(spacing: 10) {
                    Button(action: expand) {
                        HStack(spacing: 11) {
                            Artwork(track: track, size: 48, radius: 13)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.capyCallout).lineLimit(1)
                                Text(track.artist).font(.capyCaption).foregroundStyle(CapyColor.secondaryText).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if player.loading { ProgressView().tint(CapyColor.accent) }
                    Button { player.toggle(); CapyHaptics.impact() } label: {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    }.buttonStyle(CapyIconButtonStyle(prominent: true))
                    Button { Task { await player.next() }; CapyHaptics.selection() } label: {
                        Image(systemName: "forward.end.fill").frame(width: 44, height: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Next song")
                }
                .padding(.horizontal, 8).padding(.top, 7)
                GeometryReader { proxy in
                    Capsule().fill(CapyColor.accent).frame(width: proxy.size.width * progress, height: 2)
                }.frame(height: 2).padding(.horizontal, 11)
                Divider().overlay(Color.white.opacity(0.08)).padding(.horizontal, 10)
            }
            GeometryReader { geometry in
            HStack(spacing: 4) {
                ForEach(WaveTab.allCases, id: \.self) { item in
                    Button { choose(item) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon)
                                .font(.system(size: 16, weight: selection == item ? .bold : .semibold))
                            Text(item.rawValue).font(.caption2.weight(selection == item ? .bold : .semibold)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).frame(height: 52).contentShape(Rectangle())
                        .foregroundStyle(selection == item ? CapyColor.accent : CapyColor.secondaryText)
                        .overlay(alignment: .top) {
                            Capsule().fill(selection == item ? CapyColor.accent : .clear).frame(width: 28, height: 3)
                        }
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 4)
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { value in
                let count = WaveTab.allCases.count
                let x = min(max(0, value.location.x - 6), max(1, geometry.size.width - 12))
                let index = min(count - 1, Int(x / max(1, (geometry.size.width - 12) / CGFloat(count))))
                choose(WaveTab.allCases[index])
            })
            }.frame(height: 58)
        }
        .waveGlass(radius: 27, highlighted: player.current != nil)
    }

    private var progress: CGFloat {
        player.duration > 0 ? CGFloat(min(1, max(0, player.elapsed / player.duration))) : 0
    }

    private func choose(_ item: WaveTab) {
        guard selection != item else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.86)) { selection = item }
        CapyHaptics.selection()
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
            let artworkSize = min(
                geometry.size.width - 52,
                showLyrics ? max(126, geometry.size.height * 0.18) : min(340, geometry.size.height * 0.36)
            )
            ZStack {
                CapyAmbientBackdrop(
                    seed: player.current?.id ?? "capyflow-player",
                    artworkURL: player.current?.artwork,
                    intensity: 1.2
                )
                VStack(spacing: showLyrics ? 8 : 13) {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(CapyIconButtonStyle())
                            .accessibilityLabel("Close Now Playing")
                        Spacer()
                        VStack(spacing: 2) {
                            Text("NOW PLAYING").font(.caption2.weight(.black)).tracking(2)
                            Text(player.audioQuality.rawValue.uppercased()).font(.caption2).foregroundStyle(CapyColor.secondaryText)
                        }
                        Spacer()
                        Menu {
                            Picker("Audio quality", selection: $player.audioQuality) {
                                ForEach(AudioQuality.allCases) { quality in Text(quality.rawValue).tag(quality) }
                            }
                            Toggle("Autoplay related songs", isOn: $player.autoplayEnabled)
                            Divider()
                            Button("Clear queue", role: .destructive) { player.queue.removeAll() }
                        } label: { Image(systemName: "ellipsis") }
                            .buttonStyle(CapyIconButtonStyle())
                    }
                    if let track = player.current {
                        ZStack {
                            Artwork(track: track, size: artworkSize, radius: showLyrics ? 24 : 32)
                                .shadow(color: .black.opacity(0.34), radius: 26, y: 15)
                            if player.loading {
                                ProgressView().controlSize(.large).tint(.white)
                                    .padding(18).background(.black.opacity(0.52), in: Circle())
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.current?.title ?? "CapyFlow").font(.system(size: showLyrics ? 24 : 29, weight: .black, design: .rounded)).lineLimit(2)
                        Text(player.current?.artist ?? "").font(.capyBody).foregroundStyle(CapyColor.accent).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 1) {
                        CapyPlaybackSlider(value: $scrubPosition, range: 0...max(player.duration, 1)) { editing in
                            isScrubbing = editing
                            if !editing { player.seek(scrubPosition); CapyHaptics.selection() }
                        }
                        .accessibilityLabel("Playback position")
                        HStack {
                            Text(time(isScrubbing ? scrubPosition : player.elapsed))
                            Spacer()
                            Text("−" + time(max(0, player.duration - (isScrubbing ? scrubPosition : player.elapsed))))
                        }
                        .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(CapyColor.secondaryText)
                    }
                    HStack(spacing: 30) {
                        Button { Task { await player.previous() }; CapyHaptics.impact() } label: {
                            Image(systemName: "backward.end.fill").frame(width: 56, height: 56).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Previous song")
                        Button { player.toggle(); CapyHaptics.impact(.medium) } label: {
                            Image(systemName: player.playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 28, weight: .bold)).frame(width: 74, height: 74)
                                .background(CapyColor.accent, in: Circle()).foregroundStyle(CapyColor.background)
                                .contentShape(Circle())
                        }.buttonStyle(.plain)
                        Button { Task { await player.next() }; CapyHaptics.impact() } label: {
                            Image(systemName: "forward.end.fill").frame(width: 56, height: 56).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Next song")
                    }
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { showLyrics.toggle() }
                            CapyHaptics.selection()
                        } label: {
                            Label(showLyrics ? "Hide lyrics" : "Lyrics", systemImage: "quote.bubble.fill")
                                .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).font(.capyCallout)
                        .background(showLyrics ? CapyColor.accent.opacity(0.18) : CapyColor.surfaceStrong, in: Capsule())
                        Button {
                            if let track = player.current { Task { await player.download(track) } }
                            CapyHaptics.impact()
                        } label: {
                            Image(systemName: player.current.map { player.isDownloaded($0) } == true ? "arrow.down.circle.fill" : "arrow.down.circle")
                                .frame(width: 52, height: 48).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).background(CapyColor.surfaceStrong, in: Capsule())
                        .accessibilityLabel(player.current.map { player.isDownloaded($0) } == true ? "Downloaded" : "Download song")
                        Button { showQueue = true; CapyHaptics.selection() } label: {
                            Image(systemName: "list.bullet").frame(width: 52, height: 48).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).background(CapyColor.surfaceStrong, in: Capsule())
                        .accessibilityLabel("Open queue")
                    }
                    if showLyrics {
                        LyricsPanel().id(player.current?.id)
                            .frame(minHeight: 150, maxHeight: .infinity)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: CapyMetric.readableWidth, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, max(18, geometry.safeAreaInsets.leading + 18))
                .padding(.top, max(8, geometry.safeAreaInsets.top))
                .padding(.bottom, max(10, geometry.safeAreaInsets.bottom))
                .frame(maxWidth: .infinity)
            }
        }
        .tint(CapyColor.accent)
        .onAppear { scrubPosition = player.elapsed }
        .onChange(of: player.elapsed) { value in if !isScrubbing { scrubPosition = value } }
        .onChange(of: player.current?.id) { _ in
            scrubPosition = 0
        }
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
    @EnvironmentObject private var player: WavePlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollTarget: Int?

    var body: some View {
        let lines = player.lyrics
        let activeIndex = lines.lastIndex { line in
            guard let time = line.time else { return false }
            return time <= player.elapsed
        }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Lyrics").font(.title2.weight(.black))
                Spacer()
                if player.lyricsLoading { ProgressView().tint(Color.waveBlue) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !player.lyricsLoading && lines.isEmpty {
                        Text("Lyrics aren’t available for this track yet.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(lines.indices, id: \.self) { index in
                            let line = lines[index]
                            let isActive = index == activeIndex
                            Button {
                                if let time = line.time { player.seek(time) }
                            } label: {
                                Text(line.text)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(isActive ? Color.waveBlue : Color.white)
                                    .opacity(lineOpacity(index, activeIndex: activeIndex))
                                    .scaleEffect(isActive ? 1 : 0.985, anchor: .leading)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                            .accessibilityValue(isActive ? "Current lyric" : "")
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.top)
            .scrollPosition(id: $scrollTarget, anchor: .center)
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.black.opacity(0.38), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 26)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.38)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 30)
                .allowsHitTesting(false)
            }
            .onChange(of: activeIndex) { index in
                guard let index else { return }
                if reduceMotion {
                    scrollTarget = index
                } else {
                    withAnimation(.easeOut(duration: 0.24)) { scrollTarget = index }
                }
            }
        }
        .waveSurface(radius: 26)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func lineOpacity(_ index: Int, activeIndex: Int?) -> Double {
        guard let activeIndex else { return 0.52 }
        if index == activeIndex { return 1 }
        if index < activeIndex { return max(0.10, 0.34 - Double(activeIndex - index) * 0.06) }
        return max(0.34, 0.68 - Double(index - activeIndex) * 0.04)
    }
}
