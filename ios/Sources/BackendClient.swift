import Foundation
import Combine
import FirebaseAuth

struct BackendResolvedStream: Sendable {
    enum Source: Sendable {
        case cacheHit
        case newExtraction
    }

    let audioURL: URL
    let downloadURL: URL
    let duration: Double?
    let durationIsAuthoritative: Bool
    let requestHeaders: [String: String]
    let source: Source
    let mediaInfo: AudioMediaInfo?
}

struct BackendProbeResult: Sendable {
    let latencyMilliseconds: Int
    let message: String
}

struct BackendConfiguration: Sendable, Equatable {
    static let enabledKey = "capyflow.backend.enabled"
    static let baseURLKey = "capyflow.backend.baseURL"
    static let discoveryURL = URL(string: "https://raw.githubusercontent.com/sephirothkazuhakaede-hash/LastWave-Native/runtime/backend-discovery/backend.json")!

    let baseURL: URL

    var usesSecureTransport: Bool {
        baseURL.scheme?.lowercased() == "https"
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var savedURLString: String {
        UserDefaults.standard.string(forKey: baseURLKey) ?? ""
    }

    static var active: BackendConfiguration? {
        guard isEnabled,
              let url = try? normalizedURL(from: savedURLString) else { return nil }
        return BackendConfiguration(baseURL: url)
    }

    /// Include this in stream cache keys so changing servers never reuses a URL
    /// produced by the previous server.
    static var cacheDiscriminator: String {
        "\(isEnabled ? 1 : 0)|\(savedURLString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    @discardableResult
    static func save(urlString: String, enabled: Bool) throws -> BackendConfiguration? {
        let cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !enabled {
            UserDefaults.standard.set(false, forKey: enabledKey)
            if !cleaned.isEmpty {
                UserDefaults.standard.set(cleaned, forKey: baseURLKey)
            }
            return nil
        }

        let url = try normalizedURL(from: cleaned)
        UserDefaults.standard.set(url.absoluteString, forKey: baseURLKey)
        UserDefaults.standard.set(true, forKey: enabledKey)
        return BackendConfiguration(baseURL: url)
    }

    static func normalizedURL(from input: String) throws -> URL {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, var components = URLComponents(string: cleaned) else {
            throw BackendClientError.invalidAddress
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && isPrivateNetworkHost(components.host)) else {
            throw BackendClientError.secureAddressRequired
        }
        guard let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw BackendClientError.invalidAddress
        }

        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let url = components.url else { throw BackendClientError.invalidAddress }
        return url
    }

    private static func isPrivateNetworkHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if normalized == "localhost" || normalized.hasSuffix(".localhost") || normalized == "::1" {
            return true
        }

        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4,
              let first = UInt8(pieces[0]),
              let second = UInt8(pieces[1]),
              UInt8(pieces[2]) != nil,
              UInt8(pieces[3]) != nil else { return false }
        return first == 10
            || first == 127
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
    }

    var healthURL: URL {
        var root = baseURL
        if baseURL.path.split(separator: "/").last?.lowercased() == "v1" {
            root.deleteLastPathComponent()
        }
        return root.appendingPathComponent("health", isDirectory: false)
    }

    func audioURL(videoID: String, quality: AudioQuality) -> URL {
        endpointURL(route: "audio", videoID: videoID, quality: quality)
    }

    func downloadURL(videoID: String, quality: AudioQuality) -> URL {
        endpointURL(route: "download", videoID: videoID, quality: quality)
    }

    func resolveURL(videoID: String, quality: AudioQuality) -> URL {
        endpointURL(route: "resolve", videoID: videoID, quality: quality)
    }

    private func endpointURL(route: String, videoID: String, quality: AudioQuality) -> URL {
        var url = baseURL
        let pathParts = baseURL.path.split(separator: "/").map(String.init)
        if pathParts.last?.lowercased() != "v1" {
            url.appendPathComponent("v1", isDirectory: true)
        }
        url.appendPathComponent(route, isDirectory: true)
        url.appendPathComponent(videoID, isDirectory: false)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "quality", value: quality.backendValue)]
        return components.url!
    }

}

