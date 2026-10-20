import Foundation

/// The Epic Games library through Legendary (github.com/derrod/legendary, GPLv3), an open-source Epic launcher.
/// MacHub downloads its pinned macOS build once (SHA-256 checked, like the engine's components) and keeps its data in
/// MacHub's own folder. Sign-in goes through Epic's website: the user pastes the one-time authorization code it shows,
/// never a password. Games install from Epic's servers into a MacHub Windows environment and start with MacHub's Wine.
enum Legendary {
    static let version = "0.21.1"
    static let binaryURL = URL(string: "https://github.com/derrod/legendary/releases/download/0.21.1/legendary_macOS_arm64")!
    static let sha256 = "d87978321dba9cb731fab40c72f0a30bed55baca8b5341ab21024c5733cd837e"
    /// Epic's sign-in page; once signed in it shows a JSON with the one-time `authorizationCode`.
    static let loginURL = URL(string: "https://legendary.gl/epiclogin")!
    /// The Windows environment Epic games install into.
    static let prefixName = "Epic Games"

    static var directory: URL { LocalData.directory.appending(path: "Epic") }
    static var binary: URL { directory.appending(path: "legendary-\(version)") }
    static var configDirectory: URL { directory.appending(path: "config") }
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    struct Game: Equatable, Sendable, Identifiable {
        var id: String { appName }
        let appName: String
        let title: String
        let coverURL: URL?
        let headerURL: URL?
    }

    struct Installed: Equatable, Sendable {
        let appName: String
        let installPath: String
        let executable: String
    }

    enum Failure: LocalizedError, Equatable {
        case download
        case checksum
        case command(String)

        var errorDescription: String? {
            switch self {
            case .download: String(localized: "Legendary couldn't be downloaded from GitHub.")
            case .checksum: String(localized: "The downloaded Legendary doesn't match its published SHA-256, so it wasn't installed.")
            case .command(let detail): detail
            }
        }
    }

    /// Downloads and checks the pinned Legendary build (once).
    static func installTool() async throws {
        guard !isInstalled else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (file, response) = try await URLSession.shared.download(from: binaryURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
        guard try await RuntimeManager.sha256(of: file) == sha256 else {
            try? FileManager.default.removeItem(at: file)
            throw Failure.checksum
        }
        try? FileManager.default.removeItem(at: binary)
        try FileManager.default.moveItem(at: file, to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    static func run(_ arguments: [String], timeout: TimeInterval = 300, environment: [String: String] = [:]) async throws -> ProcessResult {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        var env = environment
        env["LEGENDARY_CONFIG_PATH"] = configDirectory.path
        return try await ProcessRunner.run(binary, arguments, timeout: timeout, environment: env)
    }

    /// The signed-in Epic account's display name, read from Legendary's own file.
    static func accountName() -> String? {
        guard let data = try? Data(contentsOf: configDirectory.appending(path: "user.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["displayName"] as? String
    }

    /// Accepts either the bare code or the whole JSON Epic's page shows.
    static func authorizationCode(from pasted: String) -> String {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = text.firstMatch(of: /"authorizationCode"\s*:\s*"([0-9a-fA-F]+)"/) { return String(match.1) }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    static func signIn(code: String) async throws {
        try await installTool()
        let result = try await run(["auth", "--code", authorizationCode(from: code)], timeout: 120)
        guard result.status == 0, accountName() != nil else {
            throw Failure.command(String(localized: "Epic refused the code. Codes expire after a few minutes: get a new one and paste it right away."))
        }
    }

    static func signOut() async {
        _ = try? await run(["auth", "--delete"], timeout: 60)
    }

    /// The account's games that have a Windows build (DLC folded into their game).
    static func games(refresh: Bool = false) async throws -> [Game] {
        let result = try await run(["list", "--platform", "Windows", "--json"] + (refresh ? ["--force-refresh"] : []), timeout: 300)
        guard result.status == 0 else { throw Failure.command(String(result.stderr.suffix(300))) }
        return parseGames(Data(result.stdout.utf8))
    }

    static func parseGames(_ data: Data) -> [Game] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { game in
            guard let appName = game["app_name"] as? String, let title = game["app_title"] as? String else { return nil }
            let images = ((game["metadata"] as? [String: Any])?["keyImages"] as? [[String: Any]]) ?? []
            func image(_ type: String) -> URL? {
                (images.first { $0["type"] as? String == type }?["url"] as? String).flatMap(URL.init(string:))
            }
            return Game(appName: appName, title: title,
                        coverURL: image("DieselGameBoxTall") ?? image("Thumbnail"),
                        headerURL: image("DieselGameBox") ?? image("DieselGameBoxLogo"))
        }
    }

    static func installed() async throws -> [String: Installed] {
        let result = try await run(["list-installed", "--json"], timeout: 120)
        guard result.status == 0 else { return [:] }
        return parseInstalled(Data(result.stdout.utf8))
    }

    static func parseInstalled(_ data: Data) -> [String: Installed] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var map: [String: Installed] = [:]
        for game in list {
            guard let appName = game["app_name"] as? String, let path = game["install_path"] as? String else { continue }
            map[appName] = Installed(appName: appName, installPath: path, executable: game["executable"] as? String ?? "")
        }
        return map
    }

    /// `= Progress: 12.34% (…)` lines from Legendary's downloader.
    static func progress(in line: Substring) -> Double? {
        guard let match = line.firstMatch(of: /Progress: ([0-9.]+)%/), let value = Double(match.1) else { return nil }
        return value / 100
    }

    /// Installs a game's Windows build into `basePath`, reporting progress while it downloads.
    static func install(_ appName: String, basePath: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-y", "install", appName, "--platform", "Windows", "--base-path", basePath.path]
        var env = ProcessInfo.processInfo.environment
        env["LEGENDARY_CONFIG_PATH"] = configDirectory.path
        process.environment = env
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        let lastLines = LockedLines()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") {
                if let fraction = Self.progress(in: line) { progress(fraction) }
                lastLines.append(String(line))
            }
        }
        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0 else { throw Failure.command(lastLines.joined()) }
    }

    static func uninstall(_ appName: String) async throws {
        let result = try await run(["-y", "uninstall", appName], timeout: 600)
        guard result.status == 0 else { throw Failure.command(String(result.stderr.suffix(300))) }
    }

    /// `legendary launch` with MacHub's Wine and prefix; Legendary asks Epic for the launch token and starts the game.
    static func launchArguments(_ appName: String, wine: URL, prefix: URL, options: [String]) -> [String] {
        ["launch", appName, "--wine", wine.path, "--wine-prefix", prefix.path] + options
    }
}

/// The last lines a process printed, for an error message (written from a pipe's handler thread).
final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if lines.count > 6 { lines.removeFirst(lines.count - 6) }
    }

    func joined() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
