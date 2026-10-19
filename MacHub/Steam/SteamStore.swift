import Foundation

/// A store listing: what Steam sells, not what the user owns.
struct StoreItem: Identifiable, Hashable, Sendable {
    let appID: Int
    let name: String
    var capsuleURL: URL?
    var macAvailable: Bool?
    var finalPrice: Int?
    var currency: String?
    var discountPercent: Int?
    var id: Int { appID }
}

struct StoreDetails: Equatable, Sendable {
    var name: String
    var type: String
    var shortDescription: String
    var developers: [String]
    var publishers: [String]
    var genres: [String]
    var releaseDate: String?
    var comingSoon: Bool
    var isFree: Bool
    var windows: Bool
    var mac: Bool
    var headerImage: URL?
    var background: URL?
    var screenshots: [URL]
    var metacritic: Int?
    var price: String?
    /// DirectX version named in the minimum (else recommended) PC requirements.
    var directX: Int?
    /// Steam genre IDs (language-independent), e.g. "57" Utilities.
    var genreIDs: [String] = []
    /// Store trailers, the highlighted ones first.
    var trailers: [Trailer] = []

    struct Trailer: Equatable, Hashable, Sendable, Identifiable {
        let id: Int
        let name: String
        let thumbnail: URL?
        /// HLS (H.264) stream, which AVPlayer plays natively; older pages only have an MP4.
        let stream: URL
    }

    /// Steam's software genres (Animation & Modeling … Game Development): apps the store files as "game" but that
    /// are tools, players or editors.
    static let softwareGenres: Set<String> = ["51", "52", "53", "54", "55", "56", "57", "58", "59", "60"]

    /// A real game: typed "game", with at least one genre that isn't a software genre, and not a benchmark, server,
    /// SDK or player by name.
    var isPlayableGame: Bool {
        guard type == "game", !genreIDs.isEmpty, !Set(genreIDs).isSubset(of: Self.softwareGenres) else { return false }
        let lowered = name.lowercased()
        return !["benchmark", "dedicated server", " sdk", "video player", "soundtrack"].contains { lowered.contains($0) }
    }
}

/// Steam store data. These endpoints are the ones the Steam store itself uses; Valve publishes no
/// open, exhaustive catalogue API (ISteamApps/GetAppList is gone, IStoreService/GetAppList needs a key),
/// so MacHub searches on demand, 50 results per page, and caches.
enum SteamStore {
    enum Sort: String, CaseIterable, Sendable {
        case relevance = ""
        case released = "Released_DESC"
        case reviews = "Reviews_DESC"
        case name = "Name_ASC"
        case price = "Price_ASC"
    }

    /// Steam store tag IDs for the genre filter.
    enum Genre: Int, CaseIterable, Sendable {
        case action = 19, adventure = 21, rpg = 122, strategy = 9, simulation = 599, racing = 699, sports = 701, indie = 492, casual = 597
    }

    static let pageSize = 50

    struct Featured: Sendable {
        var topSellers: [StoreItem] = []
        var newReleases: [StoreItem] = []
        var specials: [StoreItem] = []
        var comingSoon: [StoreItem] = []
        var isStale = false
    }

    static func featured(http: SteamHTTP = .shared, locale: StoreLocale = .current) async throws -> Featured {
        let url = URL(string: "https://store.steampowered.com/api/featuredcategories/?l=\(locale.language)&cc=\(locale.country)")!
        let response = try await http.get(url, ttl: 3600)
        var featured = try parseFeatured(response.data)
        featured.isStale = response.isStale
        return featured
    }

