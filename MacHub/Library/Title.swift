import Foundation

enum TitleKind: String, CaseIterable, Sendable {
    case game, software
}

enum Compatibility: String, CaseIterable, Sendable {
    case great, playable, issues, unsupported, unknown
}

enum TitleSource: Hashable, Sendable {
    /// Bundled sample content shown while no real library exists. Never launchable.
    case demo
    /// Reported by `WhiskyCmd games` for a registered bottle.
    case whisky(bottle: String, installPath: String)
}

struct Title: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: TitleKind
    let steamAppID: Int?
    var genres: [String] = []
    var developer: String?
    var publisher: String?
    var releaseYear: Int?
    var summary: String?
    var compatibility: Compatibility = .unknown
    let source: TitleSource

    var isDemo: Bool { source == .demo }

    var bottle: String? {
        if case .whisky(let bottle, _) = source { bottle } else { nil }
    }

    var installPath: String? {
        if case .whisky(_, let path) = source { path } else { nil }
    }

    /// Only a real Steam game found in a Whisky bottle can be launched.
    var canLaunch: Bool { !isDemo && steamAppID != nil && kind == .game }

    init(game: SteamGame, bottle: String) {
        id = "whisky:\(bottle):\(game.appId)"
        name = game.name
        kind = .game
        steamAppID = game.appId
        source = .whisky(bottle: bottle, installPath: game.installPath)
    }

    init(
        demo name: String, kind: TitleKind = .game, appID: Int? = nil, genres: [String], developer: String,
        publisher: String? = nil, year: Int, compatibility: Compatibility, summary: String
    ) {
        id = "demo:\(appID.map(String.init) ?? name)"
        self.name = name
        self.kind = kind
        steamAppID = appID
        self.genres = genres
        self.developer = developer
        self.publisher = publisher ?? developer
        releaseYear = year
        self.compatibility = compatibility
        self.summary = summary
        source = .demo
    }
}

/// Steam's public CDN artwork, addressed by App ID.
enum Artwork: String, Sendable {
    case hero = "library_hero.jpg"
    case logo = "logo.png"
    case cover = "library_600x900.jpg"
    case header = "header.jpg"

    func url(appID: Int) -> URL {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/\(rawValue)")!
    }
}
