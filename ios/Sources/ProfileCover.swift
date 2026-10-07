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

struct ProfileIdentityHeader: View {
    let profile: SocialProfile
    let size: CGFloat
    var coverID: String? = nil

    var body: some View {
        Group {
            if (coverID ?? profile.coverID) == ProfileCoverChoice.parade {
                ProfileCoverView(coverID: ProfileCoverChoice.parade)
                    .padding(.bottom, size / 2 + 4)
                    .overlay(alignment: .bottom) { avatar }
            } else {
                avatar
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var avatar: some View {
        SocialAvatar(profile: profile, size: size)
            .padding(4)
            .background(CapyColor.background, in: Circle())
            .overlay { Circle().stroke(CapyColor.surfaceStroke, lineWidth: 1) }
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}
