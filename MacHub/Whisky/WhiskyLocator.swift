import AppKit

struct WhiskyInstall: Equatable, Sendable {
    let cmdURL: URL
    let appURL: URL?
    let bundleIdentifier: String?
    let version: String?
    let subcommands: Set<String>
}

enum WhiskyStatus: Equatable, Sendable {
    case ready(WhiskyInstall)
    /// Found a WhiskyCmd, but it lacks commands MacHub needs (e.g. the archived 2.3.5 has no `games`/`launch`).
    case outdated(WhiskyInstall, missing: [String])
    case notFound(searched: [URL])
    case invalidCustomPath(URL, reason: String)

    var install: WhiskyInstall? {
        switch self {
        case .ready(let install), .outdated(let install, _): install
        case .notFound, .invalidCustomPath: nil
        }
    }
}

/// Finds a usable WhiskyCmd. Never trusts a path or an app name: a candidate is accepted
/// only if its own `--help` lists the subcommands MacHub relies on.
struct WhiskyLocator: Sendable {
    static let forkBundleID = "com.franke.Whisky"
    static let requiredSubcommands = ["games", "launch", "run"]

    var isExecutable: @Sendable (URL) -> Bool
    var appURLForBundleID: @Sendable (String) -> URL?
    var appsIn: @Sendable (URL) -> [URL]
    var help: @Sendable (URL) async throws -> String
    var bundleInfo: @Sendable (URL) -> (id: String?, version: String?)
    var searchDirs: [URL]

    static let live = WhiskyLocator(
        isExecutable: { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                && !isDir.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
        },
        appURLForBundleID: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        appsIn: { dir in
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        },
        help: { url in
            let result = try await ProcessRunner.run(url, ["--help"], timeout: 10)
            return result.stdout + result.stderr
        },
        bundleInfo: { app in
            let bundle = Bundle(url: app)
            return (bundle?.bundleIdentifier, bundle?.infoDictionary?["CFBundleShortVersionString"] as? String)
        },
        searchDirs: [
            URL(filePath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications"),
        ]
    )

    func locate(customPath: String?) async -> WhiskyStatus {
        if let customPath, !customPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = URL(filePath: (customPath as NSString).expandingTildeInPath)
            guard isExecutable(url) else { return .invalidCustomPath(url, reason: "Not an executable file.") }
            return await evaluate(url) ?? .invalidCustomPath(url, reason: "Running it with --help failed.")
        }

        var candidates = [URL(filePath: "/usr/local/bin/whisky")]
        if let app = appURLForBundleID(Self.forkBundleID) { candidates.append(Self.cmd(in: app)) }
        for dir in searchDirs {
            for app in appsIn(dir) where app.pathExtension == "app" && app.lastPathComponent.hasPrefix("Whisky") {
                candidates.append(Self.cmd(in: app))
            }
        }
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }

        var fallback: WhiskyStatus?
        for url in unique where isExecutable(url) {
            guard let status = await evaluate(url) else { continue }
            if case .ready = status { return status }
            fallback = fallback ?? status
        }
        return fallback ?? .notFound(searched: unique)
    }

    private func evaluate(_ cmd: URL) async -> WhiskyStatus? {
        guard let text = try? await help(cmd) else { return nil }
        let subcommands = Self.parseSubcommands(text)
        let app = Self.enclosingApp(of: cmd.resolvingSymlinksInPath())
        let info = app.map(bundleInfo)
        let install = WhiskyInstall(
            cmdURL: cmd, appURL: app, bundleIdentifier: info?.id, version: info?.version, subcommands: subcommands
        )
        let missing = Self.requiredSubcommands.filter { !subcommands.contains($0) }
        return missing.isEmpty ? .ready(install) : .outdated(install, missing: missing)
    }

    static func cmd(in app: URL) -> URL {
        app.appending(path: "Contents/Resources/WhiskyCmd")
    }

    static func enclosingApp(of url: URL) -> URL? {
        var current = url
        while current.path != "/" {
            if current.pathExtension == "app" { return current }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Parses swift-argument-parser help: subcommand names are the first word of the
    /// two-space-indented lines under `SUBCOMMANDS:`.
    static func parseSubcommands(_ help: String) -> Set<String> {
        var names = Set<String>()
        var inSection = false
        for line in help.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("SUBCOMMANDS:") { inSection = true; continue }
            guard inSection, !line.isEmpty else { continue }
            if !line.hasPrefix(" ") { break }
            guard line.hasPrefix("  "), !line.hasPrefix("   "),
                  let word = line.split(separator: " ").first,
                  word.allSatisfy({ $0.isLowercase || $0 == "-" })
            else { continue }
            names.insert(String(word))
        }
        return names
    }
}
