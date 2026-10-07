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

@MainActor
final class GlobalChatPresenceSession: ObservableObject {
    @Published private(set) var userIDs: [String] = []
    @Published private(set) var profiles: [String: SocialProfile] = [:]

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var heartbeatTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var uid: String?
    private var epoch = UUID()
    private var requestedProfiles = Set<String>()

    func start(userID: String?) {
        stop(removePresence: false)

        guard let userID else {
            userIDs = []
            profiles = [:]
            return
        }

        uid = userID
        let session = epoch

        listener = db.collection("globalChatPresence")
            .addSnapshotListener { [weak self] snapshot, _ in
                Task { @MainActor in
                    guard let self, self.epoch == session else { return }
                    guard let snapshot else { return }

                    self.updatePresence(
                        documents: snapshot.documents,
                        session: session
                    )
                }
            }

        heartbeatTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                await self.writePresence()

                try? await Task.sleep(for: .seconds(25))

                guard self.epoch == session else { return }
            }
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))

                guard self.epoch == session else { return }

                await self.refreshPresence(session: session)
            }
        }
    }

    func stop(removePresence: Bool = true) {
        let previousUID = uid

        epoch = UUID()

        listener?.remove()
        listener = nil

        heartbeatTask?.cancel()
        heartbeatTask = nil

        refreshTask?.cancel()
        refreshTask = nil

        uid = nil
        userIDs = []
        profiles = [:]
        requestedProfiles = []

        if removePresence, let previousUID {
            Task {
                try? await db.collection("globalChatPresence")
                    .document(previousUID)
                    .delete()
            }
        }
    }

    private func writePresence() async {
        guard let uid else { return }

        do {
            try await db.collection("globalChatPresence")
                .document(uid)
                .setData([
                    "uid": uid,
                    "updatedAt": FieldValue.serverTimestamp()
                ])
        } catch {
            // Presence is best-effort and must never interrupt chat.
        }
    }

    private func refreshPresence(session: UUID) async {
        do {
            let snapshot = try await db.collection("globalChatPresence")
                .getDocuments()

            guard epoch == session else { return }

            updatePresence(
                documents: snapshot.documents,
                session: session
            )
        } catch {
            // Presence failures must never interrupt Global Chat.
        }
    }

    private func updatePresence(
        documents: [QueryDocumentSnapshot],
        session: UUID
    ) {
        let cutoff = Date().addingTimeInterval(-75)

        let activeIDs = documents.compactMap { document -> String? in
            let data = document.data()

            guard
                let presenceUID = data["uid"] as? String,
                let updatedAt = data["updatedAt"] as? Timestamp,
                updatedAt.dateValue() >= cutoff
            else {
                return nil
            }

            return presenceUID
        }

        userIDs = Array(Set(activeIDs)).sorted()

        let missing = userIDs.filter {
            profiles[$0] == nil && !requestedProfiles.contains($0)
        }

        guard !missing.isEmpty else { return }

        requestedProfiles.formUnion(missing)

        Task { [weak self] in
            guard let self else { return }

            for start in stride(from: 0, to: missing.count, by: 20) {
                let end = min(start + 20, missing.count)
                let ids = Array(missing[start..<end])

                do {
                    let result = try await db.collection("profiles")
                        .whereField(FieldPath.documentID(), in: ids)
                        .limit(to: 20)
                        .getDocuments()

                    guard epoch == session else { return }

                    for document in result.documents {
                        if let profile = SocialProfile(
                            id: document.documentID,
                            data: document.data()
                        ) {
                            profiles[profile.id] = profile
                        }
                    }
                } catch {
                    guard epoch == session else { return }
                    requestedProfiles.subtract(ids)
                }
            }
        }
    }
}

