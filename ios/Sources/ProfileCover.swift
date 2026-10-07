import SwiftUI

enum ProfileCoverChoice {
    static let none = "none"
    static let parade = "capy-parade-v1"
    static func normalized(_ value: String?) -> String {
        guard let value, value.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil else { return none }
        return value
    }
}

struct ProfileCoverView: View {
    let coverID: String
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @StateObject private var catalog = ProfileBannerCatalog.shared
    @State private var data: Data?
    private var banner: ProfileBanner? { catalog.banners.first { $0.id == coverID } }

    @ViewBuilder var body: some View {
        if catalog.shows(coverID) {
            CapyGIFImage(playing: appeared && scenePhase == .active && !reduceMotion,
                         resourceName: "capy-profile-parade", contentMode: .scaleAspectFill, gifData: data)
                .id(data)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onAppear { appeared = true }
                .onDisappear { appeared = false }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .task(id: "\(coverID)-\(banner?.revision ?? "")-\(catalog.baseURL?.absoluteString ?? "")") {
                    data = nil
                    guard let banner else { return }
                    for attempt in 0..<3 {
                        do {
                            let downloaded = try await catalog.data(for: banner)
                            try Task.checkCancellation()
                            data = downloaded
                            return
                        } catch is CancellationError { return }
                        catch {
                            if Task.isCancelled { return }
                            if attempt < 2 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                        }
                    }
                }
        }
    }
}

struct ProfileIdentityHeader: View {
    let profile: SocialProfile
    let size: CGFloat
    var coverID: String? = nil
    @StateObject private var catalog = ProfileBannerCatalog.shared

    var body: some View {
        Group {
            if catalog.shows(coverID ?? profile.coverID) {
                ProfileCoverView(coverID: coverID ?? profile.coverID)
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
