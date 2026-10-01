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
}

struct BackendProbeResult: Sendable {
    let latencyMilliseconds: Int
    let message: String
}

struct BackendConfiguration: Sendable, Equatable {
    static let enabledKey = "capyflow.backend.enabled"
    static let baseURLKey = "capyflow.backend.baseURL"

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

    private let session: URLSession
    private var healthyBaseURL: URL?
    private var healthyUntil = Date.distantPast
    private var retryAfter = Date.distantPast

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 6
        session = URLSession(configuration: configuration)
    }

    /// Returns nil whenever the optional backend is disabled or unavailable.
    /// Callers should immediately use their existing YouTube resolver in that case.
    func resolveStream(
        videoID: String,
        quality: AudioQuality,
        knownDuration: Double?
    ) async -> BackendResolvedStream? {
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
                source: cacheHit ? .cacheHit : .newExtraction
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
                return "The custom server did not accept your account. Using direct YouTube."
            case .httpStatus(let code):
                return "The custom server returned HTTP \(code). Using direct YouTube."
            case .network(let detail):
                return "The custom server is unavailable (\(detail)). Using direct YouTube."
            default:
                return "The custom server is unavailable. Using direct YouTube."
            }
        }
        return "The custom server is unavailable. Using direct YouTube."
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
            return "Use HTTPS for public servers. HTTP is allowed only for localhost or a private home-network address."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .httpStatus(let code):
            return "The server returned HTTP \(code)."
        case .missingAuthenticationToken:
            return "CapyFlow could not authenticate with the server."
        case .network(let detail):
            return detail
        }
    }
}

private extension AudioQuality {
    var backendValue: String {
        switch self {
        case .automatic: return "automatic"
        case .high: return "high"
        case .dataSaver: return "dataSaver"
        }
    }
}