struct GlobalChatView: View {
    @EnvironmentObject private var messaging: MessagingStore
    @EnvironmentObject private var social: SocialStore
    @EnvironmentObject private var player: WavePlayer
    @StateObject private var chat = GlobalChatSession()
    @StateObject private var presence = GlobalChatPresenceSession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    @State private var loadingHistory = false
    @State private var showPlayer = false
    @State private var showActiveUsers = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack {
            WaveBackdrop()

            if social.currentUserID == nil {
                ContentUnavailableView(
                    "Sign in to join Global Chat",
                    systemImage: "globe",
                    description: Text(
                        "Use your Google account to chat with CapyFlow listeners."
                    )
                )
            } else {
                VStack(spacing: 0) {
                    if !presence.userIDs.isEmpty {
                        Button {
                            composerFocused = false
                            showActiveUsers = true
                        } label: {
                            HStack(spacing: 10) {
                                HStack(spacing: -8) {
                                    ForEach(
                                        Array(presence.userIDs.prefix(4)),
                                        id: \.self
                                    ) { uid in
                                        if let person = presence.profiles[uid] {
                                            SocialAvatar(
                                                profile: person,
                                                size: 28
                                            )
                                            .overlay {
                                                Circle()
                                                    .stroke(
                                                        CapyColor.background,
                                                        lineWidth: 2
                                                    )
                                            }
                                        } else {
                                            Circle()
                                                .fill(CapyColor.surfaceStrong)
                                                .frame(width: 28, height: 28)
                                                .overlay {
                                                    Image(systemName: "person.fill")
                                                        .font(.caption2)
                                                        .foregroundStyle(
                                                            CapyColor.secondaryText
                                                        )
                                                }
                                                .overlay {
                                                    Circle()
                                                        .stroke(
                                                            CapyColor.background,
                                                            lineWidth: 2
                                                        )
                                                }
                                        }
                                    }
                                }

                                Text("In chat · \(presence.userIDs.count)")
                                    .font(.capyCallout)
                                    .foregroundStyle(Color.white)

                                if presence.userIDs.count > 4 {
                                    Text("+\(presence.userIDs.count - 4)")
                                        .font(.capyCaption)
                                        .foregroundStyle(
                                            CapyColor.secondaryText
                                        )
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(
                                        CapyColor.tertiaryText
                                    )
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(
                                CapyColor.surfaceStrong,
                                in: RoundedRectangle(
                                    cornerRadius: 16,
                                    style: .continuous
                                )
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(
                                alignment: .leading,
                                spacing: 16
                            ) {
                                VStack(
                                    alignment: .leading,
                                    spacing: 10
                                ) {
                                    Text(
                                        "A shared chat for everyone on CapyFlow."
                                    )
                                    .font(.capyCaption)
                                    .foregroundStyle(
                                        CapyColor.secondaryText
                                    )
                                }

                                if chat.loading {
                                    ProgressView("Loading chat…")
                                }

                                if chat.hasMore {
                                    Button(
                                        chat.loadingOlder
                                            ? "Loading…"
                                            : "Load older messages"
                                    ) {
                                        Task {
                                            loadingHistory = true
                                            await chat.loadOlder()
                                            loadingHistory = false
                                        }
                                    }
                                    .disabled(chat.loadingOlder)
                                }

                                if !chat.loading &&
                                    chat.messages.isEmpty &&
                                    chat.error == nil {
                                    Text(
                                        "Say hello to the CapyFlow community."
                                    )
                                    .foregroundStyle(
                                        CapyColor.secondaryText
                                    )
                                }

                                ForEach(
                                    Array(chat.messages.enumerated()),
                                    id: \.element.id
                                ) { index, message in
                                    if index == 0 ||
                                        !Calendar.current.isDate(
                                            chat.messages[index - 1].createdAt,
                                            inSameDayAs: message.createdAt
                                        ) {
                                        Text(
                                            ChatDate.label(
                                                message.createdAt
                                            )
                                        )
                                        .font(.capyCaption)
                                        .foregroundStyle(
                                            CapyColor.secondaryText
                                        )
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                    }

                                    let previousSame = index > 0 && chat.messages[index - 1].senderID == message.senderID && Calendar.current.isDate(chat.messages[index - 1].createdAt, inSameDayAs: message.createdAt)
                                    let nextSame = index + 1 < chat.messages.count && chat.messages[index + 1].senderID == message.senderID && Calendar.current.isDate(chat.messages[index + 1].createdAt, inSameDayAs: message.createdAt)
                                    messageRow(message, previousSame: previousSame, nextSame: nextSame)
                                        .padding(.top, previousSame ? -11 : 0)
                                        .id(message.id)
                                }
                            }
                            .padding(16)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: chat.messages.last?.id) { _, id in
                            if !loadingHistory, let id {
                                withAnimation(
                                    .easeOut(duration: 0.2)
                                ) {
                                    proxy.scrollTo(
                                        id,
                                        anchor: .bottom
                                    )
                                }
                            }
                        }
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let track = player.current {
                    HStack(spacing: 10) {
                        Button { showPlayer = true } label: {
                            HStack(spacing: 10) {
                                Artwork(track: track, size: 36, radius: 9)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title).font(.capyCaption).lineLimit(1)
                                    Text(track.artist).font(.caption2).foregroundStyle(CapyColor.secondaryText).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Open Now Playing")
                        if player.loading { ProgressView().tint(CapyColor.accent) }
                        Button { player.toggle() } label: {
                            Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                        }.buttonStyle(.plain).foregroundStyle(CapyColor.accent).accessibilityLabel(player.playing ? "Pause music" : "Play music")
                        Button { Task { await player.next() } } label: {
                            Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
                        }.buttonStyle(.plain).accessibilityLabel("Next song")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("global-chat-music-controls")
                }

                if let error = chat.error {
                    Text(error)
                        .font(.capyCaption)
                        .foregroundStyle(CapyColor.warning)

                    if !chat.sending {
                        Button("Reconnect") {
                            chat.start(
                                userID: social.currentUserID
                            )
                        }
                    }
                }

                if social.currentUserID != nil {
                    HStack(alignment: .bottom) {
                        TextField(
                            "Message",
                            text: $draft,
                            axis: .vertical
                        )
                        .lineLimit(1...5)
                        .focused($composerFocused)
                        .padding(12)
                        .background(
                            CapyColor.surfaceStrong,
                            in: RoundedRectangle(
                                cornerRadius: 18
                            )
                        )

                        Button { composerFocused = false } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .frame(width: 38, height: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(CapyColor.secondaryText)
                        .accessibilityLabel("Dismiss keyboard")

                        Button {
                            let submitted = draft

                            Task {
                                if await chat.send(submitted),
                                   draft == submitted {
                                    draft = ""
                                }
                            }
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .rotationEffect(.degrees(45))
                                .frame(width: 44, height: 44)
                        }
                        .background(CapyColor.accent, in: Circle())
                        .disabled(
                            chat.sending ||
                            DirectMessage.cleaned(draft) == nil ||
                            social.profile == nil
                        )
                        .foregroundStyle(CapyColor.background)
                        .accessibilityLabel("Send message")
                    }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
        .sheet(isPresented: $showActiveUsers) {
            NavigationStack {
                GlobalChatActiveUsersView(presence: presence)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showActiveUsers = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView().messageBanners(messaging)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        .navigationTitle("Global Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
        .task(id: social.currentUserID) {
            messaging.globalChatVisible = true
            chat.start(userID: social.currentUserID)

            if scenePhase == .active {
                presence.start(userID: social.currentUserID)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                presence.start(userID: social.currentUserID)
            } else {
                presence.stop()
            }
        }
        .onAppear {
            messaging.globalChatVisible = true
        }
        .onDisappear {
            messaging.globalChatVisible = false
            chat.stop()
            presence.stop()
        }
    }

    private func messageRow(_ message: DirectMessage, previousSame: Bool, nextSame: Bool) -> some View {
        let own = message.senderID == social.currentUserID
        let person = chat.profiles[message.senderID]

        return HStack(alignment: .chatBubbleCenter, spacing: 7) {
            if own { Spacer(minLength: 44) }

            if !own {
                if !nextSame, let person {
                    NavigationLink { SocialPersonProfileView(person: person) } label: {
                        SocialAvatar(profile: person, size: 30)
                    }.buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 30, height: 1)
                }
            }

            VStack(alignment: own ? .trailing : .leading, spacing: 3) {
                if !previousSame, let person {
                    Text(person.displayName)
                        .font(.capyCaption)
                        .foregroundStyle(CapyColor.accent)
                        .lineLimit(1)
                }

                Text(message.text)
                    .font(.capyBody)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .foregroundStyle(own ? CapyColor.background : Color.white)
                    .background(
                        own ? CapyColor.accent : CapyColor.surfaceStrong,
                        in: RoundedRectangle(cornerRadius: previousSame || nextSame ? 13 : 18, style: .continuous)
                    )
                    .alignmentGuide(.chatBubbleCenter) { $0[VerticalAlignment.center] }

                Text(message.pending ? "Sending…" : message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(CapyColor.secondaryText)
            }

            if own {
                if !nextSame, let person {
                    NavigationLink { SocialPersonProfileView(person: person) } label: {
                        SocialAvatar(profile: person, size: 30)
                    }.buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 30, height: 1)
                }
            }

            if !own { Spacer(minLength: 44) }
        }
    }
}
private struct GlobalChatActiveUsersView: View {
    @ObservedObject var presence: GlobalChatPresenceSession

    var body: some View {
        ZStack {
            WaveBackdrop()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(presence.userIDs, id: \.self) { uid in
                        if let person = presence.profiles[uid] {
                            NavigationLink {
                                SocialPersonProfileView(person: person)
                            } label: {
                                HStack(spacing: 12) {
                                    SocialAvatar(profile: person, size: 42)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(person.displayName).font(.capyCallout).foregroundStyle(Color.white)
                                        Text("@" + person.username).font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                                    }
                                    Spacer()
                                    Circle().fill(Color.green).frame(width: 8, height: 8)
                                }.padding(12).waveSurface(radius: 18)
                            }.buttonStyle(.plain)
                        } else {
                            HStack { ProgressView(); Text("Loading profile…"); Spacer() }
                                .font(.capyCaption).foregroundStyle(CapyColor.secondaryText).padding(12)
                        }
                    }
                    if presence.userIDs.isEmpty {
                        Text("No listeners are active right now.")
                            .font(.capyCaption).foregroundStyle(CapyColor.secondaryText).padding(24)
                    }
                }.padding(16)
            }
        }
        .navigationTitle("In chat · \(presence.userIDs.count)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