@MainActor
final class BackendConnectionStatus: ObservableObject {
    enum State: Equatable, Sendable {
        case disabled
        case checking
        case connected(String)
        case fallback(String)
    }

    static let shared = BackendConnectionStatus()

    @Published private(set) var state: State = BackendConfiguration.isEnabled
        ? .checking
        : .disabled

    private init() {}

    func update(_ newState: State) {
        state = newState
    }
}

actor BackendClient {
    static let shared = BackendClient()

    func profileBannerCatalog() async throws -> (Data, URL) {
        await refreshDiscoveredConfigurationIfNeeded()
        guard let configuration = BackendConfiguration.active else { throw URLError(.notConnectedToInternet) }
        var root = configuration.baseURL
        if root.lastPathComponent == "v1" { root.deleteLastPathComponent() }
        let (data, _) = try await perform(url: root.appendingPathComponent("v1/profile-banners"), timeout: 6,
                                          retryServerErrors: false, includeAuthentication: false)
        guard data.count <= 262144 else { throw URLError(.dataLengthExceedsMaximum) }
        return (data, root)
    }

    private let session: URLSession
    private var healthyBaseURL: URL?
    private var healthyUntil = Date.distantPast
    private var retryAfter = Date.distantPast
    private var discoveryCheckedAt = Date.distantPast

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 6
        session = URLSession(configuration: configuration)
    }

    /// Lyrics use the same discovered server and HTTPS token policy as media,
    /// but do not modify playback health/backoff or duration state.
    func lyrics(for track: Track) async throws -> BackendLyricsResult? {
        await refreshDiscoveredConfigurationIfNeeded()
        guard let configuration = BackendConfiguration.active else { return nil }
        var url = configuration.baseURL
        if url.lastPathComponent.lowercased() != "v1" { url.appendPathComponent("v1") }
        url.appendPathComponent("lyrics")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "title", value: track.title),
            URLQueryItem(name: "artist", value: AlbumAudioIdentity.artist(track.artist)),
            URLQueryItem(name: "album", value: track.albumTitle),
            URLQueryItem(name: "duration", value: track.duration.map { String($0) }),
            URLQueryItem(name: "videoId", value: track.playableID),
            URLQueryItem(name: "explicit", value: track.isExplicit.map { String($0) })
        ].filter { $0.value != nil }
        let (data, _) = try await perform(url: components.url!, timeout: 12,
                                         retryServerErrors: false,
                                         includeAuthentication: configuration.usesSecureTransport)
        return try JSONDecoder().decode(BackendLyricsResult.self, from: data)
    }

    /// Returns nil whenever the optional backend is disabled or unavailable.
    /// Callers should immediately use their existing YouTube resolver in that case.
    func resolveStream(
        videoID: String,
        quality: AudioQuality,
        knownDuration: Double?
    ) async -> BackendResolvedStream? {
        await refreshDiscoveredConfigurationIfNeeded()
        guard let configuration = BackendConfiguration.active else {
            await publish(.disabled)
            return nil
        }
        guard Date() >= retryAfter else { return nil }

        do {
            try await ensureHealthy(configuration, timeout: 2)
            // Never expose a Firebase identity token over plaintext LAN HTTP.
            // Local development servers use their anonymous mode; Firebase-auth
            // deployments must be behind HTTPS.
            let headers = configuration.usesSecureTransport
                ? try await authorizationHeaders(forceRefresh: false)
                : [:]
            // This warms yt-dlp's short-lived resolution cache and begins the
            // persistent background cache. Search-result prewarming therefore
            // removes most of the delay before a later tap.
            let (metadataData, _) = try await perform(
                url: configuration.resolveURL(videoID: videoID, quality: quality),
                timeout: 6,
                retryServerErrors: false,
                includeAuthentication: configuration.usesSecureTransport
            )
            let metadata = (try? JSONSerialization.jsonObject(with: metadataData)) as? [String: Any]
            let backendDuration = (metadata?["duration"] as? NSNumber)?.doubleValue
            let cacheHit = (metadata?["cached"] as? Bool) == true
            await publish(.connected(cacheHit ? "MSI cache hit" : "MSI prepared this song"))
            return BackendResolvedStream(
                audioURL: configuration.audioURL(videoID: videoID, quality: quality),
                downloadURL: configuration.downloadURL(videoID: videoID, quality: quality),
                duration: backendDuration.flatMap { $0 > 0 ? $0 : nil }
                    ?? knownDuration.flatMap { $0 > 0 ? $0 : nil },
                durationIsAuthoritative: backendDuration.flatMap { $0 > 0 ? $0 : nil } != nil,
                requestHeaders: headers,
                source: cacheHit ? .cacheHit : .newExtraction,
                mediaInfo: metadata?["mediaInfo"].flatMap { value in
                    guard JSONSerialization.isValidJSONObject(value),
                          let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
                    return try? JSONDecoder().decode(AudioMediaInfo.self, from: data)
                }
            )
        } catch is CancellationError {
            return nil
        } catch {
            if Self.shouldQuarantineBackend(after: error) {
                healthyBaseURL = nil
                healthyUntil = .distantPast
                retryAfter = Date().addingTimeInterval(30)
            }
            await publish(.fallback(Self.fallbackMessage(for: error)))
            return nil
        }
    }

    func testConnection(to urlString: String) async throws -> BackendProbeResult {
        let configuration = BackendConfiguration(baseURL: try BackendConfiguration.normalizedURL(from: urlString))
        await publish(.checking)
        let started = Date()
        do {
            try await ensureHealthy(configuration, timeout: 10, force: true)
            let elapsed = max(1, Int(Date().timeIntervalSince(started) * 1_000))
            retryAfter = .distantPast
            await publish(.connected("Custom server connected in \(elapsed) ms"))
            return BackendProbeResult(
                latencyMilliseconds: elapsed,
                message: "Connected in \(elapsed) ms"
            )
        } catch {
            healthyBaseURL = nil
            healthyUntil = .distantPast
            await publish(.fallback(Self.fallbackMessage(for: error)))
            throw error
        }
    }

    private func refreshDiscoveredConfigurationIfNeeded() async {
        let saved = BackendConfiguration.savedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedHost = URL(string: saved)?.host?.lowercased()
        let shouldDiscover = saved.isEmpty || (BackendConfiguration.isEnabled && savedHost?.hasSuffix(".trycloudflare.com") == true)
        guard shouldDiscover, Date().timeIntervalSince(discoveryCheckedAt) >= 60 else { return }
        discoveryCheckedAt = Date()

        do {
            var request = URLRequest(url: BackendConfiguration.discoveryURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 5
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = payload["url"] as? String,
                  let url = try? BackendConfiguration.normalizedURL(from: value),
                  url.host?.lowercased().hasSuffix(".trycloudflare.com") == true else { return }

            if url.absoluteString != saved || !BackendConfiguration.isEnabled {
                _ = try BackendConfiguration.save(urlString: url.absoluteString, enabled: true)
                healthyBaseURL = nil
                healthyUntil = .distantPast
                retryAfter = .distantPast
                await publish(.checking)
            }
        } catch {
            // Best-effort discovery: keep the last working tunnel and direct fallback.
        }
    }

    func configurationDidChange() async {
        healthyBaseURL = nil
        healthyUntil = .distantPast
        retryAfter = .distantPast
        if BackendConfiguration.active == nil {
            await publish(.disabled)
        } else {
            await publish(.checking)
        }
    }

    func reportStreamFailure(_ message: String? = nil) async {
        // A media failure is normally specific to one upload or one signed URL.
        // Do not quarantine a healthy MSI for every other song in Download All.
        // Connectivity/health failures still set retryAfter in resolveStream.
        let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusMessage: String
        if let detail, !detail.isEmpty {
            statusMessage = "Custom server failed: \(detail). Using direct YouTube."
        } else {
            statusMessage = "Custom server could not play this song. Using direct YouTube."
        }
        await publish(.fallback(statusMessage))
    }

    private func ensureHealthy(
        _ configuration: BackendConfiguration,
        timeout: TimeInterval,
        force: Bool = false
    ) async throws {
        if !force,
           healthyBaseURL == configuration.baseURL,
           Date() < healthyUntil {
            return
        }

        let (_, response) = try await perform(
            url: configuration.healthURL,
            timeout: timeout,
            retryServerErrors: true,
            includeAuthentication: false
        )
        guard (200...299).contains(response.statusCode) else {
            throw BackendClientError.httpStatus(response.statusCode)
        }
        healthyBaseURL = configuration.baseURL
        healthyUntil = Date().addingTimeInterval(120)
    }

    private func perform(
        url: URL,
        timeout: TimeInterval,
        retryServerErrors: Bool,
        includeAuthentication: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        var networkRetries = 0
        var refreshedAuthentication = false

        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("CapyFlow-iOS/1", forHTTPHeaderField: "User-Agent")
            if includeAuthentication {
                let authHeaders = try await authorizationHeaders(forceRefresh: refreshedAuthentication)
                authHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw BackendClientError.invalidResponse
                }
                if includeAuthentication,
                   http.statusCode == 401,
                   Auth.auth().currentUser != nil,
                   !refreshedAuthentication {
                    refreshedAuthentication = true
                    continue
                }
                if retryServerErrors,
                   (500...599).contains(http.statusCode),
                   networkRetries == 0 {
                    networkRetries += 1
                    try await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                guard (200...299).contains(http.statusCode) else {
                    throw BackendClientError.httpStatus(http.statusCode)
                }
                return (data, http)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BackendClientError {
                throw error
            } catch {
                if networkRetries == 0, Self.isRetryable(error) {
                    networkRetries += 1
                    try await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                throw BackendClientError.network(error.localizedDescription)
            }
        }
    }

    private func authorizationHeaders(forceRefresh: Bool) async throws -> [String: String] {
        guard let user = Auth.auth().currentUser else { return [:] }
        let token: String = try await withCheckedThrowingContinuation { continuation in
            user.getIDTokenForcingRefresh(forceRefresh) { token, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token, !token.isEmpty {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: BackendClientError.missingAuthenticationToken)
                }
            }
        }
        return ["Authorization": "Bearer \(token)"]
    }

    private func publish(_ state: BackendConnectionStatus.State) async {
        await BackendConnectionStatus.shared.update(state)
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func fallbackMessage(for error: Error) -> String {
        if let backendError = error as? BackendClientError {
            switch backendError {
            case .httpStatus(401), .httpStatus(403), .missingAuthenticationToken:
                return "The streaming server could not verify your account. Using the standard connection."
            case .httpStatus:
                return "The streaming server is having trouble. Using the standard connection."
            case .network:
                return "The streaming server is unavailable. Using the standard connection."
            default:
                return "The streaming server is unavailable. Using the standard connection."
            }
        }
        return "The streaming server is unavailable. Using the standard connection."
    }

    private static func shouldQuarantineBackend(after error: Error) -> Bool {
        guard let backendError = error as? BackendClientError else { return true }
        switch backendError {
        case .httpStatus(401), .httpStatus(403), .missingAuthenticationToken,
             .invalidAddress, .secureAddressRequired, .invalidResponse, .network:
            return true
        case .httpStatus:
            // Extraction failures (usually 5xx) are often song-specific.
            return false
        }
    }
}

enum BackendClientError: LocalizedError {
    case invalidAddress
    case secureAddressRequired
    case invalidResponse
    case httpStatus(Int)
    case missingAuthenticationToken
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Enter a complete server address, such as https://music.example.com."
        case .secureAddressRequired:
            return "Use an address starting with https://. Addresses starting with http:// work only on your home network."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .httpStatus:
            return "The streaming server could not complete the request. Please try again."
        case .missingAuthenticationToken:
            return "The streaming server could not verify your account. Please sign in again."
        case .network:
            return "Could not connect. Check your internet connection and try again."
        }
    }
}
