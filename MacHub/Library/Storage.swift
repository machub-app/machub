import Foundation

/// Disk measurements for Settings › Storage.
enum Storage {
    /// Space the files under `url` take on disk (allocated, not logical size). Symbolic links aren't followed, so a
    /// prefix's `dosdevices/z:` (→ /) or a drive letter on an external disk never counts.
    static func allocatedSize(of url: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let top = try? url.resourceValues(forKeys: Set(keys)), top.isSymbolicLink != true else { return 0 }
        if top.isDirectory != true { return Int64(top.totalFileAllocatedSize ?? top.fileAllocatedSize ?? 0) }
        guard let walker = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Space left for large files on the volume holding `url`, nil when it can't be read (unplugged drive).
    static func availableSpace(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        else { return nil }
        return values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
    }

    /// "52.1 GB", the way Finder counts.
    static func format(_ bytes: Int64, locale: Locale = .autoupdatingCurrent) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }
}

/// What MacHub has on disk: games (as Steam counts them), Windows environments and engines.
struct StorageReport: Sendable {
    struct Item: Identifiable, Sendable {
        let id: String
        let name: String
        let url: URL
        let bytes: Int64
    }

    var games: [Item] = []
    var prefixes: [Item] = []
    var runtimes: [Item] = []
    var libraries: [SteamLibrary.LibraryFolder] = []

    /// Environments and engines (games inside environments are already part of them).
    var total: Int64 { (prefixes + runtimes).reduce(0) { $0 + $1.bytes } }

    /// Walks every folder: call it off the main thread.
    static func measure(prefixes: [InstalledPrefix], runtimes: [WineRuntime], fileManager: FileManager = .default) -> StorageReport {
        var report = StorageReport()
        for prefix in prefixes {
            report.prefixes.append(Item(id: prefix.id.uuidString, name: prefix.name, url: prefix.url,
                                        bytes: Storage.allocatedSize(of: prefix.url, fileManager: fileManager)))
            guard let root = SteamLibrary.steamRoot(inPrefix: prefix.url, fileManager: fileManager) else { continue }
            report.libraries += SteamLibrary.libraryFolderEntries(steamRoot: root, prefix: prefix.url, fileManager: fileManager)
            for app in SteamLibrary.apps(steamRoot: root, prefix: prefix.url, fileManager: fileManager) where app.isInstalled {
                report.games.append(Item(id: "\(prefix.id.uuidString):\(app.appID)", name: app.name, url: URL(filePath: app.installPath),
                                         bytes: app.sizeOnDisk))
            }
        }
        report.games.sort { $0.bytes > $1.bytes }
        report.runtimes = runtimes.map {
            Item(id: $0.version, name: $0.version, url: $0.root, bytes: Storage.allocatedSize(of: $0.root, fileManager: fileManager))
        }
        return report
    }
}

/// "Uninstall MacHub's data": exactly what goes to the Trash, measured before anything moves.
struct DataRemoval: Sendable {
    struct Item: Identifiable, Sendable {
        var id: URL { url }
        let url: URL
        let bytes: Int64
    }

    let items: [Item]

    var total: Int64 { items.reduce(0) { $0 + $1.bytes } }

    static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/app.machub.MacHub")
    }

    static var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "app.machub.MacHub")
    }

    /// Every item at the top of MacHub's Application Support folder (engines, environments with their games, imported
    /// D3DMetal, mods and their backups, settings files), then its logs and caches. Walks every folder: call it off
    /// the main thread.
    static func plan(dataDirectory: URL, logsDirectory: URL = logsDirectory, cachesDirectory: URL = cachesDirectory,
                     fileManager: FileManager = .default) -> DataRemoval {
        let inside = ((try? fileManager.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != ".DS_Store" }
            .sorted { rank($0) == rank($1) ? $0.lastPathComponent < $1.lastPathComponent : rank($0) < rank($1) }
        let others = [logsDirectory, cachesDirectory].filter { fileManager.fileExists(atPath: $0.path) }
        return DataRemoval(items: (inside + others).map { Item(url: $0, bytes: Storage.allocatedSize(of: $0, fileManager: fileManager)) })
    }

    /// Folders first (biggest kinds on top), then files.
    private static func rank(_ url: URL) -> Int {
        ["Prefixes", "Runtimes", "GPTK", "mods"].firstIndex(of: url.lastPathComponent) ?? (url.pathExtension.isEmpty ? 4 : 5)
    }

    /// Moves each item to the Trash; never deletes. Returns the items that couldn't be moved.
    func perform(trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> [Item] {
        items.filter { item in
            do { try trash(item.url); return false } catch { return true }
        }
    }
}
