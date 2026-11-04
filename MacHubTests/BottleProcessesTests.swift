import Foundation
import Testing
@testable import MacHub

/// Finding one bottle's Wine processes to stop a Steam stuck for days (Johan's Mac, 2026-11-04).
@Suite struct BottleProcessesTests {
    private let whisky = URL(filePath: "/Users/me/Library/Application Support/com.franke.Whisky/Libraries")
    private let machub = URL(filePath: "/Users/me/Library/Application Support/app.machub.MacHub/Runtimes")
    private let bottle = URL(filePath: "/Users/me/Library/Containers/com.franke.Whisky/Bottles/50B159DE")
    private let other = URL(filePath: "/Users/me/Library/Containers/com.franke.Whisky/Bottles/OTHER")

    @Test func onlyTheBottlesOwnWineProcesses() {
        let binaries: [Int32: String] = [
            1: whisky.path + "/Wine/lib/wine/x86_64-unix/wine",     // the stuck steam.exe
            2: whisky.path + "/Wine/bin/wineserver",                // its wineserver
            3: whisky.path + "/Wine/lib/wine/x86_64-unix/wine",     // a program in another bottle
            4: machub.path + "/1.0.6/wine/bin/wine",                // MacHub's engine, same WINEPREFIX by accident
            5: "/bin/zsh",                                          // a shell with WINEPREFIX exported
        ]
        let environments: [Int32: [String: String]] = [
            1: ["WINEPREFIX": bottle.path], 2: ["WINEPREFIX": bottle.path + "/"], 3: ["WINEPREFIX": other.path],
            4: ["WINEPREFIX": bottle.path], 5: ["WINEPREFIX": bottle.path],
        ]
        let found = ProcessWatch.processes(inPrefix: bottle, engineRoot: whisky, allPIDs: { [1, 2, 3, 4, 5] },
                                           binaryPath: { binaries[$0] }, environment: { environments[$0] })
        #expect(found == [1, 2])
    }

    @Test func readsTheEnvironmentLayoutOfProcArgs() {
        var bytes: [UInt8] = [2, 0, 0, 0]                                   // argc = 2
        for part in ["/path/wine", "", "", "wine", "steam.exe", "WINEPREFIX=/b", "LANG=fr_FR.UTF-8", "EMPTY="] {
            bytes += Array(part.utf8) + [0]
        }
        let environment = ProcessWatch.parseProcArgs(bytes)
        #expect(environment["WINEPREFIX"] == "/b")
        #expect(environment["LANG"] == "fr_FR.UTF-8")
        #expect(environment["EMPTY"] == "")
        #expect(environment["wine"] == nil && environment["steam.exe"] == nil, "arguments are not variables")
    }

    @Test func readsThisProcessesOwnEnvironment() {
        #expect(ProcessWatch.environment(of: getpid())?["HOME"] == ProcessInfo.processInfo.environment["HOME"])
    }
}

@Suite struct BottleOrphansTests {
    private let root = URL(filePath: "/W/Libraries")
    private let bottle = URL(filePath: "/B/bottle")

    private func orphans(_ processes: [Int32: (binary: String, start: TimeInterval)]) -> [Int32] {
        ProcessWatch.orphans(inPrefix: bottle, engineRoot: root, allPIDs: { Array(processes.keys).sorted() },
                             binaryPath: { processes[$0]?.binary }, environment: { _ in ["WINEPREFIX": "/B/bottle"] },
                             startTime: { processes[$0]?.start })
    }

    @Test func programsOlderThanTheirServerAreOrphans() {
        let wine = "/W/Libraries/Wine/lib/wine/x86_64-unix/wine", server = "/W/Libraries/Wine/bin/wineserver"
        // 66141: Steam from 10 days ago whose server died; 47379/47402: the new server and the Steam it serves.
        #expect(orphans([66141: (wine, 100), 66124: (wine, 99), 47379: (server, 1000), 47402: (wine, 1001)]) == [66124, 66141])
    }

    @Test func withoutAServerEveryProgramIsAnOrphan() {
        let wine = "/W/Libraries/Wine/lib/wine/x86_64-unix/wine"
        #expect(orphans([1: (wine, 1), 2: (wine, 2)]) == [1, 2])
    }

    @Test func aHealthyBottleHasNoOrphans() {
        let wine = "/W/Libraries/Wine/lib/wine/x86_64-unix/wine", server = "/W/Libraries/Wine/bin/wineserver"
        #expect(orphans([10: (server, 50), 11: (wine, 51), 12: (wine, 60)]).isEmpty)
    }
}
