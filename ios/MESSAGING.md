# In-app messaging

Messages is available from the profile drawer, your profile, and another person's profile. Follow someone to start a private text conversation; either participant can reply to an existing conversation. Messages and read markers are stored in Firebase against the account, so signing into the same account restores chats after reinstalling. Firestore rules restrict conversation and message access to the two participants. This is access-controlled storage, not end-to-end encryption.

A bounded inbox listener and a 50-message chat listener provide real-time updates. Older messages load on demand; profile reads are batched and cached per session. The inbox starts with 50 conversations and can expand to 500; it sorts the loaded window locally without requiring a composite index. Unread counts apply to that loaded window. Send failures retain the draft. Offline writes remain pending until Firebase acknowledges them.

New incoming messages show a six-second purple in-app banner, with sender and text preview, while the app is active. Tap to open the chat or dismiss with the close button. The initial server snapshot establishes a baseline, so existing unread messages show in the inbox instead of generating a burst of alerts. Own messages, duplicate snapshots, cached snapshots, and messages in the currently visible chat do not alert. There is no Apple push notification integration or signing entitlement requirement.

Deploy `firebase/firestore.rules` before installing this build. Run the existing Firebase emulator tests and the focused MessagingTests in the existing iOS workflow. Backend playback and resolver code are unchanged.
