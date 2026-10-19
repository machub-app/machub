import Foundation

/// A mod as a source describes it. Every field comes from the source; missing ones stay nil.
struct ModProject: Identifiable, Hashable, Sendable {
    let id: String
    let slug: String
    let title: String
    let summary: String
    let author: String?
    let iconURL: URL?
    let categories: [String]
    /// Counts published by the source itself (Modrinth), shown as such.
    let downloads: Int?
    let updated: Date?
    var body: String?
    var gallery: [URL] = []
    var license: String?
    var pageURL: URL?
}

struct ModFile: Hashable, Sendable, Codable {
    let url: URL
    let filename: String
    let size: Int64
    let sha512: String
    let primary: Bool
}

struct ModVersion: Identifiable, Hashable, Sendable {
    struct Dependency: Hashable, Sendable {
        enum Kind: String, Sendable { case required, optional, incompatible, embedded }
        let projectID: String?
        let versionID: String?
        let kind: Kind
    }

    let id: String
    let projectID: String
    let name: String
    let versionNumber: String
    let published: Date?
    let gameVersions: [String]
    let loaders: [String]
    /// release, beta or alpha.
    let channel: String
    let files: [ModFile]
    let dependencies: [Dependency]

    var primaryFile: ModFile? { files.first(where: \.primary) ?? files.first }
}

