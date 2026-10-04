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
    let avatarData: Data?
    let usernameChangedAt: Date?
    let usernameIsGenerated: Bool

    init?(id: String, data: [String: Any]) {
        guard let username = data["username"] as? String else { return nil }
        self.id = id
        self.username = username
        self.displayName = data["displayName"] as? String ?? username
        self.bio = data["bio"] as? String ?? ""
        self.avatarURL = (data["avatarURL"] as? String).flatMap(URL.init(string:))
        self.avatarData = data["avatarData"] as? Data
        self.usernameChangedAt = (data["usernameChangedAt"] as? Timestamp)?.dateValue()
        let generatedSuffix = "_" + String(id.prefix(6)).lowercased()
        self.usernameIsGenerated = data["usernameIsGenerated"] as? Bool ?? username.hasSuffix(generatedSuffix)
    }
}

enum UsernamePolicy {
    static let minimumLength = 3
    static let maximumLength = 20
    static let changeCooldown: TimeInterval = 14 * 24 * 60 * 60

    private static let reserved: Set<String> = [
        "admin", "administrator", "api", "apple", "capyflow", "everyone", "firebase",
        "google", "help", "here", "moderator", "mods", "null", "official", "owner",
        "root", "security", "staff", "support", "system", "undefined"
    ]

    static func key(from raw: String) -> String {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("@") { candidate.removeFirst() }
        return candidate.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func validationMessage(for raw: String) -> String? {
        let username = key(from: raw)
        guard (minimumLength...maximumLength).contains(username.count) else {
            return "Usernames must be \(minimumLength)–\(maximumLength) characters."
        }
        guard username.allSatisfy({ character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == ".")
        }) else {
            return "Use only letters, numbers, underscores, and dots."
        }
        guard username.first != ".", username.last != ".", !username.contains("..") else {
            return "Dots cannot be first, last, or repeated."
        }
        guard !reserved.contains(username) else {
            return "That username is reserved. Please choose another."
        }
        return nil
    }

    static func isValid(_ raw: String) -> Bool { validationMessage(for: raw) == nil }
}

enum UsernameAvailability: Equatable {
    case idle
    case checking(String)
    case current(String)
    case available(String)
    case taken(String)
    case invalid(String)
    case cooldown(until: Date)
    case unavailable(String)

    var canSave: Bool {
        switch self {
        case .current, .available: return true
        default: return false
        }
    }

