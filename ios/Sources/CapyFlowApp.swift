import SwiftUI
import PhotosUI
import UIKit
import FirebaseCore
import GoogleSignIn

@main struct CapyFlowApp: App {
    @StateObject private var player: WavePlayer
    @StateObject private var auth: AuthSession
    @StateObject private var social: SocialStore
    init() {
        FirebaseApp.configure()
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = navigationAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance
        UINavigationBar.appearance().compactAppearance = navigationAppearance
        let player = WavePlayer()
        let auth = AuthSession()
        let social = SocialStore()
#if DEBUG
        if LayoutFixture.requested != nil {
            LayoutFixture.install(into: player, social: social)
        }
#endif
        _player = StateObject(wrappedValue: player)
        _auth = StateObject(wrappedValue: auth)
        _social = StateObject(wrappedValue: social)
    }
    var body: some Scene {
        WindowGroup {
            appContent
                .background { WaveBackdrop() }
                .environmentObject(player)
                .environmentObject(auth)
                .environmentObject(social)
                .preferredColorScheme(.dark)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
    }

    @ViewBuilder private var appContent: some View {
#if DEBUG
        if let fixture = LayoutFixture.requested {
            LayoutFixtureView(fixture: fixture)
        } else {
            RootView()
        }
#else
        RootView()
#endif
    }
}

#if DEBUG
private enum LayoutFixture: String {
    case root, queue, player, playerLyrics = "player-lyrics", album, playlist, social, profile

    static var requested: LayoutFixture? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--layout-fixture"),
              arguments.indices.contains(flag + 1) else { return nil }
        return LayoutFixture(rawValue: arguments[flag + 1])
    }

    static let tracks: [Track] = [
        Track(id: "fixture00001", title: "A Very Long Album Song Title That Must Never Push Controls Outside the Phone", artist: "Capybara & The Extremely Long Artist Name", duration: 214),
        Track(id: "fixture00002", title: "River Glass", artist: "CapyFlow Friends", duration: 189),
        Track(id: "fixture00003", title: "Small Screen Sunrise", artist: "Responsive Ensemble", duration: 241)
    ]

    static let fixtureAlbum = Album(
        id: "MPREfixturealbum",
        title: "An Album With a Deliberately Long Name for Responsive Layout Testing",
        artist: "Capybara & The Extremely Long Artist Name",
        year: "2026",
        artworkURL: nil
    )

    @MainActor static func install(into player: WavePlayer, social: SocialStore) {
        player.current = tracks[0]
        player.duration = tracks[0].duration ?? 0
        player.elapsed = 87
        player.queue = Array(tracks.dropFirst())
        if requested == .queue {
            player.queue = (1...30).map { Track(id: "queue-fixture-\($0)", title: "River song \($0)", artist: "CapyFlow Friends", duration: 189) }
        }
        player.lyrics = [
            LyricLine(time: 0, text: "The river starts beneath the city lights"),
            LyricLine(time: 32, text: "We carry every little song together"),
            LyricLine(time: 78, text: "A long lyric sentence stays inside the readable glass panel"),
            LyricLine(time: 110, text: "The finished words drift upward and fade")
        ]
        player.playlists = [
            ImportedPlaylist(id: "fixture-playlist", name: "A Very Long Shared Road Trip Playlist Name", tracks: tracks),
            ImportedPlaylist(id: "fixture-second", name: "Quiet Capybara Hours", tracks: Array(tracks.reversed()))
        ]
        player.downloadStates[tracks[1].id] = TrackDownloadState(
            stage: .queued, progress: nil, source: nil, attempt: 0, elapsedSeconds: 0, detail: nil
        )

        if let profile = SocialProfile(id: "fixture-user-123456", data: [
            "username": "capybara.listener",
            "usernameKey": "capybara.listener",
            "displayName": "A CapyFlow Listener With a Long Display Name",
            "bio": "Music, capybaras, and shared playlists with friends.",
            "avatarURL": ""
        ]), let friend = SocialProfile(id: "fixture-friend-654321", data: [
            "username": "river.friend",
            "usernameKey": "river.friend",
            "displayName": "River Friend With a Long Name",
            "bio": "",
            "avatarURL": ""
        ]) {
            social.installLayoutFixture(profile: profile, following: [friend])
        }
    }
}

private struct LayoutFixtureView: View {
    let fixture: LayoutFixture

    @ViewBuilder var body: some View {
        switch fixture {
        case .queue: QueueSheet()
        case .root:
            RootView()
        case .player:
            PlayerView()
        case .playerLyrics:
            PlayerView(showLyricsInitially: true)
        case .album:
            NavigationStack { AlbumDetailView(album: LayoutFixture.fixtureAlbum, fixtureTracks: LayoutFixture.tracks) }
        case .playlist:
            NavigationStack { PlaylistDetailView(playlistID: "fixture-playlist") }
        case .social:
            NavigationStack { SocialHubView() }
        case .profile:
            NavigationStack { ProfilePageView() }
        }
    }
}
#endif

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

