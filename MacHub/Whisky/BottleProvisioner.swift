import Foundation

/// Creates a new bottle for MacHub and lets Wine build its Windows folder. Never touches an existing bottle:
/// the name is made unique first, and `whisky create` refuses nothing it shouldn't.
struct BottleProvisioner: Sendable {
    typealias Runner = @Sendable (URL, [String], TimeInterval, [String: String]?) async throws -> ProcessResult

    enum Failure: Error, Equatable {
        case createFailed(String)
        case bootFailed(String)
        /// `whisky create` succeeded but the bottle never showed up in Whisky's list.
        case notRegistered(String)
    }

    let install: WhiskyInstall
    var runner: Runner = { try await ProcessRunner.run($0, $1, timeout: $2, environment: $3) }
    var bottles: @Sendable () -> [BottleInfo]

    init(install: WhiskyInstall, bottles: @escaping @Sendable () -> [BottleInfo], runner: Runner? = nil) {
        self.install = install
        self.bottles = bottles
        if let runner { self.runner = runner }
    }

    /// "MacHub Apps", or "MacHub Apps 2", … if that name is taken.
    static func uniqueName(_ base: String, taken: [String]) -> String {
        let used = Set(taken.map { $0.lowercased() })
        if !used.contains(base.lowercased()) { return base }
        var n = 2
        while used.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// `export KEY="value"` lines from `whisky shellenv`. PATH is dropped: WhiskyCmd 3.7.0 escapes its space
    /// inside quotes, which makes it unusable; MacHub calls wine64 by absolute path instead.
    static func environment(fromShellenv text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let match = line.firstMatch(of: /^export ([A-Z0-9_]+)="(.*)"$/) else { continue }
            let key = String(match.1)
            guard key != "PATH" else { continue }
            env[key] = String(match.2)
        }
        return env
    }

    /// Wine lives next to the bottles' libraries: ~/Library/Application Support/<bundle id>/Libraries/Wine/bin/wine64.
    var wine64: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/\(install.bundleIdentifier ?? WhiskyLocator.forkBundleID)/Libraries/Wine/bin/wine64")
    }

    /// Creates the bottle and runs `wineboot --init` in it. Returns the bottle once Whisky lists it with a drive_c.
    func provision(name: String, progress: @Sendable (Step) async -> Void = { _ in }) async throws -> BottleInfo {
        await progress(.creating)
        let created = try await runner(install.cmdURL, ["create", name], 120, nil)
        guard created.status == 0 else {
            throw Failure.createFailed(created.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        await progress(.booting)
        let shellenv = try await runner(install.cmdURL, ["shellenv", name], 30, nil)
        let env = Self.environment(fromShellenv: shellenv.stdout)
        guard env["WINEPREFIX"] != nil else { throw Failure.bootFailed("whisky shellenv gave no WINEPREFIX") }
        let boot = try await runner(wine64, ["wineboot", "--init"], 600, env)
        guard boot.status == 0 else { throw Failure.bootFailed(boot.stderr.suffix(400).description) }
        guard let bottle = bottles().first(where: { $0.name == name && $0.isRegistered }) else { throw Failure.notRegistered(name) }
        guard bottle.hasDriveC else { throw Failure.bootFailed("drive_c missing after wineboot") }
        return bottle
    }

    enum Step: Sendable { case creating, booting }
}
