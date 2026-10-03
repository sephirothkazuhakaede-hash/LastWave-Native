import SwiftUI

struct MessagesInboxView: View {
    @EnvironmentObject private var messaging: MessagingStore
    @EnvironmentObject private var social: SocialStore
    var body: some View {
        ZStack {
            WaveBackdrop()
            ScrollView {
                CapyScreenContainer {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if social.currentUserID == nil {
                            ContentUnavailableView("Sign in to message friends", systemImage: "bubble.left.and.bubble.right")
                        } else {
                            if messaging.fromCache { Text("Showing saved conversations").font(.capyCaption).foregroundStyle(CapyColor.secondaryText) }
                            if messaging.loading { ProgressView("Loading messages…").padding(20) }
                            if let error = messaging.error {
                                Text(error).font(.capyCaption).foregroundStyle(CapyColor.warning)
                                Button("Retry messages") { messaging.retry() }.buttonStyle(CapySecondaryButtonStyle())
                            }
                            ForEach(messaging.conversations) { conversation in
                                if let uid = social.currentUserID, let peerID = conversation.peerID(for: uid) {
                                    if let person = messaging.profiles[peerID] {
                                        NavigationLink { DirectChatView(person: person) } label: {
                                            MessageConversationRow(person: person, preview: conversation.lastText, unread: conversation.isUnread(for: uid))
                                        }.buttonStyle(.plain)
                                    } else {
                                        HStack { Image(systemName: "person.crop.circle"); Text("Loading profile…"); Spacer(); Text(conversation.lastText).lineLimit(1) }
                                            .font(.capyCaption).foregroundStyle(CapyColor.secondaryText).padding(12)
                                    }
                                }
                            }
                            if !messaging.loading && messaging.conversations.isEmpty && messaging.error == nil {
                                ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right",
                                                       description: Text("Start a conversation with someone you follow."))
                            }
                            if messaging.hasMore { Button("Load more conversations") { messaging.loadMore() }.buttonStyle(CapySecondaryButtonStyle()) }
                        }
                    }.padding(.vertical, 18)
                }
            }
        }
        .navigationTitle("Messages").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if social.currentUserID != nil {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { NewMessageView() } label: { Image(systemName: "square.and.pencil").accessibilityLabel("New message") }
                }
            }
        }
    }
}

private struct MessageConversationRow: View {
    let person: SocialProfile
    let preview: String
    let unread: Bool
    var body: some View {
        HStack(spacing: 12) {
            SocialAvatar(profile: person, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(person.displayName).font(.capyCallout).foregroundStyle(Color.white)
                Text(preview).font(.capyCaption).foregroundStyle(CapyColor.secondaryText).lineLimit(2)
            }
            Spacer(minLength: 4)
            if unread { Circle().fill(CapyColor.accent).frame(width: 9, height: 9).accessibilityLabel("Unread conversation") }
        }.padding(12).waveSurface(radius: 18)
    }
}

private struct NewMessageView: View {
    @EnvironmentObject private var social: SocialStore
    var body: some View {
        ZStack {
            WaveBackdrop()
            ScrollView {
                CapyScreenContainer {
                    LazyVStack(spacing: 10) {
                        ForEach(social.following) { person in
                            NavigationLink { DirectChatView(person: person) } label: {
                                HStack(spacing: 12) {
                                    SocialAvatar(profile: person, size: 52)
                                    VStack(alignment: .leading) { Text(person.displayName).font(.capyCallout); Text("@" + person.username).font(.capyCaption).foregroundStyle(CapyColor.secondaryText) }
                                    Spacer(); Image(systemName: "chevron.right")
                                }.padding(12).waveSurface(radius: 18)
                            }.buttonStyle(.plain)
                        }
                        if social.following.isEmpty {
                            ContentUnavailableView("Follow a friend first", systemImage: "person.2", description: Text("You can also open a profile from Followers or Following and tap Message."))
                        }
                    }.padding(.vertical, 18)
                }
            }
        }.navigationTitle("New Message").navigationBarTitleDisplayMode(.inline)
    }
}

