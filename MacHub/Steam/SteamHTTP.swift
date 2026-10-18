import CryptoKit
import Foundation

/// GET with an on-disk JSON cache (TTL, stale fallback when offline) and polite per-host pacing.
/// Steam's store endpoints are undocumented and rate limited (HTTP 429), so every call is
/// on demand, cached, and spaced out. Cache keys never contain the Web API key.
actor SteamHTTP {
    enum Failure: Error, Equatable {
        case offline
        case rateLimited
        case unauthorized
        case http(Int)
    }

    struct Response: Sendable {
        let data: Data
        /// Served from cache after a network failure.
        let isStale: Bool
    }

    static let shared = SteamHTTP()

    private let session: URLSession
    private let directory: URL
    private let minimumInterval: Duration
    private let userAgent: String?
    private var nextSlot: [String: ContinuousClock.Instant] = [:]

    init(session: URLSession = .shared, directory: URL? = nil, minimumInterval: Duration = .milliseconds(350), userAgent: String? = nil) {
        self.userAgent = userAgent
        self.session = session
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "app.machub.MacHub/steam")
        self.minimumInterval = minimumInterval
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func get(_ url: URL, ttl: TimeInterval, cacheKey: String? = nil) async throws -> Response {
        let file = cacheFile(for: cacheKey ?? url.absoluteString)
        if let fresh = cached(file, maxAge: ttl) { return Response(data: fresh, isStale: false) }

        do {
            try await pace(host: url.host() ?? "")
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                try? data.write(to: file, options: .atomic)
                return Response(data: data, isStale: false)
            case 401, 403: throw Failure.unauthorized
            case 429: throw Failure.rateLimited
            default: throw Failure.http(status)
            }
        } catch let failure as Failure {
            if failure != .unauthorized, let stale = cached(file, maxAge: .infinity) { return Response(data: stale, isStale: true) }
            throw failure
        } catch {
            if let stale = cached(file, maxAge: .infinity) { return Response(data: stale, isStale: true) }
            throw Failure.offline
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func pace(host: String) async throws {
        let clock = ContinuousClock()
        let slot = max(nextSlot[host] ?? clock.now, clock.now)
        nextSlot[host] = slot + minimumInterval
        try await clock.sleep(until: slot)
    }

    private func cacheFile(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest + ".json")
    }

    private func cached(_ file: URL, maxAge: TimeInterval) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              Date.now.timeIntervalSince(modified) < maxAge
        else { return nil }
        return try? Data(contentsOf: file)
    }
}

/// Store language and country, following the app language and the Mac's region.
struct StoreLocale: Sendable {
    let language: String
    let country: String

    static var current: StoreLocale {
        let app = UserDefaults.standard.string(forKey: AppLanguage.storageKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        let code = app == .system ? (Locale.preferredLanguages.first ?? "en") : app.rawValue
        let language = if code.hasPrefix("fr") { "french" }
            else if code.hasPrefix("ja") { "japanese" }
            else if code.hasPrefix("zh") { "schinese" }
            else { "english" }
        return StoreLocale(language: language, country: Locale.current.region?.identifier ?? "US")
    }
}