    static func parseFeatured(_ data: Data) throws -> Featured {
        struct Section: Decodable { let items: [Item]? }
        struct Item: Decodable {
            let id: Int
            let type: Int?
            let name: String
            let large_capsule_image: String?
            let header_image: String?
            let mac_available: Bool?
            let final_price: Int?
            let currency: String?
            let discount_percent: Int?
        }
        struct Root: Decodable { let specials, coming_soon, top_sellers, new_releases: Section? }
        let root = try JSONDecoder().decode(Root.self, from: data)
        func items(_ section: Section?) -> [StoreItem] {
            var seen = Set<Int>()
            return (section?.items ?? []).filter { ($0.type ?? 0) == 0 && seen.insert($0.id).inserted }.map {
                StoreItem(appID: $0.id, name: $0.name,
                          capsuleURL: ($0.header_image ?? $0.large_capsule_image).flatMap(URL.init(string:)),
                          macAvailable: $0.mac_available, finalPrice: $0.final_price, currency: $0.currency,
                          discountPercent: $0.discount_percent)
            }
        }
        return Featured(topSellers: items(root.top_sellers), newReleases: items(root.new_releases),
                        specials: items(root.specials), comingSoon: items(root.coming_soon))
    }

    /// One page of the store's game search (empty term browses the whole catalogue).
    static func search(term: String, page: Int, sort: Sort = .relevance, genre: Genre? = nil,
                       http: SteamHTTP = .shared, locale: StoreLocale = .current) async throws -> [StoreItem] {
        var components = URLComponents(string: "https://store.steampowered.com/search/results/")!
        var query: [URLQueryItem] = [
            .init(name: "term", value: term), .init(name: "json", value: "1"),
            .init(name: "start", value: String(page * pageSize)), .init(name: "count", value: String(pageSize)),
            .init(name: "category1", value: "998"),  // games only
            .init(name: "l", value: locale.language), .init(name: "cc", value: locale.country),
        ]
        if !sort.rawValue.isEmpty { query.append(.init(name: "sort_by", value: sort.rawValue)) }
        if let genre { query.append(.init(name: "tags", value: String(genre.rawValue))) }
        components.queryItems = query
        let response = try await http.get(components.url!, ttl: 15 * 60)
        return try parseSearch(response.data)
    }

    static func parseSearch(_ data: Data) throws -> [StoreItem] {
        struct Root: Decodable { struct Item: Decodable { let name: String; let logo: String }; let items: [Item] }
        return try JSONDecoder().decode(Root.self, from: data).items.compactMap { item in
            // The JSON flavour has no ID field; the capsule path carries it: .../steam/apps/<id>/...
            guard let match = item.logo.firstMatch(of: /\/steam\/apps\/(\d+)\//), let id = Int(match.1) else { return nil }
            // The feed links the 120 px capsule; the 231×87 one sits next to it and is the sharpest it exposes.
            return StoreItem(appID: id, name: item.name, capsuleURL: URL(string: item.logo.replacingOccurrences(of: "capsule_sm_120", with: "capsule_231x87")))
        }
    }

    static func details(appID: Int, http: SteamHTTP = .shared, locale: StoreLocale = .current) async throws -> StoreDetails? {
        let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=\(locale.language)&cc=\(locale.country)")!
        let response = try await http.get(url, ttl: 24 * 3600)
        return try parseDetails(response.data, appID: appID)
    }

    static func parseDetails(_ data: Data, appID: Int) throws -> StoreDetails? {
        struct Entry: Decodable { let success: Bool; let data: Payload? }
        struct Payload: Decodable {
            struct Named: Decodable { let description: String; let id: LooseID? }
            /// Genre IDs come as strings, categories as numbers: accept both.
            struct LooseID: Decodable {
                let value: String
                init(from decoder: Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    value = (try? c.decode(String.self)) ?? String((try? c.decode(Int.self)) ?? 0)
                }
            }
            struct Release: Decodable { let date: String?; let coming_soon: Bool? }
            struct Platforms: Decodable { let windows, mac: Bool? }
            struct Shot: Decodable { let path_thumbnail: String? }
            struct Movie: Decodable {
                let id: Int?
                let name: String?
                let thumbnail: String?
                let hls_h264: String?
                let mp4: [String: String]?
                let highlight: Bool?
            }
            struct Meta: Decodable { let score: Int? }
            struct Price: Decodable { let final_formatted: String? }
            let name: String
            let type: String?
            let short_description: String?
            let developers, publishers: [String]?
            let genres: [Named]?
            let release_date: Release?
            let is_free: Bool?
            let platforms: Platforms?
            let header_image, background_raw: String?
            let screenshots: [Shot]?
            let movies: [Movie]?
            let metacritic: Meta?
            let price_overview: Price?
        }
        guard let entry = try JSONDecoder().decode([String: Entry].self, from: data)[String(appID)],
              entry.success, let d = entry.data
        else { return nil }
        return StoreDetails(
            name: d.name, type: d.type ?? "game", shortDescription: decodeEntities(d.short_description ?? ""),
            developers: d.developers ?? [], publishers: d.publishers ?? [], genres: d.genres?.map(\.description) ?? [],
            releaseDate: d.release_date?.date, comingSoon: d.release_date?.coming_soon ?? false, isFree: d.is_free ?? false,
            windows: d.platforms?.windows ?? false, mac: d.platforms?.mac ?? false,
            headerImage: d.header_image.flatMap(URL.init(string:)), background: d.background_raw.flatMap(URL.init(string:)),
            screenshots: (d.screenshots ?? []).compactMap { $0.path_thumbnail.flatMap(URL.init(string:)) },
            metacritic: d.metacritic?.score, price: d.price_overview?.final_formatted,
            directX: directXVersion(in: data, appID: appID),
            genreIDs: d.genres?.compactMap { $0.id?.value } ?? [],
            trailers: (d.movies ?? []).sorted { ($0.highlight ?? false) && !($1.highlight ?? false) }.compactMap { movie in
                guard let stream = (movie.hls_h264 ?? movie.mp4?["max"] ?? movie.mp4?["480"]).flatMap(URL.init(string:)) else { return nil }
                return StoreDetails.Trailer(id: movie.id ?? stream.hashValue, name: decodeEntities(movie.name ?? ""),
                                            thumbnail: movie.thumbnail.flatMap(URL.init(string:)), stream: stream)
            }
        )
    }

    /// `pc_requirements` is an object, or an empty array when the page has none: read it loosely.
    static func directXVersion(in data: Data, appID: Int) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = (root[String(appID)] as? [String: Any])?["data"] as? [String: Any],
              let requirements = payload["pc_requirements"] as? [String: Any] else { return nil }
        for key in ["minimum", "recommended"] {
            if let html = requirements[key] as? String, let version = CompatibilitySources.directXVersion(inRequirements: html) {
                return version
            }
        }
        return nil
    }