private enum ProfileDrawerDestination: String, Identifiable {
    case profile, settings
    var id: String { rawValue }
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
    @State private var showProfileDrawer = false
    @State private var drawerDestination: ProfileDrawerDestination?
    var body: some View {
        ZStack {
            WaveBackdrop()
            HomeDashboardView(selection: $tab) { openDrawer() }
                .opacity(tab == .home ? 1 : 0)
                .allowsHitTesting(tab == .home)
                .accessibilityHidden(tab != .home)
            SearchHomeView(query: $searchQuery, results: $searchResults, albums: $albumResults, searching: $searching, mode: $searchMode, lastSearchSignature: $lastSearchSignature) { openDrawer() }
                .opacity(tab == .search ? 1 : 0)
                .allowsHitTesting(tab == .search)
                .accessibilityHidden(tab != .search)
            PlaylistLibraryView { openDrawer() }
                .opacity(tab == .library ? 1 : 0)
                .allowsHitTesting(tab == .library)
                .accessibilityHidden(tab != .library)
        }
        .safeAreaInset(edge: .bottom, spacing: 5) {
            CapyDock(selection: $tab) { showPlayer = true }
                .padding(.horizontal, 12)
        }
        // Attach the window backdrop outside the dock's safe-area inset so
        // the inset cannot reduce its drawing bounds to the content region.
        .background { WaveBackdrop() }
        .overlay {
            if showProfileDrawer {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.48)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { closeDrawer() }
                        ProfileDrawerView(
                            close: { closeDrawer() },
                            openProfile: { openDrawerDestination(.profile) },
                            openSettings: { openDrawerDestination(.settings) }
                        )
                        .frame(width: min(350, geometry.size.width * 0.88))
                        .frame(maxHeight: .infinity)
                        .background(CapyColor.background)
                        .transition(.move(edge: .leading))
                        .shadow(color: .black.opacity(0.45), radius: 30, x: 12)
                    }
                }
                .zIndex(40)
            }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(30)
                .presentationBackground(.clear)
        }
        .sheet(isPresented: Binding(
            get: { drawerDestination == .profile },
            set: { if !$0 { drawerDestination = nil } }
        )) {
            NavigationStack {
                ProfilePageView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { drawerDestination = nil }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        .overlay {
            if drawerDestination == .settings {
                SettingsPageView(close: { closeDrawerDestination() })
                    .transition(.move(edge: .trailing))
                    .zIndex(35)
            }
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

    private func openDrawer() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { showProfileDrawer = true }
        CapyHaptics.selection()
    }

    private func closeDrawer() {
        withAnimation(.easeOut(duration: 0.2)) { showProfileDrawer = false }
    }

    private func openDrawerDestination(_ destination: ProfileDrawerDestination) {
        closeDrawer()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
            drawerDestination = destination
        }
    }

    private func closeDrawerDestination() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
            drawerDestination = nil
        }
    }
}

private struct CapyProfileButton: View {
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var social: SocialStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let profile = social.profile {
                    SocialAvatar(profile: profile, size: 48)
                } else if let url = auth.user?.photoURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.fill").foregroundStyle(CapyColor.accent)
                    }
                } else {
                    Image(systemName: "person.fill").foregroundStyle(CapyColor.accent)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())
            .overlay { Circle().stroke(CapyColor.surfaceStroke, lineWidth: 0.8) }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open profile and settings")
    }
}

private struct ProfileDrawerView: View {
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var social: SocialStore
    let close: () -> Void
    let openProfile: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CapyFlow").font(.capyTitle)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").frame(width: 48, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close profile menu")
            }
            .padding(.horizontal, 18)

            Button(action: openProfile) {
                HStack(spacing: 14) {
                    Group {
                        if let profile = social.profile {
                            SocialAvatar(profile: profile, size: 72)
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable().scaledToFit().foregroundStyle(CapyColor.accent)
                        }
                    }
                    .frame(width: 72, height: 72).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(social.profile?.displayName ?? auth.user?.displayName ?? "Your profile")
                            .font(.title3.bold()).lineLimit(2)
                        Text(social.profile.map { "@" + $0.username } ?? (auth.user == nil ? "Sign in to connect" : "Profile is being prepared"))
                            .font(.capyCaption).foregroundStyle(CapyColor.secondaryText).lineLimit(2)
                        Text("View profile").font(.capyCaption).foregroundStyle(CapyColor.accent)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").foregroundStyle(CapyColor.tertiaryText)
                }
                .padding(16).contentShape(Rectangle()).waveSurface(radius: 22, highlighted: true)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 12)

            VStack(spacing: 8) {
                drawerButton("Profile & friends", icon: "person.2.fill", action: openProfile)
                drawerButton("Settings", icon: "gearshape.fill", action: openSettings)
            }
            .padding(.horizontal, 16).padding(.top, 20)

            Spacer()
            Text("Your music and downloads work even when social features are offline.")
                .font(.capyCaption).foregroundStyle(CapyColor.tertiaryText)
                .padding(20)
        }
        .padding(.top, 8)
        .safeAreaPadding(.top)
        .safeAreaPadding(.bottom)
    }

    private func drawerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).foregroundStyle(CapyColor.accent).frame(width: 28)
                Text(title).font(.capyCallout)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(CapyColor.tertiaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
            .padding(.horizontal, 14).waveSurface(radius: 18)
        }
        .buttonStyle(.plain)
    }
}

