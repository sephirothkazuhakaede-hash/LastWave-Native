import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

struct SocialProfile: Identifiable, Equatable {
    let id: String
    let username: String
    let displayName: String
    let bio: String
    let avatarURL: URL?

    init?(id: String, data: [String: Any]) {
        guard let username = data["username"] as? String else { return nil }
        self.id = id
        self.username = username
        self.displayName = data["displayName"] as? String ?? username
        self.bio = data["bio"] as? String ?? ""
        self.avatarURL = (data["avatarURL"] as? String).flatMap(URL.init(string:))
    }
}

struct SharedPlaylist: Identifiable, Equatable {
    let id: String
    let sourceID: String
    let name: String
    let ownerID: String
    let ownerName: String
    let memberIDs: [String]
    let tracks: [Track]

    var imported: ImportedPlaylist { ImportedPlaylist(id: "cloud:" + id, name: name, tracks: tracks) }

    init?(id: String, data: [String: Any]) {
        guard let name = data["name"] as? String,
              let ownerID = data["ownerID"] as? String else { return nil }
        self.id = id
        self.sourceID = data["sourceID"] as? String ?? id
        self.name = name
        self.ownerID = ownerID
        self.ownerName = data["ownerName"] as? String ?? "CapyFlow listener"
        self.memberIDs = data["memberIDs"] as? [String] ?? [ownerID]
        self.tracks = (data["tracks"] as? [[String: Any]] ?? []).compactMap(Track.init(firestore:))
    }
}

enum SocialConnectionState: Equatable {
    case signedOut
    case connecting
    case ready
    case offline
    case setupRequired

    var title: String {
        switch self {
        case .signedOut: return "Social is off"
        case .connecting: return "Connecting to friends…"
        case .ready: return "Friends are connected"
        case .offline: return "Friends are temporarily offline"
        case .setupRequired: return "Friends need one-time setup"
        }
    }

    var detail: String {
        switch self {
        case .signedOut:
            return "Sign in to follow friends and share playlists. Music works without an account."
        case .connecting:
            return "Your music, downloads, and offline playback are independent from this connection."
        case .ready:
            return "Profiles, follows, and shared playlists are up to date."
        case .offline:
            return "Saved social information may still appear. Music and downloads keep working normally."
        case .setupRequired:
            return "The app owner still needs to enable the CapyFlow social database. Music and downloads are unaffected."
        }
    }

    var systemImage: String {
        switch self {
        case .signedOut: return "person.crop.circle.badge.xmark"
        case .connecting: return "person.2.circle"
        case .ready: return "person.2.circle.fill"
        case .offline: return "wifi.slash"
        case .setupRequired: return "wrench.and.screwdriver"
        }
    }

    var canRetry: Bool { self == .offline || self == .setupRequired }
}

@MainActor final class SocialStore: ObservableObject {
    @Published private(set) var profile: SocialProfile?
    @Published private(set) var following: [SocialProfile] = []
    @Published private(set) var sharedPlaylists: [SharedPlaylist] = []
    @Published private(set) var followerCount = 0
    @Published private(set) var followingCount = 0
    @Published var searchResults: [SocialProfile] = []
    @Published var working = false
    @Published var error: String?
    @Published private(set) var connectionState: SocialConnectionState = .signedOut

    private let db = Firestore.firestore()
    private var userID: String?
    private var boundUser: FirebaseAuth.User?
    private var listeners: [ListenerRegistration] = []
    private var setupTask: Task<Void, Never>?

    func bind(to user: FirebaseAuth.User?) {
        setupTask?.cancel()
        listeners.forEach { $0.remove() }
        listeners.removeAll()
        profile = nil
        following = []
        sharedPlaylists = []
        followerCount = 0
        followingCount = 0
        searchResults = []
        error = nil
        boundUser = user
        userID = user?.uid
        guard let user else { connectionState = .signedOut; return }
        startSocial(for: user)
    }

    func retryConnection() {
        guard let user = boundUser, userID == user.uid else { return }
        setupTask?.cancel()
        listeners.forEach { $0.remove() }
        listeners.removeAll()
        error = nil
        connectionState = .connecting
        startSocial(for: user)
    }

