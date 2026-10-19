import Foundation

/// Valve's text KeyValues format (`libraryfolders.vdf`, `appmanifest_*.acf`). Keys are matched case-insensitively,
/// because Steam itself writes `AppState`/`appid`/`StateFlags` with varying case.
struct VDF: Equatable, Sendable {
    var values: [String: String] = [:]
    var children: [String: VDF] = [:]
    /// Child keys in file order (library folders are "0", "1", …).
    var order: [String] = []

    subscript(key: String) -> String? { values[key.lowercased()] }
    func child(_ key: String) -> VDF? { children[key.lowercased()] }

    struct ParseError: Error, Equatable {}

    static func parse(_ text: String) throws(ParseError) -> VDF {
        var tokens = Tokens(text: Array(text.unicodeScalars))
        let root = try parseObject(&tokens, nested: false)
        return root
    }

    private static func parseObject(_ tokens: inout Tokens, nested: Bool) throws(ParseError) -> VDF {
        var object = VDF()
        while let token = tokens.next() {
            switch token {
            case .close:
                guard nested else { throw ParseError() }
                return object
            case .open:
                throw ParseError()
            case .string(let key):
                switch tokens.next() {
                case .string(let value)?:
                    object.values[key.lowercased()] = value
                case .open?:
                    let child = try parseObject(&tokens, nested: true)
                    if object.children[key.lowercased()] == nil { object.order.append(key.lowercased()) }
                    object.children[key.lowercased()] = child
                default:
                    throw ParseError()
                }
            }
        }
        guard !nested else { throw ParseError() }
        return object
    }

    private enum Token { case string(String), open, close }

    private struct Tokens {
        let text: [Unicode.Scalar]
        var index = 0

        mutating func next() -> Token? {
            while index < text.count {
                let c = text[index]
                if c == "/" && index + 1 < text.count && text[index + 1] == "/" {
                    while index < text.count && text[index] != "\n" { index += 1 }
                } else if c.properties.isWhitespace {
                    index += 1
                } else if c == "{" {
                    index += 1
                    return .open
                } else if c == "}" {
                    index += 1
                    return .close
                } else if c == "\"" {
                    index += 1
                    var value = String.UnicodeScalarView()
                    while index < text.count && text[index] != "\"" {
                        if text[index] == "\\" && index + 1 < text.count {
                            index += 1
                            switch text[index] {
                            case "n": value.append("\n")
                            case "t": value.append("\t")
                            default: value.append(text[index])
                            }
                        } else {
                            value.append(text[index])
                        }
                        index += 1
                    }
                    index += 1
                    return .string(String(value))
                } else {
                    // Unquoted token (rare in Steam files): read to the next whitespace or brace.
                    var value = String.UnicodeScalarView()
                    while index < text.count, !text[index].properties.isWhitespace, text[index] != "{", text[index] != "}" {
                        value.append(text[index])
                        index += 1
                    }
                    return .string(String(value))
                }
            }
            return nil
        }
    }
}

/// One game as Steam for Windows records it in a prefix: read straight from `appmanifest_<id>.acf`.
struct SteamApp: Equatable, Sendable {
    let appID: Int
    let name: String
    /// macOS path of `steamapps/common/<installdir>`.
    let installPath: String
    let stateFlags: Int
    let bytesToDownload: Int64
    let bytesDownloaded: Int64
    /// macOS path of `steamapps/downloading/<id>` (where Steam writes while downloading).
    let downloadingPath: String

    /// StateFlags bit 4 = fully installed. Steam keeps it while a later update is pending.
    var isInstalled: Bool { stateFlags & 4 != 0 }

    // Steam's EAppState bits (StateFlags in the manifest).
    /// A newer build exists and Steam hasn't finished applying it.
    var needsUpdate: Bool { stateFlags & 2 != 0 }
    /// Steam is working on the files right now: update running/started, preallocating, downloading, staging, committing.
    var isUpdating: Bool { stateFlags & (256 | 1024 | 524_288 | 1_048_576 | 2_097_152 | 4_194_304) != 0 }
    /// "Verify integrity of game files" is running.
    var isValidating: Bool { stateFlags & 131_072 != 0 }
    var isUninstalling: Bool { stateFlags & 2048 != 0 }

    var game: SteamGame { SteamGame(appId: appID, name: name, installPath: installPath) }
}

/// Reads the games of a Steam for Windows install inside a Wine prefix, without asking Steam or Whisky.
enum SteamLibrary {
    /// Steamworks Common Redistributables: installed by Steam itself, never a game.
    static let ignoredAppIDs: Set<Int> = [228980]