private struct HomeDashboardView: View {
    @EnvironmentObject private var player: WavePlayer
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var social: SocialStore
    @Binding var selection: WaveTab
    let openProfileDrawer: () -> Void

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
                        LazyVStack(alignment: .leading, spacing: 30) {
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
        }
    }

    private var homeHeader: some View {
        HStack(spacing: 14) {
            CapyProfileButton(action: openProfileDrawer)
                .accessibilityIdentifier("home-profile-menu")
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting).font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                Text("CapyFlow").font(.system(size: 30, weight: .bold, design: .rounded))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var flowHero: some View {
        if let track = player.current {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    Artwork(track: track, size: 164, radius: 18)
                    flowSummary(track)
                        .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Spacer(minLength: 0)
                        Artwork(track: track, size: 164, radius: 18)
                        Spacer(minLength: 0)
                    }
                    flowSummary(track)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
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

    private func flowSummary(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(player.playing ? "IN YOUR FLOW" : "READY WHEN YOU ARE")
                .font(.caption2.weight(.black)).tracking(1.8).foregroundStyle(CapyColor.accent)
            Text(track.title).font(.capyTitle).lineLimit(2)
            Text(track.artist).font(.capyBody).foregroundStyle(CapyColor.secondaryText).lineLimit(1)
            Button { player.toggle(); CapyHaptics.impact(.medium) } label: {
                Label(player.playing ? "Pause" : "Keep listening", systemImage: player.playing ? "pause.fill" : "play.fill")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(CapyPrimaryButtonStyle())
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var recentlyPlayed: some View {
        VStack(alignment: .leading, spacing: 14) {
            CapySectionHeader("Recently played")
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
            CapySectionHeader("Your library") {
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
    let openProfileDrawer: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
      NavigationStack {
        ScrollView {
            CapyScreenContainer {
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
                .padding(.top, 10).padding(.bottom, 150)
            }
        }.scrollIndicators(.hidden)
        // NavigationStack owns an opaque hosting surface. Put the decorative
        // backdrop inside that surface so its safe areas share the ambience.
        .background { CapyAmbientBackdrop(seed: "capyflow-search", intensity: 0.85) }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: query) {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let signature = mode.rawValue + "|" + term
            guard term.count >= 2, signature != lastSearchSignature else { return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await search(showSpinner: false)
        }
        .onChange(of: mode) {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 { Task { await search(showSpinner: false) } }
        }
      }
    }

    private var header: some View {
        HStack(spacing: 14) {
            CapyProfileButton(action: openProfileDrawer)
            CapyScreenTitle(title: "Search", subtitle: "Songs, artists, albums and your playlists")
        }
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

private struct SettingsPageView: View {
    @EnvironmentObject var auth: AuthSession
    @EnvironmentObject var social: SocialStore
    @EnvironmentObject var player: WavePlayer
    let close: () -> Void
    @State private var showAccount = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            ZStack {
                WaveBackdrop()
                VStack(spacing: 0) {
                    ScrollView {
                        CapyScreenContainer {
                            VStack(spacing: 12) {
                                if auth.user != nil {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) { showAccount.toggle() }
                                    } label: {
                                        VStack(spacing: 0) {
                                            HStack(spacing: 14) {
                                                Image(systemName: "person.crop.circle")
                                                    .font(.title3).foregroundStyle(CapyColor.accent).frame(width: 30)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text("Account").font(.capyCallout)
                                                    Text("Username and email").font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                                                }
                                                Spacer()
                                                Image(systemName: showAccount ? "chevron.up" : "chevron.down")
                                                    .foregroundStyle(CapyColor.tertiaryText)
                                            }
                                            .frame(minHeight: 58).contentShape(Rectangle())

                                            if showAccount, let user = auth.user {
                                                Divider().opacity(0.35)
                                                VStack(alignment: .leading, spacing: 14) {
                                                    accountField("Username", value: social.profile?.username ?? user.displayName ?? "Not set")
                                                    accountField("Email", value: user.email ?? "Not available")
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.vertical, 14)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .waveSurface(radius: 18)
                                    }
                                    .buttonStyle(.plain)
                                }

                                NavigationLink {
                                    AudioQualitySettingsView()
                                } label: {
                                    settingsRow("Audio Quality", icon: "waveform")
                                }
                                .buttonStyle(.plain)

                                NavigationLink {
                                    BackendSettingsView()
                                } label: {
                                    settingsRow("Streaming server", icon: "bolt.horizontal.circle.fill")
                                }
                                .buttonStyle(.plain)

                                storageSection

                                if let error = auth.error {
                                    Text(error).font(.footnote).foregroundStyle(.red)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
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
                            }
                            .padding(.top, 12)
                            .padding(.bottom, 18)
                        }
                    }
                    .scrollIndicators(.hidden)

                    if auth.user != nil {
                        Button(role: .destructive) { confirmSignOut = true } label: {
                            HStack {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                Text("Sign out").font(.headline)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .padding(.horizontal, 18)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: close) {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
        .alert("Sign out of CapyFlow?", isPresented: $confirmSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) {
                auth.signOut()
                close()
            }
        } message: {
            Text("You'll need to sign in again to use your account.")
        }
    }

    private func accountField(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(CapyColor.tertiaryText)
            Text(value).font(.body).foregroundStyle(.primary).textSelection(.enabled)
        }
    }

    private func settingsRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(CapyColor.accent).frame(width: 30)
            Text(title).font(.capyCallout)
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(CapyColor.tertiaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .waveSurface(radius: 18)
    }


    private var storageSection: some View {
        let usage = storageUsage
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "internaldrive.fill").foregroundStyle(CapyColor.accent).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Storage").font(.capyCallout)
                    Text("\(player.downloads.count) downloaded \(player.downloads.count == 1 ? "song" : "songs")")
                        .font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: usage.app, countStyle: .file))
                    .font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
            }
            GeometryReader { geometry in
                let total = max(usage.capacity, 1)
                HStack(spacing: 2) {
                    Rectangle().fill(CapyColor.accent)
                        .frame(width: geometry.size.width * CGFloat(Double(usage.downloads) / Double(total)))
                    Rectangle().fill(CapyColor.warning.opacity(0.85))
                        .frame(width: geometry.size.width * CGFloat(Double(usage.data) / Double(total)))
                    Rectangle().fill(.white.opacity(0.12))
                }.clipShape(Capsule())
            }.frame(height: 9)
            HStack(spacing: 18) {
                storageLegend("Downloaded Audio", usage.downloads, CapyColor.accent)
                storageLegend("Cache & Data", usage.data, CapyColor.warning)
            }
            if usage.capacity > 0 {
                Text("\(ByteCountFormatter.string(fromByteCount: usage.free, countStyle: .file)) free on this iPhone")
                    .font(.caption).foregroundStyle(CapyColor.tertiaryText)
            }
        }.padding(16).waveSurface(radius: 18)
    }

    private func storageLegend(_ title: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption)
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.caption2).foregroundStyle(CapyColor.secondaryText)
            }
        }
    }

    private var storageUsage: (downloads: Int64, data: Int64, app: Int64, capacity: Int64, free: Int64) {
        let fm = FileManager.default
        func directorySize(_ url: URL) -> Int64 {
            guard let files = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
            var bytes: Int64 = 0
            for case let file as URL in files {
                if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
            }
            return bytes
        }
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let offline = documents.appendingPathComponent("Offline", isDirectory: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let downloaded = directorySize(offline)
        let other = max(0, directorySize(documents) - downloaded) + directorySize(caches)
        let volume = try? documents.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (downloaded, other, downloaded + other, Int64(volume?.volumeTotalCapacity ?? 0), volume?.volumeAvailableCapacityForImportantUsage ?? 0)
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
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding(12).contentShape(Rectangle()).waveSurface(radius: 22)
    }
}

private struct AlbumDetailView: View {
    @EnvironmentObject var player: WavePlayer
    let album: Album
    private let fixtureTracks: [Track]?
    @State private var tracks: [Track]
    @State private var loading: Bool

    init(album: Album, fixtureTracks: [Track]? = nil) {
        self.album = album
        self.fixtureTracks = fixtureTracks
        _tracks = State(initialValue: fixtureTracks ?? [])
        _loading = State(initialValue: fixtureTracks == nil)
    }
    private var downloadableAlbum: ImportedPlaylist { ImportedPlaylist(id: "album:" + album.id, name: album.title, tracks: tracks) }
    var body: some View {
        ZStack {
            CapyAmbientBackdrop(seed: album.id, artworkURL: album.artwork)
            ScrollView {
                CapyScreenContainer {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        albumHeader
                        if loading {
                            CapyScreenState(kind: .loading, title: "Loading album", message: "Bringing in the complete track list…")
                        } else {
                            HStack(spacing: 10) {
                                Button { play(tracks) } label: { Label("Play", systemImage: "play.fill") }
                                    .buttonStyle(CapyPrimaryButtonStyle()).disabled(tracks.isEmpty)
                                Button { play(tracks.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }
                                    .buttonStyle(CapySecondaryButtonStyle()).disabled(tracks.isEmpty)
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 18) { albumDownloadButton; saveAlbumButton; Spacer(minLength: 0) }
                                VStack(spacing: 0) { albumDownloadButton; saveAlbumButton }
                            }
                            .font(.capyCallout)
                            if let summary = player.downloadBatchSummary,
                               summary.playlistID == downloadableAlbum.id {
                                DownloadBatchStatusView(summary: summary)
                            }
                            CapySectionHeader("Track list", subtitle: "Actual playback time replaces catalog estimates")
                            ForEach(tracks) { TrackCard(track: $0) }
                        }
                    }
                    .padding(.top, 18).padding(.bottom, 120)
                }
            }.scrollIndicators(.hidden)
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard fixtureTracks == nil else { return }
            do { tracks = try await player.catalog.albumTracks(for: album); player.prewarm(tracks) }
            catch { player.error = error.localizedDescription }
            loading = false
        }
    }

    private var albumHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 18) {
                AlbumArtwork(album: album, size: 154, radius: 24)
                    .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
                albumMetadata.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 16) {
                CapyArtworkHero(url: album.artwork, placeholder: "square.stack.fill", maximumSize: 260)
                    .frame(maxWidth: .infinity)
                albumMetadata
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var albumMetadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ALBUM").font(.caption2.weight(.black)).tracking(2).foregroundStyle(CapyColor.accent)
            Text(album.title)
                .font(.system(size: 30, weight: .black, design: .rounded))
                .lineLimit(3)
                .minimumScaleFactor(0.8)
            Text(album.artist).font(.capyBody).foregroundStyle(CapyColor.accent).lineLimit(2)
            Text([album.year, tracks.isEmpty ? nil : "\(tracks.count) songs"].compactMap { $0 }.joined(separator: " • "))
                .font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var albumDownloadButton: some View {
        Button { Task { await player.downloadPlaylist(downloadableAlbum) }; CapyHaptics.impact() } label: {
            Label(player.playlistDownloadProgress[downloadableAlbum.id].map { "Downloading \($0)" } ?? (player.isPlaylistDownloaded(downloadableAlbum) ? "Downloaded" : "Download"), systemImage: player.isPlaylistDownloaded(downloadableAlbum) ? "arrow.down.circle.fill" : "arrow.down.circle")
                .frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(CapyColor.accent)
        .disabled(tracks.isEmpty || player.downloadingPlaylists.contains(downloadableAlbum.id))
    }

    private var saveAlbumButton: some View {
        Button { player.saveAlbum(album, tracks: tracks); CapyHaptics.notification(.success) } label: {
            Label("Save album", systemImage: "plus.rectangle.on.folder").frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.white).disabled(tracks.isEmpty)
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
                CapyScreenContainer {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        artistHeader
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
                    .padding(.top, 18).padding(.bottom, 110)
                }
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

    private var artistHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                artistArtwork(size: 126)
                artistMetadata.frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack { Spacer(minLength: 0); artistArtwork(size: 126); Spacer(minLength: 0) }
                artistMetadata
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func artistArtwork(size: CGFloat) -> some View {
        if let first = tracks.first {
            Artwork(track: first, size: size, radius: size / 2)
        } else {
            Image(systemName: "person.wave.2.fill").font(.system(size: 46))
                .frame(width: size, height: size).background(CapyColor.surfaceStrong, in: Circle())
        }
    }

    private var artistMetadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ARTIST").font(.caption2.weight(.black)).tracking(2).foregroundStyle(CapyColor.accent)
            Text(artist).font(.system(size: 32, weight: .black, design: .rounded)).lineLimit(3).minimumScaleFactor(0.8)
            Text("Top matching songs").font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
    let openProfileDrawer: () -> Void
    var body: some View {
      NavigationStack {
       ZStack {
         CapyAmbientBackdrop(seed: "capyflow-library", artworkURL: visiblePlaylists.first?.tracks.first?.artwork, intensity: 0.78)
         ScrollView {
            CapyScreenContainer {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        CapyProfileButton(action: openProfileDrawer)
                        CapyScreenTitle(title: "Library", subtitle: "Everything you made yours")
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
                    GeometryReader { geometry in
                      ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(LibraryFilter.allCases) { item in
                                Button { filter = item; CapyHaptics.selection() } label: {
                                    Text(item.rawValue).font(.capyCaption).padding(.horizontal, 15).frame(height: 40)
                                        .foregroundStyle(filter == item ? CapyColor.background : .white)
                                        .background(filter == item ? CapyColor.accent : CapyColor.surfaceStrong, in: Capsule())
                                }.buttonStyle(.plain)
                                    .accessibilityIdentifier("library-filter-\(item.rawValue)")
                            }
                        }
                      }.scrollIndicators(.hidden)
                        .frame(width: geometry.size.width, height: 40)
                        .accessibilityIdentifier("library-filter-scroll")
                    }.frame(height: 40)

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
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 230), spacing: 14)], spacing: 18) {
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
                }
                .padding(.top, 10).padding(.bottom, 30)
            }
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
            .onChange(of: selectedPhoto) { _, item in
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
                CapyScreenContainer {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let playlist {
                            playlistHeader(playlist)
                            HStack(spacing: 10) {
                                Button { play(playlist.tracks) } label: { Label("Play", systemImage: "play.fill") }
                                    .buttonStyle(CapyPrimaryButtonStyle()).disabled(playlist.tracks.isEmpty)
                                Button { play(playlist.tracks.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }
                                    .buttonStyle(CapySecondaryButtonStyle()).disabled(playlist.tracks.isEmpty)
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { playlistActions(playlist) }
                                VStack(spacing: 0) { playlistActions(playlist) }
                            }
                            if let summary = player.downloadBatchSummary,
                               summary.playlistID == playlist.id {
                                DownloadBatchStatusView(summary: summary)
                            } else if let failed = playlist.tracks.first(where: { player.downloadFailures[$0.id] != nil }) {
                                Label("Some downloads need attention: \(failed.title)", systemImage: "exclamationmark.triangle.fill")
                                    .font(.capyCaption).foregroundStyle(CapyColor.warning)
                                    .lineLimit(3)
                            }
                            CapySectionHeader("Songs", subtitle: playlist.tracks.isEmpty ? "Add music from Search" : "Tap a row to play")
                            if playlist.tracks.isEmpty {
                                CapyScreenState(kind: .empty, title: "This playlist is ready", message: "Find a song in Search, open its menu, then choose Add to playlist.")
                            } else {
                                ForEach(playlist.tracks) { TrackCard(track: $0) }
                            }
                        }
                    }
                    .padding(.top, 18).padding(.bottom, 120)
                }
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
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                do { try player.setPlaylistArtwork(data, for: playlistID) }
                catch { player.error = error.localizedDescription }
            }
        }
    }

    private func playlistHeader(_ playlist: ImportedPlaylist) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 18) {
                PlaylistCover(playlist: playlist, size: 154, radius: 24)
                    .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
                playlistMetadata(playlist).frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Spacer(minLength: 0)
                    PlaylistCover(playlist: playlist, size: 230, radius: 28)
                    Spacer(minLength: 0)
                }
                playlistMetadata(playlist)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func playlistMetadata(_ playlist: ImportedPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(playlist.id.hasPrefix("album:") ? "SAVED ALBUM" : "PLAYLIST")
                .font(.caption2.weight(.black)).tracking(2).foregroundStyle(CapyColor.accent)
            Text(playlist.name)
                .font(.system(size: 30, weight: .black, design: .rounded))
                .lineLimit(4)
                .minimumScaleFactor(0.8)
            Text(auth.user?.displayName.map { "By \($0)" } ?? "Made on this iPhone")
                .font(.capyCaption).foregroundStyle(CapyColor.secondaryText).lineLimit(2)
            Text("\(playlist.tracks.count) songs")
                .font(.capyCaption).foregroundStyle(CapyColor.tertiaryText)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func playlistActions(_ playlist: ImportedPlaylist) -> some View {
        compactAction(
            player.isPlaylistDownloaded(playlist) ? "Downloaded" : "Download",
            icon: player.isPlaylistDownloaded(playlist) ? "arrow.down.circle.fill" : "arrow.down.circle"
        ) {
            Task { await player.downloadPlaylist(playlist) }
            CapyHaptics.impact()
        }
        .disabled(player.downloadingPlaylists.contains(playlist.id) || playlist.tracks.isEmpty)
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
            Label("Artwork", systemImage: "photo.badge.plus")
                .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain).font(.capyCaption).foregroundStyle(.white)
        if auth.user != nil {
            compactAction("Collaborate", icon: "person.2.badge.plus") { showCollaborate = true }
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
            CapyScreenContainer {
                LazyVStack(spacing: 14) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            Text(title)
                                .font(.system(size: 42, weight: .black, design: .rounded))
                                .lineLimit(2)
                                .minimumScaleFactor(0.72)
                            Text(subtitle).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Image(systemName: isOffline ? "arrow.down.circle.fill" : "music.note.list")
                            .font(.title).foregroundStyle(Color.waveBlue).frame(width: 56, height: 56).waveGlass(radius: 22)
                    }.padding(.bottom, 8)
                    if tracks.isEmpty {
                        VStack(spacing: 18) {
                            Image(systemName: isOffline ? "internaldrive" : "music.note.list").font(.system(size: 52)).foregroundStyle(Color.waveBlue)
                            Text(isOffline ? "Nothing downloaded yet" : "Your queue is clear").font(.title3.bold())
                            Text(isOffline ? "Download any search result to listen without internet." : "Add songs from search and they’ll wait here.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 30).padding(.vertical, 70)
                        .frame(maxWidth: .infinity)
                        .waveGlass(radius: 30)
                    } else { ForEach(tracks) { TrackCard(track: $0, canDelete: isOffline) } }
                }
                .padding(.top, 10).padding(.bottom, 30)
            }
        }.scrollIndicators(.hidden)
    }
}

