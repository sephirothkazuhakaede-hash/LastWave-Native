import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

struct DirectConversation: Identifiable {
    let id: String
    let members: [String]
    let lastMessageID: String
    let lastText: String
    let lastSenderID: String
    let updatedAt: Date
    let readMessageIDs: [String: String]

    init?(id: String, data: [String: Any]) {
        guard let members = data["memberIDs"] as? [String], members.count == 2,
              Set(members).count == 2, let lastMessageID = data["lastMessageID"] as? String,
              let lastText = data["lastText"] as? String, let sender = data["lastSenderID"] as? String,
              members.contains(sender) else { return nil }
        self.id = id; self.members = members; self.lastMessageID = lastMessageID
        self.lastText = lastText; self.lastSenderID = sender
        self.updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? .distantPast
        self.readMessageIDs = (data["readMessageIDs"] as? [String: String]) ?? [:]
    }
    static func id(for first: String, and second: String) -> String { [first, second].sorted().joined(separator: "_") }
    func peerID(for uid: String) -> String? { members.first { $0 != uid } }
    func isUnread(for uid: String) -> Bool {
        members.contains(uid) && lastSenderID != uid && readMessageIDs[uid] != lastMessageID
    }
}

struct DirectMessage: Identifiable {
    let id: String
    let senderID: String
    let text: String
    let createdAt: Date
    let pending: Bool
    init?(document: DocumentSnapshot) {
        guard let data = document.data(), let sender = data["senderID"] as? String,
              let text = data["text"] as? String else { return nil }
        id = document.documentID; senderID = sender; self.text = text
        createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        pending = document.metadata.hasPendingWrites
    }
    static func cleaned(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.utf16.count <= 4000 ? value : nil
    }
}


enum DirectMessageStatus: String {
    case sending = "Sending…"
    case sent = "Sent"
    case read = "Read"

    static func resolve(messageID: String, pending: Bool, peerReadID: String?, orderedIDs: [String]) -> Self {
        if pending { return .sending }
        guard let peerReadID, !peerReadID.isEmpty else { return .sent }
        if peerReadID == messageID { return .read }
        guard let messageIndex = orderedIDs.firstIndex(of: messageID),
              let readIndex = orderedIDs.firstIndex(of: peerReadID),
              messageIndex <= readIndex else { return .sent }
        return .read
    }
}

struct MessageBannerEvent: Identifiable {
    let id: String
    let peerID: String
    let preview: String
}

// The first server snapshot establishes a baseline; saved unread messages
// appear in the inbox rather than being replayed as new alerts.
struct MessageArrivalTracker {
    private var established = false
    private var seen: [String: String] = [:]
    mutating func receive(_ conversations: [DirectConversation], uid: String, fromCache: Bool, activePeerID: String?) -> MessageBannerEvent? {
        guard !fromCache else { return nil }
        defer { established = true; seen = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0.lastMessageID) }) }
        guard established else { return nil }
        guard let newest = conversations.filter({ $0.isUnread(for: uid) && seen[$0.id] != $0.lastMessageID && $0.peerID(for: uid) != activePeerID })
            .max(by: { $0.updatedAt < $1.updatedAt }), let peer = newest.peerID(for: uid) else { return nil }
        return MessageBannerEvent(id: newest.lastMessageID, peerID: peer, preview: newest.lastText)
    }
}

@MainActor final class MessagingStore: ObservableObject {
    @Published private(set) var conversations: [DirectConversation] = []
    @Published private(set) var profiles: [String: SocialProfile] = [:]
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var fromCache = false
    @Published private(set) var hasMore = false
    @Published private(set) var banner: MessageBannerEvent?
    var activePeerID: String?
    private var arrivals = MessageArrivalTracker()
    func dismissBanner() { banner = nil }
    private let db = Firestore.firestore()
    private var uid: String?
    private var listener: ListenerRegistration?
    private var epoch = UUID()
    private var limit = 50
    private var profileTask: Task<Void, Never>?
    var unreadCount: Int { guard let uid else { return 0 }; return conversations.filter { $0.isUnread(for: uid) }.count }

