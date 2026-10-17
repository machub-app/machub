import Foundation
import Testing
@testable import MacHub

/// Verbatim `WhiskyCmd --help` of the archived Whisky 2.3.5 installed on the dev Mac (captured 2026-10-17).
let help235 = """
OVERVIEW: A CLI interface for Whisky.

USAGE: whisky <subcommand>

OPTIONS:
  -h, --help              Show help information.

SUBCOMMANDS:
  list                    List existing bottles.
  create                  Create a new bottle.
  add                     Add an existing bottle.
  delete                  Delete an existing bottle from disk.
  remove                  Remove an existing bottle from Whisky.
  run                     Run a program with Whisky.
  shellenv                Prints export statements for a Bottle for eval.

  See 'whisky help <subcommand>' for detailed help.

"""

/// Verbatim `WhiskyCmd --help` of frankea Whisky 3.7.0 (com.franke.Whisky), captured 2026-10-17.
let helpFork = """
OVERVIEW: A CLI interface for Whisky.

Exit codes: 64 for a malformed invocation (unknown flags, missing or empty
arguments; printed with usage), 1 for a well-formed command that fails (no such
bottle, game not found, operation failed), and `run` and `launch` pass through
the launched program's own nonzero exit code.

USAGE: whisky <subcommand>

OPTIONS:
  -h, --help              Show help information.

SUBCOMMANDS:
  list                    List existing bottles.
  create                  Create a new bottle.
  add                     Add an existing bottle.
  delete                  Delete an existing bottle from disk.
  remove                  Remove an existing bottle from Whisky.
  run                     Run a program with Whisky.
  games                   List Steam games installed in a bottle.
  launch                  Launch a Steam game by App ID.
  shortcut                Create a macOS app shortcut for a Windows program.
  shellenv                Prints export statements for a Bottle for eval.

  See 'whisky help <subcommand>' for detailed help.

"""

private let appsDir = URL(filePath: "/Fake/Applications")
private let oldApp = appsDir.appending(path: "Whisky 2.3.5.app")
private let forkApp = appsDir.appending(path: "Whisky.app")

private func locator(
    executables: [URL],
    helps: [URL: String],
    forkByBundleID: URL? = nil,
    apps: [URL] = []
) -> WhiskyLocator {
    let executablePaths = Set(executables.map(\.path))
    let helpByPath = Dictionary(uniqueKeysWithValues: helps.map { ($0.key.path, $0.value) })
    return WhiskyLocator(
        isExecutable: { executablePaths.contains($0.path) },
        appURLForBundleID: { $0 == WhiskyLocator.forkBundleID ? forkByBundleID : nil },
        appsIn: { $0 == appsDir ? apps : [] },
        help: { url in
            guard let text = helpByPath[url.path] else { throw ProcessError.timedOut(seconds: 0) }
            return text
        },
        bundleInfo: { app in
            app.path == oldApp.path ? ("com.isaacmarovitz.Whisky", "2.3.5") : (WhiskyLocator.forkBundleID, "3.7.0")
        },
        searchDirs: [appsDir]
    )
}

@Suite struct WhiskyLocatorTests {
    @Test func parsesSubcommandsOfArchivedWhisky() {
        #expect(WhiskyLocator.parseSubcommands(help235) == ["list", "create", "add", "delete", "remove", "run", "shellenv"])
    }

    @Test func parsesForkSubcommands() {
        let names = WhiskyLocator.parseSubcommands(helpFork)
        #expect(names.isSuperset(of: ["games", "launch", "run"]))
        #expect(!names.contains("see"))
    }

    @Test func archivedWhiskyIsOutdated() async {
        let cmd = WhiskyLocator.cmd(in: oldApp)
        let status = await locator(executables: [cmd], helps: [cmd: help235], apps: [oldApp]).locate(customPath: nil)
        guard case .outdated(let install, let missing) = status else {
            Issue.record("expected outdated, got \(status)")
            return
        }
        #expect(missing == ["games", "launch"])
        #expect(install.version == "2.3.5")
        #expect(install.bundleIdentifier == "com.isaacmarovitz.Whisky")
    }

    @Test func capabilitiesWinOverNameAndOrder() async {
        let old = WhiskyLocator.cmd(in: oldApp), fork = WhiskyLocator.cmd(in: forkApp)
        let status = await locator(
            executables: [old, fork], helps: [old: help235, fork: helpFork], apps: [oldApp, forkApp]
        ).locate(customPath: nil)
        guard case .ready(let install) = status else {
            Issue.record("expected ready, got \(status)")
            return
        }
        #expect(install.cmdURL == fork)
        #expect(install.version == "3.7.0")
    }

    @Test func findsForkThroughLaunchServices() async {
        let elsewhere = URL(filePath: "/Volumes/Games/Whisky.app")
        let cmd = WhiskyLocator.cmd(in: elsewhere)
        let status = await locator(executables: [cmd], helps: [cmd: helpFork], forkByBundleID: elsewhere)
            .locate(customPath: nil)
        guard case .ready(let install) = status else {
            Issue.record("expected ready, got \(status)")
            return
        }
        #expect(install.appURL?.path == elsewhere.path)
    }

    @Test func nothingInstalledIsNotFound() async {
        let status = await locator(executables: [], helps: [:]).locate(customPath: nil)
        guard case .notFound(let searched) = status else {
            Issue.record("expected notFound, got \(status)")
            return
        }
        #expect(searched.contains(URL(filePath: "/usr/local/bin/whisky")))
    }

    @Test func unusableCustomPathsAreReported() async {
        let missing = await locator(executables: [], helps: [:]).locate(customPath: "/nope/WhiskyCmd")
        #expect(missing == .invalidCustomPath(URL(filePath: "/nope/WhiskyCmd"), reason: "Not an executable file."))

        let broken = URL(filePath: "/opt/broken/WhiskyCmd")
        let failing = await locator(executables: [broken], helps: [:]).locate(customPath: broken.path)
        #expect(failing == .invalidCustomPath(broken, reason: "Running it with --help failed."))
    }

    @Test func customPathSkipsAutomaticDetection() async {
        let custom = URL(filePath: "/opt/whisky/WhiskyCmd"), fork = WhiskyLocator.cmd(in: forkApp)
        let status = await locator(
            executables: [custom, fork], helps: [custom: help235, fork: helpFork], apps: [forkApp]
        ).locate(customPath: custom.path)
        guard case .outdated(let install, _) = status else {
            Issue.record("expected outdated, got \(status)")
            return
        }
        #expect(install.cmdURL == custom)
    }
}

@Suite struct ProcessRunnerTests {
    @Test func capturesOutputAndStatus() async throws {
        let result = try await ProcessRunner.run(URL(filePath: "/bin/sh"), ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result == ProcessResult(status: 3, stdout: "out\n", stderr: "err\n"))
    }

    @Test func killsAfterTimeout() async {
        await #expect(throws: ProcessError.timedOut(seconds: 0.2)) {
            try await ProcessRunner.run(URL(filePath: "/bin/sleep"), ["5"], timeout: 0.2)
        }
    }
}
