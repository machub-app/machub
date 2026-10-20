import Foundation
import Testing
@testable import MacHub

/// Creates the real Mac shortcut for an installed Steam game, through the same path as the game menu's
/// "Create Mac Shortcut". Opt-in, because it writes into `~/Applications/MacHub Games`:
/// `TEST_RUNNER_MACHUB_SHORTCUT_APP_ID=284160 xcodebuild … test -only-testing:MacHubTests/RealShortcutTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACHUB_SHORTCUT_APP_ID"] != nil))
@MainActor
struct RealShortcutTests {
    @Test func createsShortcutForInstalledGame() async throws {
        let appID = try #require(ProcessInfo.processInfo.environment["MACHUB_SHORTCUT_APP_ID"].flatMap(Int.init))
        let store = LibraryStore()
        await store.refreshEngine()
        let title = try #require(store.installedTitles.first { $0.steamAppID == appID }, "the game should be installed in a MacHub prefix")
        await store.createMacShortcut(for: title)

        let app = MacShortcut.folder.appending(path: MacShortcut.bundleName(for: title.name))
        #expect(MacShortcut.isShortcut(app))
        #expect(FileManager.default.fileExists(atPath: app.appending(path: "Contents/Resources/AppIcon.icns").path))
        let verify = try await ProcessRunner.run(URL(filePath: "/usr/bin/codesign"), ["--verify", "--strict", app.path], timeout: 30)
        #expect(verify.status == 0, "\(verify.stderr)")
    }
}
