import SwiftUI

struct SocialHubView: View {
    @EnvironmentObject private var social: SocialStore
    @State private var query = ""
    @State private var showEditor = false

    var body: some View {
        ZStack {
            WaveBackdrop()
            ScrollView {
                LazyVStack(spacing: 16) {
                    if let profile = social.profile {
                        HStack(spacing: 15) {
                            SocialAvatar(profile: profile, size: 70)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.displayName).font(.title2.bold())
                                Text("@" + profile.username).foregroundStyle(Color.waveBlue)
                                Text("\(social.followerCount) followers  •  \(social.followingCount) following")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") { showEditor = true }.buttonStyle(.bordered)
                        }
                        .padding(15).waveSurface(radius: 24)
                    } else if social.working {
                        HStack { ProgressView(); Text("Setting up your CapyFlow profile…") }.padding(24)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Find people").font(.title3.bold())
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(Color.waveBlue)
                            TextField("Search @username", text: $query)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            if !query.isEmpty { Button { query = ""; social.searchResults = [] } label: { Image(systemName: "xmark.circle.fill") } }
                        }
                        .padding(.horizontal, 15).frame(height: 52).waveGlass(radius: 20)
                    }

                    if !social.searchResults.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(social.searchResults) { person in SocialPersonRow(person: person) }
                        }
                    } else if !social.following.isEmpty {
                        HStack { Text("Following").font(.title3.bold()); Spacer() }
                        ForEach(social.following) { person in SocialPersonRow(person: person) }
                    }

                    if !social.sharedPlaylists.isEmpty {
                        HStack { Text("Shared playlists").font(.title3.bold()); Spacer(); Image(systemName: "person.2.fill").foregroundStyle(Color.waveBlue) }
                        ForEach(social.sharedPlaylists) { playlist in
                            NavigationLink { SharedPlaylistDetailView(playlistID: playlist.id) } label: {
                                SharedPlaylistRow(playlist: playlist)
                            }.buttonStyle(.plain)
                        }
                    }

                    if let error = social.error {
                        Text(error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center).padding(14).waveSurface(radius: 18)
                    }
                }
                .padding(18).padding(.bottom, 30)
            }
        }
        .navigationTitle("Profile & Friends")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: query) {
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await social.search(query)
        }
        .sheet(isPresented: $showEditor) { ProfileEditorSheet() }
    }
}

private struct SocialPersonRow: View {
    @EnvironmentObject private var social: SocialStore
    let person: SocialProfile
    var body: some View {
        HStack(spacing: 13) {
            SocialAvatar(profile: person, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName).font(.headline)
                Text("@" + person.username).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            let follows = social.isFollowing(person.id)
            Button(follows ? "Following" : "Follow") {
                Task { await social.setFollowing(person, following: !follows) }
            }
            .buttonStyle(.borderedProminent)
            .tint(follows ? Color.white.opacity(0.12) : Color.waveBlue)
            .foregroundStyle(follows ? Color.primary : Color.black)
        }
        .padding(12).waveSurface(radius: 20)
    }
}

private struct SocialAvatar: View {
    let profile: SocialProfile
    let size: CGFloat
    var body: some View {
        Group {
            if let url = profile.avatarURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { avatarFallback }
            } else { avatarFallback }
        }
        .frame(width: size, height: size).clipShape(Circle())
    }
    private var avatarFallback: some View {
        ZStack {
            Color.waveBlue.opacity(0.18)
            Text(String(profile.displayName.prefix(1)).uppercased()).font(.title2.bold()).foregroundStyle(Color.waveBlue)
        }
    }
}

