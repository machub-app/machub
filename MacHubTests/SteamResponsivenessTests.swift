import Foundation
import Testing
@testable import MacHub

/// Steam for Windows that stops taking launch requests, and Steam on two engines at once (Johan's Mac, 2026-10-20).
@MainActor @Suite struct SteamResponsivenessTests {
    private let ps = """
      51832 C:\\Program Files (x86)\\Steam\\steam.exe -applaunch 244210
      60001 C:\\Program Files (x86)\\Steam\\steam.exe
    """

    @Test func eachSteamBelongsToItsOwnEngine() {
        let whisky = URL(filePath: "/Users/me/Library/Application Support/com.franke.Whisky/Libraries")
        let machub = URL(filePath: "/Users/me/Library/Application Support/app.machub.MacHub/Runtimes")
        let binaries: (Int32) -> String? = { pid in
            pid == 51832 ? whisky.path + "/Wine/bin/wine64-preloader" : nil
        }
        #expect(ProcessWatch.isSteamRunning(in: ps, engineRoot: whisky, binaryPath: binaries))
        #expect(!ProcessWatch.isSteamRunning(in: ps, engineRoot: machub, binaryPath: binaries),
                "Whisky's Steam must not make MacHub think its own Steam is running")
    }

    final class Box: @unchecked Sendable {
        var restarted = false
        var log: Int64? = 100
        var handoffs = 0
        var looks = 0
    }

    private func runner(_ box: Box, gameAfterRestart: Bool, logGrows: Bool) -> LaunchRunner {
        var runner = LaunchRunner { _ in box.handoffs += 1 }
        runner.pollInterval = .milliseconds(10)
        runner.exitInterval = .milliseconds(10)
        runner.crashThreshold = .zero
        runner.steamAnswerTimeout = .milliseconds(150)
        runner.steamTimeout = .seconds(1)
        runner.steamIsRunning = { true }
        runner.steamActivity = {
            if logGrows, box.handoffs > 0 { box.log = 200 }
            return box.log
        }
        runner.restartSteam = { box.restarted = true }
        let game = "70000 C:\\Steam\\steamapps\\common\\assettocorsa\\AssettoCorsa.exe"
        runner.snapshot = {
            // The game appears only once Steam took the request (after a restart, or right away when it answers).
            guard box.restarted || (logGrows && box.handoffs > 0) else { return "" }
            box.looks += 1
            return box.looks < 4 ? game : ""
        }
        return runner
    }

    @Test func aSilentSteamIsRestartedAndTheGameStarts() async {
        let box = Box()
        var states: [LibraryStore.LaunchState] = []
        await runner(box, gameAfterRestart: true, logGrows: false)
            .run(LaunchPlan(route: .steam(appID: 244210), bottle: "MacHub Steam", target: .installFolder("assettocorsa"))) { states.append($0) }
        #expect(box.restarted)
        #expect(box.handoffs == 2, "the launch request is sent again after the restart")
        #expect(states.contains(.restartingSteam))
        #expect(states.contains(.running("AssettoCorsa.exe")))
    }

    @Test func aSteamThatLogsTheRequestIsLeftAlone() async {
        let box = Box()
        var states: [LibraryStore.LaunchState] = []
        await runner(box, gameAfterRestart: false, logGrows: true)
            .run(LaunchPlan(route: .steam(appID: 244210), bottle: "MacHub Steam", target: .installFolder("assettocorsa"))) { states.append($0) }
        #expect(!box.restarted)
        #expect(!states.contains(.restartingSteam))
        #expect(states.contains(.running("AssettoCorsa.exe")))
    }

    @Test func withoutALogNothingIsRestarted() async {
        let box = Box()
        box.log = nil
        var runner = runner(box, gameAfterRestart: false, logGrows: false)
        runner.startTimeout = .milliseconds(200)
        var states: [LibraryStore.LaunchState] = []
        await runner.run(LaunchPlan(route: .steam(appID: 244210), bottle: "MacHub Steam", target: .installFolder("assettocorsa"))) { states.append($0) }
        #expect(!box.restarted, "no log proves nothing: MacHub never quits Steam on a guess")
    }
}
