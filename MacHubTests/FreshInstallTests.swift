import Foundation
import Testing
@testable import MacHub

/// A first run on a Mac that has never had MacHub: downloads the published engine, installs it into an empty folder
/// and creates a Windows environment there, exactly like Settings › Steam for Windows does. Opt-in (downloads 227 MB):
/// `TEST_RUNNER_MACHUB_FRESH_INSTALL=1 xcodebuild … test -only-testing:MacHubTests/FreshInstallTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACHUB_FRESH_INSTALL"] != nil))
struct FreshInstallTests {
    @Test func downloadsEngineAndCreatesEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "machub-fresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try #require(RuntimeManifest.bundled)
        let runtime = try await RuntimeManager(directory: root.appending(path: "Runtimes")).download(manifest) { _, _ in }
        #expect(try await RuntimeManager.check(runtime).hasPrefix("wine-"))
        let prefix = try await PrefixStore(directory: root.appending(path: "Prefixes"))
            .create(name: "Steam", role: .steam, runtime: runtime, takenNames: [])
        #expect(prefix.hasDriveC)
    }
}
