import Foundation

enum TitleKind: String, CaseIterable, Sendable, Codable {
    case game, software
}

enum Compatibility: String, CaseIterable, Sendable {
    case great, playable, issues, unsupported, unknown
}

/// Where a title stands for this user, from weakest to strongest. Each step is checked, never assumed.
enum Availability: Int, Comparable, Sendable {
    /// Listed on the Steam store only.
    case store
    /// In the signed-in account's Steam library (needs a Web API key and public game details).
    case owned
    /// Found installed inside a Whisky bottle.
    case installed

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct Title: Identifiable, Hashable, Sendable {
    struct Owned: Hashable, Sendable {
        var playtimeMinutes: Int
        var lastPlayed: Date?
    }

    struct Install: Hashable, Sendable {
        let bottle: String
        /// macOS path of the install folder (games) or of the program itself (software).
        let path: String
        /// Windows executables found on disk. Empty means nothing launchable was detected.
        let executables: [String]
    }

    let id: String
    var name: String
    let kind: TitleKind
    let steamAppID: Int?
    var genres: [String] = []
    var developer: String?
    var publisher: String?
    var releaseYear: Int?
    var summary: String?
    /// No compatibility source exists yet: real titles stay `.unknown` ("not verified").
    var compatibility: Compatibility = .unknown
    var isDemo = false
    var owned: Owned?
    var install: Install?
    /// Store-provided capsule, used when Steam's CDN has no library artwork at the classic path
    /// (recent games keep their art under hashed paths that only the store APIs reveal).
    var capsuleURL: URL?
    /// Large store background (from the store page), the hero fallback for those games.
    var backgroundURL: URL?
    /// Steam ships a native macOS build: Whisky isn't needed for it.
    var macAvailable: Bool?
    /// A game that runs natively on the Mac through its own launcher (Minecraft: Java Edition).
    var nativeApp: URL?
    /// Installed through Steam for Mac (native build): path of its install folder there.
    var macInstall: String?
    /// Nintendo Switch game played in Astris: its title ID (16 hex digits).
    var switchTitleID: String?
    /// The Switch game's file that Astris opens; nil when Astris knows the game but the file wasn't found.
    var switchFile: URL?
    /// Epic Games Store app name (Legendary's `app_name`): the game comes from the user's Epic library.
    var epicAppName: String?

    var availability: Availability {
        if install != nil || macInstall != nil || switchFile != nil { .installed } else if owned != nil { .owned } else { .store }
    }

    var bottle: String? { install?.bottle }
    var installPath: String? { install?.path }
    var hasExecutable: Bool { install?.executables.isEmpty == false }

    /// Play is offered only for an identified, launchable install. Never for store or demo titles.
    var canLaunch: Bool {
        guard !isDemo, hasExecutable else { return false }
        return kind == .software || steamAppID != nil || epicAppName != nil
    }

    static func steamID(_ appID: Int) -> String { "steam:\(appID)" }

    init(id: String, name: String, kind: TitleKind, steamAppID: Int?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.steamAppID = steamAppID
    }

    init(game: SteamGame, bottle: String, executables: [String]) {
        self.init(id: Self.steamID(game.appId), name: game.name, kind: .game, steamAppID: game.appId)
        install = Install(bottle: bottle, path: game.installPath, executables: executables)
    }

    init(owned game: SteamWebAPI.OwnedGame) {
        self.init(id: Self.steamID(game.appID), name: game.name, kind: .game, steamAppID: game.appID)
        owned = Owned(playtimeMinutes: game.playtimeMinutes, lastPlayed: game.lastPlayed)
    }

    static func epicID(_ appName: String) -> String { "epic:\(appName)" }

    static func switchID(_ titleID: String) -> String { "switch:\(titleID.uppercased())" }

    /// A Switch game Astris knows or that sits in its game folders, with nlib's details when they're loaded.
    init(switch game: Astris.Game, info: SwitchCatalog.Info?) {
        self.init(id: Self.switchID(game.titleID), name: info?.name ?? game.name, kind: .game, steamAppID: nil)
        switchTitleID = game.titleID
        switchFile = game.file
        owned = Owned(playtimeMinutes: Int(game.playtime / 60), lastPlayed: game.lastPlayed)
        if let info {
            summary = info.summary
            publisher = info.publisher
            developer = info.developer ?? info.publisher
            releaseYear = info.releaseYear
            genres = info.genres
            capsuleURL = info.icon
            backgroundURL = info.banner
        } else {
            capsuleURL = SwitchCatalog.url(game.titleID).appending(path: "icon")
        }
    }

    /// A game from the user's Epic library; installed when Legendary has it on disk.
    init(epic game: Legendary.Game, install: Install?) {
        self.init(id: Self.epicID(game.appName), name: game.title, kind: .game, steamAppID: nil)
        epicAppName = game.appName
        owned = Owned(playtimeMinutes: 0, lastPlayed: nil)
        capsuleURL = game.coverURL
        backgroundURL = game.headerURL
        self.install = install
    }

    init(store item: StoreItem) {
        self.init(id: Self.steamID(item.appID), name: item.name, kind: .game, steamAppID: item.appID)
        capsuleURL = item.capsuleURL
        macAvailable = item.macAvailable
    }

    init(
        demo name: String, kind: TitleKind = .game, appID: Int? = nil, genres: [String], developer: String,
        publisher: String? = nil, year: Int, compatibility: Compatibility, summary: String
    ) {
        self.init(id: "demo:\(appID.map(String.init) ?? name)", name: name, kind: kind, steamAppID: appID)
        self.genres = genres
        self.developer = developer
        self.publisher = publisher ?? developer
        releaseYear = year
        self.compatibility = compatibility
        self.summary = summary
        isDemo = true
    }

    /// Combines what different sources know about the same title (installed + owned + store).
    func merged(with other: Title) -> Title {
        var t = self
        t.install = t.install ?? other.install
        t.owned = t.owned ?? other.owned
        t.capsuleURL = t.capsuleURL ?? other.capsuleURL
        t.backgroundURL = t.backgroundURL ?? other.backgroundURL
        t.macAvailable = t.macAvailable ?? other.macAvailable
        t.macInstall = t.macInstall ?? other.macInstall
        if let mine = t.owned, let theirs = other.owned, (theirs.lastPlayed ?? .distantPast) > (mine.lastPlayed ?? .distantPast) {
            t.owned?.lastPlayed = theirs.lastPlayed
        }
        if t.name.hasPrefix("App "), !other.name.hasPrefix("App ") { t.name = other.name }
        return t
    }

    /// Fills descriptive fields from the store page.
    mutating func apply(_ details: StoreDetails) {
        if name.isEmpty || name.hasPrefix("App ") { name = details.name }
        summary = details.shortDescription.isEmpty ? summary : details.shortDescription
        genres = details.genres.isEmpty ? genres : details.genres
        developer = details.developers.first ?? developer
        publisher = details.publishers.first ?? publisher
        macAvailable = details.mac || macInstall != nil
        capsuleURL = details.headerImage ?? capsuleURL
        backgroundURL = details.background ?? backgroundURL
        if let year = details.releaseDate.flatMap({ $0.firstMatch(of: /\b(19|20)\d{2}\b/) }).map({ Int($0.0)! }) {
            releaseYear = year
        }
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

/// Finds Windows executables in an install folder (root and one level down), skipping installers and helpers.
enum ExecutableScanner {
    static func executables(in folder: URL, fileManager: FileManager = .default) -> [String] {
        let ignored = /(?i)^(unins|uninstall|vc_?redist|vcredist|dxsetup|dotnet|crashreport|crashhandler|ue4prereq|directx|setup|installer)/
        var found: [String] = []
        let top = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        for url in top {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                let inner = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                found += inner.filter { $0.pathExtension.lowercased() == "exe" }.map { "\(url.lastPathComponent)/\($0.lastPathComponent)" }
            } else if url.pathExtension.lowercased() == "exe" {
                found.append(url.lastPathComponent)
            }
        }
        return found.filter { ($0.split(separator: "/").last.map(String.init) ?? $0).firstMatch(of: ignored) == nil }.sorted()
    }
}
