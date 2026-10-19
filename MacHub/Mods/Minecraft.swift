import AppKit
import Foundation

/// Minecraft: Java Edition as the official macOS launcher lays it out. It runs natively: no Whisky involved.
struct MinecraftHome: Sendable {
    let root: URL

    static let launcherBundleID = "com.mojang.minecraftlauncher"
    static var standard: MinecraftHome {
        MinecraftHome(root: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/minecraft"))
    }

    var exists: Bool { FileManager.default.fileExists(atPath: root.appending(path: "launcher_profiles.json").path) }
    var profilesFile: URL { root.appending(path: "launcher_profiles.json") }
    /// MacHub's own instances live here, one game folder each, so the vanilla game folder is never modded.
    var machubFolder: URL { root.appending(path: "machub") }

    @MainActor static var launcherApp: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: launcherBundleID)
    }

    @MainActor static var isLauncherRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: launcherBundleID).isEmpty
    }

    /// Release versions the launcher has already downloaded (versions/<id>/<id>.json), newest first.
    func installedReleases(fileManager: FileManager = .default) -> [String] {
        let dir = root.appending(path: "versions")
        let ids = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        return ids.filter { id in
            guard let data = try? Data(contentsOf: dir.appending(path: "\(id)/\(id).json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json["type"] as? String == "release" && json["inheritsFrom"] == nil
        }
        .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// Launcher profiles MacHub created (their game folder is inside `machub/`).
    func instances() -> [MinecraftInstance] {
        guard let data = try? Data(contentsOf: profilesFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profiles"] as? [String: [String: Any]] else { return [] }
        return profiles.compactMap { key, profile in
            guard let gameDir = profile["gameDir"] as? String, gameDir.hasPrefix(machubFolder.path),
                  let versionID = profile["lastVersionId"] as? String,
                  let match = versionID.firstMatch(of: /^fabric-loader-(.+?)-(.+)$/) else { return nil }
            return MinecraftInstance(id: key, name: profile["name"] as? String ?? key, gameVersion: String(match.2),
                                     loader: "fabric", loaderVersion: String(match.1), gameDir: URL(filePath: gameDir))
        }
        .sorted { $0.gameVersion.compare($1.gameVersion, options: .numeric) == .orderedDescending }
    }
}

/// One MacHub-managed Minecraft profile: a game version, a mod loader and its own folder.
struct MinecraftInstance: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let gameVersion: String
    let loader: String
    let loaderVersion: String
    let gameDir: URL

    var modsDir: URL { gameDir.appending(path: "mods") }
}

/// Installs the Fabric loader the way Fabric's own installer does (version JSON + empty jar + launcher profile),
/// using Fabric's documented meta API. Additive only, with a backup of launcher_profiles.json first.
struct FabricSetup: Sendable {
    enum Failure: Error, Equatable {
        case launcherRunning
        case noLoader(String)
        case network
        case badProfile
    }

    typealias Fetch = @Sendable (URL) async throws -> Data
    let home: MinecraftHome
    var fetch: Fetch = { url in
        var request = URLRequest(url: url)
        request.setValue("MacHub (app.machub.MacHub)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.network }
        return data
    }

    static let meta = URL(string: "https://meta.fabricmc.net/v2/versions/loader/")!

    /// Newest stable Fabric loader for a game version.
    func latestLoader(for gameVersion: String) async throws -> String {
        let data = try await fetch(Self.meta.appending(path: gameVersion))
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure.network }
        let loaders = list.compactMap { $0["loader"] as? [String: Any] }
        guard let pick = loaders.first(where: { $0["stable"] as? Bool == true }) ?? loaders.first,
              let version = pick["version"] as? String else { throw Failure.noLoader(gameVersion) }
        return version
    }

    /// Creates "MacHub · Fabric <version>" and returns it. `launcherRunning` must be false: the launcher rewrites
    /// launcher_profiles.json on quit and would drop the new profile.
    func createInstance(gameVersion: String, launcherRunning: Bool, now: Date = .now) async throws -> MinecraftInstance {
        guard !launcherRunning else { throw Failure.launcherRunning }
        let fm = FileManager.default
        let loader = try await latestLoader(for: gameVersion)
        let profileData = try await fetch(Self.meta.appending(path: "\(gameVersion)/\(loader)/profile/json"))
        guard let profile = try JSONSerialization.jsonObject(with: profileData) as? [String: Any],
              let versionID = profile["id"] as? String, versionID.hasPrefix("fabric-loader-") else { throw Failure.badProfile }

        let versionDir = home.root.appending(path: "versions/\(versionID)")
        try fm.createDirectory(at: versionDir, withIntermediateDirectories: true)
        let json = versionDir.appending(path: "\(versionID).json")
        if !fm.fileExists(atPath: json.path) { try profileData.write(to: json, options: .atomic) }
        let jar = versionDir.appending(path: "\(versionID).jar")
        if !fm.fileExists(atPath: jar.path) { fm.createFile(atPath: jar.path, contents: Data()) }

        let key = "machub-fabric-\(gameVersion)"
        let gameDir = home.machubFolder.appending(path: "fabric-\(gameVersion)")
        try fm.createDirectory(at: gameDir.appending(path: "mods"), withIntermediateDirectories: true)

        let original = try Data(contentsOf: home.profilesFile)
        let backups = home.machubFolder.appending(path: "backups")
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        try original.write(to: backups.appending(path: "launcher_profiles-\(stamp).json"))

        guard var root = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw Failure.badProfile }
        var profiles = root["profiles"] as? [String: Any] ?? [:]
        let iso = ISO8601DateFormatter().string(from: now)
        profiles[key] = [
            "name": "MacHub · Fabric \(gameVersion)", "type": "custom", "icon": "Furnace",
            "lastVersionId": versionID, "gameDir": gameDir.path, "created": iso, "lastUsed": iso,
        ]
        root["profiles"] = profiles
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: home.profilesFile, options: .atomic)
        return MinecraftInstance(id: key, name: "MacHub · Fabric \(gameVersion)", gameVersion: gameVersion, loader: "fabric",
                                 loaderVersion: loader, gameDir: gameDir)
    }
}