    func clearError() { error = nil }

    private func startSocial(for user: FirebaseAuth.User) {
        connectionState = .connecting
        listen(to: user.uid)
        setupTask = Task { [weak self] in
            guard let self else { return }
            await self.ensureProfileWithRetry(for: user)
        }
    }

    func saveProfile(username rawUsername: String, displayName rawDisplayName: String, bio rawBio: String) async {
        guard let uid = userID else { return }
        let username = Self.normalizedUsername(rawUsername)
        let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bio = String(rawBio.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard Self.validUsername(username) else {
            error = "Use 3–20 lowercase letters, numbers, underscores, or single dots for your username."
            return
        }
        guard !displayName.isEmpty else { error = "Add a display name first."; return }
        working = true; error = nil
        defer { working = false }
        do {
            let usernameRef = db.collection("usernames").document(username)
            let existing = try await usernameRef.getDocument()
            if let owner = existing.data()?["uid"] as? String, owner != uid {
                throw SocialError.message("That username is already taken.")
            }
            let profileRef = db.collection("profiles").document(uid)
            let oldUsername = profile?.username
            let batch = db.batch()
            if !existing.exists {
                batch.setData(["uid": uid, "createdAt": FieldValue.serverTimestamp()], forDocument: usernameRef)
            }
            batch.setData([
                "username": username,
                "usernameKey": username,
                "displayName": displayName,
                "bio": bio,
                "avatarURL": profile?.avatarURL?.absoluteString ?? "",
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: profileRef, merge: true)
            if let oldUsername, oldUsername != username {
                batch.deleteDocument(db.collection("usernames").document(oldUsername))
            }
            try await batch.commit()
        } catch { handleSocialError(error) }
    }

    func search(_ rawQuery: String) async {
        let query = Self.normalizedUsername(rawQuery)
        guard query.count >= 2 else { searchResults = []; return }
        do {
            let request = db.collection("profiles")
                .whereField("usernameKey", isGreaterThanOrEqualTo: query)
                .whereField("usernameKey", isLessThan: query + "\u{f8ff}")
                .limit(to: 20)
            let snapshot: QuerySnapshot
            do {
                snapshot = try await request.getDocuments()
            } catch {
                snapshot = try await request.getDocuments(source: .cache)
                connectionState = .offline
            }
            searchResults = snapshot.documents.compactMap { SocialProfile(id: $0.documentID, data: $0.data()) }
                .filter { $0.id != userID }
        } catch { handleSocialError(error) }
    }

    func isFollowing(_ profileID: String) -> Bool { following.contains { $0.id == profileID } }

    func setFollowing(_ person: SocialProfile, following shouldFollow: Bool) async {
        guard let uid = userID, uid != person.id else { return }
        let ref = db.collection("follows").document(uid + "_" + person.id)
        do {
            if shouldFollow {
                try await ref.setData([
                    "followerID": uid,
                    "followingID": person.id,
                    "createdAt": FieldValue.serverTimestamp()
                ])
            } else {
                try await ref.delete()
            }
        } catch { handleSocialError(error) }
    }

    @discardableResult func publish(_ playlist: ImportedPlaylist) async -> String? {
        guard let uid = userID, let profile else {
            error = "Sign in and finish your profile before sharing a playlist."
            return nil
        }
        let key = "capyflow.cloudPlaylist.\(uid).\(playlist.id)"
        let savedPlaylistID = UserDefaults.standard.string(forKey: key)
        let playlistID = savedPlaylistID ?? UUID().uuidString
        let ref = db.collection("playlists").document(playlistID)
        do {
            var data: [String: Any] = [
                "sourceID": playlist.id,
                "name": playlist.name,
                "ownerID": uid,
                "ownerName": profile.username,
                "tracks": playlist.tracks.map(\.firestoreData),
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if savedPlaylistID == nil {
                data["memberIDs"] = [uid]
                data["createdAt"] = FieldValue.serverTimestamp()
            }
            try await ref.setData(data, merge: true)
            UserDefaults.standard.set(playlistID, forKey: key)
            return playlistID
        } catch {
            handleSocialError(error)
            return nil
        }
    }

    func invite(username rawUsername: String, to playlist: ImportedPlaylist) async {
        let username = Self.normalizedUsername(rawUsername)
        guard !username.isEmpty, let playlistID = await publish(playlist) else { return }
        do {
            let reservation = try await db.collection("usernames").document(username).getDocument()
            guard let inviteeID = reservation.data()?["uid"] as? String else {
                throw SocialError.message("No CapyFlow profile uses @\(username).")
            }
            try await db.collection("playlists").document(playlistID).updateData([
                "memberIDs": FieldValue.arrayUnion([inviteeID]),
                "updatedAt": FieldValue.serverTimestamp()
            ])
        } catch { handleSocialError(error) }
    }

    func add(_ track: Track, to playlist: SharedPlaylist) async {
        guard let uid = userID, playlist.memberIDs.contains(uid) else { return }
        do {
            try await db.collection("playlists").document(playlist.id).updateData([
                "tracks": FieldValue.arrayUnion([track.firestoreData]),
                "updatedAt": FieldValue.serverTimestamp()
            ])
        } catch { handleSocialError(error) }
    }

    private func ensureProfileWithRetry(for user: FirebaseAuth.User) async {
        working = true
        defer { working = false }
        for attempt in 0..<3 {
            guard !Task.isCancelled, userID == user.uid else { return }
            do {
                try await ensureProfile(for: user)
                guard userID == user.uid else { return }
                error = nil
                if connectionState != .offline { connectionState = .ready }
                return
            } catch {
                guard !Task.isCancelled else { return }
                handleSocialError(error)
                guard shouldAutomaticallyRetry(error) else { return }
                guard attempt < 2 else { break }
                let delay = attempt == 0 ? 1_000_000_000 : 3_000_000_000
                try? await Task.sleep(nanoseconds: UInt64(delay))
            }
        }
        // A brand-new account that cannot reach Firestore after the bounded
        // retries usually means the project database/API has not had its
        // one-time console setup yet. Keep that state out of the audio path.
        if profile == nil, connectionState == .offline {
            connectionState = .setupRequired
            error = "Friends and shared playlists need one-time setup. Music and downloads are unaffected."
        }
    }

    private func ensureProfile(for user: FirebaseAuth.User) async throws {
        let ref = db.collection("profiles").document(user.uid)
        do {
            let snapshot = try await ref.getDocument()
            guard !snapshot.exists else { return }
            let base = Self.normalizedUsername(user.displayName ?? user.email?.components(separatedBy: "@").first ?? "capy")
            let prefix = String(user.uid.prefix(6)).lowercased()
            let stem = String((base.isEmpty ? "capy" : base).prefix(13))
            let username = Self.validUsername(stem) ? stem + "_" + prefix : "capy_" + prefix
            let usernameRef = db.collection("usernames").document(username)
            let batch = db.batch()
            batch.setData(["uid": user.uid, "createdAt": FieldValue.serverTimestamp()], forDocument: usernameRef)
            batch.setData([
                "username": username,
                "usernameKey": username,
                "displayName": user.displayName ?? "CapyFlow listener",
                "bio": "",
                "avatarURL": user.photoURL?.absoluteString ?? "",
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: ref)
            try await batch.commit()
        } catch {
            // Firestore's local cache is useful on a disconnected launch, but it must
            // never be mistaken for proof that a username is available.
            if let cached = try? await ref.getDocument(source: .cache), cached.exists { return }
            throw error
        }
    }

    private func listen(to uid: String) {
        listeners.append(db.collection("profiles").document(uid).addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.userID == uid else { return }
                if let data = snapshot?.data() { self.profile = SocialProfile(id: uid, data: data) }
                if let error { self.handleSocialError(error); return }
                if snapshot?.metadata.isFromCache == true {
                    self.connectionState = .offline
                } else if snapshot != nil {
                    self.connectionState = .ready
                    self.error = nil
                }
            }
        })
        listeners.append(db.collection("follows").whereField("followerID", isEqualTo: uid).addSnapshotListener { [weak self] snapshot, error in
            let ids = snapshot?.documents.compactMap { $0.data()["followingID"] as? String } ?? []
            Task { @MainActor in
                if let error { self?.handleSocialError(error); return }
                await self?.loadFollowing(ids, owner: uid)
            }
        })
        listeners.append(db.collection("follows").whereField("followingID", isEqualTo: uid).addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.userID == uid else { return }
                if let error { self.handleSocialError(error); return }
                self.followerCount = snapshot?.documents.count ?? 0
            }
        })
        listeners.append(db.collection("playlists").whereField("memberIDs", arrayContains: uid).addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.userID == uid else { return }
                self.sharedPlaylists = snapshot?.documents.compactMap { SharedPlaylist(id: $0.documentID, data: $0.data()) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
                if let error { self.handleSocialError(error) }
            }
        })
    }

    private func loadFollowing(_ ids: [String], owner uid: String) async {
        guard userID == uid else { return }
        followingCount = ids.count
        var people: [SocialProfile] = []
        for id in ids.prefix(50) {
            let ref = db.collection("profiles").document(id)
            let snapshot = (try? await ref.getDocument()) ?? (try? await ref.getDocument(source: .cache))
            if let data = snapshot?.data(), let profile = SocialProfile(id: id, data: data) { people.append(profile) }
        }
        guard userID == uid else { return }
        following = people.sorted { $0.username < $1.username }
    }

    private func shouldAutomaticallyRetry(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return code == FirestoreErrorCode.unavailable.rawValue ||
            code == FirestoreErrorCode.deadlineExceeded.rawValue ||
            code == FirestoreErrorCode.aborted.rawValue
    }

    private func handleSocialError(_ failure: Error) {
        guard userID != nil else { return }
        if let socialError = failure as? SocialError {
            error = socialError.localizedDescription
            return
        }

        let code = (failure as NSError).code
        switch code {
        case FirestoreErrorCode.cancelled.rawValue:
            return
        case FirestoreErrorCode.unavailable.rawValue,
             FirestoreErrorCode.deadlineExceeded.rawValue,
             FirestoreErrorCode.aborted.rawValue:
            connectionState = .offline
            error = "Friends and shared playlists are temporarily offline. Music and downloads still work normally."
        case FirestoreErrorCode.permissionDenied.rawValue,
             FirestoreErrorCode.failedPrecondition.rawValue,
             FirestoreErrorCode.notFound.rawValue:
            connectionState = .setupRequired
            error = "Friends and shared playlists need one-time setup. Music and downloads are unaffected."
        case FirestoreErrorCode.unauthenticated.rawValue:
            connectionState = .offline
            error = "Please sign in again to reconnect friends and shared playlists."
        case FirestoreErrorCode.alreadyExists.rawValue:
            error = "That username is already taken."
        case FirestoreErrorCode.resourceExhausted.rawValue:
            connectionState = .offline
            error = "Friends and shared playlists are busy right now. Please try again shortly."
        default:
            error = "Friends and shared playlists couldn't update. Music and downloads are unaffected."
        }
    }

    private static func normalizedUsername(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }
    }

    private static func validUsername(_ username: String) -> Bool {
        guard (3...20).contains(username.count),
              !username.hasPrefix("."), !username.hasSuffix("."),
              !username.contains("..") else { return false }
        return !["admin", "capyflow", "support"].contains(username)
    }
}

private enum SocialError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

private extension Track {
    init?(firestore data: [String: Any]) {
        guard let id = data["id"] as? String,
              let title = data["title"] as? String,
              let artist = data["artist"] as? String else { return nil }
        self.init(
            id: id,
            title: title,
            artist: artist,
            duration: data["duration"] as? Double,
            artworkURL: (data["artworkURL"] as? String).flatMap(URL.init(string:))
        )
    }

    var firestoreData: [String: Any] {
        var data: [String: Any] = ["id": id, "title": title, "artist": artist]
        if let duration { data["duration"] = duration }
        if let artworkURL { data["artworkURL"] = artworkURL.absoluteString }
        return data
    }
}
