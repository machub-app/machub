import Foundation

/// Where and how a game takes its mods. Every file MacHub writes is recorded, a file it replaces is backed up first,
/// and a mod can be disabled (its files moved to MacHub's storage) or removed (files to the Trash, backups restored).
struct NexusModInstaller: Sendable {
    enum Layout: Sendable, Equatable {
        /// BeamNG.drive: each mod is a .zip dropped as-is into the user folder's `mods/`.
        case zipIntoFolder(URL)
        /// Cyberpunk 2077: archives mirror the game folder (archive/pc/mod, bin/x64, r6, red4ext…), merged into it.
        case mergeIntoGame(URL, roots: [String])
        /// Dead Island 2: .pak/.utoc/.ucas files go to Content/Paks/~mods.
        case paksInto(URL)
    }

    struct Installed: Codable, Hashable, Identifiable, Sendable {
        var id: String { "\(modID)-\(fileID)" }
        let modID: Int
        let fileID: Int
        let name: String
        let version: String
        /// Paths relative to the layout's root, as written.
        let files: [String]
        /// Relative path → backup file of what it replaced.
        let backups: [String: String]
        var enabled: Bool
        let installedAt: Date
    }

    enum Failure: Error, Equatable {
        case unsupportedFormat(String)
        case unsafeEntry(String)
        case nothingRecognised
        case extraction(String)
        case destinationMissing(String)
    }

    let layout: Layout
    let dataFolder: URL
    var runner: @Sendable (URL, [String], TimeInterval) async throws -> ProcessResult = { try await ProcessRunner.run($0, $1, timeout: $2) }

    var root: URL {
        switch layout {
        case .zipIntoFolder(let url), .mergeIntoGame(let url, _), .paksInto(let url): url
        }
    }

    /// The layout for a Steam game installed in a MacHub prefix, or nil if MacHub doesn't know the game.
    static func layout(appID: Int, installPath: String, prefix: URL) -> Layout? {
        switch appID {
        case 284160:
            let users = (try? FileManager.default.contentsOfDirectory(atPath: prefix.appending(path: "drive_c/users").path)) ?? []
            guard let user = users.first(where: { $0 != "Public" && !$0.hasPrefix(".") }) else { return nil }
            return .zipIntoFolder(prefix.appending(path: "drive_c/users/\(user)/AppData/Local/BeamNG/BeamNG.drive/current/mods"))
        case 1091500:
            return .mergeIntoGame(URL(filePath: installPath), roots: ["archive", "bin", "r6", "red4ext", "engine", "mods", "tools"])
        case 934700:
            return .paksInto(URL(filePath: installPath).appending(path: "DeadIsland/Content/Paks/~mods"))
        default:
            return nil
        }
    }

    func installed() -> [Installed] {
        LocalData.load([Installed].self, from: "installed.json", in: dataFolder) ?? []
    }

    private func save(_ mods: [Installed]) {
        try? FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        LocalData.save(mods, to: "installed.json", in: dataFolder)
    }

    // MARK: Install