    var message: String? {
        switch self {
        case .idle: return nil
        case .checking: return "Checking availability…"
        case .current: return "This is your current username."
        case .available(let username): return "@\(username) is available."
        case .taken(let username): return "@\(username) is already taken."
        case .invalid(let message), .unavailable(let message): return message
        case .cooldown(let date):
            return "You can change your username again \(date.formatted(date: .abbreviated, time: .omitted))."
        }
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

    func sourcePlaylist(for userID: String) -> ImportedPlaylist? {
        guard ownerID == userID, !sourceID.hasPrefix("cloud:") else { return nil }
        return ImportedPlaylist(id: sourceID, name: name, tracks: tracks)
    }

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

enum RelationshipKind: String { case followers = "Followers", following = "Following" }
struct RelationshipPage {
    let people: [SocialProfile]
    let cursor: DocumentSnapshot?
    let hasMore: Bool
    let fromCache: Bool
}

enum SocialConnectionState: Equatable {
    case signedOut
    case connecting
    case ready
    case offline
    case setupRequired

    func receivingProfileSnapshot(isFromCache: Bool, exists: Bool) -> SocialConnectionState {
        // A cache hit cannot demote ready, invent offline, or erase an error state.
        exists && !isFromCache && self != .setupRequired ? .ready : self
    }

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
    @Published private(set) var usernameAvailability: UsernameAvailability = .idle

    private let db = Firestore.firestore()
    private var userID: String?
    private var boundUser: FirebaseAuth.User?
    private var listeners: [ListenerRegistration] = []
    private var followingIDs: Set<String> = []
    private var profileCache: [String: (SocialProfile, Date)] = [:]
    private var followingListeners: [String: ListenerRegistration] = [:]
    var currentUserID: String? { userID }
    private var setupTask: Task<Void, Never>?
    private var listenerEpoch = UUID()

    func bind(to user: FirebaseAuth.User?) {
        listenerEpoch = UUID()
        setupTask?.cancel()
        listeners.forEach { $0.remove() }
        listeners.removeAll()
        followingListeners.values.forEach { $0.remove() }
        followingListeners.removeAll()
        profile = nil
        following = []
        followingIDs = []
        profileCache = [:]
        sharedPlaylists = []
        followerCount = 0
        followingCount = 0
        searchResults = []
        usernameAvailability = .idle
        error = nil
        boundUser = user
        userID = user?.uid
        guard let user else { connectionState = .signedOut; return }
        startSocial(for: user)
    }

    func retryConnection() {
        guard let user = boundUser, userID == user.uid else { return }
        listenerEpoch = UUID()
        setupTask?.cancel()
        listeners.forEach { $0.remove() }
        listeners.removeAll()
        followingListeners.values.forEach { $0.remove() }
        followingListeners.removeAll()
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

    @discardableResult func saveProfile(
        username rawUsername: String,
        displayName rawDisplayName: String,
        bio rawBio: String,
        avatarData newAvatarData: Data? = nil
    ) async -> Bool {
        guard let uid = userID else { error = "Sign in before saving your profile."; return false }
        let username = UsernamePolicy.key(from: rawUsername)
        let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bio = String(rawBio.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        if let validationMessage = UsernamePolicy.validationMessage(for: rawUsername) {
            usernameAvailability = .invalid(validationMessage)
            error = validationMessage
            return false
        }
        guard !displayName.isEmpty else { error = "Add a display name first."; return false }
        guard displayName.count <= 60 else { error = "Display names can be up to 60 characters."; return false }
        let avatarData = newAvatarData ?? profile?.avatarData
        guard avatarData?.count ?? 0 <= 131_072 else {
            error = "That profile photo is still too large. Choose another image."
            return false
        }
        if username != profile?.username, let nextChange = nextUsernameChangeDate, nextChange > Date() {
            usernameAvailability = .cooldown(until: nextChange)
            error = usernameAvailability.message
            return false
        }
        working = true; error = nil
        defer { working = false }
        do {
            try await commitProfileUpdate(
                uid: uid,
                username: username,
                displayName: displayName,
                bio: bio,
                avatarURL: profile?.avatarURL?.absoluteString ?? "",
                avatarData: avatarData
            )
            usernameAvailability = .current(username)
            connectionState = .ready
            return true
        } catch {
            if isSocialTransactionError(error, code: .usernameTaken) {
                usernameAvailability = .taken(username)
            }
            handleSocialError(error)
            return false
        }
    }

    var nextUsernameChangeDate: Date? {
        guard profile?.usernameIsGenerated != true, let changedAt = profile?.usernameChangedAt else { return nil }
        return changedAt.addingTimeInterval(UsernamePolicy.changeCooldown)
    }

    @discardableResult
    func checkUsernameAvailability(_ rawUsername: String) async -> UsernameAvailability {
        let username = UsernamePolicy.key(from: rawUsername)
        if let validationMessage = UsernamePolicy.validationMessage(for: rawUsername) {
            let state = UsernameAvailability.invalid(validationMessage)
            usernameAvailability = state
            return state
        }
        if username == profile?.username {
            let state = UsernameAvailability.current(username)
            usernameAvailability = state
            return state
        }
        if let nextChange = nextUsernameChangeDate, nextChange > Date() {
            let state = UsernameAvailability.cooldown(until: nextChange)
            usernameAvailability = state
            return state
        }

        usernameAvailability = .checking(username)
        do {
            let snapshot = try await db.collection("usernames").document(username).getDocument(source: .server)
            guard !Task.isCancelled else { return usernameAvailability }
            let owner = snapshot.data()?["uid"] as? String
            let state: UsernameAvailability = owner == nil || owner == userID ? .available(username) : .taken(username)
            usernameAvailability = state
            return state
        } catch {
            guard !Task.isCancelled else { return usernameAvailability }
            let state = UsernameAvailability.unavailable("Couldn't verify availability. Check your connection and try again.")
            usernameAvailability = state
            return state
        }
    }

    func search(_ rawQuery: String) async {
        let query = UsernamePolicy.key(from: rawQuery)
        guard query.count >= 2,
              query.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }) else {
            searchResults = []
            return
        }
        do {
            let request = db.collection("profiles")
                .whereField("usernameKey", isGreaterThanOrEqualTo: query)
                .whereField("usernameKey", isLessThan: query + "\u{f8ff}")
                .limit(to: 20)
            let snapshot: QuerySnapshot
            do {
                snapshot = try await request.getDocuments()
            } catch {
                handleSocialError(error)
                snapshot = try await request.getDocuments(source: .cache)
            }
            var people = snapshot.documents.compactMap { SocialProfile(id: $0.documentID, data: $0.data()) }

            // The reservation lookup also finds exact legacy profiles that predate
            // usernameKey prefix indexing. Relationships continue to use the UID.
            if !people.contains(where: { $0.username == query }) {
                let reservation = try? await db.collection("usernames").document(query).getDocument()
                if let exactID = reservation?.data()?["uid"] as? String,
                   let exact = await loadProfile(exactID) {
                    people.append(exact)
                }
            }
            guard !Task.isCancelled else { return }
            searchResults = people
                .filter { $0.id != userID }
                .uniqued(by: \SocialProfile.id)
                .sorted {
                    if $0.username == query { return true }
                    if $1.username == query { return false }
                    return $0.username.localizedStandardCompare($1.username) == .orderedAscending
                }
        } catch { handleSocialError(error) }
    }

    func isFollowing(_ profileID: String) -> Bool { followingIDs.contains(profileID) || following.contains { $0.id == profileID } }

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
            if userID == uid {
                if shouldFollow { followingIDs.insert(person.id) } else { followingIDs.remove(person.id) }
                objectWillChange.send()
            }
        } catch { handleSocialError(error) }
    }

