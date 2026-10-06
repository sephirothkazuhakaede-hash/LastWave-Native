import SwiftUI

enum ChatNotificationPreferences {
    static var messages: Bool { UserDefaults.standard.object(forKey: "messageBanners") as? Bool ?? true }
    static var global: Bool { UserDefaults.standard.object(forKey: "globalChatBanners") as? Bool ?? true }
}

struct ChatNotificationSettingsView: View {
    @AppStorage("messageBanners") private var messages = true
    @AppStorage("globalChatBanners") private var global = true
    var body: some View {
        Form {
            Section {
                Toggle("Message banners", isOn: $messages)
                Toggle("Global Chat banners", isOn: $global)
            } header: { Text("In-app notifications") } footer: {
                Text("Show a banner at the top while you’re using CapyFlow. Messages remain available when banners are off.")
            }
        }
        .tint(CapyColor.accent)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}
