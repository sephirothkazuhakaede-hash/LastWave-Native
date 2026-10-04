import SwiftUI
import PhotosUI
import UIKit
import FirebaseFirestore

struct SocialHubView: View {
    @EnvironmentObject private var social: SocialStore
    @State private var query = ""
    @State private var showEditor = false

    var body: some View {
        ZStack {
            CapyAmbientBackdrop(seed: social.profile?.id ?? "capyflow-social", artworkURL: social.profile?.avatarURL, intensity: 0.85)
            ScrollView {
                CapyScreenContainer {
                    LazyVStack(spacing: 16) {
                        connectionCard
                        if let profile = social.profile {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 15) {
                                    SocialAvatar(profile: profile, size: 70)
                                    profileSummary(profile)
                                    Button("Edit") { showEditor = true }.buttonStyle(.bordered)
                                }
                                VStack(alignment: .leading, spacing: 14) {
                                    HStack(spacing: 14) {
                                        SocialAvatar(profile: profile, size: 70)
                                        profileSummary(profile)
                                    }
                                    Button("Edit profile") { showEditor = true }
                                        .buttonStyle(CapySecondaryButtonStyle())
                                }
                            }
                            .padding(16).waveSurface(radius: 24, highlighted: true)
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

                        FriendActivityShelf().padding(16).waveSurface(radius: 22)

                        if !social.sharedPlaylists.isEmpty {
                            HStack { Text("Shared playlists").font(.title3.bold()); Spacer(); Image(systemName: "person.2.fill").foregroundStyle(Color.waveBlue) }
                            ForEach(social.sharedPlaylists) { playlist in
                                NavigationLink { SharedPlaylistDetailView(playlistID: playlist.id) } label: {
                                    SharedPlaylistRow(playlist: playlist)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 10).padding(.bottom, 30)
                }
            }
        }
        .navigationTitle("Profile & Friends")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: query) {
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
                social.searchResults = []
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await social.search(query)
        }
        .sheet(isPresented: $showEditor) { ProfileEditorSheet() }
    }

    private func profileSummary(_ profile: SocialProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.displayName).font(.title2.bold()).lineLimit(2)
            Text("@" + profile.username).foregroundStyle(Color.waveBlue).lineLimit(1)
            HStack {
                NavigationLink("\(social.followerCount) followers") { RelationshipListView(ownerID: profile.id, kind: .followers) }
                NavigationLink("\(social.followingCount) following") { RelationshipListView(ownerID: profile.id, kind: .following) }
            }.font(.caption).foregroundStyle(CapyColor.secondaryText)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    private var connectionCard: some View {
        HStack(spacing: 13) {
            Group {
                if social.connectionState == .connecting { ProgressView().tint(CapyColor.accent) }
                else { Image(systemName: social.connectionState.systemImage).foregroundStyle(social.connectionState == .ready ? CapyColor.accent : CapyColor.warning) }
            }
            .frame(width: 42, height: 42).background(CapyColor.surfaceStrong, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(social.connectionState.title).font(.capyCallout)
                Text(social.error ?? social.connectionState.detail).font(.capyCaption).foregroundStyle(CapyColor.secondaryText).lineLimit(3)
            }
            Spacer(minLength: 4)
            if social.connectionState.canRetry {
                Button("Retry") { social.retryConnection(); CapyHaptics.selection() }
                    .font(.capyCaption).foregroundStyle(CapyColor.accent)
                    .frame(minWidth: 48, minHeight: 48).contentShape(Rectangle())
            }
        }
        .padding(14).waveSurface(radius: 20, highlighted: social.connectionState == .ready)
    }
}

private struct SocialPersonRow: View {
    @EnvironmentObject private var social: SocialStore
    let person: SocialProfile
    var body: some View {
        HStack(spacing: 13) {
            NavigationLink { SocialPersonProfileView(person: person) } label: {
                HStack(spacing: 13) {
                    SocialAvatar(profile: person, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.displayName).font(.headline).lineLimit(2)
                        Text("@" + person.username).font(.subheadline).foregroundStyle(CapyColor.secondaryText).lineLimit(1)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if person.id != social.currentUserID { FollowControl(person: person) }
            Menu {
                Button(social.isFollowing(person.id) ? "Unfollow" : "Follow") {
                    Task { await social.setFollowing(person, following: !social.isFollowing(person.id)) }
                }.disabled(person.id == social.currentUserID)
            } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44) }

        }
        .padding(12).waveSurface(radius: 20)
    }
}

struct SocialAvatar: View {
    let profile: SocialProfile
    let size: CGFloat
    var body: some View {
        Group {
            if let data = profile.avatarData,
               let image = SocialAvatarImageCache.image(profileID: profile.id, data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = profile.avatarURL {
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

@MainActor private enum SocialAvatarImageCache {
    private static let images = NSCache<NSString, UIImage>()

    static func image(profileID: String, data: Data) -> UIImage? {
        let key = "\(profileID):\(data.count):\(data.hashValue)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let decoded = UIImage(data: data) else { return nil }
        images.setObject(decoded, forKey: key, cost: data.count)
        return decoded
    }
}

struct ProfilePageView: View {
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var social: SocialStore
    @State private var showEditor = false

    var body: some View {
        ZStack {
            CapyAmbientBackdrop(seed: social.profile?.id ?? "capyflow-profile", artworkURL: social.profile?.avatarURL, intensity: 0.9)
            ScrollView {
                CapyScreenContainer {
                    VStack(spacing: 20) {
                        if let profile = social.profile {
                            SocialAvatar(profile: profile, size: 132)
                                .overlay { Circle().stroke(CapyColor.surfaceStroke, lineWidth: 1) }
                                .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
                            VStack(spacing: 6) {
                                Text(profile.displayName).font(.system(size: 32, weight: .black, design: .rounded)).multilineTextAlignment(.center)
                                Text("@" + profile.username).font(.capyBody).foregroundStyle(CapyColor.accent)
                                if !profile.bio.isEmpty {
                                    Text(profile.bio).font(.capyBody).foregroundStyle(CapyColor.secondaryText).multilineTextAlignment(.center)
                                }
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) {
                                    NavigationLink { RelationshipListView(ownerID: profile.id, kind: .followers) } label: { profileMetric("\(social.followerCount)", "Followers") }.buttonStyle(.plain)
                                    NavigationLink { RelationshipListView(ownerID: profile.id, kind: .following) } label: { profileMetric("\(social.followingCount)", "Following") }.buttonStyle(.plain)
                                    profileMetric("\(social.sharedPlaylists.count)", "Shared")
                                }
                                VStack(spacing: 10) {
                                    NavigationLink { RelationshipListView(ownerID: profile.id, kind: .followers) } label: { profileMetric("\(social.followerCount)", "Followers") }.buttonStyle(.plain)
                                    NavigationLink { RelationshipListView(ownerID: profile.id, kind: .following) } label: { profileMetric("\(social.followingCount)", "Following") }.buttonStyle(.plain)
                                    profileMetric("\(social.sharedPlaylists.count)", "Shared")
                                }
                            }
                            FriendActivityShelf().padding(16).waveSurface(radius: 22)
                            NavigationLink { MessagesInboxView() } label: { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
                                .buttonStyle(CapySecondaryButtonStyle())
                            NavigationLink { FriendActivitySettingsView() } label: { Label("Friend Activity privacy", systemImage: "hand.raised") }
                                .buttonStyle(CapySecondaryButtonStyle())
                            Button { showEditor = true; CapyHaptics.selection() } label: {
                                Label("Customize profile", systemImage: "person.crop.circle.badge.plus")
                            }
                            .buttonStyle(CapyPrimaryButtonStyle())

                            NavigationLink { SocialHubView() } label: {
                                Label("Friends & shared playlists", systemImage: "person.2.fill")
                                    .frame(maxWidth: .infinity, minHeight: 50).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).waveSurface(radius: 20)
                        } else if auth.user == nil {
                            Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 72)).foregroundStyle(CapyColor.accent)
                            Text("Your CapyFlow profile").font(.capyTitle)
                            Text("Sign in with Google to choose a username, profile picture, follow friends, and share playlists.")
                                .font(.capyBody).foregroundStyle(CapyColor.secondaryText).multilineTextAlignment(.center)
                            Button { Task { await auth.signInWithGoogle() } } label: {
                                Label("Continue with Google", systemImage: "person.badge.key.fill")
                            }
                            .buttonStyle(CapyPrimaryButtonStyle())
                            .disabled(auth.working)
                        } else if social.working || social.connectionState == .connecting {
                            ProgressView("Preparing your profile…").tint(CapyColor.accent).padding(40)
                        } else {
                            Image(systemName: social.connectionState.systemImage)
                                .font(.system(size: 64))
                                .foregroundStyle(CapyColor.warning)
                            Text(social.connectionState.title).font(.capyTitle).multilineTextAlignment(.center)
                            Text(social.error ?? social.connectionState.detail)
                                .font(.capyBody)
                                .foregroundStyle(CapyColor.secondaryText)
                                .multilineTextAlignment(.center)
                            if social.connectionState.canRetry {
                                Button { social.retryConnection(); CapyHaptics.selection() } label: {
                                    Label("Try again", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(CapyPrimaryButtonStyle())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24).padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditor) { ProfileEditorSheet() }
    }

    private func profileMetric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(label).font(.capyCaption).foregroundStyle(CapyColor.secondaryText).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14).waveSurface(radius: 18)
    }
}

private struct ProfileEditorSheet: View {
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var displayName = ""
    @State private var bio = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var processingPhoto = false
    var body: some View {
        NavigationStack {
            ZStack {
                WaveBackdrop()
                ScrollView {
                    VStack(spacing: 15) {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                avatarPreview
                                    .frame(width: 112, height: 112).clipShape(Circle())
                                Image(systemName: "camera.fill")
                                    .foregroundStyle(CapyColor.background)
                                    .padding(10).background(CapyColor.accent, in: Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        Text("Tap the photo to choose a custom profile picture.")
                            .font(.capyCaption).foregroundStyle(CapyColor.secondaryText).multilineTextAlignment(.center)
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(16).waveGlass(radius: 20)
                        availabilityLabel
                        TextField("Display name", text: $displayName).padding(16).waveGlass(radius: 20)
                        TextField("Bio", text: $bio, axis: .vertical).lineLimit(3...5).padding(16).waveGlass(radius: 20)
                        Text("Friends find you by your unique @username. Names ignore capitalization and can be changed once every 14 days.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = social.error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(CapyColor.warning)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .waveSurface(radius: 16)
                        }
                    }
                    .padding(22).padding(.bottom, 30)
                }
            }
            .navigationTitle("Edit Profile").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            social.clearError()
                            if await social.saveProfile(username: username, displayName: displayName, bio: bio, avatarData: avatarData) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(social.working || processingPhoto || !social.usernameAvailability.canSave || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                social.clearError()
                username = social.profile?.username ?? ""
                displayName = social.profile?.displayName ?? ""
                bio = social.profile?.bio ?? ""
                avatarData = social.profile?.avatarData
            }
            .task(id: username) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                _ = await social.checkUsernameAvailability(username)
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task {
                    processingPhoto = true
                    defer { processingPhoto = false }
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let resized = profileAvatarJPEG(from: data) else {
                        social.error = "That image couldn't be used. Try a different photo."
                        return
                    }
                    avatarData = resized
                    CapyHaptics.notification(.success)
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private var avatarPreview: some View {
        if let avatarData, let image = UIImage(data: avatarData) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let profile = social.profile {
            SocialAvatar(profile: profile, size: 112)
        } else {
            Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(CapyColor.accent)
        }
    }

    @ViewBuilder private var availabilityLabel: some View {
        if let message = social.usernameAvailability.message {
            HStack(spacing: 8) {
                switch social.usernameAvailability {
                case .checking:
                    ProgressView().controlSize(.small)
                case .available, .current:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(CapyColor.accent)
                default:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(CapyColor.warning)
                }
                Text(message).font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CollaborateSheet: View {
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss
    let playlist: ImportedPlaylist
    @State private var username = ""
    @State private var cloudID: String?
    @State private var working = false
    @State private var profiles: [String: SocialProfile] = [:]
    @State private var removeID: String?
    @State private var confirmRemove = false

    private var shared: SharedPlaylist? {
        social.sharedPlaylist(for: playlist.id) ?? social.sharedPlaylists.first { $0.id == cloudID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WaveBackdrop()
                ScrollView {
                    CapyScreenContainer {
                        VStack(alignment: .leading, spacing: 22) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(shared == nil ? "Build a playlist together" : "Manage collaborators", systemImage: "person.2.fill")
                                    .font(.capySection).foregroundStyle(CapyColor.accent)
                                Text(shared?.name ?? playlist.name).font(.capyTitle).lineLimit(3)
                                Text("Everyone here can add and remove songs. Your collection and shared playlist stay in sync.")
                                    .font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Invite a friend").font(.capyCallout)
                                TextField("Friend's @username", text: $username)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .padding(14).background(CapyColor.surfaceStrong, in: RoundedRectangle(cornerRadius: 16))
                                Button {
                                    Task {
                                        working = true
                                        if let id = await social.invite(username: username, to: playlist) {
                                            cloudID = id; username = ""
                                        }
                                        working = false
                                    }
                                } label: {
                                    if working { ProgressView().frame(maxWidth: .infinity) }
                                    else { Label("Add collaborator", systemImage: "person.badge.plus").frame(maxWidth: .infinity) }
                                }
                                .buttonStyle(CapyPrimaryButtonStyle())
                                .disabled(!UsernamePolicy.isValid(username) || working)
                                if shared == nil && cloudID == nil {
                                    Button {
                                        Task { working = true; cloudID = await social.publish(playlist); working = false }
                                    } label: { Label("Enable collaboration", systemImage: "person.2").frame(maxWidth: .infinity) }
                                        .buttonStyle(CapySecondaryButtonStyle()).disabled(working)
                                }
                            }.padding(16).waveSurface(radius: 22)

                            if let shared {
                                VStack(alignment: .leading, spacing: 12) {
                                    CapySectionHeader("People", subtitle: "\(shared.memberIDs.count) in this playlist")
                                    ForEach(shared.memberIDs.sorted { $0 == shared.ownerID && $1 != shared.ownerID }, id: \.self) { uid in
                                        collaboratorRow(uid, in: shared)
                                    }
                                }
                            }
                            if let error = social.error {
                                Text(error).font(.capyCaption).foregroundStyle(CapyColor.warning)
                            }
                        }.padding(.vertical, 20)
                    }
                }
            }
            .navigationTitle("Collaborate").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(CapyColor.accent) } }
            .task(id: shared?.memberIDs) {
                profiles = [:]
                for uid in shared?.memberIDs ?? [] {
                    guard !Task.isCancelled else { return }
                    if let person = await social.loadProfile(uid), !Task.isCancelled { profiles[uid] = person }
                }
            }
            .confirmationDialog("Remove collaborator?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove collaborator", role: .destructive) {
                    if let shared, let removeID {
                        Task { working = true; await social.removeMember(removeID, from: shared); working = false }
                    }
                }
                Button("Cancel", role: .cancel) { removeID = nil }
            } message: { Text("They will lose access to this playlist. Songs already added will stay.") }
        }
        .presentationDetents([.large])
    }

    private func collaboratorRow(_ uid: String, in shared: SharedPlaylist) -> some View {
        let person = profiles[uid] ?? social.following.first { $0.id == uid }
        let owner = uid == shared.ownerID
        return HStack(spacing: 12) {
            if let person { SocialAvatar(profile: person, size: 48) }
            else {
                Image(systemName: "person.fill").foregroundStyle(CapyColor.accent)
                    .frame(width: 48, height: 48).background(CapyColor.surfaceStrong, in: Circle())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(person?.displayName ?? (owner ? "Playlist owner" : "Collaborator")).font(.capyCallout).lineLimit(1)
                if let person { Text("@" + person.username).font(.capyCaption).foregroundStyle(CapyColor.secondaryText).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if owner {
                Text("Owner").font(.caption.weight(.semibold)).foregroundStyle(CapyColor.accent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(CapyColor.accent.opacity(0.12), in: Capsule())
            } else if shared.ownerID == social.currentUserID {
                Button { removeID = uid; confirmRemove = true } label: {
                    Image(systemName: "person.fill.badge.minus").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44).background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).foregroundStyle(Color.red).disabled(working)
                    .accessibilityLabel("Remove " + (person?.displayName ?? "collaborator"))
            } else {
                Text("Collaborator").font(.caption).foregroundStyle(CapyColor.secondaryText)
            }
        }.padding(12).waveSurface(radius: 20)
    }
}

struct SharedPlaylistDetailView: View {
    @State private var deletePresented = false
    @EnvironmentObject private var player: WavePlayer
    @EnvironmentObject private var social: SocialStore
    let playlistID: String
    @State private var renamePresented = false
    @State private var playlistName = ""
    @State private var managePresented = false
    @State private var addSongsPresented = false
    @Environment(\.dismiss) private var dismiss
    private var playlist: SharedPlaylist? { social.sharedPlaylists.first { $0.id == playlistID } }
    var body: some View {
        ZStack {
            CapyAmbientBackdrop(seed: playlistID, artworkURL: playlist?.tracks.first?.artwork)
            ScrollView {
                CapyScreenContainer {
                    LazyVStack(alignment: .leading, spacing: 15) {
                        if let playlist {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .bottom, spacing: 18) {
                                    sharedCover(playlist, size: 154)
                                    sharedMetadata(playlist).frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                                }
                                VStack(alignment: .leading, spacing: 16) {
                                    HStack { Spacer(minLength: 0); sharedCover(playlist, size: 230); Spacer(minLength: 0) }
                                    sharedMetadata(playlist)
                                }
                            }
                            HStack(spacing: 10) {
                                Button { player.queue = Array(playlist.tracks.dropFirst()); if let first = playlist.tracks.first { Task { await player.play(first) } } } label: {
                                    Label("Play", systemImage: "play.fill")
                                }.buttonStyle(CapyPrimaryButtonStyle())
                                Button { Task { await player.downloadPlaylist(playlist.imported) } } label: {
                                    Label("Download", systemImage: "arrow.down.circle")
                                }.buttonStyle(CapySecondaryButtonStyle())
                            }
                            Button { addSongsPresented = true } label: { Label("Add songs", systemImage: "plus").frame(maxWidth: .infinity) }
                                .buttonStyle(CapySecondaryButtonStyle())
                            CapySectionHeader("Songs", subtitle: "Everyone in this playlist sees shared changes")
                            ForEach(playlist.tracks) { track in
                                SocialTrackRow(track: track)
                                    .contextMenu {
                                        Button("Remove from shared playlist", role: .destructive) {
                                            Task { await social.remove(track, from: playlist) }
                                        }
                                    }
                            }
                            if let error = social.error { Text(error).font(.capyCaption).foregroundStyle(CapyColor.warning) }
                        } else { ProgressView().padding(50) }
                    }
                    .padding(.top, 18).padding(.bottom, 100)
                }
            }
        }
        .navigationTitle("Shared Playlist").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let playlist {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if playlist.ownerID == social.currentUserID {
                            Button("Rename playlist") { playlistName = playlist.name; renamePresented = true }
                            Button("Manage collaborators") { managePresented = true }
                            Button("Delete shared playlist", role: .destructive) { deletePresented = true }
                        } else if let uid = social.currentUserID {
                            Button("Leave playlist", role: .destructive) {
                                Task { await social.removeMember(uid, from: playlist) }
                            }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                }
            }
        }
        .alert("Delete shared playlist?", isPresented: $deletePresented) {
            Button("Delete", role: .destructive) { if let playlist { Task { await social.deleteSharedPlaylist(playlist) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Remove this shared playlist for everyone. Local playlists and downloaded songs will stay.") }
        .alert("Rename playlist", isPresented: $renamePresented) {
            TextField("Playlist name", text: $playlistName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let playlist { Task { await social.rename(playlist, to: playlistName) } } }
        }
        .sheet(isPresented: $addSongsPresented) { PlaylistSongPicker(playlistID: "cloud:" + playlistID) }
        .sheet(isPresented: $managePresented) {
            if let playlist { CollaborateSheet(playlist: playlist.imported) }
        }
        .onChange(of: playlist == nil) { _, missing in if missing { dismiss() } }
    }

    @ViewBuilder private func sharedCover(_ playlist: SharedPlaylist, size: CGFloat) -> some View {
        if let uid = social.currentUserID, let source = playlist.sourcePlaylist(for: uid) {
            PlaylistCover(playlist: source, size: size, radius: 24)
        } else {
            SharedCover(tracks: playlist.tracks, size: size)
        }
    }

    private func sharedMetadata(_ playlist: SharedPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SHARED PLAYLIST").font(.caption2.weight(.black)).tracking(2).foregroundStyle(CapyColor.accent)
            Text(playlist.name).font(.system(size: 30, weight: .black, design: .rounded)).lineLimit(3).minimumScaleFactor(0.8)
            Label("By @\(playlist.ownerName)", systemImage: "person.2.fill").font(.capyCaption).foregroundStyle(CapyColor.secondaryText).lineLimit(2)
            Text("\(playlist.tracks.count) songs • \(playlist.memberIDs.count) collaborators").font(.capyCaption).foregroundStyle(CapyColor.tertiaryText).lineLimit(2)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

struct SharedPlaylistRow: View {
    @EnvironmentObject private var social: SocialStore
    @State private var deletePresented = false
    let playlist: SharedPlaylist
    var body: some View {
        HStack(spacing: 13) {
            SharedCover(tracks: playlist.tracks, size: 68)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name).font(.headline).lineLimit(2)
                Text("@\(playlist.ownerName) • \(playlist.tracks.count) songs").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }.padding(11).waveSurface(radius: 22)
        .contextMenu {
            if playlist.ownerID == social.currentUserID {
                Button("Delete shared playlist", role: .destructive) { deletePresented = true }
            }
        }
        .alert("Delete shared playlist?", isPresented: $deletePresented) {
            Button("Delete", role: .destructive) { Task { await social.deleteSharedPlaylist(playlist) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Remove this shared playlist for everyone. Local playlists and downloaded songs will stay.") }
    }
}

private func profileAvatarJPEG(from data: Data) -> Data? {
    guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let rendered = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320), format: format).image { _ in
        UIColor(CapyColor.background).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 320, height: 320))
        let scale = max(320 / image.size.width, 320 / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(
            x: (320 - drawSize.width) / 2,
            y: (320 - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        ))
    }
    let compressionQualities: [CGFloat] = [0.82, 0.68, 0.54, 0.42]
    for quality in compressionQualities {
        if let jpeg = rendered.jpegData(compressionQuality: quality), jpeg.count <= 131_072 { return jpeg }
    }
    return nil
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

struct RelationshipListView: View {
    @EnvironmentObject private var social: SocialStore
    let ownerID: String
    let kind: RelationshipKind
    @State private var people: [SocialProfile] = []
    @State private var cursor: DocumentSnapshot?
    @State private var loading = false
    @State private var loaded = false
    @State private var hasMore = false
    @State private var failure: String?
    @State private var fromCache = false

    var body: some View {
        ZStack {
            WaveBackdrop()
            ScrollView {
                CapyScreenContainer {
                    LazyVStack(spacing: 10) {
                        if fromCache { Text("Showing saved profiles").font(.capyCaption).foregroundStyle(CapyColor.secondaryText) }
                        ForEach(people) { SocialPersonRow(person: $0) }
                        if let error = social.error { Text(error).font(.capyCaption).foregroundStyle(CapyColor.warning) }
                        if loading { ProgressView("Loading \(kind.rawValue.lowercased())…").padding(24) }
                        if let failure {
                            Text(failure).font(.capyCaption).foregroundStyle(CapyColor.warning)
                            Button("Retry") { Task { await load(reset: !loaded) } }.buttonStyle(CapySecondaryButtonStyle())
                        } else if loaded && people.isEmpty {
                            ContentUnavailableView("No \(kind.rawValue.lowercased()) yet", systemImage: "person.2",
                                                   description: Text(kind == .followers ? "People who follow this profile will appear here." : "Follow someone to see them here."))
                        }
                        if hasMore && !loading && failure == nil {
                            Button("Load more") { Task { await load(reset: false) } }.buttonStyle(CapySecondaryButtonStyle())
                        }
                    }.padding(.top, 16).padding(.bottom, 30)
                }
            }.refreshable { await load(reset: true) }
        }
        .navigationTitle(kind.rawValue).navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await load(reset: true) } }
    }

    @MainActor private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let page = try await social.relationshipPage(ownerID: ownerID, kind: kind, after: reset ? nil : cursor)
            try Task.checkCancellation()
            if reset { people = [] }
            let existing = Set(people.map(\.id))
            people.append(contentsOf: page.people.filter { !existing.contains($0.id) })
            cursor = page.cursor; hasMore = page.hasMore; fromCache = page.fromCache; loaded = true
        } catch {
            if !Task.isCancelled { failure = "Couldn't load \(kind.rawValue.lowercased()): " + error.localizedDescription }
        }
    }
}

struct SocialPersonProfileView: View {
    @EnvironmentObject private var social: SocialStore
    let person: SocialProfile
    var body: some View {
        ZStack {
            CapyAmbientBackdrop(seed: person.id, artworkURL: person.avatarURL)
            ScrollView {
                CapyScreenContainer {
                    VStack(spacing: 18) {
                        SocialAvatar(profile: person, size: 124)
                        Text(person.displayName).font(.capyTitle).multilineTextAlignment(.center)
                        Text("@" + person.username).foregroundStyle(CapyColor.accent)
                        if !person.bio.isEmpty { Text(person.bio).foregroundStyle(CapyColor.secondaryText) }
                        if person.id != social.currentUserID {
                            FollowControl(person: person)
                            if social.currentUserID != nil {
                                NavigationLink { DirectChatView(person: person) } label: { Label("Message", systemImage: "bubble.left") }
                                    .buttonStyle(CapyPrimaryButtonStyle())
                            }
                        }
                        HStack {
                            NavigationLink("Followers") { RelationshipListView(ownerID: person.id, kind: .followers) }
                            NavigationLink("Following") { RelationshipListView(ownerID: person.id, kind: .following) }
                        }.buttonStyle(CapySecondaryButtonStyle())
                        if let error = social.error { Text(error).font(.capyCaption).foregroundStyle(CapyColor.warning) }
                    }.padding(.vertical, 24)
                }
            }
        }.navigationTitle(person.displayName).navigationBarTitleDisplayMode(.inline)
    }
}

private struct FollowControl: View {
    @EnvironmentObject private var social: SocialStore
    let person: SocialProfile
    @State private var working = false
    var body: some View {
        let follows = social.isFollowing(person.id)
        Button {
            Task {
                working = true
                await social.setFollowing(person, following: !follows)
                working = false
            }
        } label: {
            if working { ProgressView().frame(minWidth: 56) }
            else { Text(follows ? "Following" : "Follow").font(.capyCaption) }
        }
        .buttonStyle(.borderedProminent).tint(follows ? CapyColor.surfaceStrong : CapyColor.accent)
        .foregroundStyle(follows ? Color.white : Color.black).disabled(working)
    }
}

struct FriendActivityShelf: View {
    @EnvironmentObject private var social: SocialStore
    @EnvironmentObject private var activity: ListeningActivityStore
    @EnvironmentObject private var player: WavePlayer
    var openPerson: ((SocialProfile) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Friend Activity").font(.capyCallout)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let friends = social.following.filter { person in
                    guard let item = activity.activities[person.id] else { return false }
                    return context.date.timeIntervalSince(item.updatedAt) < 86400
                }.sorted { (activity.activities[$0.id]?.updatedAt ?? .distantPast) > (activity.activities[$1.id]?.updatedAt ?? .distantPast) }
                if friends.isEmpty {
                    Text("When friends share their listening activity, it appears here.")
                        .font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(friends) { person in
                                if let item = activity.activities[person.id] {
                                    VStack(spacing: 7) {
                                        personLink(person, item: item)
                                        Button { Task { await player.play(item.track) } } label: {
                                            Text(item.track.title).font(.capyCaption).lineLimit(2)
                                                .foregroundStyle(CapyColor.secondaryText)
                                        }.buttonStyle(.plain).disabled(!item.canPlay)
                                        Text(item.track.artist).font(.caption2).foregroundStyle(CapyColor.tertiaryText).lineLimit(1)
                                        Text(item.isListening(at: context.date) ? "Listening now" : "Recently · " + item.updatedAt.formatted(.relative(presentation: .numeric)))
                                            .font(.caption2).foregroundStyle(item.isListening(at: context.date) ? CapyColor.accent : CapyColor.tertiaryText)
                                            .lineLimit(2)
                                    }.frame(width: 100)
                                }
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
            }
            if let error = activity.error {
                Text(error).font(.capyCaption).foregroundStyle(CapyColor.warning)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func personLink(_ person: SocialProfile, item: FriendListeningActivity) -> some View {
        if let openPerson {
            Button { openPerson(person) } label: { personLabel(person, item: item) }.buttonStyle(.plain)
        } else {
            NavigationLink { SocialPersonProfileView(person: person) } label: { personLabel(person, item: item) }.buttonStyle(.plain)
        }
    }
    private func personLabel(_ person: SocialProfile, item: FriendListeningActivity) -> some View {
        VStack(spacing: 6) {
            SocialAvatar(profile: person, size: 64)
                .overlay(alignment: .bottomTrailing) { Artwork(track: item.track, size: 28, radius: 6).offset(x: 7, y: 3) }
            Text(person.displayName).font(.capyCaption).foregroundStyle(.primary).lineLimit(1)
        }.accessibilityLabel("View \(person.displayName)'s profile")
    }
}

struct FriendActivitySettingsView: View {
    @EnvironmentObject private var activity: ListeningActivityStore
    @EnvironmentObject private var social: SocialStore
    var body: some View {
        ZStack {
            WaveBackdrop()
            ScrollView {
                CapyScreenContainer {
                    VStack(alignment: .leading, spacing: 18) {
                        Toggle("Share my listening activity", isOn: Binding(get: { activity.sharing }, set: { value in
                            Task { await activity.setSharing(value) }
                        }))
                        .tint(CapyColor.accent).disabled(social.currentUserID == nil || activity.preferenceLoading)
                        Text("Friends can see your current or recent song. Turning this off removes your shared activity. Only song details are shared.")
                            .font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                        if social.currentUserID == nil { Text("Sign in to share listening activity.").font(.capyCaption) }
                        if activity.preferenceLoading { ProgressView("Loading privacy preference…") }
                        if let error = activity.error {
                            Text(error).font(.capyCaption).foregroundStyle(CapyColor.warning)
                            Button("Retry preference sync") { Task { await activity.retryPreferenceSync() } }
                                .buttonStyle(CapySecondaryButtonStyle())
                        }
                    }.padding(16).waveSurface(radius: 20).padding(.top, 16)
                }
            }
        }.navigationTitle("Friend Activity").navigationBarTitleDisplayMode(.inline)
    }
}
