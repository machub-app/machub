import Foundation
import Testing
@testable import MacHub

private let install = WhiskyInstall(
    cmdURL: URL(filePath: "/Applications/Whisky.app/Contents/Resources/WhiskyCmd"),
    appURL: nil, bundleIdentifier: "com.franke.Whisky", version: "3.7.0", subcommands: ["games", "launch", "run"]
)

/// A CLI whose runner checks the arguments it receives and replies with a canned result.
private func cli(expecting arguments: [String]? = nil, reply: ProcessResult) -> WhiskyCLI {
    WhiskyCLI(install: install) { url, args, _ in
        #expect(url == install.cmdURL)
        if let arguments { #expect(args == arguments) }
        return reply
    }
}

@Suite struct WhiskyCLITests {
    // Verbatim shape of WhiskyCmd 3.7.0 `games --json` (2026-10-18): appId is a STRING.
    @Test func decodesInstalledGames() async throws {
        let json = """
        [
          {
            "appId" : "244210",
            "installPath" : "/Users/me/Library/Containers/com.franke.Whisky/Bottles/X/drive_c/Program Files (x86)/Steam/steamapps/common/assettocorsa",
            "name" : "Assetto Corsa"
          }
        ]
        """
        let games = try await cli(expecting: ["games", "Steam", "--json"], reply: .init(status: 0, stdout: json, stderr: ""))
            .games(bottle: "Steam")
        #expect(games.count == 1)
        #expect(games.first?.appId == 244210)
        #expect(games.first?.installPath.hasSuffix("common/assettocorsa") == true)
    }

    @Test func launchConfirmationWithStringAppID() throws {
        let json = #"{"appId":"244210","bottle":"MacHub Steam","status":"launched"}"#
        #expect(try JSONDecoder().decode(LaunchConfirmation.self, from: Data(json.utf8))
            == LaunchConfirmation(appId: 244210, bottle: "MacHub Steam", status: "launched"))
    }

    @Test func numericAppIDIsAlsoAccepted() throws {
        let json = #"[{"appId":244210,"installPath":"/x","name":"Assetto Corsa"}]"#
        #expect(try JSONDecoder().decode([SteamGame].self, from: Data(json.utf8)).first?.appId == 244210)
    }

    @Test func emptyLibraryIsNotAnError() async throws {
        let games = try await cli(reply: .init(status: 0, stdout: "[\n\n]\n", stderr: "")).games(bottle: "Steam")
        #expect(games.isEmpty)
    }

    @Test func launchSkipsNoiseBeforeJSON() async throws {
        let out = "wine: configuration updated\n{\n  \"appId\" : 244210,\n  \"bottle\" : \"Steam\",\n  \"status\" : \"launched\"\n}\n"
        let confirmation = try await cli(
            expecting: ["launch", "244210", "--bottle", "Steam", "--json"], reply: .init(status: 0, stdout: out, stderr: "")
        ).launch(appId: 244210, bottle: "Steam")
        #expect(confirmation == LaunchConfirmation(appId: 244210, bottle: "Steam", status: "launched"))
    }

    @Test func runPassesProgramArgumentsAfterSeparator() async throws {
        _ = try await cli(
            expecting: ["run", "Steam", #"C:\windows\notepad.exe"#, "--", "readme.txt"],
            reply: .init(status: 0, stdout: "", stderr: "")
        ).run(#"C:\windows\notepad.exe"#, bottle: "Steam", arguments: ["readme.txt"], timeout: 5)
    }

    @Test func unknownBottleIsADomainFailure() async {
        // Exact stderr of WhiskyCmd for a missing bottle.
        let reply = ProcessResult(status: 1, stdout: "", stderr: "Error: A bottle with that name doesn't exist.\n")
        await #expect(throws: WhiskyError.failure("Error: A bottle with that name doesn't exist.")) {
            try await cli(reply: reply).games(bottle: "Nope")
        }
    }

    @Test func badInvocationIs64() async {
        let reply = ProcessResult(status: 64, stdout: "", stderr: "Error: Unexpected argument 'games'\n")
        await #expect(throws: WhiskyError.invalidInvocation("Error: Unexpected argument 'games'")) {
            try await cli(reply: reply).games(bottle: "Steam")
        }
    }

    @Test func programExitKeepsCodeAndLog() async {
        let reply = ProcessResult(
            status: 3, stdout: "",
            stderr: "Program exited with code 3. Log: /Users/me/Library/Logs/com.franke.Whisky/2026-10-17.log\n"
        )
        await #expect(throws: WhiskyError.programExit(code: 3, logPath: "/Users/me/Library/Logs/com.franke.Whisky/2026-10-17.log")) {
            try await cli(reply: reply).run("/tmp/x.exe", bottle: "Steam", timeout: 5)
        }
    }

    @Test func nonZeroWithoutLogStillReportsCode() {
        #expect(WhiskyCLI.error(for: .init(status: 255, stdout: "", stderr: "")) == .programExit(code: 255, logPath: nil))
        #expect(WhiskyCLI.error(for: .init(status: 0, stdout: "", stderr: "noise")) == nil)
    }

    @Test func garbageOutputIsReported() async {
        await #expect(throws: WhiskyError.unexpectedOutput("Launched 244210 in Steam\n")) {
            try await cli(reply: .init(status: 0, stdout: "Launched 244210 in Steam\n", stderr: ""))
                .launch(appId: 244210, bottle: "Steam")
        }
    }

    @Test func timeoutsAreMapped() async {
        let slow = WhiskyCLI(install: install) { _, _, timeout in throw ProcessError.timedOut(seconds: timeout) }
        await #expect(throws: WhiskyError.timedOut(seconds: 150)) {
            try await slow.launch(appId: 1, bottle: "Steam")
        }
    }
}

