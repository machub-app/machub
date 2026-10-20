import Foundation
import Security

/// Nexus Mods, the largest mod catalog for PC games. Browsing uses Nexus's public GraphQL API (no key). Files and
/// downloads use the v1 REST API with the user's own personal API key (free, from nexusmods.com › Settings › API).
/// Free accounts download through "Mod Manager Download" links (nxm://) that Nexus hands to MacHub after a click on
/// its site; Premium accounts get direct links from the API. MacHub never works around Premium.
enum NexusMods {
    static let graphQL = URL(string: "https://api.nexusmods.com/v2/graphql")!
    static let rest = URL(string: "https://api.nexusmods.com/v1")!

    /// Games MacHub installs Nexus mods for, by Steam App ID → Nexus game domain (checked 2026-10-19).
    static let domains: [Int: String] = [284160: "beamngdrive", 1091500: "cyberpunk2077", 934700: "deadisland2",
                                         244210: "assettocorsa"]

    struct Mod: Identifiable, Hashable, Sendable {
        let id: Int
        let domain: String
        let name: String
        let summary: String
        let version: String
        let author: String
        let pictureURL: URL?
        let endorsements: Int
        let downloads: Int
        /// Kilobytes, as Nexus reports them.
        let fileSizeKB: Int
        let updatedAt: Date?

        var pageURL: URL { URL(string: "https://www.nexusmods.com/\(domain)/mods/\(id)")! }
        var filesPageURL: URL { URL(string: "https://www.nexusmods.com/\(domain)/mods/\(id)?tab=files")! }
    }

    struct File: Identifiable, Hashable, Sendable {
        let id: Int
        let name: String
        let version: String
        /// MAIN, UPDATE, OPTIONAL, OLD_VERSION, MISCELLANEOUS…
        let category: String
        let sizeKB: Int
        let fileName: String
        let uploadedAt: Date?
    }

    enum Sort: String, CaseIterable, Sendable {
        case endorsements, downloads, updatedAt, createdAt
    }

    struct Page: Sendable {
        let mods: [Mod]
        let total: Int
    }

    enum Failure: Error, Equatable {
        case noKey
        case invalidKey
        case premiumRequired
        case http(Int)
        case unreadable
    }

