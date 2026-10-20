import Foundation
import Testing
@testable import MacHub

struct EpicTests {
    @Test func readsGamesAndArtwork() {
        let json = Data(#"""
        [{"app_name":"Fortnite","app_title":"Fortnite","metadata":{"keyImages":[
            {"type":"DieselGameBoxTall","url":"https://cdn.epic/tall.jpg"},{"type":"DieselGameBox","url":"https://cdn.epic/wide.jpg"}]},"dlcs":[]},
         {"app_name":"Sugar","app_title":"Sugar Game","metadata":{"keyImages":[{"type":"Thumbnail","url":"https://cdn.epic/thumb.jpg"}]}},
         {"app_title":"No id"}]
        """#.utf8)
        let games = Legendary.parseGames(json)
        #expect(games.map(\.appName) == ["Fortnite", "Sugar"])
        #expect(games[0].coverURL?.absoluteString == "https://cdn.epic/tall.jpg" && games[0].headerURL?.absoluteString == "https://cdn.epic/wide.jpg")
        #expect(games[1].coverURL?.absoluteString == "https://cdn.epic/thumb.jpg")
        let title = Title(epic: games[0], install: nil)
        #expect(title.id == "epic:Fortnite" && title.epicAppName == "Fortnite" && title.availability == .owned && !title.canLaunch)
    }

    @Test func readsInstalledGamesAndProgress() {
        let json = Data(#"[{"app_name":"Sugar","install_path":"/tmp/Sugar","executable":"Sugar.exe","title":"Sugar Game"}]"#.utf8)
        #expect(Legendary.parseInstalled(json)["Sugar"]?.installPath == "/tmp/Sugar")
        #expect(Legendary.progress(in: "[DLManager] INFO: = Progress: 42.50% (85/200), Running for 00:00:10") == 0.425)
        #expect(Legendary.progress(in: "other line") == nil)
    }

    @Test func extractsTheAuthorizationCode() {
        #expect(Legendary.authorizationCode(from: #"{"redirectUrl":"https://x","authorizationCode":"0a1b2c3d","exchangeCode":null}"#) == "0a1b2c3d")
        #expect(Legendary.authorizationCode(from: "  \"0a1b2c3d\" \n") == "0a1b2c3d")
    }

    @Test func epicLaunchesWatchTheInstallFolder() {
        let route = LaunchPlan.Route.epic(appName: "Sugar")
        #expect(route.watchesInstallFolder && !route.isSteam)
        #expect(LaunchTimeline.steps(for: route, steamAlreadyRunning: false) == [.prepare, .checkBottle, .handOff, .waitForGame, .running])
    }
}

/// Downloads the pinned Legendary build and runs it. Opt-in: `TEST_RUNNER_MACHUB_EPIC=1 xcodebuild … test -only-testing:MacHubTests/RealEpicTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACHUB_EPIC"] != nil))
struct RealEpicTests {
    @Test func downloadsAndRunsLegendary() async throws {
        try await Legendary.installTool()
        #expect(Legendary.isInstalled)
        let version = try await Legendary.run(["--version"], timeout: 60)
        #expect(version.status == 0 && (version.stdout + version.stderr).contains(Legendary.version))
        // Signed out, listing must fail cleanly rather than hang.
        if Legendary.accountName() == nil {
            let list = try await Legendary.run(["list", "--json"], timeout: 60)
            #expect(list.status != 0)
        }
    }
}
