import Foundation

/// Which layer runs a bottle: MacHub's own Wine runtime, or Whisky (kept as a fallback during the migration).
enum EngineKind: String, Codable, Sendable {
    case embedded
    case whisky
}

/// What the library and launch code need from a compatibility layer. Both engines take a bottle by name and a
/// program as a macOS path or a `C:\…` path; both wait for the program to exit.
protocol CompatibilityEngine: Sendable {
    var kind: EngineKind { get }
    func run(_ path: String, bottle: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult
    /// The log to show when a launch fails.
    func latestLog() -> URL?
}

enum EngineError: Error, Equatable {
    case runtimeMissing
    case prefixMissing(String)
    /// The Windows program exited non-zero; its Wine output is in the log.
    case programExit(code: Int32, log: URL)
}

/// Runs programs with MacHub's own runtime. No Whisky process is involved at any point.
struct EmbeddedWineEngine: CompatibilityEngine {
    let runtime: WineRuntime
    /// Added last to every process it starts (a title's own variables, passed through Steam).
    var extraEnvironment: [String: String] = [:]
    var prefixes: PrefixStore = .live
    var logs: URL = EmbeddedWineEngine.logDirectory

    var kind: EngineKind { .embedded }

    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/app.machub.MacHub/Wine")
    }

    func run(_ path: String, bottle: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        guard let prefix = prefixes.prefix(named: bottle) else { throw EngineError.prefixMissing(bottle) }
        let log = logs.appending(path: Self.logName(for: path))
        var env = WineEnvironment(runtime: runtime, prefix: prefix).variables
        if path.lowercased().hasSuffix("steam.exe") { env.merge(SteamSetup.environment) { _, steam in steam } }
        WineEnvironment.merge(extraEnvironment, into: &env)
        let result = try await ProcessRunner.run(runtime.wine, Self.command(for: path) + arguments,
                                                 timeout: timeout, environment: env, log: log)
        guard result.status == 0 else { throw EngineError.programExit(code: result.status, log: log) }
        return result
    }

    /// Ends every Wine process of a prefix (the game, Steam, helpers). Used by "Stop".
    func stopAll(in bottle: String) async throws {
        guard let prefix = prefixes.prefix(named: bottle) else { throw EngineError.prefixMissing(bottle) }
        let env = WineEnvironment(runtime: runtime, prefix: prefix).variables
        _ = try await ProcessRunner.run(runtime.wineserver, ["-k"], timeout: 30, environment: env)
    }

    func latestLog() -> URL? { Self.newestLog(in: logs) }

    /// `.msi` packages go through msiexec; everything else is started directly.
    static func command(for path: String) -> [String] {
        path.lowercased().hasSuffix(".msi") ? ["msiexec", "/i", path] : [path]
    }

    static func logName(for path: String, date: Date = .now) -> String {
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "program"
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d-%02d-%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "\(stamp)-\(name).log"
    }

    static func newestLog(in directory: URL) -> URL? {
        let logs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return logs.filter { $0.pathExtension == "log" }.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
    }
}

/// The previous integration, unchanged in behaviour: everything goes through WhiskyCmd.
struct WhiskyEngine: CompatibilityEngine {
    let cli: WhiskyCLI

    var kind: EngineKind { .whisky }

    func run(_ path: String, bottle: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await cli.run(path, bottle: bottle, arguments: arguments, timeout: timeout)
    }

    func latestLog() -> URL? {
        ProcessWatch.latestWineLog(bundleID: cli.install.bundleIdentifier ?? WhiskyLocator.forkBundleID)
    }
}