    static var headers: [String: String] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        return ["Application-Name": "MacHub", "Application-Version": version, "Accept": "application/json"]
    }

    // MARK: Catalog (public GraphQL)

    static func search(domain: String, query: String, sort: Sort, offset: Int, count: Int = 30) async throws -> Page {
        var filter: [String: Any] = ["gameDomainName": [["value": domain, "op": "EQUALS"]]]
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { filter["name"] = [["value": "*\(trimmed)*", "op": "WILDCARD"]] }
        let body: [String: Any] = [
            "query": """
            query($filter: ModsFilter, $sort: [ModsSort!], $offset: Int, $count: Int) {
              mods(filter: $filter, sort: $sort, offset: $offset, count: $count) {
                totalCount
                nodes { modId name summary version author pictureUrl endorsements downloads fileSize updatedAt game { domainName } }
              }
            }
            """,
            "variables": ["filter": filter, "sort": [[sort.rawValue: ["direction": "DESC"]]], "offset": offset, "count": count],
        ]
        var request = URLRequest(url: graphQL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.http(http.statusCode) }
        return try parseSearch(data, domain: domain)
    }

    static func parseSearch(_ data: Data, domain: String) throws -> Page {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mods = (root["data"] as? [String: Any])?["mods"] as? [String: Any],
              let nodes = mods["nodes"] as? [[String: Any]]
        else { throw Failure.unreadable }
        let iso = ISO8601DateFormatter()
        return Page(mods: nodes.compactMap { node in
            guard let id = node["modId"] as? Int, let name = node["name"] as? String else { return nil }
            return Mod(id: id, domain: ((node["game"] as? [String: Any])?["domainName"] as? String) ?? domain, name: name,
                       summary: node["summary"] as? String ?? "", version: node["version"] as? String ?? "",
                       author: node["author"] as? String ?? "", pictureURL: (node["pictureUrl"] as? String).flatMap(URL.init(string:)),
                       endorsements: node["endorsements"] as? Int ?? 0, downloads: node["downloads"] as? Int ?? 0,
                       fileSizeKB: node["fileSize"] as? Int ?? 0, updatedAt: (node["updatedAt"] as? String).flatMap(iso.date(from:)))
        }, total: mods["totalCount"] as? Int ?? nodes.count)
    }

    // MARK: Account, files and downloads (REST, user's key)

    struct Account: Equatable, Sendable {
        let name: String
        let isPremium: Bool
    }

    private static func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard let key = NexusKeyStore.load() else { throw Failure.noKey }
        var components = URLComponents(url: rest.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(key, forHTTPHeaderField: "apikey")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data
        case 401: throw Failure.invalidKey
        case 403: throw Failure.premiumRequired
        case let code: throw Failure.http(code)
        }
    }

    static func validate() async throws -> Account {
        let data = try await get("users/validate.json")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        return Account(name: json["name"] as? String ?? "", isPremium: json["is_premium"] as? Bool ?? false)
    }

    static func files(domain: String, modID: Int) async throws -> [File] {
        try parseFiles(try await get("games/\(domain)/mods/\(modID)/files.json"))
    }

    static func parseFiles(_ data: Data) throws -> [File] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else { throw Failure.unreadable }
        return files.compactMap { file in
            guard let id = file["file_id"] as? Int else { return nil }
            return File(id: id, name: file["name"] as? String ?? "", version: file["version"] as? String ?? "",
                        category: file["category_name"] as? String ?? "", sizeKB: file["size_kb"] as? Int ?? 0,
                        fileName: file["file_name"] as? String ?? "", uploadedAt: (file["uploaded_timestamp"] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
        .sorted { ($0.uploadedAt ?? .distantPast) > ($1.uploadedAt ?? .distantPast) }
    }

    /// Download URLs for a file. Free accounts must pass the key/expires of an nxm:// link; Premium may omit them.
    static func downloadLinks(domain: String, modID: Int, fileID: Int, key: String? = nil, expires: String? = nil) async throws -> [URL] {
        var query: [URLQueryItem] = []
        if let key, let expires { query = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "expires", value: expires)] }
        let data = try await get("games/\(domain)/mods/\(modID)/files/\(fileID)/download_link.json", query: query)
        guard let links = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure.unreadable }
        return links.compactMap { ($0["URI"] as? String).flatMap(URL.init(string:)) }
    }
}

/// A "Mod Manager Download" link from Nexus: nxm://<domain>/mods/<mod>/files/<file>?key=…&expires=…&user_id=…
struct NexusLink: Equatable, Sendable {
    let domain: String
    let modID: Int
    let fileID: Int
    let key: String?
    let expires: String?

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "nxm", let domain = url.host(), !domain.isEmpty else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[0] == "mods", parts[2] == "files", let mod = Int(parts[1]), let file = Int(parts[3]) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        self.domain = domain.lowercased()
        modID = mod
        fileID = file
        key = items.first { $0.name == "key" }?.value
        expires = items.first { $0.name == "expires" }?.value
    }
}

/// nxm:// links handed to MacHub by macOS (the user clicked "Mod Manager Download" on nexusmods.com).
@MainActor @Observable
final class NexusLinkInbox {
    static let shared = NexusLinkInbox()
    var pending: [NexusLink] = []

    func receive(_ urls: [URL]) {
        pending += urls.compactMap(NexusLink.init)
    }
}

/// The user's personal Nexus API key, kept in the Keychain only (never in files or logs).
enum NexusKeyStore {
    private static let service = "app.machub.MacHub.nexus-api"

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(baseQuery as CFDictionary) }

    /// Nexus personal keys are long base64-like strings; reject obvious paste mistakes only.
    static func isPlausible(_ key: String) -> Bool {
        key.count >= 40 && key.allSatisfy { $0.isLetter || $0.isNumber || "+/=-_".contains($0) }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "default"]
    }
}
