import Foundation
import Testing
@testable import MacHub

struct AppUpdatesTests {
    static let listing = Data("""
    [
      {"tag_name": "runtime-1.0.6", "draft": false, "prerelease": false, "html_url": "https://github.com/machub-app/machub/releases/tag/runtime-1.0.6",
       "assets": [{"name": "MacHubRuntime-1.0.6.tar.xz", "browser_download_url": "https://example.com/r", "size": 1}]},
      {"tag_name": "v0.10.0", "draft": true, "prerelease": false, "html_url": "https://github.com/machub-app/machub/releases/tag/v0.10.0",
       "assets": [{"name": "MacHub.dmg", "browser_download_url": "https://example.com/draft", "size": 1}]},
      {"tag_name": "v0.9.0", "draft": false, "prerelease": true, "html_url": "https://github.com/machub-app/machub/releases/tag/v0.9.0",
       "assets": [{"name": "MacHub.dmg", "browser_download_url": "https://example.com/pre", "size": 1}]},
      {"tag_name": "v0.3.0", "name": "MacHub 0.3.0", "body": "Notes", "draft": false, "prerelease": false,
       "html_url": "https://github.com/machub-app/machub/releases/tag/v0.3.0",
       "assets": [{"name": "MacHub.dmg", "browser_download_url": "https://example.com/latest.dmg", "size": 10},
                  {"name": "MacHub-0.3.0.dmg", "browser_download_url": "https://example.com/0.3.0.dmg", "size": 3900000},
                  {"name": "MacHub-0.3.0.dmg.sha256", "browser_download_url": "https://example.com/0.3.0.sha256", "size": 90}]},
      {"tag_name": "v0.2.0", "draft": false, "prerelease": false, "html_url": "https://github.com/machub-app/machub/releases/tag/v0.2.0",
       "assets": [{"name": "MacHub-0.2.0.dmg", "browser_download_url": "https://example.com/0.2.0.dmg", "size": 1}]}
    ]
    """.utf8)

    @Test func picksNewestPublishedAppRelease() throws {
        let release = try #require(try AppUpdates.newestRelease(in: Self.listing))
        #expect(release.version == "0.3.0")
        #expect(release.dmg.absoluteString == "https://example.com/0.3.0.dmg")
        #expect(release.checksum?.absoluteString == "https://example.com/0.3.0.sha256")
        #expect(release.dmgSize == 3_900_000)
    }

    @Test func comparesVersionsNumerically() {
        #expect(AppUpdates.isNewer("0.10.0", than: "0.9.1"))
        #expect(AppUpdates.isNewer("0.2.1", than: "0.2.0"))
        #expect(!AppUpdates.isNewer("0.2.0", than: "0.2.0"))
        #expect(!AppUpdates.isNewer("0.1.9", than: "0.2.0"))
    }

    @Test func swapScriptReplacesTheAppAndKeepsNothingElse() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "machub-swap-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let old = dir.appending(path: "Apps/MacHub it's.app"), new = dir.appending(path: "staged/MacHub.app")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try "old".write(to: old.appending(path: "v"), atomically: true, encoding: .utf8)
        try "new".write(to: new.appending(path: "v"), atomically: true, encoding: .utf8)
        // A pid that has already exited, and no "open" at the end (it would launch Finder on a fake app).
        let script = UpdateInstaller.swapScript(old: old, new: new, pid: 999_999).replacingOccurrences(of: "\nopen ", with: "\n: ")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run(); process.waitUntilExit()
        #expect(try String(contentsOf: old.appending(path: "v"), encoding: .utf8) == "new")
        #expect(!fm.fileExists(atPath: new.path))
        #expect(!fm.fileExists(atPath: old.path + ".previous"))
    }
}

/// Talks to the real GitHub: finds the newest release and stages it exactly as an update would. Opt-in:
/// `TEST_RUNNER_MACHUB_UPDATE_CHECK=1 xcodebuild … test -only-testing:MacHubTests/RealUpdateTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACHUB_UPDATE_CHECK"] != nil))
struct RealUpdateTests {
    @Test func stagesTheNewestRelease() async throws {
        let release = try #require(try await AppUpdates.fetchNewest())
        #expect(release.checksum != nil)
        let staged = try await UpdateInstaller.stage(release) { _ in }
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        let info = try #require(NSDictionary(contentsOf: staged.appending(path: "Contents/Info.plist")))
        #expect(info["CFBundleShortVersionString"] as? String == release.version)
    }
}

struct UpdateScheduleTests {
    @Test @MainActor func checksAtLaunchThenHourly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppUpdater.isDue(lastCheck: nil, now: now))
        #expect(!AppUpdater.isDue(lastCheck: now.addingTimeInterval(-59 * 60), now: now))
        #expect(AppUpdater.isDue(lastCheck: now.addingTimeInterval(-60 * 60), now: now))
        // A clock set back must not block checks forever.
        #expect(AppUpdater.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }
}