private struct ProfileEditorSheet: View {
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var displayName = ""
    @State private var bio = ""
    var body: some View {
        NavigationStack {
            ZStack {
                WaveBackdrop()
                VStack(spacing: 15) {
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().padding(16).waveGlass(radius: 20)
                    TextField("Display name", text: $displayName).padding(16).waveGlass(radius: 20)
                    TextField("Bio", text: $bio, axis: .vertical).lineLimit(3...5).padding(16).waveGlass(radius: 20)
                    Text("Friends find you by your unique @username. Your email is never shown publicly.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(22)
            }
            .navigationTitle("Edit Profile").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await social.saveProfile(username: username, displayName: displayName, bio: bio); if social.error == nil { dismiss() } } }
                        .disabled(social.working)
                }
            }
            .onAppear {
                username = social.profile?.username ?? ""
                displayName = social.profile?.displayName ?? ""
                bio = social.profile?.bio ?? ""
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct CollaborateSheet: View {
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss
    let playlist: ImportedPlaylist
    @State private var username = ""
    @State private var cloudID: String?
    @State private var working = false
    var body: some View {
        NavigationStack {
            ZStack {
                WaveBackdrop()
                VStack(spacing: 18) {
                    Image(systemName: "person.2.badge.plus").font(.system(size: 46)).foregroundStyle(Color.waveBlue)
                    Text("Share “\(playlist.name)”").font(.title2.bold()).multilineTextAlignment(.center)
                    Text("Publish the playlist to your CapyFlow account, then add a friend by username. Changes appear on both phones.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    TextField("Friend's @username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().padding(16).waveGlass(radius: 20)
                    Button {
                        Task {
                            working = true
                            await social.invite(username: username, to: playlist)
                            cloudID = await social.publish(playlist)
                            working = false
                        }
                    } label: {
                        Group { if working { ProgressView() } else { Label("Add collaborator", systemImage: "person.badge.plus") } }
                            .frame(maxWidth: .infinity).frame(height: 50).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent).tint(Color.waveBlue).foregroundStyle(.black)
                    .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                    Button {
                        Task { working = true; cloudID = await social.publish(playlist); working = false }
                    } label: {
                        Label(cloudID == nil ? "Publish shared copy" : "Shared copy updated", systemImage: cloudID == nil ? "icloud.and.arrow.up" : "checkmark.circle.fill")
                            .frame(maxWidth: .infinity).frame(height: 48).contentShape(Rectangle())
                    }.buttonStyle(.bordered).disabled(working)
                    if let error = social.error { Text(error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center) }
                    Spacer()
                }.padding(24)
            }
            .navigationTitle("Collaborate").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct SharedPlaylistDetailView: View {
    @EnvironmentObject private var player: WavePlayer
    @EnvironmentObject private var social: SocialStore
    let playlistID: String
    private var playlist: SharedPlaylist? { social.sharedPlaylists.first { $0.id == playlistID } }
    var body: some View {
        ZStack {
            WaveBackdrop()
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let playlist {
                        SharedCover(tracks: playlist.tracks, size: 220)
                        Text(playlist.name).font(.system(size: 34, weight: .black, design: .rounded)).multilineTextAlignment(.center)
                        Label("Shared by @\(playlist.ownerName)", systemImage: "person.2.fill").font(.subheadline).foregroundStyle(Color.waveBlue)
                        HStack {
                            Button { player.queue = Array(playlist.tracks.dropFirst()); if let first = playlist.tracks.first { Task { await player.play(first) } } } label: {
                                Label("Play all", systemImage: "play.fill").frame(maxWidth: .infinity).frame(height: 50)
                            }.buttonStyle(.borderedProminent).tint(Color.waveBlue).foregroundStyle(.black)
                            Button { Task { await player.downloadPlaylist(playlist.imported) } } label: {
                                Label("Download", systemImage: "arrow.down.circle").frame(maxWidth: .infinity).frame(height: 50)
                            }.buttonStyle(.bordered)
                        }
                        ForEach(playlist.tracks) { track in SocialTrackRow(track: track) }
                    } else { ProgressView().padding(50) }
                }.padding(18).padding(.bottom, 100)
            }
        }
        .navigationTitle("Shared Playlist").navigationBarTitleDisplayMode(.inline)
    }
}

struct SharedPlaylistRow: View {
    let playlist: SharedPlaylist
    var body: some View {
        HStack(spacing: 13) {
            SharedCover(tracks: playlist.tracks, size: 68)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name).font(.headline)
                Text("@\(playlist.ownerName) • \(playlist.tracks.count) songs").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }.padding(11).waveSurface(radius: 22)
    }
}

private struct SharedCover: View {
    let tracks: [Track]
    let size: CGFloat
    var body: some View {
        Group {
            if let first = tracks.first { Artwork(track: first, size: size, radius: 0) }
            else { ZStack { Color.waveBlue.opacity(0.16); Image(systemName: "person.2.fill").foregroundStyle(Color.waveBlue) } }
        }
        .frame(width: size, height: size).clipped().clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
    }
}

private struct SocialTrackRow: View {
    @EnvironmentObject private var player: WavePlayer
    let track: Track
    var body: some View {
        HStack(spacing: 12) {
            Button { Task { await player.play(track) } } label: {
                HStack(spacing: 12) {
                    Artwork(track: track, size: 58, radius: 13)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.headline).lineLimit(2)
                        Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button { player.queue.append(track) } label: { Label("Add to queue", systemImage: "text.append") }
                Button { Task { await player.download(track) } } label: { Label("Download", systemImage: "arrow.down.circle") }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
        }.padding(10).waveSurface(radius: 20, highlighted: player.current?.id == track.id)
    }
}