    func bind(userID: String?) {
        guard uid != userID else { return }
        listener?.remove(); profileTask?.cancel(); epoch = UUID()
        uid = userID; arrivals = MessageArrivalTracker(); banner = nil; activePeerID = nil; limit = 50; conversations = []; profiles = [:]; error = nil; fromCache = false
        loading = userID != nil; hasMore = false
        listen()
    }
    func retry() { error = nil; loading = true; listen() }
    func loadMore() { guard limit < 500 else { return }; limit += 50; listen() }
    private func listen() {
        listener?.remove()
        guard let uid else { loading = false; return }
        let session = epoch
        // Sorting locally avoids a composite-index dependency and keeps one
        // bounded inbox listener. A larger bounded window loads on demand.
        listener = db.collection("conversations").whereField("memberIDs", arrayContains: uid).limit(to: limit)
            .addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, failure in
                Task { @MainActor in
                    guard let self, self.uid == uid, self.epoch == session else { return }
                    self.loading = false
                    if let failure { self.error = "Messages could not load: " + failure.localizedDescription; return }
                    guard let snapshot else { return }
                    self.error = nil; self.fromCache = snapshot.metadata.isFromCache
                    self.conversations = snapshot.documents.compactMap { DirectConversation(id: $0.documentID, data: $0.data()) }
                        .sorted { $0.updatedAt > $1.updatedAt }
                    self.hasMore = snapshot.documents.count == self.limit && self.limit < 500
                    if let event = self.arrivals.receive(self.conversations, uid: uid, fromCache: self.fromCache, activePeerID: self.activePeerID) { self.banner = event }
                    self.loadProfiles(session: session)
                }
            }
    }
    private func loadProfiles(session: UUID) {
        guard let uid else { return }
        profileTask?.cancel()
        let missing = Array(Set(conversations.compactMap { $0.peerID(for: uid) })).filter { profiles[$0] == nil }
        profileTask = Task { [weak self] in
            guard let self else { return }
            do {
                for start in stride(from: 0, to: missing.count, by: 20) {
                    let ids = Array(missing[start..<min(start + 20, missing.count)])
                    let result = try await self.db.collection("profiles").whereField(FieldPath.documentID(), in: ids).limit(to: 20).getDocuments()
                    guard self.epoch == session, !Task.isCancelled else { return }
                    for doc in result.documents {
                        if let person = SocialProfile(id: doc.documentID, data: doc.data()) { self.profiles[person.id] = person }
                    }
                    for id in ids where self.profiles[id] == nil {
                        self.profiles[id] = SocialProfile(id: id, data: ["username": "unavailable", "displayName": "Unavailable profile", "bio": ""])
                    }
                }
            } catch {
                if self.epoch == session && !Task.isCancelled { self.error = "Some message profiles could not load. Retry to reconnect." }
            }
        }
    }
}

@MainActor final class DirectChatSession: ObservableObject {
    @Published private(set) var messages: [DirectMessage] = []
    @Published private(set) var loading = true
    @Published private(set) var sending = false
    @Published private(set) var exists = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = false
    @Published private(set) var loadingOlder = false
    private let db = Firestore.firestore()
    private var uid: String?
    private var peerID: String?
    private var thread: DocumentReference?
    private var threadListener: ListenerRegistration?
    private var messageListener: ListenerRegistration?
    private var epoch = UUID()
    private var history: [String: DirectMessage] = [:]
    private var oldest: DocumentSnapshot?
    private var lastReadAttempt: String?
    private var visible = false
    private var creationEstablished = false
    @Published private(set) var conversation: DirectConversation?

    func status(for message: DirectMessage) -> DirectMessageStatus {
        DirectMessageStatus.resolve(messageID: message.id, pending: message.pending,
                                    peerReadID: peerID.flatMap { conversation?.readMessageIDs[$0] },
                                    orderedIDs: messages.map(\.id))
    }

