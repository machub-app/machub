import Foundation

/// A Windows environment (Wine prefix) owned by MacHub. Its settings live in `prefix.json` inside the prefix.
struct WinePrefix: Codable, Identifiable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        /// Holds Steam for Windows and every game it installs.
        case steam
        /// Software the user imports.
        case apps
        case custom
    }

    let id: UUID
    var name: String
    var role: Role
    /// The runtime version that created the prefix; a different one may need `wineboot -u`.
    var runtimeVersion: String
    var windowsVersion = "win10"
    let created: Date

    static let fileName = "prefix.json"
}

/// The prefix as found on disk.
struct InstalledPrefix: Identifiable, Equatable, Sendable {
    let url: URL
    let settings: WinePrefix

    var id: UUID { settings.id }
    var name: String { settings.name }
    var hasDriveC: Bool { FileManager.default.fileExists(atPath: url.appending(path: "drive_c").path) }

    /// The same prefix through the type the library and launch code already use for Whisky bottles.
    var bottle: BottleInfo {
        BottleInfo(url: url, name: settings.name, windowsVersion: settings.windowsVersion,
                   isRegistered: true, hasDriveC: hasDriveC, engine: .embedded)
    }
}

enum PrefixError: Error, Equatable {
    case bootFailed(String)
    case notFound(String)
}

/// Creates and lists prefixes in `Application Support/app.machub.MacHub/Prefixes/<uuid>/`.
/// Never deletes anything: removal goes through the Trash, and only on the user's request.
struct PrefixStore: Sendable {
    let directory: URL

    static let live = PrefixStore(directory: LocalData.directory.appending(path: "Prefixes"))

    func all(fileManager: FileManager = .default) -> [InstalledPrefix] {
        let folders = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { url in
            guard let data = try? Data(contentsOf: url.appending(path: WinePrefix.fileName)),
                  let settings = try? decoder.decode(WinePrefix.self, from: data)
            else { return nil }
            return InstalledPrefix(url: url, settings: settings)
        }
        .sorted { $0.settings.created < $1.settings.created }
    }

    func prefix(named name: String) -> InstalledPrefix? {
        all().first { $0.name == name }
    }

    func save(_ settings: WinePrefix, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(settings).write(to: url.appending(path: WinePrefix.fileName), options: .atomic)
    }