    func sharedPlaylist(for playlistID: String) -> SharedPlaylist? {
        sharedPlaylists.first {
            "cloud:" + $0.id == playlistID ||
            ($0.ownerID == userID && $0.sourceID == playlistID)
        }
    }

    @discardableResult func publish(_ playlist: ImportedPlaylist) async -> String? {
        guard let uid = userID, let profile else {
            error = "Sign in and finish your profile before sharing a playlist."
            return nil
        }
        let key = "capyflow.cloudPlaylist.\(uid).\(playlist.id)"
        let savedPlaylistID = sharedPlaylist(for: playlist.id)?.id ?? (playlist.id.hasPrefix("cloud:") ? String(playlist.id.dropFirst(6))
            : UserDefaults.standard.string(forKey: key))
        let playlistID = savedPlaylistID ?? UUID().uuidString
        let ref = db.collection("playlists").document(playlistID)
        do {
            if savedPlaylistID != nil {
                let existing = try await ref.getDocument(source: .server)
                if existing.exists {
                    guard existing.data()?["ownerID"] as? String == uid else {
                        throw SocialError.message("Only the playlist owner can invite collaborators.")
                    }
                    return playlistID
                }
            }
            var data: [String: Any] = [
                "sourceID": playlist.id,
                "name": playlist.name,
                "ownerID": uid,
                "ownerName": profile.username,
                "tracks": playlist.tracks.map(\.firestoreData),
                "updatedAt": FieldValue.serverTimestamp()
            ]
            data["memberIDs"] = [uid]
            data["createdAt"] = FieldValue.serverTimestamp()
            try await ref.setData(data, merge: true)
            UserDefaults.standard.set(playlistID, forKey: key)
            return playlistID
        } catch {
            handleSocialError(error)
            return nil
        }
    }

