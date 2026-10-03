import Foundation
import SwiftUI

/// Numeric version components and build numbers, never lexical comparison.
struct AppReleaseVersion: Comparable, Equatable {
    let components: [Int]
    let build: Int
    init?(version: String, build: Int) {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count), build > 0,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        self.components = parts.map { Int($0)! }; self.build = build
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        padded(lhs.components) == padded(rhs.components) && lhs.build == rhs.build
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        let left = padded(lhs.components), right = padded(rhs.components)
        for (a, b) in zip(left, right) where a != b { return a < b }
        return lhs.build < rhs.build
    }
    private static func padded(_ value: [Int]) -> [Int] { value + Array(repeating: 0, count: max(0, 4 - value.count)) }
}

struct StableUpdateManifest: Decodable, Identifiable {
    let schemaVersion: Int
    let channel: String
    let version: String
    let build: Int
    let releaseNotes: String
    let installURL: URL
    var id: String { version + ":" + String(build) }
    var releaseVersion: AppReleaseVersion? { AppReleaseVersion(version: version, build: build) }
    var isStable: Bool {
        schemaVersion == 1 && channel == "stable" && releaseVersion != nil &&
        installURL.scheme?.lowercased() == "https" && installURL.host != nil &&
        installURL.user == nil && installURL.password == nil && !releaseNotes.isEmpty
    }
    func isNewer(than current: AppReleaseVersion) -> Bool { isStable && (releaseVersion.map { $0 > current } ?? false) }
}

struct GitHubStableRelease: Decodable {
    struct Asset: Decodable { let name: String; let browser_download_url: URL }
    let draft: Bool
    let prerelease: Bool
    let tag_name: String
    let assets: [Asset]
    var isEligible: Bool { !draft && !prerelease && tag_name.hasPrefix("capyflow-v") && AppReleaseVersion(version: String(tag_name.dropFirst(10)), build: 1) != nil }
}