struct DirectChatView: View {
    @EnvironmentObject private var messaging: MessagingStore
    @EnvironmentObject private var social: SocialStore
    @StateObject private var chat = DirectChatSession()
    @State private var draft = ""
    @State private var loadingHistory = false
    let person: SocialProfile
    var body: some View {
        ZStack {
            WaveBackdrop()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if chat.loading { ProgressView("Connecting…").padding(20) }
                        if chat.hasMore {
                            Button(chat.loadingOlder ? "Loading…" : "Load older messages") {
                                Task { loadingHistory = true; await chat.loadOlder(); loadingHistory = false }
                            }.disabled(chat.loadingOlder)
                        }
                        if !chat.loading && chat.messages.isEmpty { Text("Start your conversation with @\(person.username)").font(.capyCaption).foregroundStyle(CapyColor.secondaryText).padding(24) }
                        ForEach(chat.messages) { message in
                            let mine = message.senderID == social.currentUserID
                            HStack {
                                if mine { Spacer(minLength: 40) }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(message.text).font(.capyBody).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    Text(message.pending ? "Sending…" : message.createdAt.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2).opacity(0.6)
                                }
                                .padding(12).foregroundStyle(mine ? Color.black : Color.white)
                                .background(mine ? CapyColor.accent : CapyColor.surfaceStrong, in: RoundedRectangle(cornerRadius: 18))
                                if !mine { Spacer(minLength: 40) }
                            }.id(message.id)
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 18)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages.last?.id) { _, id in
                    if !loadingHistory, let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if let error = chat.error {
                    Text(error).font(.capyCaption).foregroundStyle(CapyColor.warning).fixedSize(horizontal: false, vertical: true)
                    if !chat.sending { Button("Reconnect chat") { chat.start(userID: social.currentUserID, peerID: person.id) } }
                }
                if !chat.exists && !social.isFollowing(person.id) { Text("Follow this person to start a new conversation.").font(.capyCaption).foregroundStyle(CapyColor.secondaryText) }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Message", text: $draft, axis: .vertical).lineLimit(1...5)
                        .padding(12).background(CapyColor.surfaceStrong, in: RoundedRectangle(cornerRadius: 18))
                    Button {
                        let outgoing = draft
                        Task { if await chat.send(outgoing), draft == outgoing { draft = "" } }
                    } label: {
                        Group { if chat.sending { ProgressView() } else { Image(systemName: "arrow.up") } }
                            .frame(width: 44, height: 44)
                    }.buttonStyle(.borderedProminent).tint(CapyColor.accent).foregroundStyle(Color.black)
                        .accessibilityLabel("Send message")
                        .disabled(chat.loading || chat.sending || DirectMessage.cleaned(draft) == nil || (!chat.exists && !social.isFollowing(person.id)))
                }
                if draft.utf16.count > 4000 { Text("Messages can contain up to 4,000 characters.").font(.capyCaption).foregroundStyle(CapyColor.warning) }
            }.padding(12).background(CapyColor.background)
        }
        .navigationTitle(person.displayName).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { NavigationLink { SocialPersonProfileView(person: person) } label: { SocialAvatar(profile: person, size: 34) } }
        }
        .task(id: social.currentUserID) { messaging.activePeerID = person.id; chat.start(userID: social.currentUserID, peerID: person.id) }
        .onDisappear { if messaging.activePeerID == person.id { messaging.activePeerID = nil }; chat.stop() }
    }
}

private struct MessageBannerModifier: ViewModifier {
    @EnvironmentObject private var messaging: MessagingStore
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPerson: SocialProfile?
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if phase == .active, let event = messaging.banner {
                    HStack(spacing: 12) {
                        Button {
                            if let person = messaging.profiles[event.peerID] { selectedPerson = person; messaging.dismissBanner() }
                        } label: {
                            HStack(spacing: 12) {
                                if let person = messaging.profiles[event.peerID] { SocialAvatar(profile: person, size: 42) }
                                else { Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(CapyColor.accent) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(messaging.profiles[event.peerID]?.displayName ?? "New message").font(.capyCallout).foregroundStyle(CapyColor.accent)
                                    Text(event.preview).font(.capyCaption).foregroundStyle(Color.white).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(messaging.profiles[event.peerID] == nil)
                        Button { messaging.dismissBanner() } label: { Image(systemName: "xmark").padding(8) }
                            .foregroundStyle(CapyColor.secondaryText).accessibilityLabel("Dismiss message notification")
                    }
                    .padding(14).waveSurface(radius: 20).padding(.horizontal, 12).padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    .task(id: event.id) {
                        do { try await Task.sleep(for: .seconds(6)); if messaging.banner?.id == event.id { messaging.dismissBanner() } } catch { }
                    }
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.9), value: messaging.banner?.id)
            .onChange(of: phase) { _, phase in if phase != .active { messaging.dismissBanner() } }
            .sheet(item: $selectedPerson) { person in
                NavigationStack {
                    DirectChatView(person: person)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { selectedPerson = nil } } }
                }.presentationDetents([.large])
            }
    }
}

extension View {
    func messageBanners() -> some View { modifier(MessageBannerModifier()) }
}
