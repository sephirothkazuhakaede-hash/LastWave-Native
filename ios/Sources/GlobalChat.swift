import SwiftUI
import FirebaseFirestore

struct ChatDate {
    static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// One listener for the newest 50 messages; older pages and profiles are fetched on demand.
@MainActor final class GlobalChatSession: ObservableObject {
    @Published private(set) var messages: [DirectMessage] = []
    @Published private(set) var profiles: [String: SocialProfile] = [:]
    @Published private(set) var loading = true
    @Published private(set) var sending = false
    @Published private(set) var loadingOlder = false
    @Published private(set) var hasMore = false
    @Published private(set) var error: String?
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var epoch = UUID()
    private var uid: String?
    private var oldest: DocumentSnapshot?
    private var history: [String: DirectMessage] = [:]
    private var requestedProfiles = Set<String>()
    private var lastSent = Date.distantPast

    func start(userID: String?) {
        stop(); uid = userID; messages = []; profiles = [:]; history = [:]; requestedProfiles = []; oldest = nil
        loading = userID != nil; error = nil; hasMore = false
        guard userID != nil else { return }
        let session = epoch
        listener = db.collection("globalMessages").order(by: "createdAt", descending: true).limit(to: 50)
            .addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, failure in
                Task { @MainActor in
                    guard let self, self.epoch == session else { return }
                    self.loading = false
                    if failure != nil { self.error = "Global Chat couldn’t connect. Please try again."; return }
                    guard let snapshot else { return }
                    self.error = nil; self.merge(snapshot.documents, session: session)
                    if self.oldest == nil { self.oldest = snapshot.documents.last; self.hasMore = snapshot.documents.count == 50 }
                }
            }
    }
    func stop() { epoch = UUID(); listener?.remove(); listener = nil; sending = false; loadingOlder = false }
    private func merge(_ docs: [QueryDocumentSnapshot], session: UUID) {
        for doc in docs { if let message = DirectMessage(document: doc) { history[message.id] = message } }
        messages = Array(history.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }.suffix(500))
        history = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        if messages.count >= 500 { hasMore = false }
        let missing = Array(Set(messages.map(\.senderID)).subtracting(requestedProfiles))
        requestedProfiles.formUnion(missing)
        Task { [weak self] in
            guard let self else { return }
            for start in stride(from: 0, to: missing.count, by: 20) {
                let ids = Array(missing[start..<min(start + 20, missing.count)])
                do {
                    let result = try await self.db.collection("profiles").whereField(FieldPath.documentID(), in: ids).limit(to: 20).getDocuments()
                    guard self.epoch == session else { return }
                    for doc in result.documents { if let person = SocialProfile(id: doc.documentID, data: doc.data()) { self.profiles[person.id] = person } }
                } catch {
                    guard self.epoch == session else { return }
                    self.requestedProfiles.subtract(ids)
                    self.error = "Some profiles couldn’t load. Please try again."
                }
            }
        }
    }
    func loadOlder() async {
        guard !loadingOlder, hasMore, let oldest else { return }
        loadingOlder = true; let session = epoch
        defer { if epoch == session { loadingOlder = false } }
        do {
            let result = try await db.collection("globalMessages").order(by: "createdAt", descending: true).start(afterDocument: oldest).limit(to: 50).getDocuments()
            guard epoch == session else { return }
            merge(result.documents, session: session); self.oldest = result.documents.last; hasMore = result.documents.count == 50 && messages.count < 500
        } catch { if epoch == session { self.error = "Older messages couldn’t load. Please try again." } }
    }
    func send(_ raw: String) async -> Bool {
        guard !sending, let uid, let text = DirectMessage.cleaned(raw) else { return false }
        guard Date().timeIntervalSince(lastSent) >= 2 else { error = "Give it a moment before sending another message."; return false }
        sending = true; error = nil; let session = epoch
        defer { if epoch == session { sending = false } }
        let ref = db.collection("globalMessages").document()
        let batch = db.batch(), timestamp = FieldValue.serverTimestamp()
        batch.setData(["senderID": uid, "text": text, "createdAt": timestamp], forDocument: ref)
        batch.setData(["lastSentAt": timestamp, "messageID": ref.documentID], forDocument: db.collection("globalChatSenders").document(uid))
        do { try await batch.commit(); if epoch == session { lastSent = Date() }; return epoch == session }
        catch { if epoch == session { self.error = "Message wasn’t sent. Wait a moment and try again." }; return false }
    }
}

