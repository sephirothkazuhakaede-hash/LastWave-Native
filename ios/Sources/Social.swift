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

@MainActor final class SocialStore: ObservableObject {
    @Published private(set) var profile: SocialProfile?
    @Published private(set) var following: [SocialProfile] = []
    @Published private(set) var sharedPlaylists: [SharedPlaylist] = []
    @Published private(set) var followerCount = 0
    @Published private(set) var followingCount = 0
    @Published var searchResults: [SocialProfile] = []
    @Published var working = false
    @Published var error: String?

    private let db = Firestore.firestore()
    private var userID: String?
    private var listeners: [ListenerRegistration] = []

    func bind(to user: FirebaseAuth.User?) {
        listeners.forEach { $0.remove() }
        listeners.removeAll()
        profile = nil
        following = []
        sharedPlaylists = []
        followerCount = 0
        followingCount = 0
        searchResults = []
        userID = user?.uid
        guard let user else { return }
        Task {
            await ensureProfile(for: user)
            guard self.userID == user.uid else { return }
            listen(to: user.uid)
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
        } catch { self.error = error.localizedDescription }
    }

    func search(_ rawQuery: String) async {
        let query = Self.normalizedUsername(rawQuery)
        guard query.count >= 2 else { searchResults = []; return }
        do {
            let snapshot = try await db.collection("profiles")
                .whereField("usernameKey", isGreaterThanOrEqualTo: query)
                .whereField("usernameKey", isLessThan: query + "\u{f8ff}")
                .limit(to: 20)
                .getDocuments()
            searchResults = snapshot.documents.compactMap { SocialProfile(id: $0.documentID, data: $0.data()) }
                .filter { $0.id != userID }
        } catch { self.error = error.localizedDescription }
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
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult func publish(_ playlist: ImportedPlaylist) async -> String? {
        guard let uid = userID, let profile else {
            error = "Sign in and finish your profile before sharing a playlist."
            return nil
        }
        let key = "capyflow.cloudPlaylist.\(uid).\(playlist.id)"
        let playlistID = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
        let ref = db.collection("playlists").document(playlistID)
        do {
            let currentSnapshot = try await ref.getDocument()
            let current = currentSnapshot.data()
            let members = current?["memberIDs"] as? [String] ?? [uid]
            try await ref.setData([
                "sourceID": playlist.id,
                "name": playlist.name,
                "ownerID": uid,
                "ownerName": profile.username,
                "memberIDs": members,
                "tracks": playlist.tracks.map(\.firestoreData),
                "updatedAt": FieldValue.serverTimestamp(),
                "createdAt": current?["createdAt"] ?? FieldValue.serverTimestamp()
            ], merge: true)
            UserDefaults.standard.set(playlistID, forKey: key)
            return playlistID
        } catch {
            self.error = error.localizedDescription
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
        } catch { self.error = error.localizedDescription }
    }

    func add(_ track: Track, to playlist: SharedPlaylist) async {
        guard let uid = userID, playlist.memberIDs.contains(uid) else { return }
        do {
            try await db.collection("playlists").document(playlist.id).updateData([
                "tracks": FieldValue.arrayUnion([track.firestoreData]),
                "updatedAt": FieldValue.serverTimestamp()
            ])
        } catch { self.error = error.localizedDescription }
    }

    private func ensureProfile(for user: FirebaseAuth.User) async {
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
        } catch { self.error = "Social setup needs Firestore: \(error.localizedDescription)" }
    }

    private func listen(to uid: String) {
        listeners.append(db.collection("profiles").document(uid).addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.userID == uid else { return }
                if let data = snapshot?.data() { self.profile = SocialProfile(id: uid, data: data) }
                if let error { self.error = error.localizedDescription }
            }
        })
        listeners.append(db.collection("follows").whereField("followerID", isEqualTo: uid).addSnapshotListener { [weak self] snapshot, _ in
            let ids = snapshot?.documents.compactMap { $0.data()["followingID"] as? String } ?? []
            Task { @MainActor in await self?.loadFollowing(ids, owner: uid) }
        })
        listeners.append(db.collection("follows").whereField("followingID", isEqualTo: uid).addSnapshotListener { [weak self] snapshot, _ in
            Task { @MainActor in
                guard let self, self.userID == uid else { return }
                self.followerCount = snapshot?.documents.count ?? 0
            }
        })
        listeners.append(db.collection("playlists").whereField("memberIDs", arrayContains: uid).addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.userID == uid else { return }
                self.sharedPlaylists = snapshot?.documents.compactMap { SharedPlaylist(id: $0.documentID, data: $0.data()) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
                if let error { self.error = error.localizedDescription }
            }
        })
    }

    private func loadFollowing(_ ids: [String], owner uid: String) async {
        guard userID == uid else { return }
        followingCount = ids.count
        var people: [SocialProfile] = []
        for id in ids.prefix(50) {
            if let snapshot = try? await db.collection("profiles").document(id).getDocument(),
               let data = snapshot.data(), let profile = SocialProfile(id: id, data: data) { people.append(profile) }
        }
        guard userID == uid else { return }
        following = people.sorted { $0.username < $1.username }
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