private struct TrackCard: View {
    @EnvironmentObject var player: WavePlayer
    @EnvironmentObject var social: SocialStore
    let track: Track
    var canDelete = false
    var titleIdentifier: String? = nil
    var body: some View {
        HStack(spacing: 14) {
            Button { Task { await player.play(track) } } label: {
                HStack(spacing: 14) {
                    Artwork(track: track)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.headline.weight(.bold)).lineLimit(2)
                            .accessibilityIdentifier(titleIdentifier ?? "track-title-\(track.id)")
                        HStack(spacing: 6) {
                            Text(track.artist).lineLimit(1)
                            if let duration = track.duration, duration > 0 {
                                Text("•"); Text(shortTime(duration)).monospacedDigit()
                            }
                        }.font(.caption.weight(.semibold)).foregroundStyle(CapyColor.secondaryText)
                        if let state = player.downloadStates[track.id], state.stage != .downloaded {
                            Text(state.statusText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(state.stage == .failed ? CapyColor.warning : CapyColor.accent)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if let state = player.downloadStates[track.id] {
                downloadIndicator(state)
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

    @ViewBuilder private func downloadIndicator(_ state: TrackDownloadState) -> some View {
        switch state.stage {
        case .queued:
            Image(systemName: "clock.badge.checkmark")
                .foregroundStyle(CapyColor.secondaryText)
                .frame(width: 42, height: 42)
                .accessibilityLabel(state.statusText)
        case .preparing, .saving:
            ProgressView()
                .tint(CapyColor.accent)
                .frame(width: 42, height: 42)
                .accessibilityLabel(state.statusText)
        case .downloading:
            VStack(spacing: 3) {
                ProgressView(value: state.progress ?? 0)
                    .tint(CapyColor.accent)
                    .frame(width: 44)
                Text("\(Int(((state.progress ?? 0) * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(CapyColor.secondaryText)
            .accessibilityLabel(state.statusText)
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(CapyColor.accent)
                .frame(width: 42, height: 42)
                .accessibilityLabel(state.statusText)
        case .failed:
            Button {
                Task { await player.download(track) }
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(CapyColor.warning)
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry download. \(state.detail ?? "Previous download failed.")")
        }
    }
}

private struct DownloadBatchStatusView: View {
    let summary: DownloadBatchSummary

    var body: some View {
        HStack(spacing: 11) {
            if summary.finishedAt == nil {
                ProgressView().tint(CapyColor.accent)
            } else {
                Image(systemName: summary.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.failed == 0 ? CapyColor.accent : CapyColor.warning)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.finishedAt == nil ? "Download queue" : "Download finished")
                    .font(.capyCallout)
                Text(summary.statusText)
                    .font(.capyCaption)
                    .foregroundStyle(CapyColor.secondaryText)
                    .lineLimit(2)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .waveSurface(radius: 18, highlighted: summary.finishedAt == nil)
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
            .contextMenu {
                Button("Copy error details", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = message
                }
            }
    }
}

struct PlayerView: View {
    @EnvironmentObject var player: WavePlayer
    @Environment(\.dismiss) private var dismiss
    @State private var scrubPosition = 0.0
    @State private var isScrubbing = false
    @State private var showLyrics: Bool
    @State private var showQueue = false
    @State private var showAudioInfo = false

    init(showLyricsInitially: Bool = false) {
        _showLyrics = State(initialValue: showLyricsInitially)
    }
    var body: some View {
        GeometryReader { geometry in
            let horizontalInset = max(18, max(geometry.safeAreaInsets.leading, geometry.safeAreaInsets.trailing) + 18)
            let contentWidth = max(1, min(CapyMetric.readableWidth, geometry.size.width - (horizontalInset * 2)))
            let artworkSize = min(
                contentWidth,
                showLyrics ? max(126, geometry.size.height * 0.18) : min(340, geometry.size.height * 0.36)
            )
            ZStack {
                CapyAmbientBackdrop(
                    seed: player.current?.id ?? "capyflow-player",
                    artworkURL: player.current?.artwork,
                    intensity: 1.2
                )
                VStack(spacing: showLyrics ? 8 : 13) {
                    CenteredPlayerHeader {
                        Button { dismiss() } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(CapyIconButtonStyle())
                            .accessibilityLabel("Close Now Playing")
                        VStack(spacing: 2) {
                            Text("NOW PLAYING").font(.caption2.weight(.black)).tracking(2)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .accessibilityIdentifier("now-playing-centered-title")
                            Text(player.audioOutputName).font(.caption2)
                                .foregroundStyle(CapyColor.secondaryText).lineLimit(1)
                                .accessibilityIdentifier("now-playing-centered-output")
                        }
                        .frame(maxWidth: .infinity)
                        HStack {
                        AudioOutputPicker().frame(width: 44, height: 44)
                        Menu {
                            Button("Audio Info / Current Quality") { showAudioInfo = true }
                            Divider()
                            Button("Clear queue", role: .destructive) { player.queue.removeAll() }
                        } label: { Image(systemName: "ellipsis") }
                            .buttonStyle(CapyIconButtonStyle())
                        }
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
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
                // Constrain the stack before padding: maxWidth alone permits
                // long titles and sliders to retain a wider ideal size.
                .frame(width: contentWidth)
                .padding(.horizontal, horizontalInset)
                .padding(.top, max(8, geometry.safeAreaInsets.top))
                .padding(.bottom, max(10, geometry.safeAreaInsets.bottom))
                .frame(width: contentWidth + (horizontalInset * 2))
                .frame(maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .tint(CapyColor.accent)
        .onAppear { scrubPosition = player.elapsed }
        .onChange(of: player.elapsed) { _, value in if !isScrubbing { scrubPosition = value } }
        .onChange(of: player.current?.id) {
            scrubPosition = 0
        }
        .sheet(isPresented: $showQueue) { QueueSheet().presentationDetents([.medium, .large]) }
        .alert("Audio Info / Current Quality", isPresented: $showAudioInfo) {
            Button("Done", role: .cancel) {}
        } message: {
            Text(player.currentAudioInfo?.description ?? "Media details unavailable")
        }
    }
    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private struct QueueSheet: View {
    @EnvironmentObject var player: WavePlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                CapyAmbientBackdrop(seed: player.current?.id ?? "queue", artworkURL: player.current?.artwork)
                VStack(spacing: 0) {
                    Button {
                        player.autoplayEnabled.toggle()
                        CapyHaptics.selection()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "infinity").font(.callout.weight(.semibold))
                            Text("Related songs").font(.capyCallout)
                            Spacer()
                            Text(player.autoplayEnabled ? "On" : "Off").font(.caption.weight(.semibold))
                            Image(systemName: player.autoplayEnabled ? "checkmark.circle.fill" : "circle")
                        }
                        .foregroundStyle(player.autoplayEnabled ? CapyColor.accent : CapyColor.secondaryText)
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play related songs when the queue ends")
                    .accessibilityValue(player.autoplayEnabled ? "On" : "Off")
                    .accessibilityIdentifier("queue-autoplay")
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    List {
                        if let current = player.current {
                            Label("Now playing", systemImage: "waveform")
                                .font(.capyCallout).foregroundStyle(CapyColor.accent)
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                            TrackCard(track: current)
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        }
                        HStack {
                            Text("Up next").font(.capyCallout)
                            Spacer()
                            Text("\(player.queue.count) songs").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(CapyColor.secondaryText)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        if player.autoplayLoading {
                            HStack(spacing: 12) { ProgressView(); Text("Finding related songs…") }
                                .padding(12).listRowBackground(Color.clear).listRowSeparator(.hidden)
                        } else if player.queue.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("You’re all caught up").font(.capyCallout)
                                Text(player.autoplayEnabled ? "Related songs will keep the music flowing." : "Add songs to choose what plays next.")
                                    .font(.caption).foregroundStyle(CapyColor.secondaryText)
                            }
                            .padding(12).waveSurface(radius: 22)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        }
                        // Keep row identity attached to the recording, not its list
                        // position. Using the offset as identity makes SwiftUI reuse the
                        // destination row while native reordering animates, briefly
                        // compositing both songs in the same cell.
                        ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                            QueueTrackRow(
                                track: track,
                                position: index,
                                remove: { player.removeFromQueue(at: index) }
                            )
                            .id(track.id)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        }
                        .onMove { source, destination in
                            player.moveQueueItems(fromOffsets: source, toOffset: destination)
                        }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Queue").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(CapyColor.accent)
    }
}

private struct QueueTrackRow: View {
    let track: Track
    let position: Int
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TrackCard(track: track, titleIdentifier: "queue-title-\(position)")
                .frame(maxWidth: .infinity)

            // Native List reordering keeps the row inline/full-size and moves
            // neighbouring rows out of the way instead of creating a drag preview.
            Image(systemName: "line.3.horizontal")
                .font(.title3.weight(.semibold))
                .foregroundStyle(CapyColor.secondaryText)
                .frame(width: 38, height: 56)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                remove()
                CapyHaptics.selection()
            } label: {
                Label("Remove", systemImage: "trash.fill")
            }
            .accessibilityIdentifier("queue-action-trash-\(position)")
        }
        .accessibilityAction(named: "Remove") {
            remove()
            CapyHaptics.selection()
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
            .onChange(of: activeIndex) { _, index in
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
