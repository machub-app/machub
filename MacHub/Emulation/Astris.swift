import AppKit

/// Nintendo Switch games through Astris, a Switch emulator for macOS (Ryujinx-based, installed separately by the
/// user). MacHub only reads what Astris already knows (its per-game folders and library folders) plus the user's own
/// game files, and opens a game's file with Astris to play it. MacHub never downloads, ships or decrypts games or keys.
enum Astris {
    static let bundleID = "V380-Ori.Astris"

    static var app: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/astris")
    }

    /// File types Astris opens (base games); updates and DLC sit next to them with other title IDs.
    static let gameExtensions: Set<String> = ["nsp", "xci"]

    struct Game: Equatable, Sendable, Identifiable {
        var id: String { titleID }
        /// 16 hex digits, uppercase (e.g. 0100F2C0115B6000).
        let titleID: String
        let name: String
        /// The base game's file in a library folder; nil when Astris knows the game but its file wasn't found.
        let file: URL?
        let playtime: TimeInterval
        let lastPlayed: Date?
    }

    /// What Astris remembers about a game it has run: `games/<titleid>/gui/metadata.json`.
    struct Metadata: Equatable, Sendable {
        let titleID: String
        let name: String
        let playtime: TimeInterval
        let lastPlayed: Date?
    }

    static func metadata(dataDirectory: URL = dataDirectory, fileManager: FileManager = .default) -> [Metadata] {
        let games = dataDirectory.appending(path: "games")
        let ids = (try? fileManager.contentsOfDirectory(atPath: games.path)) ?? []
        return ids.sorted().compactMap { id -> Metadata? in
            guard isTitleID(id),
                  let data = try? Data(contentsOf: games.appending(path: "\(id)/gui/metadata.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["title"] as? String, !name.isEmpty
            else { return nil }
            return Metadata(titleID: id.uppercased(), name: name,
                            playtime: (json["timespan_played"] as? String).flatMap(timespan) ?? 0,
                            lastPlayed: (json["last_played_utc"] as? String).flatMap(date))
        }
    }

    /// The game folders the user added in Astris (`LibraryBookmarks` keys are their file URLs), else ~/Game.
    static func libraryFolders(defaults: UserDefaults? = UserDefaults(suiteName: bundleID), fileManager: FileManager = .default) -> [URL] {
        let saved = (defaults?.dictionary(forKey: "LibraryBookmarks")?.keys).map(Array.init) ?? []
        let folders = saved.sorted().compactMap(URL.init(string:)).filter(\.isFileURL)
        let candidates = folders.isEmpty ? [fileManager.homeDirectoryForCurrentUser.appending(path: "Game")] : folders
        return candidates.filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Game files in the library folders (top level and one folder down).
    static func gameFiles(in folders: [URL], fileManager: FileManager = .default) -> [URL] {
        folders.flatMap { folder -> [URL] in
            let top = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
            return top.flatMap { url -> [URL] in
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    return (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                }
                return [url]
            }
        }
        .filter { gameExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.path < $1.path }
    }

    /// Astris' games matched with their files, plus files named with a base-game title ID that Astris hasn't run yet.
    static func games(metadata: [Metadata], files: [URL]) -> [Game] {
        var remaining = files
        var games = metadata.map { meta -> Game in
            let index = remaining.firstIndex { titleID(inFileName: $0.lastPathComponent) == meta.titleID }
                ?? remaining.firstIndex { titleID(inFileName: $0.lastPathComponent) == nil && sameName(meta.name, $0.lastPathComponent) }
            let file = index.map { remaining.remove(at: $0) }
            return Game(titleID: meta.titleID, name: meta.name, file: file, playtime: meta.playtime, lastPlayed: meta.lastPlayed)
        }
        for file in remaining {
            guard let id = titleID(inFileName: file.lastPathComponent), isBaseGame(id), !games.contains(where: { $0.titleID == id }) else { continue }
            games.append(Game(titleID: id, name: displayName(fileName: file.lastPathComponent), file: file, playtime: 0, lastPlayed: nil))
        }
        return games
    }

    static func games() -> [Game] {
        guard app != nil else { return [] }
        return games(metadata: metadata(), files: gameFiles(in: libraryFolders()))
    }

    /// Opens the game's file with Astris, which starts it.
    @MainActor
    static func play(_ file: URL) async -> Bool {
        guard let app else { return false }
        return (try? await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: .init())) != nil
    }

    // MARK: Names and IDs

    static func isTitleID(_ text: String) -> Bool { text.wholeMatch(of: /[0-9A-Fa-f]{16}/) != nil }

    /// Base games end in 000; updates (…800) and DLC (…1xxx and up) don't.
    static func isBaseGame(_ titleID: String) -> Bool { titleID.hasSuffix("000") && !titleID.hasSuffix("800") }

    /// `[0100DCA0064A6000]` in a file name (the usual dump naming), uppercased.
    static func titleID(inFileName name: String) -> String? {
        name.firstMatch(of: /\[(01[0-9A-Fa-f]{14})\]/).map { String($0.1).uppercased() }
    }

    /// The name before any [tags] or (tags), without the extension.
    static func displayName(fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let cut = base.firstIndex { $0 == "[" || $0 == "(" } ?? base.endIndex
        return base[..<cut].trimmingCharacters(in: .whitespaces)
    }

    /// Letters and digits only, lowercased: "The Legend of Zelda: Tears of the Kingdom" matches its file name.
    static func normalized(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func sameName(_ title: String, _ fileName: String) -> Bool {
        let a = normalized(title), b = normalized(displayName(fileName: fileName))
        return !a.isEmpty && a == b
    }

    /// "05:48:03", "1.02:03:04" or "05:48:03.1234567" (.NET TimeSpan: [days.]hours:minutes:seconds[.fraction]).
    static func timespan(_ text: String) -> TimeInterval? {
        guard let match = text.wholeMatch(of: /(?:(\d+)\.)?(\d+):(\d+):(\d+)(\.\d+)?/) else { return nil }
        let days = match.1.flatMap { Double($0) } ?? 0
        return days * 86400 + Double(match.2)! * 3600 + Double(match.3)! * 60 + Double(match.4)!
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // .NET writes 7 fractional digits; ISO8601DateFormatter reads at most 3.
        let trimmed = text.replacing(/(\.\d{3})\d+/) { $0.1 }
        return formatter.date(from: trimmed) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Public metadata and artwork for Switch titles from nlib (api.nlib.cc), cached like Steam's store answers.
enum SwitchCatalog {
    struct Info: Equatable, Sendable {
        let name: String
        let summary: String?
        let publisher: String?
        let developer: String?
        let releaseYear: Int?
        let genres: [String]
        let icon: URL
        let banner: URL
    }

    static func url(_ titleID: String) -> URL { URL(string: "https://api.nlib.cc/nx/\(titleID.uppercased())")! }

    static func info(titleID: String, http: SteamHTTP = .shared) async -> Info? {
        guard let data = try? await http.get(url(titleID), ttl: 30 * 24 * 3600).data else { return nil }
        return parse(data, titleID: titleID)
    }

    static func parse(_ data: Data, titleID: String) -> Info? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = json["name"] as? String
        else { return nil }
        let base = url(titleID)
        return Info(
            name: name.replacingOccurrences(of: "™", with: "").replacingOccurrences(of: "®", with: ""),
            summary: json["description"] as? String,
            publisher: json["publisher"] as? String,
            developer: json["developer"] as? String,
            releaseYear: (json["releaseDate"] as? String).flatMap { Int($0.prefix(4)) },
            genres: json["category"] as? [String] ?? [],
            // nlib lists http:// links; the same paths answer over HTTPS.
            icon: base.appending(path: "icon"),
            banner: base.appending(path: "banner"))
    }
}
