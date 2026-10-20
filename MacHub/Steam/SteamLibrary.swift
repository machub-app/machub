import Foundation

/// Valve's text KeyValues format (`libraryfolders.vdf`, `appmanifest_*.acf`). Keys are matched case-insensitively,
/// because Steam itself writes `AppState`/`appid`/`StateFlags` with varying case.
struct VDF: Equatable, Sendable {
    var values: [String: String] = [:]
    var children: [String: VDF] = [:]
    /// Child keys in file order (library folders are "0", "1", …).
    var order: [String] = []
    /// Value keys in file order, so a file written back keeps Steam's layout.
    var valueOrder: [String] = []
    /// Each key as the file spelled it (`StateFlags`), by its lowercased form.
    var spelling: [String: String] = [:]

    subscript(key: String) -> String? {
        get { values[key.lowercased()] }
        set {
            let lower = key.lowercased()
            if values[lower] == nil, newValue != nil { valueOrder.append(lower) }
            if newValue == nil { valueOrder.removeAll { $0 == lower } }
            if spelling[lower] == nil { spelling[lower] = key }
            values[lower] = newValue
        }
    }

    func child(_ key: String) -> VDF? { children[key.lowercased()] }

    mutating func setChild(_ key: String, _ child: VDF) {
        let lower = key.lowercased()
        if children[lower] == nil { order.append(lower) }
        if spelling[lower] == nil { spelling[lower] = key }
        children[lower] = child
    }

    /// Steam's own layout: tab indents, `"key"\t\t"value"`, values before child objects.
    func text(indent: Int = 0) -> String {
        let pad = String(repeating: "\t", count: indent)
        var out = ""
        for key in valueOrder {
            guard let value = values[key] else { continue }
            out += "\(pad)\"\(Self.escape(spelling[key] ?? key))\"\t\t\"\(Self.escape(value))\"\n"
        }
        for key in order {
            guard let child = children[key] else { continue }
            out += "\(pad)\"\(Self.escape(spelling[key] ?? key))\"\n\(pad){\n\(child.text(indent: indent + 1))\(pad)}\n"
        }
        return out
    }

    private static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

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
                    object[key] = value
                case .open?:
                    object.setChild(key, try parseObject(&tokens, nested: true))
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
    /// What Steam counts for the game on disk (`SizeOnDisk`), 0 when it hasn't said.
    var sizeOnDisk: Int64 = 0

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

    /// Every library folder Steam knows that is reachable now (its own folder first), as macOS URLs inside the
    /// prefix. A folder on an unplugged drive is left out rather than read as an empty library.
    static func libraryFolders(steamRoot: URL, prefix: URL, fileManager: FileManager = .default) -> [URL] {
        libraryFolderEntries(steamRoot: steamRoot, prefix: prefix, fileManager: fileManager).filter(\.isAvailable).map(\.url)
    }

    /// One `libraryfolders.vdf` entry, reachable or not.
    struct LibraryFolder: Equatable, Sendable {
        /// As Steam wrote it (`E:\`, `C:\Program Files (x86)\Steam`).
        let windowsPath: String
        /// Where it lives on the Mac (for an unplugged drive, where it would be).
        let url: URL
        let isAvailable: Bool
    }

    /// Every library folder in `libraryfolders.vdf`, Steam's own first, including ones on a drive that is unplugged.
    static func libraryFolderEntries(steamRoot: URL, prefix: URL, fileManager: FileManager = .default) -> [LibraryFolder] {
        var folders = [LibraryFolder(windowsPath: #"C:\Program Files (x86)\Steam"#, url: steamRoot, isAvailable: true)]
        if let text = try? String(contentsOf: libraryFoldersFile(steamRoot: steamRoot), encoding: .utf8),
           let vdf = try? VDF.parse(text), let list = vdf.child("libraryfolders") {
            for key in list.order {
                guard let path = list.child(key)?["path"], let url = macURL(forWindowsPath: path, prefix: prefix, fileManager: fileManager)
                else { continue }
                if folders.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) { continue }
                var isDirectory: ObjCBool = false
                let available = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                folders.append(LibraryFolder(windowsPath: path, url: url, isAvailable: available))
            }
        }
        return folders
    }

    static func libraryFoldersFile(steamRoot: URL) -> URL { steamRoot.appending(path: "steamapps/libraryfolders.vdf") }

    /// `C:\Program Files (x86)\Steam` → `<prefix>/drive_c/Program Files (x86)/Steam`; other drives go through
    /// Wine's `dosdevices/<letter>:` links. A link whose target is gone (unplugged drive) still maps to that target.
    static func macURL(forWindowsPath path: String, prefix: URL, fileManager: FileManager = .default) -> URL? {
        guard let match = path.firstMatch(of: /^([A-Za-z]):[\\\/]*(.*)$/) else { return nil }
        let letter = match.1.lowercased()
        let rest = match.2.split(whereSeparator: { $0 == "\\" || $0 == "/" }).joined(separator: "/")
        let base = letter == "c" ? prefix.appending(path: "drive_c") : driveTarget(letter: letter, prefix: prefix, fileManager: fileManager)
        return rest.isEmpty ? base : base.appending(path: rest)
    }

    /// Where `dosdevices/<letter>:` points, read from the link itself so a missing target doesn't matter.
    static func driveTarget(letter: String, prefix: URL, fileManager: FileManager = .default) -> URL {
        let dosdevices = prefix.appending(path: "dosdevices")
        let link = dosdevices.appending(path: "\(letter):")
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
            return link.resolvingSymlinksInPath()
        }
        let target = destination.hasPrefix("/") ? URL(filePath: destination) : dosdevices.appending(path: destination)
        return target.standardizedFileURL
    }

