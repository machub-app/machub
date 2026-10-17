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
    // Shape from frankea WhiskyCmd `games --json`: pretty-printed, sorted keys.
    @Test func decodesInstalledGames() async throws {
        let json = """
        [
          {
            "appId" : 244210,
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
