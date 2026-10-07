import Foundation
import Combine
import UIKit

struct ProfileBanner: Codable, Identifiable {
    let id: String
    let name: String
    let revision: String
    let path: String
    var valid: Bool {
        ProfileCoverChoice.normalized(id) == id && id != ProfileCoverChoice.none &&
        revision.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
        path == "/v1/profile-banners/\(id)/\(revision).gif"
    }
}
struct ProfileBannerEnvelope: Codable { let schemaVersion: Int; let banners: [ProfileBanner] }

@MainActor final class ProfileBannerCatalog: ObservableObject {
    static let shared = ProfileBannerCatalog()
    @Published private(set) var banners: [ProfileBanner] = []
    @Published private(set) var hasCatalog = false
    @Published private(set) var baseURL: URL?
    @Published private(set) var offline = false
    private var refreshTask: Task<Void, Never>?
    private let cacheFile: URL

    private init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("profile-banners")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cacheFile = root.appendingPathComponent("catalog.json")
        if let data = try? Data(contentsOf: cacheFile),
           let cached = try? JSONDecoder().decode(ProfileBannerEnvelope.self, from: data),
           cached.schemaVersion == 1 {
            banners = cached.banners.filter(\.valid); hasCatalog = true
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                if UIApplication.shared.applicationState != .background { await self?.refresh() }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
    func refresh() async {
        do {
            let (data, root) = try await BackendClient.shared.profileBannerCatalog()
            let envelope = try JSONDecoder().decode(ProfileBannerEnvelope.self, from: data)
            guard envelope.schemaVersion == 1, envelope.banners.count <= 100,
                  envelope.banners.allSatisfy(\.valid) else { throw URLError(.cannotParseResponse) }
            banners = envelope.banners.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            baseURL = root; hasCatalog = true; offline = false
            try? data.write(to: cacheFile, options: .atomic)
        } catch { offline = true }
    }
    func shows(_ id: String) -> Bool {
        banners.contains { $0.id == id } || (!hasCatalog && id == ProfileCoverChoice.parade)
    }
    func data(for banner: ProfileBanner) async throws -> Data {
        let file = cacheFile.deletingLastPathComponent().appendingPathComponent("\(banner.id)-\(banner.revision).gif")
        if let data = try? Data(contentsOf: file) { return data }
        guard let root = baseURL ?? BackendConfiguration.active?.baseURL else { throw URLError(.notConnectedToInternet) }
        var origin = root
        if origin.lastPathComponent == "v1" { origin.deleteLastPathComponent() }
        let url = origin.appendingPathComponent(String(banner.path.dropFirst()))
        var request = URLRequest(url: url); request.timeoutInterval = 15
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= 5 * 1024 * 1024 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 5 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        guard data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) else { throw URLError(.cannotDecodeContentData) }
        try? data.write(to: file, options: .atomic)
        // Keep storage bounded while retaining the most recently used banners.
        let files = (try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let gifs = files.filter { $0.pathExtension == "gif" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for old in gifs.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
        return data
    }
}
