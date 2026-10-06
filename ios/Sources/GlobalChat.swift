import SwiftUI
import FirebaseAuth
import FirebaseFirestore

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
                        NavigationLink {
                            GlobalChatActiveUsersView(
                                presence: presence
                            )
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

                                    messageRow(message)
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
            presence.stop()
        }
    }

    private func messageRow(_ message: DirectMessage) -> some View {
        let own = message.senderID == social.currentUserID
        let person = chat.profiles[message.senderID]

        return HStack(alignment: .top, spacing: 8) {
            if own {
                Spacer(minLength: 45)
            }

            if !own {
                if let person {
                    NavigationLink {
                        SocialPersonProfileView(person: person)
                    } label: {
                        SocialAvatar(profile: person, size: 32)
                    }
                    .buttonStyle(.plain)
                } else {
                    Circle()
                        .fill(CapyColor.surfaceStrong)
                        .frame(width: 32, height: 32)
                }
            }

            VStack(
                alignment: own ? .trailing : .leading,
                spacing: 4
            ) {
                if let person {
                    NavigationLink {
                        SocialPersonProfileView(person: person)
                    } label: {
                        Text(person.displayName)
                            .font(.capyCaption)
                            .foregroundStyle(CapyColor.accent)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(CapyColor.surfaceStrong)
                        .frame(width: 96, height: 12)
                        .accessibilityLabel("Loading profile")
                }

                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.text)
                        .font(.capyBody)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                        .textSelection(.enabled)

                    Text(
                        message.pending
                            ? "Sending…"
                            : message.createdAt.formatted(
                                date: .omitted,
                                time: .shortened
                            )
                    )
                    .font(.caption2)
                    .opacity(0.65)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .foregroundStyle(
                    own ? CapyColor.background : Color.white
                )
                .background(
                    own
                        ? CapyColor.accent
                        : CapyColor.surfaceStrong,
                    in: RoundedRectangle(
                        cornerRadius: 18,
                        style: .continuous
                    )
                )
            }

            if own, let person {
                NavigationLink {
                    SocialPersonProfileView(person: person)
                } label: {
                    SocialAvatar(profile: person, size: 32)
                }
                .buttonStyle(.plain)
            }

            if !own {
                Spacer(minLength: 45)
            }
        }
    }
}