import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

struct FriendListeningActivity: Identifiable {
    let id: String
    let track: Track
    let playing: Bool
    let updatedAt: Date
    let expiresAt: Date

    init?(id: String, data: [String: Any]) {
        guard let title = data["title"] as? String, let artist = data["artist"] as? String,
              let videoID = data["videoID"] as? String,
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue(),
              let expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue() else { return nil }
        self.id = id
        self.track = Track(id: videoID, title: title, artist: artist,
                           artworkURL: (data["artworkURL"] as? String).flatMap(URL.init(string:)))
        self.playing = (data["playing"] as? Bool) ?? false
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }
    func isListening(at now: Date) -> Bool { playing && expiresAt > now && now.timeIntervalSince(updatedAt) < 300 }
    var canPlay: Bool { track.playableID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil }
}

@MainActor final class ListeningActivityStore: ObservableObject {
    @Published private(set) var sharing = false
    @Published private(set) var preferenceLoading = false
    @Published private(set) var activities: [String: FriendListeningActivity] = [:]
    @Published private(set) var error: String?
    private let db = Firestore.firestore()
    private var uid: String?
    private var preferenceListener: ListenerRegistration?
    private var feedListeners: [ListenerRegistration] = []
    private var feedIDs: Set<String> = []
    private var subscriptions: Set<AnyCancellable> = []
    private var publishTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var latestTrack: Track?
    private var latestPlaying = false
    private var lastPublished = Date.distantPast
    private var epoch = UUID()
    private var privacyWritePending = false

