import SwiftUI

// The same catalog search used by Search; this sheet never changes playback.
struct PlaylistSongPicker: View {
    @EnvironmentObject private var player: WavePlayer
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss
    let playlistID: String
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searching = false
    @State private var failure: String?
    @State private var adding: Set<String> = []
    @State private var added: Set<String> = []
    @FocusState private var searchFocused: Bool

    private var shared: SharedPlaylist? { social.sharedPlaylist(for: playlistID) }
    private var local: ImportedPlaylist? { player.playlists.first { $0.id == playlistID } }
    private var title: String { shared?.name ?? local?.name ?? "Playlist" }
    private var tracks: [Track] { shared?.tracks ?? local?.tracks ?? [] }
    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var displayed: [Track] { term.isEmpty ? player.recentTracks : results }
    private var canEdit: Bool { shared != nil || local != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                CapyAmbientBackdrop(seed: playlistID)
                ScrollView {
                    CapyScreenContainer {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            Text(title).font(.capyTitle).lineLimit(2)
                            Text("Find songs and add them without leaving your playlist.")
                                .font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass").foregroundStyle(CapyColor.secondaryText)
                                TextField("Search songs or artists", text: $query)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .submitLabel(.search).focused($searchFocused)
                                if !query.isEmpty {
                                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                        .foregroundStyle(CapyColor.secondaryText).accessibilityLabel("Clear search")
                                }
                            }.padding(14).background(CapyColor.surfaceStrong, in: RoundedRectangle(cornerRadius: 18))
                            CapySectionHeader(term.isEmpty ? "Recently played" : "Songs",
                                              subtitle: term.isEmpty ? "Your recent listens" : "YouTube Music results")
                            if !canEdit {
                                Text("This playlist is no longer available.").foregroundStyle(CapyColor.warning)
                            }
                            if searching { ProgressView("Searching…").padding(.vertical, 16) }
                            if let failure {
                                Text(failure).font(.capyCaption).foregroundStyle(CapyColor.warning)
                            }
                            ForEach(displayed) { track in songRow(track) }
                            if !searching && displayed.isEmpty && failure == nil {
                                ContentUnavailableView(term.isEmpty ? "Find your next song" : "No songs found",
                                                       systemImage: "music.note",
                                                       description: Text(term.isEmpty ? "Search for a song or artist above." : "Try another song title or artist."))
                            }
                        }.padding(.vertical, 18).padding(.bottom, 24)
                    }
                }.scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Add songs").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(CapyColor.accent) } }
            .task(id: term) {
                let requested = term
                results = []; failure = nil; searching = false
                guard !requested.isEmpty else { return }
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    try Task.checkCancellation()
                    searching = true
                    let found = try await player.catalog.search(requested)
                    try Task.checkCancellation()
                    guard term == requested else { return }
                    results = found; searching = false
                } catch {
                    guard !Task.isCancelled, term == requested else { return }
                    searching = false; failure = "Search could not load: " + error.localizedDescription
                }
            }
        }.presentationDetents([.large])
    }

    private func songRow(_ track: Track) -> some View {
        let isAdded = added.contains(track.id) || tracks.contains { $0.id == track.id || $0.playableID == track.playableID }
        return HStack(spacing: 12) {
            Artwork(track: track, size: 56, radius: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.capyCallout).lineLimit(2)
                Text(track.artist).font(.capyCaption).foregroundStyle(CapyColor.secondaryText).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await add(track) }
            } label: {
                VStack(spacing: 3) {
                    if adding.contains(track.id) { ProgressView() }
                    else { Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle").font(.title2) }
                    if isAdded { Text("Added").font(.caption2) }
                }.frame(width: 52, height: 52).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(isAdded ? CapyColor.secondaryText : CapyColor.accent)
                .disabled(isAdded || adding.contains(track.id) || !canEdit)
                .accessibilityLabel(isAdded ? "Already added " + track.title : "Add " + track.title)
        }.padding(.vertical, 5)
    }

    @MainActor private func add(_ track: Track) async {
        guard canEdit, !adding.contains(track.id) else { return }
        adding.insert(track.id); failure = nil
        defer { adding.remove(track.id) }
        if let shared {
            social.clearError()
            await social.add(track, to: shared)
            if let error = social.error { failure = error; return }
        } else {
            player.add(track, to: playlistID)
        }
        added.insert(track.id)
        CapyHaptics.selection()
    }
}

struct AddTrackToPlaylistSheet: View {
    @EnvironmentObject private var player: WavePlayer
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var addingID: String?
    @State private var failure: String?

    private var destinations: [ImportedPlaylist] {
        let local = player.playlists.filter { !$0.id.hasPrefix("album:") }
        let linked = Set(local.compactMap { social.sharedPlaylist(for: $0.id)?.id })
        return local + social.sharedPlaylists.filter { !linked.contains($0.id) }.map(\.imported)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WaveBackdrop()
                ScrollView {
                    CapyScreenContainer {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 12) {
                                Artwork(track: track, size: 56, radius: 12)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.title).font(.capyCallout).lineLimit(2)
                                    Text(track.artist).font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                                }
                            }.padding(.vertical, 8)
                            if let failure { Text(failure).font(.capyCaption).foregroundStyle(CapyColor.warning) }
                            if destinations.isEmpty {
                                ContentUnavailableView("No playlists yet", systemImage: "music.note.list",
                                                       description: Text("Create a playlist in Library first."))
                            }
                            ForEach(destinations) { playlist in
                                destinationRow(playlist)
                            }
                        }.padding(.vertical, 18)
                    }
                }
            }
            .navigationTitle("Add to playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.tint(CapyColor.accent) } }
        }.presentationDetents([.large])
    }

    private func destinationRow(_ playlist: ImportedPlaylist) -> some View {
        let shared = social.sharedPlaylist(for: playlist.id)
        let songs = shared?.tracks ?? playlist.tracks
        let contains = songs.contains { $0.id == track.id || $0.playableID == track.playableID }
        return Button {
            Task {
                addingID = playlist.id; failure = nil
                defer { addingID = nil }
                if let shared {
                    social.clearError()
                    await social.add(track, to: shared)
                    if let error = social.error { failure = error; return }
                } else { player.add(track, to: playlist.id) }
                CapyHaptics.selection(); dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                if let first = songs.first { Artwork(track: first, size: 56, radius: 12) }
                else {
                    Image(systemName: "music.note.list").foregroundStyle(CapyColor.accent)
                        .frame(width: 56, height: 56).background(CapyColor.surfaceStrong, in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(shared?.name ?? playlist.name).font(.capyCallout).foregroundStyle(Color.white).lineLimit(2)
                    Text(contains ? "Already added" : (shared == nil ? "\(songs.count) songs" : "Shared • \(songs.count) songs"))
                        .font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if addingID == playlist.id { ProgressView() }
                else { Image(systemName: contains ? "checkmark.circle.fill" : "plus.circle").font(.title2).foregroundStyle(CapyColor.accent) }
            }.padding(12).waveSurface(radius: 20)
        }.buttonStyle(.plain).disabled(addingID != nil || contains)
    }
}