    func invite(username rawUsername: String, to playlist: ImportedPlaylist) async -> String? {
        let username = UsernamePolicy.key(from: rawUsername)
        guard UsernamePolicy.isValid(username) else {
            error = UsernamePolicy.validationMessage(for: rawUsername) ?? "Enter a valid username."
            return nil
        }
        guard let playlistID = await publish(playlist) else { return nil }
        do {
            let reservation = try await db.collection("usernames").document(username).getDocument()
            guard let inviteeID = reservation.data()?["uid"] as? String else {
                throw SocialError.message("No CapyFlow profile uses @\(username).")
            }
            try await db.collection("playlists").document(playlistID).updateData([
                "memberIDs": FieldValue.arrayUnion([inviteeID]),
                "updatedAt": FieldValue.serverTimestamp()
            ])
            return playlistID
        } catch { handleSocialError(error); return nil }
    }

    func add(_ track: Track, to playlist: SharedPlaylist) async {
        await editSharedTracks(playlistID: playlist.id, adding: track, removingID: nil)
    }

    func remove(_ track: Track, from playlist: SharedPlaylist) async {
        await editSharedTracks(playlistID: playlist.id, adding: nil, removingID: track.id)
    }

    private func editSharedTracks(playlistID: String, adding: Track?, removingID: String?) async {
        guard let uid = userID else { return }
        let ref = db.collection("playlists").document(playlistID)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                db.runTransaction({ transaction, errorPointer -> Any? in
                    do {
                        let snapshot = try transaction.getDocument(ref)
                        guard let data = snapshot.data(), (data["memberIDs"] as? [String])?.contains(uid) == true else {
                            throw SocialError.message("You are no longer a member of this playlist.")
                        }
                        var tracks = data["tracks"] as? [[String: Any]] ?? []
                        if let removingID { tracks.removeAll { $0["id"] as? String == removingID } }
                        if let adding, !tracks.contains(where: { $0["id"] as? String == adding.id }) { tracks.append(adding.firestoreData) }
                        transaction.updateData(["tracks": tracks, "updatedAt": FieldValue.serverTimestamp()], forDocument: ref)
                        return nil
                    } catch { errorPointer?.pointee = error as NSError; return nil }
                }, completion: { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } catch { handleSocialError(error) }
    }

    func rename(_ playlist: SharedPlaylist, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard playlist.ownerID == userID, !name.isEmpty, name.count <= 100 else {
            error = "Only the owner can rename a playlist. Use a name of 1–100 characters."; return
        }
        do { try await db.collection("playlists").document(playlist.id).updateData(["name": name, "updatedAt": FieldValue.serverTimestamp()]) }
        catch { handleSocialError(error) }
    }

    func deleteSharedPlaylist(_ playlist: SharedPlaylist) async {
        guard playlist.ownerID == userID else {
            error = "Only the owner can delete a shared playlist."; return
        }
        do {
            try await db.collection("playlists").document(playlist.id).delete()
            sharedPlaylists.removeAll { $0.id == playlist.id }
        } catch { handleSocialError(error) }
    }

    func removeMember(_ uid: String, from playlist: SharedPlaylist) async {
        guard uid != playlist.ownerID, playlist.ownerID == userID || uid == userID else {
            error = "Only the owner can remove another collaborator."; return
        }
        do { try await db.collection("playlists").document(playlist.id).updateData([
            "memberIDs": FieldValue.arrayRemove([uid]), "updatedAt": FieldValue.serverTimestamp()
        ]) } catch { handleSocialError(error) }
    }

    private func commitProfileUpdate(
        uid: String,
        username: String,
        displayName: String,
        bio: String,
        avatarURL: String,
        avatarData: Data?
    ) async throws {
        let usernames = db.collection("usernames")
        let profileRef = db.collection("profiles").document(uid)
        let usernameRef = usernames.document(username)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            db.runTransaction({ transaction, errorPointer -> Any? in
                do {
                    let profileSnapshot = try transaction.getDocument(profileRef)
                    guard let profileData = profileSnapshot.data(),
                          let previousUsername = profileData["username"] as? String else {
                        throw socialTransactionError(.profileMissing, "Your profile is still being prepared. Please try again.")
                    }

                    // Firestore retries this entire block when another client changes
                    // either document. The reservation check and profile rename are one
                    // atomic operation, so two users cannot claim the same key.
                    let reservation = try transaction.getDocument(usernameRef)
                    if let owner = reservation.data()?["uid"] as? String, owner != uid {
                        throw socialTransactionError(.usernameTaken, "That username is already taken.")
                    }

                    let isRename = previousUsername != username
                    let previousReservation = isRename
                        ? try transaction.getDocument(usernames.document(previousUsername)) : nil
                    if isRename, profileData["usernameIsGenerated"] as? Bool != true,
                       let changedAt = (profileData["usernameChangedAt"] as? Timestamp)?.dateValue() {
                        let nextChange = changedAt.addingTimeInterval(UsernamePolicy.changeCooldown)
                        if nextChange > Date() {
                            throw socialTransactionError(
                                .usernameCooldown,
                                "You can change your username again \(nextChange.formatted(date: .abbreviated, time: .omitted))."
                            )
                        }
                    }

                    if !reservation.exists {
                        transaction.setData([
                            "uid": uid,
                            "createdAt": FieldValue.serverTimestamp()
                        ], forDocument: usernameRef)
                    }

                    var update: [String: Any] = [
                        "username": username,
                        "usernameKey": username,
                        "displayName": displayName,
                        "bio": bio,
                        "avatarURL": avatarURL,
                        "updatedAt": FieldValue.serverTimestamp()
                    ]
                    if let avatarData { update["avatarData"] = avatarData }
                    if isRename {
                        update["usernameIsGenerated"] = false
                        update["usernameChangedAt"] = FieldValue.serverTimestamp()
                    }
                    transaction.updateData(update, forDocument: profileRef)

                    if isRename, previousReservation?.data()?["uid"] as? String == uid {
                        transaction.deleteDocument(usernames.document(previousUsername))
                    }
                    return nil
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }, completion: { _, failure in
                if let failure { continuation.resume(throwing: failure) }
                else { continuation.resume() }
            })
        }
    }

    /// One edge page and batched profile reads, performed on page load rather
    /// than in row bodies. Firestore profile list rules cap each batch at 20.
    func relationshipPage(ownerID: String, kind: RelationshipKind,
                          after cursor: DocumentSnapshot? = nil) async throws -> RelationshipPage {
        var query: Query = db.collection("follows")
            .whereField(kind == .followers ? "followingID" : "followerID", isEqualTo: ownerID)
            .order(by: FieldPath.documentID()).limit(to: 50)
        if let cursor { query = query.start(afterDocument: cursor) }
        let snapshot = try await query.getDocuments()
        try Task.checkCancellation()
        let ids = snapshot.documents.compactMap { $0.data()[kind == .followers ? "followerID" : "followingID"] as? String }
        var people: [SocialProfile] = []
        let missing = ids.filter { id in
            if let cached = profileCache[id], Date().timeIntervalSince(cached.1) < 300 { people.append(cached.0); return false }
            return true
        }
        for start in stride(from: 0, to: missing.count, by: 20) {
            let batch = Array(missing[start..<min(start + 20, missing.count)])
            let profiles = try await db.collection("profiles").whereField(FieldPath.documentID(), in: batch).limit(to: 20).getDocuments()
            try Task.checkCancellation()
            for document in profiles.documents {
                if let person = SocialProfile(id: document.documentID, data: document.data()) {
                    profileCache[person.id] = (person, Date()); people.append(person)
                }
            }
        }
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        people.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        return RelationshipPage(people: people, cursor: snapshot.documents.last, hasMore: snapshot.documents.count == 50,
                                fromCache: snapshot.metadata.isFromCache)
    }

    func loadProfile(_ uid: String) async -> SocialProfile? {
        let ref = db.collection("profiles").document(uid)
        let snapshot: DocumentSnapshot?
        do {
            snapshot = try await ref.getDocument()
        } catch {
            snapshot = try? await ref.getDocument(source: .cache)
        }
        guard let data = snapshot?.data() else { return nil }
        return SocialProfile(id: uid, data: data)
    }

    private func ensureProfileWithRetry(for user: FirebaseAuth.User) async {
        let epoch = listenerEpoch
        working = true
        defer { if listenerEpoch == epoch { working = false } }
        for attempt in 0..<3 {
            guard !Task.isCancelled, userID == user.uid else { return }
            do {
                try await ensureProfile(for: user)
                guard !Task.isCancelled, userID == user.uid, listenerEpoch == epoch else { return }
                if connectionState != .setupRequired {
                    if connectionState == .offline { error = nil }
                    connectionState = .ready
                }
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
    }

    private func ensureProfile(for user: FirebaseAuth.User) async throws {
        let ref = db.collection("profiles").document(user.uid)
        do {
            let snapshot = try await ref.getDocument(source: .server)
            if let username = snapshot.data()?["username"] as? String, UsernamePolicy.isValid(username) {
                try await repairProfile(for: user)
                return
            }
            var lastFailure: Error?
            for candidate in generatedUsernameCandidates(for: user) {
                do {
                    try await createProfile(user: user, username: candidate)
                    return
                } catch {
                    lastFailure = error
                    guard isSocialTransactionError(error, code: .usernameTaken) else { throw error }
                }
            }
            throw lastFailure ?? socialTransactionError(.usernameTaken, "Couldn't reserve an initial username. Please try again.")
        } catch {
            // The profile listener already exposes cache data. The caller handles
            // this actual server failure; no cache-derived connectivity decisions.
            throw error
        }
    }

    private func createProfile(user: FirebaseAuth.User, username: String) async throws {
        let profileRef = db.collection("profiles").document(user.uid)
        let usernameRef = db.collection("usernames").document(username)
        let rawDisplayName = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = String(((rawDisplayName?.isEmpty == false ? rawDisplayName : nil) ?? "CapyFlow listener").prefix(60))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            db.runTransaction({ transaction, errorPointer -> Any? in
                do {
                    let profileSnapshot = try transaction.getDocument(profileRef)
                    let existing = profileSnapshot.data() ?? [:]
                    if let currentName = existing["username"] as? String, UsernamePolicy.isValid(currentName) { return nil }

                    let reservation = try transaction.getDocument(usernameRef)
                    if let owner = reservation.data()?["uid"] as? String, owner != user.uid {
                        throw socialTransactionError(.usernameTaken, "That username is already taken.")
                    }
                    if !reservation.exists {
                        transaction.setData([
                            "uid": user.uid,
                            "createdAt": FieldValue.serverTimestamp()
                        ], forDocument: usernameRef)
                    }
                    transaction.setData([
                        "username": username,
                        "usernameKey": username,
                        "usernameIsGenerated": true,
                        "displayName": existing["displayName"] as? String ?? displayName,
                        "bio": existing["bio"] as? String ?? "",
                        "avatarURL": existing["avatarURL"] as? String ?? user.photoURL?.absoluteString ?? "",
                        "createdAt": existing["createdAt"] ?? FieldValue.serverTimestamp(),
                        "updatedAt": FieldValue.serverTimestamp()
                    ], forDocument: profileRef, merge: true)
                    return nil
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }, completion: { _, failure in
                if let failure { continuation.resume(throwing: failure) }
                else { continuation.resume() }
            })
        }
    }

    private func repairProfile(for user: FirebaseAuth.User) async throws {
        let ref = db.collection("profiles").document(user.uid)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            db.runTransaction({ transaction, errorPointer -> Any? in
                do {
                    let snapshot = try transaction.getDocument(ref)
                    guard let data = snapshot.data(), let username = data["username"] as? String,
                          UsernamePolicy.isValid(username) else {
                        throw socialTransactionError(.profileMissing, "Your profile needs repair. Please reconnect and try again.")
                    }
                    let reservationRef = self.db.collection("usernames").document(username)
                    let reservation = try transaction.getDocument(reservationRef)
                    if let owner = reservation.data()?["uid"] as? String, owner != user.uid {
                        throw socialTransactionError(.usernameTaken, "Your previous username is reserved by another account. Choose another username in Edit Profile.")
                    }
                    var update: [String: Any] = [:]
                    if data["usernameKey"] as? String != username { update["usernameKey"] = username }
                    if data["usernameIsGenerated"] == nil {
                        // A legacy profile has no recorded cooldown. Preserve
                        // that first free rename without allowing cooldown reset.
                        update["usernameIsGenerated"] = false
                    }
                    let displayName = (data["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if displayName.isEmpty || displayName.count > 60 {
                        update["displayName"] = String((displayName.isEmpty ? (user.displayName ?? username) : displayName).prefix(60))
                    }
                    let bio = data["bio"] as? String
                    if bio == nil || bio!.count > 160 { update["bio"] = String((bio ?? "").prefix(160)) }
                    if data["avatarURL"] as? String == nil { update["avatarURL"] = user.photoURL?.absoluteString ?? "" }
                    if !reservation.exists {
                        transaction.setData(["uid": user.uid, "createdAt": FieldValue.serverTimestamp()], forDocument: reservationRef)
                    }
                    if !update.isEmpty {
                        update["updatedAt"] = FieldValue.serverTimestamp()
                        transaction.updateData(update, forDocument: ref)
                    }
                    return nil
                } catch { errorPointer?.pointee = error as NSError; return nil }
            }, completion: { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func generatedUsernameCandidates(for user: FirebaseAuth.User) -> [String] {
        let source = user.displayName ?? user.email?.components(separatedBy: "@").first ?? "capy"
        var stem = UsernamePolicy.key(from: source)
            .map { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "_") ? character : "_"
            }
            .reduce(into: "") { partial, character in
                if character != "_" || partial.last != "_" { partial.append(character) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if stem.count < UsernamePolicy.minimumLength { stem = "capy" }

        var uidKey = user.uid.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if uidKey.count < 6 { uidKey += String(UUID().uuidString.lowercased().filter(\.isLetter).prefix(6)) }
        let suffixes = [String(uidKey.prefix(6)), String(uidKey.prefix(10)), String(UUID().uuidString.lowercased().filter(\.isLetter).prefix(8))]
        return suffixes.map { suffix in
            let stemLimit = max(3, UsernamePolicy.maximumLength - suffix.count - 1)
            return String(stem.prefix(stemLimit)) + "_" + suffix
        }
    }

    private func listen(to uid: String) {
        let epoch = listenerEpoch
        listeners.append(db.collection("profiles").document(uid).addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.userID == uid, self.listenerEpoch == epoch else { return }
                if let data = snapshot?.data() { self.profile = SocialProfile(id: uid, data: data) }
                if let error { self.handleSocialError(error); return }
                // Cache is data availability, not a connectivity failure. Metadata
                // changes must be observed even if the server returns identical data.
                if let snapshot {
                    self.connectionState = self.connectionState.receivingProfileSnapshot(
                        isFromCache: snapshot.metadata.isFromCache, exists: snapshot.exists)
                }
            }
        })
        listeners.append(db.collection("follows").whereField("followerID", isEqualTo: uid).addSnapshotListener { [weak self] snapshot, error in
            let ids = snapshot?.documents.compactMap { $0.data()["followingID"] as? String } ?? []
            Task { @MainActor in
                guard let self, self.userID == uid, self.listenerEpoch == epoch else { return }
                if let error { self.handleSocialError(error); return }
                await self.loadFollowing(ids, owner: uid)
            }
        })
        listeners.append(db.collection("follows").whereField("followingID", isEqualTo: uid).addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.userID == uid, self.listenerEpoch == epoch else { return }
                if let error { self.handleSocialError(error); return }
                self.followerCount = snapshot?.documents.count ?? 0
            }
        })
        listeners.append(db.collection("playlists").whereField("memberIDs", arrayContains: uid).addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, self.userID == uid, self.listenerEpoch == epoch else { return }
                if let error { self.handleSocialError(error); return }
                guard let snapshot else { return }
                self.sharedPlaylists = snapshot.documents.compactMap { SharedPlaylist(id: $0.documentID, data: $0.data()) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        })
    }

    private func loadFollowing(_ ids: [String], owner uid: String) async {
        let epoch = listenerEpoch
        guard userID == uid else { return }
        followingCount = ids.count
        followingIDs = Set(ids)
        let selected = Set(ids.prefix(50))
        for id in Array(followingListeners.keys) where !selected.contains(id) {
            followingListeners.removeValue(forKey: id)?.remove()
        }
        following.removeAll { !selected.contains($0.id) }
        for id in selected where followingListeners[id] == nil {
            followingListeners[id] = db.collection("profiles").document(id).addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self, self.userID == uid, self.listenerEpoch == epoch, self.followingIDs.contains(id) else { return }
                    if let error { self.handleSocialError(error); return }
                    self.following.removeAll { $0.id == id }
                    if let data = snapshot?.data(), let person = SocialProfile(id: id, data: data) {
                        self.following.append(person)
                        self.profileCache[id] = (person, Date())
                    }
                    self.following.sort { $0.username < $1.username }
                }
            }
        }
        return
    }

#if DEBUG
    func installLayoutFixture(profile: SocialProfile, following: [SocialProfile] = []) {
        self.profile = profile
        self.following = following
        self.followingCount = following.count
        self.followerCount = 27
        self.connectionState = .ready
        self.error = nil
    }
#endif

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

        let nsError = failure as NSError
        if nsError.domain == socialTransactionErrorDomain {
            error = nsError.localizedDescription
            return
        }

        print("CapyFlow social update failed: \(nsError.domain) / \(nsError.code): \(nsError.localizedDescription)")
        let code = nsError.code
        switch code {
        case FirestoreErrorCode.cancelled.rawValue:
            return
        case FirestoreErrorCode.unavailable.rawValue,
             FirestoreErrorCode.deadlineExceeded.rawValue,
             FirestoreErrorCode.aborted.rawValue:
            connectionState = .offline
            error = "Friends and shared playlists are temporarily offline. Music and downloads still work normally."
        case FirestoreErrorCode.permissionDenied.rawValue:
            error = "This change wasn't permitted. Check playlist membership or reconnect your profile and try again."
        case FirestoreErrorCode.failedPrecondition.rawValue:
            connectionState = .setupRequired
            error = "The social service needs an update. Please retry after the update is complete."
        case FirestoreErrorCode.notFound.rawValue:
            error = "This profile or playlist is no longer available. Refresh and try again."
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

}

private let socialTransactionErrorDomain = "com.seph.capyflow.social-transaction"

private enum SocialTransactionErrorCode: Int {
    case usernameTaken = 1
    case usernameCooldown = 2
    case profileMissing = 3
}

private func socialTransactionError(_ code: SocialTransactionErrorCode, _ message: String) -> NSError {
    NSError(
        domain: socialTransactionErrorDomain,
        code: code.rawValue,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

private func isSocialTransactionError(_ error: Error, code: SocialTransactionErrorCode) -> Bool {
    let nsError = error as NSError
    return nsError.domain == socialTransactionErrorDomain && nsError.code == code.rawValue
}

private enum SocialError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

private extension Sequence {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
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
        albumID = data["albumID"] as? String
        mediaID = data["mediaID"] as? String
        musicVideoType = data["musicVideoType"] as? String
        albumTitle = data["albumTitle"] as? String
        trackNumber = data["trackNumber"] as? Int
        isExplicit = data["isExplicit"] as? Bool
    }

    var firestoreData: [String: Any] {
        var data: [String: Any] = ["id": id, "title": title, "artist": artist]
        if let duration { data["duration"] = duration }
        if let artworkURL { data["artworkURL"] = artworkURL.absoluteString }
        if let albumID { data["albumID"] = albumID }
        if let mediaID { data["mediaID"] = mediaID }
        if let musicVideoType { data["musicVideoType"] = musicVideoType }
        if let albumTitle { data["albumTitle"] = albumTitle }
        if let trackNumber { data["trackNumber"] = trackNumber }
        if let isExplicit { data["isExplicit"] = isExplicit }
        return data
    }
}
