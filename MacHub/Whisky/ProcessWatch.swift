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

    /// Parses `ps -axo pid=,command=` output and returns the game's processes. Only the executable
    /// itself counts: the command must *start* with a Windows path (`C:\…`) whose folders include the
    /// game's install folder. Text in another process's arguments (a shell, a grep) never matches.
    static func matches(in psOutput: String, installFolder: String) -> [Match] {
        let folder = installFolder.lowercased()
        let ignored = /(?i)^(unins.*|vc_?redist.*|dxsetup|directx.*|dotnet.*|ue4prereq.*|crash.*)\.exe$/
        return psOutput.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { return nil }
            let command = trimmed[space...].trimmingCharacters(in: .whitespaces)
            // Wine shows a Windows program as its own Windows path: "C:\Program Files (x86)\…\game.exe args".
            guard let exe = command.firstMatch(of: /^(?i)([a-z]:\\[^:*?"<>|]*?\.exe)(\s|$)/) else { return nil }
            let components = exe.1.split(separator: "\\").map { $0.lowercased() }
            guard components.dropLast().contains(folder), !components.contains("_commonredist") else { return nil }
            let name = String(exe.1.split(separator: "\\").last ?? Substring(exe.1))
            guard name.firstMatch(of: ignored) == nil else { return nil }
            return Match(pid: pid, executable: name)
        }
    }

    static func snapshot() async -> String {
        (try? await ProcessRunner.run(URL(filePath: "/bin/ps"), ["-axo", "pid=,command="], timeout: 5).stdout) ?? ""
    }

    /// Polls until one of the game's processes appears, or gives up after `timeout`.
    static func waitForStart(installFolder: String, timeout: Duration = .seconds(180), interval: Duration = .seconds(2)) async -> [Match]? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            let found = matches(in: await snapshot(), installFolder: installFolder)
            if !found.isEmpty { return found }
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return nil }
        }
        return nil
    }

    /// Returns once none of the game's processes has been seen for two polls in a row.
    static func waitForExit(installFolder: String, interval: Duration = .seconds(3)) async {
        var misses = 0
        while misses < 2, !Task.isCancelled {
            try? await Task.sleep(for: interval)
            misses = matches(in: await snapshot(), installFolder: installFolder).isEmpty ? misses + 1 : 0
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