@MainActor final class StableUpdateStore: ObservableObject {
    static let repository = "sephirothkazuhakaede-hash/LastWave-Native"
    static let manifestURL = URL(string: "https://raw.githubusercontent.com/\(repository)/stable-updates/capyflow-stable.json")!
    @Published private(set) var available: StableUpdateManifest?
    @Published var presented: StableUpdateManifest?
    @Published private(set) var checking = false
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    private var lastCheck = Date.distantPast
    private let session: URLSession
    private let current: AppReleaseVersion?
    init(session: URLSession = .shared, bundle: Bundle = .main) {
        self.session = session
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        current = AppReleaseVersion(version: version, build: Int(build) ?? 0)
    }
    func check(manual: Bool = false) async {
        guard !checking, let current, manual || Date().timeIntervalSince(lastCheck) > 6 * 3600 else { return }
        checking = true; error = nil; status = nil; lastCheck = Date()
        defer { checking = false }
        do {
            // Consider both sources: an old branch manifest must not mask a
            // newer stable GitHub release. Either source may fail independently.
            async let branchResult = candidateResult(manifestSource: true)
            async let releaseResult = candidateResult(manifestSource: false)
            let results = await [branchResult, releaseResult]
            var candidates: [StableUpdateManifest] = []
            var succeeded = false
            var lastFailure: Error?
            for result in results {
                switch result {
                case .success(let candidate):
                    succeeded = true
                    if let candidate { candidates.append(candidate) }
                case .failure(let failure): lastFailure = failure
                }
            }
            guard succeeded else { throw lastFailure ?? WaveError.message("Stable update source is unavailable.") }
            let candidate = candidates.max { $0.releaseVersion! < $1.releaseVersion! }
            guard let candidate, candidate.isNewer(than: current) else {
                available = nil; status = candidate == nil ? "No published stable update is available." : "CapyFlow is up to date."; return
            }
            available = candidate
            // Later suppresses repeated automatic prompts for the same build.
            if manual || UserDefaults.standard.string(forKey: "capyflow.updates.deferred") != candidate.id {
                presented = candidate
            }
        } catch {
            if manual { self.error = "Couldn't check for stable updates: " + error.localizedDescription }
        }
    }
    func later(_ manifest: StableUpdateManifest) {
        UserDefaults.standard.set(manifest.id, forKey: "capyflow.updates.deferred")
        presented = nil
    }
    private func candidateResult(manifestSource: Bool) async -> Result<StableUpdateManifest?, Error> {
        do {
            if manifestSource {
                let data = try await fetch(Self.manifestURL)
                let manifest = try JSONDecoder().decode(StableUpdateManifest.self, from: data)
                guard manifest.isStable else { throw WaveError.message("The update manifest is not a valid stable release.") }
                return .success(manifest)
            }
            return .success(try await githubCandidate())
        } catch { return .failure(error) }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 15
        request.setValue("CapyFlow/0.4.5", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 1_000_000 else {
            throw WaveError.message("Stable update source is unavailable.")
        }
        return data
    }
    private func githubCandidate() async throws -> StableUpdateManifest? {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=30")!
        let releases = try JSONDecoder().decode([GitHubStableRelease].self, from: await fetch(url))
        var manifests: [StableUpdateManifest] = []
        for release in releases where release.isEligible {
            guard let asset = release.assets.first(where: { $0.name == "capyflow-stable.json" }),
                  asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
                  asset.browser_download_url.path.hasPrefix("/" + Self.repository + "/releases/download/") else { continue }
            guard let data = try? await fetch(asset.browser_download_url),
                  let manifest = try? JSONDecoder().decode(StableUpdateManifest.self, from: data) else { continue }
            if manifest.isStable && release.tag_name == "capyflow-v" + manifest.version { manifests.append(manifest) }
            if manifests.count >= 5 { break }
        }
        return manifests.max { $0.releaseVersion! < $1.releaseVersion! }
    }
}

struct StableUpdateSheet: View {
    @EnvironmentObject private var updates: StableUpdateStore
    @Environment(\.openURL) private var openURL
    let manifest: StableUpdateManifest
    var body: some View {
        NavigationStack {
            ZStack {
                WaveBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Label("CapyFlow \(manifest.version)", systemImage: "arrow.down.circle.fill")
                            .font(.capyTitle).foregroundStyle(CapyColor.accent)
                        Text("Build \(manifest.build)").font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                        Text("What’s new").font(.headline)
                        Text(manifest.releaseNotes).font(.capyBody).textSelection(.enabled)
                        Text("Update opens the release or installation page. Sign the update with your usual certificate and install it over CapyFlow to retain your data.")
                            .font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                        Button("Update") { openURL(manifest.installURL) }.buttonStyle(CapyPrimaryButtonStyle())
                        Button("Later") { updates.later(manifest) }.buttonStyle(CapySecondaryButtonStyle())
                    }.padding(24)
                }
            }.navigationTitle("Update available").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct StableUpdatesView: View {
    @EnvironmentObject private var updates: StableUpdateStore
    var body: some View {
        ZStack {
            WaveBackdrop()
            VStack(spacing: 18) {
                Text("Stable updates").font(.capyTitle)
                Text("Only published stable CapyFlow releases appear here.").font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                if let manifest = updates.available {
                    Text("Version \(manifest.version) · Build \(manifest.build)").foregroundStyle(CapyColor.accent)
                    Button("View update") { updates.presented = manifest }.buttonStyle(CapyPrimaryButtonStyle())
                }
                Button { Task { await updates.check(manual: true) } } label: {
                    if updates.checking { ProgressView() } else { Text("Check for updates") }
                }.buttonStyle(CapySecondaryButtonStyle()).disabled(updates.checking)
                if let status = updates.status { Text(status).font(.capyCaption).foregroundStyle(CapyColor.secondaryText) }
                if let error = updates.error { Text(error).font(.capyCaption).foregroundStyle(CapyColor.warning) }
            }.padding(24)
        }.navigationTitle("Updates").navigationBarTitleDisplayMode(.inline)
    }
}