    static func steamRoot(inPrefix prefix: URL, fileManager: FileManager = .default) -> URL? {
        ["drive_c/Program Files (x86)/Steam", "drive_c/Program Files/Steam"]
            .map { prefix.appending(path: $0) }
            .first { fileManager.fileExists(atPath: $0.appending(path: "steam.exe").path) }
    }

    /// App IDs the signed-in Steam client keeps library artwork for (`appcache/librarycache/<id>`): every app its
    /// library shows, games shared through Steam Families included, mixed with DLC, demos and tools.
    static func libraryCacheAppIDs(steamRoot: URL, fileManager: FileManager = .default) -> [Int] {
        let cache = steamRoot.appending(path: "appcache/librarycache")
        return ((try? fileManager.contentsOfDirectory(atPath: cache.path)) ?? []).compactMap(Int.init).sorted()
    }

    /// Every library folder Steam knows (its own folder first), as macOS URLs inside the prefix.
    static func libraryFolders(steamRoot: URL, prefix: URL) -> [URL] {
        var folders = [steamRoot]
        if let text = try? String(contentsOf: steamRoot.appending(path: "steamapps/libraryfolders.vdf"), encoding: .utf8),
           let vdf = try? VDF.parse(text), let list = vdf.child("libraryfolders") {
            for key in list.order {
                guard let path = list.child(key)?["path"], let url = macURL(forWindowsPath: path, prefix: prefix) else { continue }
                if !folders.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) { folders.append(url) }
            }
        }
        return folders
    }

    /// `C:\Program Files (x86)\Steam` → `<prefix>/drive_c/Program Files (x86)/Steam`; other drives go through
    /// Wine's `dosdevices/<letter>:` links.
    static func macURL(forWindowsPath path: String, prefix: URL) -> URL? {
        guard let match = path.firstMatch(of: /^([A-Za-z]):[\\\/]*(.*)$/) else { return nil }
        let letter = match.1.lowercased()
        let rest = match.2.split(whereSeparator: { $0 == "\\" || $0 == "/" }).joined(separator: "/")
        let base = letter == "c" ? prefix.appending(path: "drive_c") : prefix.appending(path: "dosdevices/\(letter):").resolvingSymlinksInPath()
        return rest.isEmpty ? base : base.appending(path: rest)
    }

    static func apps(steamRoot: URL, prefix: URL, fileManager: FileManager = .default) -> [SteamApp] {
        var seen = Set<Int>()
        return libraryFolders(steamRoot: steamRoot, prefix: prefix).flatMap { library -> [SteamApp] in
            let steamapps = library.appending(path: "steamapps")
            let files = (try? fileManager.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil)) ?? []
            return files
                .filter { $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { app(manifest: $0, steamapps: steamapps) }
        }
        .filter { !ignoredAppIDs.contains($0.appID) && seen.insert($0.appID).inserted }
    }

    static func app(manifest: URL, steamapps: URL) -> SteamApp? {
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }
        return app(acf: text, steamapps: steamapps)
    }

    static func app(acf text: String, steamapps: URL) -> SteamApp? {
        guard let state = (try? VDF.parse(text))?.child("AppState"),
              let id = state["appid"].flatMap(Int.init), let dir = state["installdir"], !dir.isEmpty
        else { return nil }
        return SteamApp(
            appID: id,
            name: state["name"] ?? "App \(id)",
            installPath: steamapps.appending(path: "common/\(dir)").path,
            stateFlags: state["StateFlags"].flatMap(Int.init) ?? 0,
            bytesToDownload: state["BytesToDownload"].flatMap(Int64.init) ?? 0,
            bytesDownloaded: state["BytesDownloaded"].flatMap(Int64.init) ?? 0,
            downloadingPath: steamapps.appending(path: "downloading/\(id)").path
        )
    }

    /// Fraction downloaded, or nil when Steam hasn't said how much there is. Steam keeps `BytesDownloaded` current in
    /// the manifest while it downloads (checked 2026-10-18 with BeamNG.drive). The size of `downloading/<id>` is no
    /// measure: Steam preallocates the files there (2.9 GB on disk for 0.13 GB received).
    static func progress(of app: SteamApp) -> Double? {
        guard !app.isInstalled || app.isUpdating, app.bytesToDownload > 0 else { return nil }
        return min(1, Double(app.bytesDownloaded) / Double(app.bytesToDownload))
    }

    static func folderSize(_ url: URL, fileManager: FileManager = .default) -> Int64 {
        guard let walker = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