    static func decodeEntities(_ text: String) -> String {
        var out = text.replacing(/<[^>]+>/, with: "")
        for (entity, char) in ["&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&amp;": "&"] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Official Steam Web API calls that need the user's key (owned and played games).
enum SteamWebAPI {
    struct OwnedGame: Equatable, Sendable {
        let appID: Int
        let name: String
        let playtimeMinutes: Int
        let lastPlayed: Date?
    }

    enum Library: Equatable, Sendable {
        case games([OwnedGame])
        /// Steam answered with no game list: the profile's "Game details" are not public.
        case privateOrEmpty
    }

    static func ownedGames(steamID: String, key: String, http: SteamHTTP = .shared) async throws -> Library {
        var components = URLComponents(string: "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/")!
        components.queryItems = [
            .init(name: "key", value: key), .init(name: "steamid", value: steamID), .init(name: "include_appinfo", value: "1"),
            .init(name: "include_played_free_games", value: "1"), .init(name: "format", value: "json"),
        ]
        // The cache key deliberately omits the API key.
        let response = try await http.get(components.url!, ttl: 10 * 60, cacheKey: "owned:\(steamID)")
        return try parseOwned(response.data)
    }

    static func parseOwned(_ data: Data) throws -> Library {
        struct Root: Decodable {
            struct Response: Decodable {
                struct Game: Decodable { let appid: Int; let name: String?; let playtime_forever: Int?; let rtime_last_played: Int? }
                let game_count: Int?
                let games: [Game]?
            }
            let response: Response
        }
        let response = try JSONDecoder().decode(Root.self, from: data).response
        guard response.game_count != nil, let games = response.games else { return .privateOrEmpty }
        return .games(games.map {
            OwnedGame(appID: $0.appid, name: $0.name ?? "App \($0.appid)", playtimeMinutes: $0.playtime_forever ?? 0,
                      lastPlayed: ($0.rtime_last_played ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval($0.rtime_last_played!)) : nil)
        })
    }
}