    /// Makes the folder, records its settings, then lets Wine build the Windows tree (`wineboot --init`).
    /// `takenNames` covers Whisky bottles too, so a name always points to one environment.
    func create(name: String, role: WinePrefix.Role, runtime: WineRuntime, takenNames: [String]) async throws -> InstalledPrefix {
        let unique = BottleProvisioner.uniqueName(name, taken: takenNames + all().map(\.name))
        let settings = WinePrefix(id: UUID(), name: unique, role: role, runtimeVersion: runtime.version, created: .now)
        let url = directory.appending(path: settings.id.uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try save(settings, at: url)
        let prefix = InstalledPrefix(url: url, settings: settings)
        do {
            try await boot(prefix, runtime: runtime, arguments: ["--init"])
            Self.isolateUserFolders(in: url)
            try await applyMacDriverSettings(.load(), to: prefix, runtime: runtime)
        } catch {
            // Only the folder made a moment ago, which holds nothing but prefix.json and Wine's partial tree.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return prefix
    }

    /// Wine links the Windows user's Desktop, Documents, Downloads, Music, Pictures and Videos to the Mac's own folders,
    /// so installers drop shortcuts on the Mac Desktop and games write into ~/Documents. MacHub keeps everything inside
    /// the prefix: each link becomes a real folder there. Only links are replaced; a real folder is never touched.
    static func isolateUserFolders(in prefix: URL, fileManager: FileManager = .default) {
        let users = prefix.appending(path: "drive_c/users")
        let accounts = (try? fileManager.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? []
        for account in accounts {
            for folder in ["Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos"] {
                let url = account.appending(path: folder)
                guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil else { continue }
                try? fileManager.removeItem(at: url)   // removes the link only, not its target
                try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    /// Writes the Mac driver keys (Retina, Option/Command mapping, fullscreen capture) into the prefix.
    func applyMacDriverSettings(_ settings: EngineSettings, to prefix: InstalledPrefix, runtime: WineRuntime) async throws {
        let file = prefix.url.appending(path: "drive_c/users/Public/machub-macdriver.reg")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try settings.macDriverRegistry.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let env = WineEnvironment(runtime: runtime, prefix: prefix, settings: settings).variables
        let result = try await ProcessRunner.run(runtime.wine, ["regedit", "/S", file.path], timeout: 60, environment: env)
        guard result.status == 0 else { throw PrefixError.bootFailed("regedit: \(result.stderr.suffix(200))") }
    }

    /// `wineboot -u`: refreshes the Windows tree after a runtime change. Keeps every user file.
    func repair(_ prefix: InstalledPrefix, runtime: WineRuntime) async throws {
        try await boot(prefix, runtime: runtime, arguments: ["-u"])
        Self.isolateUserFolders(in: prefix.url)
        var settings = prefix.settings
        settings.runtimeVersion = runtime.version
        try save(settings, at: prefix.url)
    }

    /// Runs wineboot, writing its output to a log in ~/Library/Logs/app.machub.MacHub/Wine. A failed first attempt
    /// is retried once after stopping the prefix's wineserver (a first start on a new Mac can stall while Rosetta
    /// translates Wine). The error then carries the exit code, Wine's last lines and the log's path.
    private func boot(_ prefix: InstalledPrefix, runtime: WineRuntime, arguments: [String]) async throws {
        let env = WineEnvironment(runtime: runtime, prefix: prefix).variables
        let log = Self.bootLog(for: prefix)
        var failure = ""
        for attempt in 1...2 {
            let boot: ProcessResult
            do {
                boot = try await ProcessRunner.run(runtime.wine, ["wineboot"] + arguments, timeout: 900, environment: env)
            } catch let error as NSError where RuntimeManager.isBadArchitecture(error) {
                throw RuntimeError.rosettaMissing
            }
            Self.append(boot, attempt: attempt, to: log)
            if boot.status == 0 {
                // wineboot returns before wineserver has written the registry; wait for it to finish.
                _ = try await ProcessRunner.run(runtime.wineserver, ["-w"], timeout: 120, environment: env)
                if prefix.hasDriveC { return }
                failure = String(localized: "drive_c is missing after wineboot.")
            } else {
                failure = Self.describeExit(boot)
            }
            _ = try? await ProcessRunner.run(runtime.wineserver, ["-k"], timeout: 30, environment: env)
        }
        throw PrefixError.bootFailed(failure + "\n" + String(localized: "Log: \(log.path)"))
    }

    static func bootLog(for prefix: InstalledPrefix) -> URL {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        return EmbeddedWineEngine.logDirectory.appending(path: "wineboot-\(prefix.settings.name)-\(stamp).log")
    }

    private static func append(_ result: ProcessResult, attempt: Int, to log: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "=== wineboot attempt \(attempt), exit \(result.status)\n\(result.stdout)\(result.stderr)\n"
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: log, atomically: true, encoding: .utf8)
        }
    }

    /// Exit code plus the last meaningful lines Wine printed (empty when Wine printed nothing, as on a crash).
    static func describeExit(_ result: ProcessResult) -> String {
        let lines = (result.stderr + "\n" + result.stdout).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tail = lines.suffix(4).joined(separator: "\n")
        let code = String(localized: "Wine stopped with code \(Int(result.status)).")
        return tail.isEmpty ? code + " " + String(localized: "It printed nothing.") : code + "\n" + tail
    }
}

/// The environment every Wine process of a prefix gets. One place, so launches and maintenance agree.
struct WineEnvironment: Equatable, Sendable {
    let runtime: WineRuntime
    let prefix: InstalledPrefix
    var dllOverrides: [String: String] = [:]
    var settings: EngineSettings = .load()

    var variables: [String: String] {
        // Wine finds its own DLLs, Mono and Gecko relative to its binary: nothing to point at.
        var env = [
            "WINEPREFIX": prefix.url.path,
            // Wine dlopens gnutls, freetype, MoltenVK… by name; the runtime keeps them in wine/lib.
            "DYLD_FALLBACK_LIBRARY_PATH": runtime.root.appending(path: "wine/lib").path + ":/usr/lib",
            // Chromium-based launchers (Steam, Epic…) can't run their sandbox under Wine and hang without these.
            "STEAM_DISABLE_CEF_SANDBOX": "1",
            "CEF_DISABLE_SANDBOX": "1",
            // Since macOS 15.3/15.4: Metal's validation layer breaks rendering; the Linux Steam Runtime must stay off.
            "MTL_DEBUG_LAYER": "0",
            "STEAM_RUNTIME": "0",
            // MacHub's winemac patch (tools/wine-patches): these processes don't get a Dock icon of their own.
            // Steam's UI window belongs to steamwebhelper.exe, which keeps the single Steam icon.
            "MACHUB_NO_DOCK_ICON": "steam.exe;steamservice.exe;steamerrorreporter.exe;steamerrorreporter64.exe",
        ]
        var chosen = settings
        // msync exists only in CrossOver's Wine; elsewhere WINEMSYNC is ignored and Wine would fall back to the
        // slowest path, so use esync instead.
        if chosen.sync == .msync, !runtime.supportsMsync { chosen.sync = .esync }
        env.merge(chosen.environment) { _, setting in setting }
        // winemenubuilder turns Windows shortcuts into .desktop files on the Mac Desktop: never wanted here.
        var overrides = ["winemenubuilder.exe": "d"]
        overrides.merge(dllOverrides) { _, own in own }
        env["WINEDLLOVERRIDES"] = overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        return env
    }
}

extension WineRuntime {
    /// CrossOver's Wine carries msync (server/msync.c); the WineHQ build doesn't.
    var supportsMsync: Bool { info.component("winecx") != nil }
}