    // MARK: Games folders on other drives

    enum AddFolderError: Error, Equatable {
        case noFreeDriveLetter
        case unreadableLibraryFile
    }

    /// The drive letter already pointing at `folder`, else the first letter from E: that Wine doesn't use.
    /// Wine's mount manager adds `x::` links for raw devices and `x:` links for volumes it sees: both count as taken.
    static func driveLetter(for folder: URL, prefix: URL, fileManager: FileManager = .default) -> String? {
        let dosdevices = prefix.appending(path: "dosdevices")
        let entries = Set(((try? fileManager.contentsOfDirectory(atPath: dosdevices.path)) ?? []).map { $0.lowercased() })
        let letters = "defghijklmnopqrstuvwxy".map(String.init)
        for letter in letters where entries.contains("\(letter):") {
            if driveTarget(letter: letter, prefix: prefix, fileManager: fileManager).path == folder.standardizedFileURL.path { return letter }
        }
        return letters.dropFirst().first { !entries.contains("\($0):") && !entries.contains("\($0)::") }
    }

    /// Makes `folder` (usually on an external drive) a Steam library: maps it as a Wine drive letter, prepares it the
    /// way Steam does (`steamapps/`, `libraryfolder.vdf`) and lists it in `libraryfolders.vdf`, after copying that
    /// file to `libraryfolders.vdf.machub-backup`. Steam must not be running: it rewrites the file when it quits.
    /// Returns the Windows path Steam sees (`E:\`).
    @discardableResult
    static func addLibraryFolder(_ folder: URL, steamRoot: URL, prefix: URL, fileManager: FileManager = .default) throws -> String {
        // Steam writes the file on its first start; without it there's no list of its own folder to add to.
        let file = libraryFoldersFile(steamRoot: steamRoot)
        guard let text = try? String(contentsOf: file, encoding: .utf8), let parsed = try? VDF.parse(text) else {
            throw AddFolderError.unreadableLibraryFile
        }
        guard let letter = driveLetter(for: folder, prefix: prefix, fileManager: fileManager) else { throw AddFolderError.noFreeDriveLetter }
        let link = prefix.appending(path: "dosdevices/\(letter):")
        if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) == nil {
            try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: folder.standardizedFileURL.path)
        }
        let windowsPath = "\(letter.uppercased()):\\"

        try fileManager.createDirectory(at: folder.appending(path: "steamapps"), withIntermediateDirectories: true)
        // The folder's own marker and Steam's list share one content ID, as when Steam adds a library itself.
        let marker = folder.appending(path: "libraryfolder.vdf")
        var contentID = String(UInt64.random(in: 1...UInt64(Int64.max)))
        if let text = try? String(contentsOf: marker, encoding: .utf8), let id = (try? VDF.parse(text))?.child("libraryfolder")?["contentid"] {
            contentID = id
        } else {
            var inner = VDF()
            inner["contentid"] = contentID
            inner["label"] = ""
            var root = VDF()
            root.setChild("libraryfolder", inner)
            try root.text().write(to: marker, atomically: true, encoding: .utf8)
        }

        let root = addingLibrary(windowsPath, contentID: contentID, to: parsed)
        let backup = file.appendingPathExtension("machub-backup")
        try? fileManager.removeItem(at: backup)
        try fileManager.copyItem(at: file, to: backup)
        try root.text().write(to: file, atomically: true, encoding: .utf8)
        return windowsPath
    }

    /// `libraryfolders.vdf` with one more library (next free number), unchanged if Steam already lists that path.
    static func addingLibrary(_ windowsPath: String, contentID: String, to root: VDF) -> VDF {
        var root = root
        var list = root.child("libraryfolders") ?? VDF()
        let normalized = { (path: String) in path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\\/")) }
        if list.children.values.contains(where: { $0["path"].map(normalized) == normalized(windowsPath) }) { return root }
        let next = (list.order.compactMap(Int.init).max() ?? -1) + 1
        var entry = VDF()
        entry["path"] = windowsPath
        entry["label"] = ""
        entry["contentid"] = contentID
        entry["totalsize"] = "0"
        entry["update_clean_bytes_tally"] = "0"
        entry["time_last_update_verified"] = "0"
        entry.setChild("apps", VDF())
        list.setChild(String(next), entry)
        root.setChild("libraryfolders", list)
        return root
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
            downloadingPath: steamapps.appending(path: "downloading/\(id)").path,
            sizeOnDisk: state["SizeOnDisk"].flatMap(Int64.init) ?? 0
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