    /// Installs a downloaded archive. `fileName` is the name Nexus gave it (the download URL may not carry one).
    func install(archive: URL, fileName: String, modID: Int, fileID: Int, name: String, version: String) async throws -> Installed {
        let fm = FileManager.default
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard ext == "zip" else { throw Failure.unsupportedFormat(ext) }
        let entries = try await zipEntries(archive)
        try Self.check(entries)

        // Placement plan: source file → path relative to root.
        var plan: [(source: URL, relative: String)] = []
        var staging: URL?
        defer { if let staging { try? fm.removeItem(at: staging) } }

        switch layout {
        case .zipIntoFolder:
            let beamRoots = ["vehicles", "levels", "lua", "art", "ui", "scripts", "settings", "gameplay", "campaigns", "flowEditor"]
            let roots = Set(entries.compactMap { $0.split(separator: "/").first.map(String.init) })
            if !roots.isDisjoint(with: beamRoots) {
                plan = [(archive, Self.safeName(fileName))]
            } else {
                let unpacked = try await extract(archive)
                staging = unpacked
                plan = Self.files(in: unpacked).filter { $0.pathExtension.lowercased() == "zip" }.map { ($0, Self.safeName($0.lastPathComponent)) }
            }
        case .mergeIntoGame(_, let roots):
            let unpacked = try await extract(archive)
            staging = unpacked
            guard let base = Self.base(of: unpacked, containingOneOf: roots) else { throw Failure.nothingRecognised }
            plan = Self.files(in: base).map { ($0, String($0.path.dropFirst(base.path.count + 1))) }
        case .paksInto:
            let unpacked = try await extract(archive)
            staging = unpacked
            plan = Self.files(in: unpacked).filter { ["pak", "utoc", "ucas"].contains($0.pathExtension.lowercased()) }
                .map { ($0, $0.lastPathComponent) }
        }
        guard !plan.isEmpty else { throw Failure.nothingRecognised }

        var mods = installed()
        let stamp = String(Int(Date.now.timeIntervalSince1970))
        var backups: [String: String] = [:]
        for (source, relative) in plan {
            guard !relative.split(separator: "/").contains("..") else { throw Failure.unsafeEntry(relative) }
            let target = root.appending(path: relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let ownedByAnother = mods.contains { $0.files.contains(relative) }
            if fm.fileExists(atPath: target.path), !ownedByAnother {
                let saved = dataFolder.appending(path: "backups/\(stamp)/\(relative)")
                try fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: target, to: saved)
                backups[relative] = saved.path
            } else if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: source, to: target)
        }
        let record = Installed(modID: modID, fileID: fileID, name: name, version: version, files: plan.map(\.relative),
                               backups: backups, enabled: true, installedAt: .now)
        mods.removeAll { $0.modID == modID }
        mods.append(record)
        save(mods)
        return record
    }

    // MARK: Enable, disable, remove

    /// Disabled mods keep their files in MacHub's storage, so the game no longer sees them.
    func setEnabled(_ mod: Installed, _ enabled: Bool) throws {
        let fm = FileManager.default
        let storage = dataFolder.appending(path: "disabled/\(mod.id)")
        for relative in mod.files {
            let live = root.appending(path: relative), parked = storage.appending(path: relative)
            let (from, to) = enabled ? (parked, live) : (live, parked)
            guard fm.fileExists(atPath: from.path) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.moveItem(at: from, to: to)
        }
        var mods = installed()
        if let index = mods.firstIndex(where: { $0.id == mod.id }) { mods[index].enabled = enabled }
        save(mods)
    }

    /// Moves the mod's files to the Trash and puts back what they replaced.
    func uninstall(_ mod: Installed) throws {
        let fm = FileManager.default
        for relative in mod.files {
            for url in [root.appending(path: relative), dataFolder.appending(path: "disabled/\(mod.id)/\(relative)")]
            where fm.fileExists(atPath: url.path) {
                try fm.trashItem(at: url, resultingItemURL: nil)
            }
            if let backup = mod.backups[relative], fm.fileExists(atPath: backup) {
                try fm.moveItem(at: URL(filePath: backup), to: root.appending(path: relative))
            }
        }
        save(installed().filter { $0.id != mod.id })
    }

    // MARK: Helpers

    private func zipEntries(_ archive: URL) async throws -> [String] {
        let listing = try await runner(URL(filePath: "/usr/bin/zipinfo"), ["-1", archive.path], 60)
        guard listing.status == 0 else { throw Failure.extraction(listing.stderr) }
        return listing.stdout.split(separator: "\n").map(String.init)
    }

    private func extract(_ archive: URL) async throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appending(path: "machub-nexus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let result = try await runner(URL(filePath: "/usr/bin/ditto"), ["-x", "-k", archive.path, staging.path], 900)
        guard result.status == 0 else { throw Failure.extraction(result.stderr) }
        do { try ArchiveModImporter.rejectSymlinks(in: staging) } catch { throw Failure.unsafeEntry("symbolic link") }
        return staging
    }

    static func files(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .filter { !$0.path.contains("__MACOSX") }
    }

    /// The folder (the archive root, or a single wrapper folder inside it) that holds one of the game's roots.
    static func base(of folder: URL, containingOneOf roots: [String]) -> URL? {
        func matches(_ url: URL) -> Bool {
            let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).map { $0.lowercased() })
            return roots.contains { names.contains($0) }
        }
        if matches(folder) { return folder }
        let children = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
        if children.count == 1, matches(children[0]) { return children[0] }
        return nil
    }

    /// Rejects entries that would land outside the extraction folder (zip-slip), with the importer's own rules.
    static func check(_ entries: [String]) throws(Failure) {
        do throws(ArchiveModImporter.Failure) {
            try ArchiveModImporter.validate(entries: entries)
        } catch {
            if case .unsafeEntry(let entry) = error { throw .unsafeEntry(entry) }
            throw .unsafeEntry("archive")
        }
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        return cleaned.hasPrefix(".") ? "_" + cleaned : cleaned
    }
}

