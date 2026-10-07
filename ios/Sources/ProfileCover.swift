import SwiftUI

enum ProfileCoverChoice {
    static let none = "none"
    static let parade = "capy-parade-v1"
    static func normalized(_ value: String?) -> String { value == parade ? parade : none }
}

struct ProfileCoverView: View {
    let coverID: String
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    @ViewBuilder var body: some View {
        if coverID == ProfileCoverChoice.parade {
            CapyGIFImage(playing: appeared && scenePhase == .active && !reduceMotion,
                         resourceName: "capy-profile-parade", contentMode: .scaleAspectFill)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onAppear { appeared = true }
                .onDisappear { appeared = false }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