struct GlobalChatView: View {
    @EnvironmentObject private var messaging: MessagingStore
    @EnvironmentObject private var social: SocialStore
    @StateObject private var chat = GlobalChatSession()
    @State private var draft = ""
    @State private var loadingHistory = false
    var body: some View {
        ZStack {
            WaveBackdrop()
            if social.currentUserID == nil {
                ContentUnavailableView("Sign in to join Global Chat", systemImage: "globe", description: Text("Use your Google account to chat with CapyFlow listeners."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            Text("A shared chat for everyone on CapyFlow.").font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                            if chat.loading { ProgressView("Loading chat…") }
                            if chat.hasMore {
                                Button(chat.loadingOlder ? "Loading…" : "Load older messages") {
                                    Task { loadingHistory = true; await chat.loadOlder(); loadingHistory = false }
                                }.disabled(chat.loadingOlder)
                            }
                            if !chat.loading && chat.messages.isEmpty && chat.error == nil { Text("Say hello to the CapyFlow community.").foregroundStyle(CapyColor.secondaryText) }
                            ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                                if index == 0 || !Calendar.current.isDate(chat.messages[index - 1].createdAt, inSameDayAs: message.createdAt) {
                                    Text(ChatDate.label(message.createdAt)).font(.capyCaption).foregroundStyle(CapyColor.secondaryText).frame(maxWidth: .infinity).padding(.vertical, 8)
                                }
                                messageRow(message).id(message.id)
                            }
                        }.padding(16)
                    }.scrollDismissesKeyboard(.interactively)
                        .onChange(of: chat.messages.last?.id) { _, id in if !loadingHistory, let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) } } }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let error = chat.error {
                    Text(error).font(.capyCaption).foregroundStyle(CapyColor.warning)
                    if !chat.sending { Button("Reconnect") { chat.start(userID: social.currentUserID) } }
                }
                if social.currentUserID != nil {
                    HStack(alignment: .bottom) {
                        TextField("Message", text: $draft, axis: .vertical).lineLimit(1...5).padding(12).background(CapyColor.surfaceStrong, in: RoundedRectangle(cornerRadius: 18))
                        Button { let submitted = draft; Task { if await chat.send(submitted), draft == submitted { draft = "" } } } label: {
                            Image(systemName: "paperplane.fill").rotationEffect(.degrees(45)).frame(width: 44, height: 44)
                        }.background(CapyColor.accent, in: Circle()).disabled(chat.sending || DirectMessage.cleaned(draft) == nil || social.profile == nil).foregroundStyle(CapyColor.background).accessibilityLabel("Send message")
                    }
                }
            }.padding(12).background(.ultraThinMaterial)
        }
        .navigationTitle("Global Chat").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar).toolbar(.visible, for: .navigationBar)
        .task(id: social.currentUserID) { messaging.globalChatVisible = true; chat.start(userID: social.currentUserID) }
        .onDisappear { messaging.globalChatVisible = false; chat.stop() }
    }
    private func messageRow(_ message: DirectMessage) -> some View {
        let own = message.senderID == social.currentUserID
        let person = chat.profiles[message.senderID]
        return HStack(alignment: .top, spacing: 8) {
            if own { Spacer(minLength: 45) }
            if !own {
                if let person {
                    NavigationLink { SocialPersonProfileView(person: person) } label: { SocialAvatar(profile: person, size: 32) }.buttonStyle(.plain)
                } else { Circle().fill(CapyColor.surfaceStrong).frame(width: 32, height: 32) }
            }
            VStack(alignment: own ? .trailing : .leading, spacing: 4) {
                if let person {
                    NavigationLink { SocialPersonProfileView(person: person) } label: {
                        Text(person.displayName).font(.capyCaption).foregroundStyle(CapyColor.accent).lineLimit(1)
                    }.buttonStyle(.plain)
                } else { RoundedRectangle(cornerRadius: 6).fill(CapyColor.surfaceStrong).frame(width: 96, height: 12).accessibilityLabel("Loading profile") }
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.text).font(.capyBody).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Text(message.pending ? "Sending…" : message.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption2).opacity(0.65)
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .foregroundStyle(own ? CapyColor.background : Color.white)
                .background(own ? CapyColor.accent : CapyColor.surfaceStrong, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if own, let person {
                NavigationLink { SocialPersonProfileView(person: person) } label: { SocialAvatar(profile: person, size: 32) }.buttonStyle(.plain)
            }
            if !own { Spacer(minLength: 45) }
        }
    }
}
