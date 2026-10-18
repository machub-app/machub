import Foundation

/// Assetto Corsa content (cars, tracks) imported from a .zip or a folder the user downloaded.
/// No archive is trusted: entries are checked before extraction, extraction happens in a staging folder,
/// only `content/cars/<name>` and `content/tracks/<name>` are written, and anything replaced is backed up first.
struct ArchiveModImporter: Sendable {
    enum Kind: String, Codable, Sendable { case car, track }

    struct Item: Equatable, Sendable {
        let kind: Kind
        let name: String
        /// Folder inside the staging area.
        let source: URL
    }

    struct Installed: Codable, Hashable, Identifiable, Sendable {
        var id: String { "\(kind.rawValue)/\(name)" }
        let kind: Kind
        let name: String
        let archive: String
        let installedAt: Date
        /// Where the folder it replaced was moved, to restore on uninstall.
        let backup: String?
    }

    enum Failure: Error, Equatable {
        case unsupportedFormat(String)
        case unsafeEntry(String)
        case symlink(String)
        case nothingRecognised
        case extraction(String)
        case gameFolderMissing
        case notInstalled
    }

    let gameFolder: URL
    let dataFolder: URL
    var runner: @Sendable (URL, [String], TimeInterval) async throws -> ProcessResult = { try await ProcessRunner.run($0, $1, timeout: $2) }

    init(gameFolder: URL, dataFolder: URL = LocalData.directory.appending(path: "mods/assettocorsa")) {
        self.gameFolder = gameFolder
        self.dataFolder = dataFolder
    }

    var manifestName: String { "installed.json" }

    func installed() -> [Installed] {
        LocalData.load([Installed].self, from: manifestName, in: dataFolder) ?? []
    }

    /// Rejects entries that would land outside the extraction folder (zip-slip) or are absolute.
    static func validate(entries: [String]) throws(Failure) {
        for entry in entries {
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            if entry.hasPrefix("/") || entry.hasPrefix("\\") || entry.contains("\\") || parts.contains("..") || entry.contains(":") {
                throw .unsafeEntry(entry)
            }
        }
    }

    /// Finds car and track folders in an extracted tree: `content/cars/<x>` / `content/tracks/<x>` first,
    /// then folders carrying a car's or track's own UI file.
    static func items(in root: URL, fileManager: FileManager = .default) -> [Item] {
        var found: [Item] = []
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else { return [] }
        for case let url as URL in walker where walker.level <= 5 {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let parent = url.deletingLastPathComponent()
            let name = url.lastPathComponent
            if parent.lastPathComponent.lowercased() == "cars", parent.deletingLastPathComponent().lastPathComponent.lowercased() == "content" {
                found.append(Item(kind: .car, name: name, source: url)); walker.skipDescendants()
            } else if parent.lastPathComponent.lowercased() == "tracks", parent.deletingLastPathComponent().lastPathComponent.lowercased() == "content" {
                found.append(Item(kind: .track, name: name, source: url)); walker.skipDescendants()
            } else if fileManager.fileExists(atPath: url.appending(path: "ui/ui_car.json").path) {
                found.append(Item(kind: .car, name: name, source: url)); walker.skipDescendants()
            } else if fileManager.fileExists(atPath: url.appending(path: "ui/ui_track.json").path)
                        || hasLayoutTrackUI(url, fileManager: fileManager) {
                found.append(Item(kind: .track, name: name, source: url)); walker.skipDescendants()
            }
        }
        return found
    }

    /// Multi-layout tracks keep their UI file one level deeper: ui/<layout>/ui_track.json.
    private static func hasLayoutTrackUI(_ url: URL, fileManager: FileManager) -> Bool {
        let ui = url.appending(path: "ui")
        let layouts = (try? fileManager.contentsOfDirectory(atPath: ui.path)) ?? []
        return layouts.contains { fileManager.fileExists(atPath: ui.appending(path: "\($0)/ui_track.json").path) }
    }

    /// Extracts (zip) or reads (folder) and returns what would be installed, without touching the game.
    func prepare(_ source: URL) async throws -> (staging: URL, items: [Item]) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw Failure.extraction("missing") }
        if isDirectory.boolValue {
            try Self.rejectSymlinks(in: source)
            let items = Self.items(in: source)
            guard !items.isEmpty else { throw Failure.nothingRecognised }
            return (source, items)
        }
        guard source.pathExtension.lowercased() == "zip" else { throw Failure.unsupportedFormat(source.pathExtension) }
        let listing = try await runner(URL(filePath: "/usr/bin/zipinfo"), ["-1", source.path], 60)
        guard listing.status == 0 else { throw Failure.extraction(listing.stderr) }
        try Self.validate(entries: listing.stdout.split(separator: "\n").map(String.init))
        let staging = fm.temporaryDirectory.appending(path: "machub-staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let extract = try await runner(URL(filePath: "/usr/bin/ditto"), ["-x", "-k", source.path, staging.path], 600)
        guard extract.status == 0 else { throw Failure.extraction(extract.stderr) }
        try Self.rejectSymlinks(in: staging)
        let items = Self.items(in: staging)
        guard !items.isEmpty else { throw Failure.nothingRecognised }
        return (staging, items)
    }

    static func rejectSymlinks(in root: URL) throws {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw Failure.symlink(url.lastPathComponent)
        }
    }

    func destination(for item: Item) -> URL {
        gameFolder.appending(path: "content/\(item.kind == .car ? "cars" : "tracks")/\(item.name)")
    }

    /// Copies each item in; an existing folder of the same name is moved to MacHub's backups first.
    func install(_ items: [Item], from archive: String, now: Date = .now) throws -> [Installed] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: gameFolder.appending(path: "content").path) else { throw Failure.gameFolderMissing }
        var manifest = installed()
        var done: [Installed] = []
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        for item in items {
            guard FolderModInstaller.isSafeFolderName(item.name) else { throw Failure.unsafeEntry(item.name) }
            let target = destination(for: item)
            var backup: URL?
            if fm.fileExists(atPath: target.path) {
                let saved = dataFolder.appending(path: "backups/\(stamp)/\(item.kind.rawValue)/\(item.name)")
                try fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: target, to: saved)
                backup = saved
            }
            try fm.copyItem(at: item.source, to: target)
            let record = Installed(kind: item.kind, name: item.name, archive: archive, installedAt: now,
                                   backup: backup?.path ?? manifest.first { $0.id == "\(item.kind.rawValue)/\(item.name)" }?.backup)
            manifest.removeAll { $0.id == record.id }
            manifest.append(record)
            done.append(record)
        }
        try fm.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        LocalData.save(manifest, to: manifestName, in: dataFolder)
        return done
    }

    /// Moves the installed folder to the Trash and puts back what it replaced, if anything.
    func uninstall(_ item: Installed) throws {
        let fm = FileManager.default
        var manifest = installed()
        guard manifest.contains(item) else { throw Failure.notInstalled }
        let target = gameFolder.appending(path: "content/\(item.kind == .car ? "cars" : "tracks")/\(item.name)")
        if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
        if let backup = item.backup, fm.fileExists(atPath: backup) { try fm.moveItem(at: URL(filePath: backup), to: target) }
        manifest.removeAll { $0 == item }
        LocalData.save(manifest, to: manifestName, in: dataFolder)
    }
}

extension FolderModInstaller {
    static func isSafeFolderName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".")
    }
}