/// Modrinth's public API v2 (docs.modrinth.com). No key needed for reading; a User-Agent naming the app is required.
/// Downloads come from cdn.modrinth.com with SHA-512 hashes published by the API.
enum Modrinth {
    static let base = URL(string: "https://api.modrinth.com/v2/")!
    static let http = SteamHTTP(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "app.machub.MacHub/modrinth"),
        minimumInterval: .milliseconds(220),
        userAgent: "MacHub/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (app.machub.MacHub)"
    )

    enum Sort: String, CaseIterable, Sendable { case relevance, downloads, updated, newest }

    /// The mod categories Modrinth defines (GET /v2/tag/category, project_type "mod"), kept short for the filter.
    static let categories = ["optimization", "utility", "decoration", "adventure", "technology", "magic",
                             "storage", "worldgen", "mobs", "food", "equipment", "transportation", "game-mechanics", "library"]

    struct SearchPage: Sendable {
        let hits: [ModProject]
        let total: Int
    }

    static func search(query: String, category: String?, gameVersion: String?, loader: String?, sort: Sort, offset: Int) async throws -> SearchPage {
        var facets = [["project_type:mod"]]
        if let loader { facets.append(["categories:\(loader)"]) }
        if let gameVersion { facets.append(["versions:\(gameVersion)"]) }
        if let category { facets.append(["categories:\(category)"]) }
        let facetJSON = String(decoding: try JSONSerialization.data(withJSONObject: facets), as: UTF8.self)
        var components = URLComponents(url: base.appending(path: "search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "query", value: query), .init(name: "facets", value: facetJSON),
            .init(name: "index", value: sort.rawValue), .init(name: "offset", value: String(offset)), .init(name: "limit", value: "30"),
        ]
        return try parseSearch(try await http.get(components.url!, ttl: 600).data)
    }

    static func project(_ id: String) async throws -> ModProject {
        try parseProject(try await http.get(base.appending(path: "project/\(id)"), ttl: 3600).data)
    }

    static func versions(projectID: String, gameVersion: String?, loader: String?) async throws -> [ModVersion] {
        var components = URLComponents(url: base.appending(path: "project/\(projectID)/version"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let loader { items.append(.init(name: "loaders", value: "[\"\(loader)\"]")) }
        if let gameVersion { items.append(.init(name: "game_versions", value: "[\"\(gameVersion)\"]")) }
        components.queryItems = items.isEmpty ? nil : items
        return try parseVersions(try await http.get(components.url!, ttl: 600).data)
    }

    // MARK: Parsing (pure, tested against captured API responses)

    static func parseSearch(_ data: Data) throws -> SearchPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let hits = root["hits"] as? [[String: Any]] else {
            throw SteamHTTP.Failure.http(0)
        }
        let projects = hits.compactMap { hit -> ModProject? in
            guard let id = hit["project_id"] as? String, let title = hit["title"] as? String else { return nil }
            return ModProject(
                id: id, slug: hit["slug"] as? String ?? id, title: title, summary: hit["description"] as? String ?? "",
                author: hit["author"] as? String, iconURL: (hit["icon_url"] as? String).flatMap(URL.init(string:)),
                categories: hit["display_categories"] as? [String] ?? hit["categories"] as? [String] ?? [],
                downloads: hit["downloads"] as? Int, updated: date(hit["date_modified"]),
                gallery: ((hit["gallery"] as? [String]) ?? []).compactMap(URL.init(string:)),
                pageURL: URL(string: "https://modrinth.com/mod/\(hit["slug"] as? String ?? id)")
            )
        }
        return SearchPage(hits: projects, total: root["total_hits"] as? Int ?? projects.count)
    }

    static func parseProject(_ data: Data) throws -> ModProject {
        guard let p = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = p["id"] as? String,
              let title = p["title"] as? String else { throw SteamHTTP.Failure.http(0) }
        let gallery = ((p["gallery"] as? [[String: Any]]) ?? [])
            .sorted { ($0["ordering"] as? Int ?? 0) < ($1["ordering"] as? Int ?? 0) }
            .compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
        let slug = p["slug"] as? String ?? id
        return ModProject(
            id: id, slug: slug, title: title, summary: p["description"] as? String ?? "", author: nil,
            iconURL: (p["icon_url"] as? String).flatMap(URL.init(string:)), categories: p["categories"] as? [String] ?? [],
            downloads: p["downloads"] as? Int, updated: date(p["updated"]), body: p["body"] as? String, gallery: gallery,
            license: (p["license"] as? [String: Any])?["id"] as? String, pageURL: URL(string: "https://modrinth.com/mod/\(slug)")
        )
    }

    static func parseVersions(_ data: Data) throws -> [ModVersion] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw SteamHTTP.Failure.http(0) }
        return list.compactMap { v in
            guard let id = v["id"] as? String, let project = v["project_id"] as? String else { return nil }
            let files = ((v["files"] as? [[String: Any]]) ?? []).compactMap { f -> ModFile? in
                guard let url = (f["url"] as? String).flatMap(URL.init(string:)), let name = f["filename"] as? String,
                      let sha512 = (f["hashes"] as? [String: Any])?["sha512"] as? String else { return nil }
                return ModFile(url: url, filename: name, size: (f["size"] as? NSNumber)?.int64Value ?? 0, sha512: sha512, primary: f["primary"] as? Bool ?? false)
            }
            let dependencies = ((v["dependencies"] as? [[String: Any]]) ?? []).compactMap { d -> ModVersion.Dependency? in
                guard let kind = (d["dependency_type"] as? String).flatMap(ModVersion.Dependency.Kind.init(rawValue:)) else { return nil }
                return .init(projectID: d["project_id"] as? String, versionID: d["version_id"] as? String, kind: kind)
            }
            return ModVersion(
                id: id, projectID: project, name: v["name"] as? String ?? id, versionNumber: v["version_number"] as? String ?? "",
                published: date(v["date_published"]), gameVersions: v["game_versions"] as? [String] ?? [],
                loaders: v["loaders"] as? [String] ?? [], channel: v["version_type"] as? String ?? "release",
                files: files, dependencies: dependencies
            )
        }
    }

    private static func date(_ value: Any?) -> Date? {
        // Modrinth sends microseconds ("…28.513893Z"); seconds are precise enough for "updated on".
        guard let text = (value as? String)?.replacing(/\.\d+/, with: "") else { return nil }
        return try? Date(text, strategy: .iso8601)
    }

    /// The newest release (then beta) matching the instance; Modrinth returns versions newest first.
    static func bestVersion(_ versions: [ModVersion], gameVersion: String, loader: String) -> ModVersion? {
        let compatible = versions.filter { $0.gameVersions.contains(gameVersion) && $0.loaders.contains(loader) && $0.primaryFile != nil }
        return compatible.first { $0.channel == "release" } ?? compatible.first
    }
}
