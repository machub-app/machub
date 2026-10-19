import Foundation
import Testing
@testable import MacHub

/// The embedded engine end to end on this Mac, without Whisky. Opt-in, because it installs the runtime into
/// MacHub's real folder and opens Notepad:
/// `TEST_RUNNER_MACHUB_ENGINE_ARCHIVE=/path/MacHubRuntime-1.0.0.tar.xz xcodebuild … test -only-testing:MacHubTests/RealEngineTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACHUB_ENGINE_ARCHIVE"] != nil), .serialized)
struct RealEngineTests {
    static let archive = URL(filePath: ProcessInfo.processInfo.environment["MACHUB_ENGINE_ARCHIVE"] ?? "/dev/null")

    private func installedRuntime() async throws -> WineRuntime {
        let manifest = try #require(RuntimeManifest.bundled, "the app should ship runtime-manifest.json")
        return try await RuntimeManager.live.install(archive: Self.archive, manifest: manifest)
    }

    @Test func installsAndStartsWine() async throws {
        let runtime = try await installedRuntime()
        #expect(runtime.info.components.contains { $0.name == "wine" || $0.name == "winecx" })
        #expect(runtime.info.component("dxmt") != nil && runtime.info.component("dxvk") != nil)
        let version = try await RuntimeManager.check(runtime)
        #expect(version.hasPrefix("wine-"))
    }

    @Test func createsPrefixAndOpensNotepad() async throws {
        let runtime = try await installedRuntime()
        let store = PrefixStore.live
        let prefix: InstalledPrefix
        if let existing = store.all().first(where: { $0.settings.role == .apps && $0.hasDriveC }) {
            prefix = existing
        } else {
            prefix = try await store.create(name: "Applications", role: .apps, runtime: runtime, takenNames: [])
        }
        #expect(prefix.hasDriveC)
        #expect(FileManager.default.fileExists(atPath: prefix.url.appending(path: "drive_c/windows/system32/notepad.exe").path))

        let engine = EmbeddedWineEngine(runtime: runtime)
        let run = Task.detached {
            try await engine.run(#"C:\windows\system32\notepad.exe"#, bottle: prefix.name, arguments: [], timeout: 120)
        }
        let seen = await ProcessWatch.waitForProgram(named: "notepad.exe", timeout: .seconds(60), interval: .milliseconds(500))
        #expect(seen != nil, "notepad.exe never appeared in the process list")
        try await engine.stopAll(in: prefix.name)
        _ = try? await run.value
        await ProcessWatch.waitForExit(.executable("notepad.exe"), interval: .seconds(1))
    }
}

/// Installs Steam for Windows in MacHub's Steam prefix with the app's own code and leaves it running for the user
/// to sign in. Opt-in: downloads Valve's installer. `TEST_RUNNER_MACHUB_ENGINE_STEAM=1 xcodebuild … test
/// -only-testing:MacHubTests/RealSteamEngineTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACHUB_ENGINE_STEAM"] == "1"))
struct RealSteamEngineTests {
    @MainActor @Test func setsUpAndStartsSteam() async throws {
        let store = LibraryStore()
        await store.refreshEngine()
        guard case .ready = store.engineState else { throw TestFailure("engine not ready: \(store.engineState)") }
        await store.setUpSteam()
        #expect(store.steamSetup == .waitingForSignIn, "setup ended in \(String(describing: store.steamSetup))")
        let prefix = try #require(store.steamPrefix)
        #expect(SteamLibrary.steamRoot(inPrefix: prefix.url) != nil)
        #expect(store.steamBottle?.engine == .embedded)
    }
}