    func start(userID: String?, peerID: String) {
        stop(); epoch = UUID(); uid = userID; self.peerID = peerID
        loading = true; messages = []; history = [:]; exists = false; error = nil; hasMore = false
        oldest = nil; conversation = nil
        guard let userID, userID != peerID else { loading = false; error = "Sign in to message a friend."; return }
        visible = true
        let ref = db.collection("conversations").document(DirectConversation.id(for: userID, and: peerID))
        thread = ref; let session = epoch
        threadListener = ref.addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, failure in
            Task { @MainActor in
                guard let self, self.epoch == session else { return }
                if let failure { self.loading = false; self.error = "Conversation could not load: " + failure.localizedDescription; return }
                guard let snapshot else { return }
                if !snapshot.exists {
                    // A cached absence is inconclusive on a fresh install.
                    if !snapshot.metadata.isFromCache { self.creationEstablished = true; self.loading = false }
                    return
                }
                guard let conversation = snapshot.data().flatMap({ DirectConversation(id: snapshot.documentID, data: $0) }) else { return }
                self.exists = true; self.creationEstablished = true
                self.conversation = conversation
                if self.messageListener == nil { self.listenMessages(ref, session: session) }
                self.markRead(conversation, ref: ref, session: session)
            }
        }
    }
    func stop() {
        visible = false; epoch = UUID(); threadListener?.remove(); messageListener?.remove()
        threadListener = nil; messageListener = nil; lastReadAttempt = nil; creationEstablished = false
        sending = false; loadingOlder = false
    }
    private func listenMessages(_ ref: DocumentReference, session: UUID) {
        messageListener = ref.collection("messages").order(by: "createdAt", descending: true).limit(to: 50)
            .addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, failure in
                Task { @MainActor in
                    guard let self, self.epoch == session else { return }
                    self.loading = false
                    if let failure { self.error = "Messages could not load: " + failure.localizedDescription; return }
                    guard let snapshot else { return }
                    self.error = nil
                    self.merge(snapshot.documents)
                    if let conversation = self.conversation { self.markRead(conversation, ref: ref, session: session) }
                    if self.oldest == nil { self.oldest = snapshot.documents.last; self.hasMore = snapshot.documents.count == 50 }
                }
            }
    }
    private func merge(_ docs: [QueryDocumentSnapshot]) {
        for doc in docs { if let message = DirectMessage(document: doc) { history[message.id] = message } }
        messages = history.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }
    func loadOlder() async {
        guard !loadingOlder, hasMore, let thread, let oldest else { return }
        loadingOlder = true; let session = epoch
        defer { if epoch == session { loadingOlder = false } }
        do {
            let result = try await thread.collection("messages").order(by: "createdAt", descending: true).start(afterDocument: oldest).limit(to: 50).getDocuments()
            guard epoch == session else { return }
            merge(result.documents); self.oldest = result.documents.last; hasMore = result.documents.count == 50
        } catch { if epoch == session { self.error = "Older messages could not load: " + error.localizedDescription } }
    }
    func send(_ raw: String) async -> Bool {
        guard !sending, creationEstablished, let uid, let peerID, let thread, let text = DirectMessage.cleaned(raw) else { return false }
        sending = true; error = nil; let session = epoch
        defer { if epoch == session { sending = false } }
        let id = UUID().uuidString
        let batch = db.batch()
        let timestamp = FieldValue.serverTimestamp()
        batch.setData(["senderID": uid, "text": text, "createdAt": timestamp], forDocument: thread.collection("messages").document(id))
        if exists {
            batch.updateData(["lastMessageID": id, "lastText": text, "lastSenderID": uid, "updatedAt": timestamp,
                              "readMessageIDs." + uid: id], forDocument: thread)
        } else {
            batch.setData(["memberIDs": [uid, peerID].sorted(), "lastMessageID": id, "lastText": text,
                           "lastSenderID": uid, "createdAt": timestamp, "updatedAt": timestamp,
                           "readMessageIDs": [uid: id, peerID: ""]], forDocument: thread)
        }
        do {
            try await batch.commit()
            return epoch == session
        } catch {
            if epoch == session { self.error = "Message was not sent: " + error.localizedDescription }
            return false
        }
    }
    private func markRead(_ conversation: DirectConversation, ref: DocumentReference, session: UUID) {
        guard visible, history[conversation.lastMessageID] != nil, let uid,
              conversation.isUnread(for: uid), lastReadAttempt != conversation.lastMessageID else { return }
        lastReadAttempt = conversation.lastMessageID
        ref.updateData(["readMessageIDs." + uid: conversation.lastMessageID]) { [weak self] failure in
            Task { @MainActor in
                guard let self, self.epoch == session else { return }
                if let failure { self.lastReadAttempt = nil; self.error = "Read status could not sync: " + failure.localizedDescription }
            }
        }
    }
}
