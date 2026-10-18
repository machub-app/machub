import Foundation

struct SteamGame: Decodable, Equatable, Sendable {
    let appId: Int
    let name: String
    let installPath: String

    init(appId: Int, name: String, installPath: String) {
        self.appId = appId
        self.name = name
        self.installPath = installPath
    }

    /// WhiskyCmd 3.7.0 emits `"appId" : "244210"` (a string); accept a number too.
    init(from decoder: Decoder) throws {
        enum Keys: String, CodingKey { case appId, name, installPath }
        let c = try decoder.container(keyedBy: Keys.self)
        if let number = try? c.decode(Int.self, forKey: .appId) {
            appId = number
        } else if let text = try? c.decode(String.self, forKey: .appId), let number = Int(text) {
            appId = number
        } else {
            throw DecodingError.dataCorruptedError(forKey: .appId, in: c, debugDescription: "appId is neither a number nor a numeric string")
        }
        name = try c.decode(String.self, forKey: .name)
        installPath = try c.decode(String.self, forKey: .installPath)
    }
}

struct LaunchConfirmation: Decodable, Equatable, Sendable {
    let appId: Int
    let bottle: String
    /// `launched` means Wine started `steam.exe -applaunch`, NOT that the game is running.
    let status: String

    init(appId: Int, bottle: String, status: String) {
        self.appId = appId
        self.bottle = bottle
        self.status = status
    }

    /// Same tolerance as SteamGame: WhiskyCmd may emit appId as a string.
    init(from decoder: Decoder) throws {
        enum Keys: String, CodingKey { case appId, bottle, status }
        let c = try decoder.container(keyedBy: Keys.self)
        appId = (try? c.decode(Int.self, forKey: .appId)) ?? Int((try? c.decode(String.self, forKey: .appId)) ?? "") ?? 0
        bottle = try c.decode(String.self, forKey: .bottle)
        status = try c.decode(String.self, forKey: .status)
    }
}

enum WhiskyError: Error, Equatable {
    /// Exit 64: WhiskyCmd rejected the invocation (bad arguments or unknown subcommand).
    case invalidInvocation(String)
    /// Exit 1 without a log: a well-formed request failed (e.g. unknown bottle, Steam not installed).
    case failure(String)
    /// The Windows program exited non-zero; WhiskyCmd relays its code and points to the Wine log.
    case programExit(code: Int32, logPath: String?)
    case timedOut(seconds: TimeInterval)
    case unexpectedOutput(String)
}

/// Thin wrapper over WhiskyCmd's documented contract: 0 ok, 64 invalid invocation,
/// 1 domain failure, anything else is the Windows program's own exit code.
struct WhiskyCLI: Sendable {
    typealias Runner = @Sendable (URL, [String], TimeInterval) async throws -> ProcessResult

    let install: WhiskyInstall
    var runner: Runner = { try await ProcessRunner.run($0, $1, timeout: $2) }

    func games(bottle: String) async throws -> [SteamGame] {
        try decode(try await call(["games", bottle, "--json"], timeout: 30))
    }

    /// Covers WhiskyCmd's own wait for the Steam client (up to 90 s) plus the `-applaunch` hand-off.
    func launch(appId: Int, bottle: String) async throws -> LaunchConfirmation {
        try decode(try await call(["launch", String(appId), "--bottle", bottle, "--json"], timeout: 150))
    }

    /// Runs a program and waits for it to exit. `path` may be a macOS path or `C:\…`.
    func run(_ path: String, bottle: String, arguments: [String] = [], timeout: TimeInterval) async throws -> ProcessResult {
        try await call(["run", bottle, path] + (arguments.isEmpty ? [] : ["--"] + arguments), timeout: timeout)
    }

    /// Bottles as Whisky itself registers them; read-only.
    func bottles() -> [BottleInfo] {
        guard let id = install.bundleIdentifier else { return [] }
        return BottleReader.read(container: BottleReader.containerURL(bundleID: id))
    }

    private func call(_ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let result: ProcessResult
        do {
            result = try await runner(install.cmdURL, arguments, timeout)
        } catch ProcessError.timedOut(let seconds) {
            throw WhiskyError.timedOut(seconds: seconds)
        }
        if let error = Self.error(for: result) { throw error }
        return result
    }

    static func error(for result: ProcessResult) -> WhiskyError? {
        guard result.status != 0 else { return nil }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let log = logPath(in: result.stderr + result.stdout) {
            return .programExit(code: result.status, logPath: log)
        }
        switch result.status {
        case 64: return .invalidInvocation(message)
        case 1: return .failure(message)
        default: return .programExit(code: result.status, logPath: nil)
        }
    }

    static func logPath(in text: String) -> String? {
        guard let match = text.firstMatch(of: /(\/[^\s"']+\.log)\b/) else { return nil }
        return String(match.1)
    }

    /// Wine or Steam may print before the JSON; decode from the first `{` or `[`.
    private func decode<T: Decodable>(_ result: ProcessResult) throws -> T {
        let out = result.stdout
        guard let start = out.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let value = try? JSONDecoder().decode(T.self, from: Data(out[start...].utf8))
        else { throw WhiskyError.unexpectedOutput(String(out.prefix(500))) }
        return value
    }
}