    func observe(_ player: WavePlayer) {
        guard subscriptions.isEmpty else { return }
        player.$current.combineLatest(player.$playing)
            .sink { [weak self] track, playing in
                guard let self else { return }
                self.latestTrack = track; self.latestPlaying = playing
                self.schedulePublish()
            }.store(in: &subscriptions)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { return }
                if self?.latestPlaying == true { self?.schedulePublish() }
            }
        }
    }

    func bind(userID: String?) {
        if uid == userID { return }
        // Clear old-session presence before replacing the identity. These writes
        // are scoped to the old UID; a new session never publishes under it.
        if let old = uid { db.collection("listeningActivity").document(old).delete() }
        epoch = UUID(); publishTask?.cancel(); preferenceListener?.remove()
        feedListeners.forEach { $0.remove() }; feedListeners = []; feedIDs = []
        activities = [:]; sharing = false; privacyWritePending = false
        preferenceLoading = userID != nil; error = nil; uid = userID; lastPublished = .distantPast
        guard let userID else { return }
        if UserDefaults.standard.bool(forKey: "capyflow.activity.pendingOff." + userID) {
            privacyWritePending = true
            Task { await self.setSharing(false) }
        }
        let saved = (UserDefaults.standard.object(forKey: "capyflow.activity.sharing." + userID) as? Bool) ?? false
        preferenceListener = db.collection("activitySettings").document(userID)
            .addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, failure in
                Task { @MainActor in
                    guard let self, self.uid == userID else { return }
                    if let failure { self.error = Self.syncError(failure, prefix: "Listening activity preference could not sync"); self.preferenceLoading = false; return }
                    guard !self.privacyWritePending else { return }
                    if UserDefaults.standard.bool(forKey: "capyflow.activity.pendingOff." + userID) {
                        self.sharing = false; self.preferenceLoading = false
                        return
                    }
                    if let enabled = snapshot?.data()?["sharing"] as? Bool {
                        if snapshot?.metadata.isFromCache == false { self.error = nil }
                        // An explicit local OFF survives an offline restart.
                        self.sharing = enabled && !(snapshot?.metadata.isFromCache == true && !saved)
                        self.preferenceLoading = false
                        UserDefaults.standard.set(enabled, forKey: "capyflow.activity.sharing." + userID)
                        if self.sharing { self.schedulePublish() } else { self.publishTask?.cancel() }
                    } else if snapshot?.metadata.isFromCache == false {
                        // New accounts default to private. Existing explicit local
                        // preference can be restored once a server read establishes absence.
                        self.preferenceLoading = false
                        await self.setSharing(saved)
                    }
                }
            }
    }

    func setSharing(_ enabled: Bool) async {
        guard let uid else { return }
        epoch = UUID(); publishTask?.cancel()
        // Apply OFF immediately, even without a network connection. The ordered
        // batch queues a persistent preference and removes stale activity atomically.
        sharing = enabled; privacyWritePending = true; error = nil
        UserDefaults.standard.set(enabled, forKey: "capyflow.activity.sharing." + uid)
        UserDefaults.standard.set(!enabled, forKey: "capyflow.activity.pendingOff." + uid)
        let generation = epoch
        let batch = db.batch()
        batch.setData(["sharing": enabled, "updatedAt": FieldValue.serverTimestamp()], forDocument: db.collection("activitySettings").document(uid))
        if !enabled { batch.deleteDocument(db.collection("listeningActivity").document(uid)) }
        do {
            try await batch.commit()
            guard self.uid == uid, epoch == generation else { return }
            privacyWritePending = false; preferenceLoading = false
            UserDefaults.standard.removeObject(forKey: "capyflow.activity.pendingOff." + uid)
            if enabled { schedulePublish() }
        } catch {
            guard self.uid == uid, epoch == generation else { return }
            privacyWritePending = false; preferenceLoading = false
            if enabled { sharing = false } // Never publish after a failed opt-in.
            self.error = Self.syncError(error, prefix: "Listening activity preference could not sync")
        }
    }

    func retryPreferenceSync() async {
        guard let uid else { return }
        if UserDefaults.standard.bool(forKey: "capyflow.activity.pendingOff." + uid) {
            await setSharing(false)
            return
        }
        // Read the cloud preference again rather than replacing it with the
        // default OFF value after a failed/denied initial read.
        preferenceListener?.remove(); preferenceListener = nil
        self.uid = nil
        bind(userID: uid)
    }

    private func schedulePublish() {
        publishTask?.cancel()
        guard sharing, !privacyWritePending, let uid else { return }
        let generation = epoch
        let wait = max(2, 15 - Date().timeIntervalSince(lastPublished))
        publishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, self.sharing, !self.privacyWritePending,
                  self.uid == uid, self.epoch == generation else { return }
            self.lastPublished = Date()
            do {
                guard let track = self.latestTrack else {
                    try await self.db.collection("listeningActivity").document(uid).delete(); return
                }
                let now = Date()
                let data: [String: Any] = [
                    "title": String(track.title.prefix(300)), "artist": String(track.artist.prefix(300)),
                    "videoID": String(track.playableID.prefix(128)),
                    "artworkURL": String((track.artwork?.absoluteString ?? "").prefix(2048)),
                    "playing": self.latestPlaying, "updatedAt": FieldValue.serverTimestamp(),
                    "expiresAt": Timestamp(date: now.addingTimeInterval(300))
                ]
                try await self.db.collection("listeningActivity").document(uid).setData(data)
            } catch {
                guard self.uid == uid, self.epoch == generation else { return }
                self.error = Self.syncError(error, prefix: "Listening activity could not sync")
            }
        }
    }

    func watchFriends(_ profiles: [SocialProfile]) {
        let ids = Set(profiles.prefix(50).map(\.id))
        guard uid != nil, ids != feedIDs else { return }
        feedIDs = ids; feedListeners.forEach { $0.remove() }; feedListeners = []
        activities = activities.filter { ids.contains($0.key) }
        let ordered = ids.sorted(), owner = uid
        for start in stride(from: 0, to: ordered.count, by: 20) {
            let batch = Array(ordered[start..<min(start + 20, ordered.count)])
            feedListeners.append(db.collection("listeningActivity").whereField(FieldPath.documentID(), in: batch).limit(to: 20)
                .addSnapshotListener { [weak self] snapshot, failure in
                    Task { @MainActor in
                        guard let self, self.uid == owner, self.feedIDs == ids else { return }
                        if let failure { self.error = Self.syncError(failure, prefix: "Friend Activity could not load"); return }
                        guard let snapshot else { return }
                        for id in batch { self.activities.removeValue(forKey: id) }
                        for doc in snapshot.documents {
                            if let activity = FriendListeningActivity(id: doc.documentID, data: doc.data()) { self.activities[doc.documentID] = activity }
                        }
                    }
                })
        }
    }
    private static func syncError(_ error: Error, prefix: String) -> String {
        let code = error as NSError
        if code.domain == FirestoreErrorDomain && code.code == FirestoreErrorCode.permissionDenied.rawValue {
            return prefix + ": Firebase denied access. The CapyFlow owner must publish the current Firestore rules; Retry cannot repair missing server permissions."
        }
        return prefix + ": " + error.localizedDescription
    }
}