@Suite struct ProcessWatchTests {
    // Shape of real `ps -axo pid=,command=` lines for Wine processes (observed 2026-10-18).
    let ps = """
      52590 C:\\windows\\system32\\services.exe
      52693 C:\\Program Files (x86)\\Steam\\steam.exe
      52702 C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\steamwebhelper.exe -nocrashdialog
      60001 C:\\Program Files (x86)\\Steam\\steamapps\\common\\assettocorsa\\_CommonRedist\\DirectX\\Jun2010\\DXSETUP.exe /silent
      60002 C:\\Program Files (x86)\\Steam\\steamapps\\common\\assettocorsa\\AssettoCorsa.exe
      60003 C:\\Program Files (x86)\\Steam\\steamapps\\common\\AssettoCorsa\\acs.exe -race
      60004 C:\\Program Files (x86)\\Steam\\steamapps\\common\\othergame\\game.exe
      47974 /Users/me/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx
    """

    @Test func findsOnlyTheGamesOwnProcesses() {
        let found = ProcessWatch.matches(in: ps, installFolder: "assettocorsa")
        #expect(found == [.init(pid: 60002, executable: "AssettoCorsa.exe"), .init(pid: 60003, executable: "acs.exe")])
    }

    @Test func steamAloneIsNotAGame() {
        let onlySteam = ps.split(separator: "\n").filter { !$0.contains("assettocorsa") && !$0.contains("AssettoCorsa") }.joined(separator: "\n")
        #expect(ProcessWatch.matches(in: onlySteam, installFolder: "assettocorsa").isEmpty)
    }

    @Test func textInAnotherProcessArgumentsNeverCounts() {
        // Real false positive of 2026-10-18: a monitoring shell whose arguments mention the folder and ".exe".
        let shell = #"  56863 /bin/zsh -c n=$(ps -axo pid=,command= | grep -i 'common\\assettocorsa\\' | sed -E 's/.*\\([^\\]+\.exe).*/\1/')"#
        let launcherArg = #"  70000 C:\Program Files (x86)\Steam\steam.exe -applaunch 244210 C:\x\common\assettocorsa\acs.exe"#
        #expect(ProcessWatch.matches(in: shell, installFolder: "assettocorsa").isEmpty)
        #expect(ProcessWatch.matches(in: launcherArg, installFolder: "assettocorsa").isEmpty)
    }

    @Test func redistributableInstallersDoNotCount() {
        let redist = "  1 C:\\Steam\\steamapps\\common\\assettocorsa\\_CommonRedist\\vcredist\\2015\\vc_redist.x64.exe /q"
        #expect(ProcessWatch.matches(in: redist, installFolder: "assettocorsa").isEmpty)
    }
}
