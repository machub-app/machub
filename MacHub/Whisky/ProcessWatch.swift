import Foundation

/// Confirms that a launched Windows game is really running: Wine processes keep their Windows
/// command line (`C:\…\steamapps\common\<folder>\game.exe`), so a game counts as started only
/// when a process from its own install folder shows up. Steam, its web helper and the
/// redistributable installers Steam runs on first launch never count.
enum ProcessWatch {
    struct Match: Equatable, Sendable {
        let pid: Int32
        let executable: String
    }

    /// What to look for: a Steam game's processes (anything from its install folder) or one program by name.
    enum Target: Equatable, Sendable {
        case installFolder(String)
        case executable(String)
        /// A program whose command line also mentions `argument` (msiexec running one given package).
        case executableWithArgument(String, String)
    }

    typealias Snapshot = @Sendable () async -> String

    /// Parses `ps -axo pid=,command=` output and returns the game's processes. Only the executable
    /// itself counts: the command must *start* with a Windows path (`C:\…`) whose folders include the
    /// game's install folder. Text in another process's arguments (a shell, a grep) never matches.
    static func matches(in psOutput: String, installFolder: String) -> [Match] {
        matches(in: psOutput, target: .installFolder(installFolder))
    }

    static func matches(in psOutput: String, target: Target) -> [Match] {
        let ignored = /(?i)^(unins.*|vc_?redist.*|dxsetup|directx.*|dotnet.*|ue4prereq.*|crash.*)\.exe$/
        return psOutput.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { return nil }
            let command = trimmed[space...].trimmingCharacters(in: .whitespaces)
            // Wine shows a Windows program as its own Windows path: "C:\Program Files (x86)\…\game.exe args".
            guard let exe = command.firstMatch(of: /^(?i)([a-z]:\\[^:*?"<>|]*?\.exe)(\s|$)/) else { return nil }
            let parts = exe.1.split(separator: "\\")
            let components = parts.map { $0.lowercased() }
            let name = String(parts.last ?? Substring(exe.1))
            switch target {
            case .installFolder(let folder):
                guard components.dropLast().contains(folder.lowercased()), !components.contains("_commonredist") else { return nil }
                guard name.firstMatch(of: ignored) == nil else { return nil }
            case .executable(let wanted):
                guard name.caseInsensitiveCompare(wanted) == .orderedSame else { return nil }
            case .executableWithArgument(let wanted, let argument):
                guard name.caseInsensitiveCompare(wanted) == .orderedSame,
                      command[exe.range.upperBound...].localizedCaseInsensitiveContains(argument) else { return nil }
            }
            return Match(pid: pid, executable: name)
        }
    }

    @Sendable static func snapshot() async -> String {
        (try? await ProcessRunner.run(URL(filePath: "/bin/ps"), ["-axo", "pid=,command="], timeout: 5).stdout) ?? ""
    }

    /// Polls until one of the game's processes appears, or gives up after `timeout`.
    static func waitForStart(installFolder: String, timeout: Duration = .seconds(180), interval: Duration = .seconds(2)) async -> [Match]? {
        await waitForStart(.installFolder(installFolder), timeout: timeout, interval: interval)
    }

    static func waitForProgram(named name: String, timeout: Duration, interval: Duration = .seconds(1)) async -> [Match]? {
        await waitForStart(.executable(name), timeout: timeout, interval: interval)
    }

    static func waitForStart(_ target: Target, timeout: Duration, interval: Duration, snapshot: Snapshot = snapshot) async -> [Match]? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            let found = matches(in: await snapshot(), target: target)
            if !found.isEmpty { return found }
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return nil }
        }
        return nil
    }

    /// Returns once none of the game's processes has been seen for two polls in a row.
    static func waitForExit(installFolder: String, interval: Duration = .seconds(3)) async {
        await waitForExit(.installFolder(installFolder), interval: interval)
    }

    static func waitForExit(_ target: Target, interval: Duration, snapshot: Snapshot = snapshot) async {
        var misses = 0
        while misses < 2, !Task.isCancelled {
            try? await Task.sleep(for: interval)
            misses = matches(in: await snapshot(), target: target).isEmpty ? misses + 1 : 0
        }
    }

    /// Whisky writes one Wine log per launch; the newest is the one to show on failure.
    static func latestWineLog(bundleID: String = WhiskyLocator.forkBundleID) -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/\(bundleID)")
        let logs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return logs.filter { $0.pathExtension == "log" }.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
    }
}
