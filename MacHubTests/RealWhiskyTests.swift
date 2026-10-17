import Foundation
import Testing
@testable import MacHub

/// Read-only checks against the Whisky installed on this Mac. Opt-in so the unit suite stays hermetic:
/// `TEST_RUNNER_MACHUB_INTEGRATION=1 xcodebuild … test`. Never creates, changes or launches anything:
/// every call below either only reads, or targets a bottle that doesn't exist (rejected before any launch).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACHUB_INTEGRATION"] == "1"))
struct RealWhiskyTests {
    static let missingBottle = "MacHub-NoSuchBottle"
    static let missingBottleError = WhiskyError.failure("Error: A bottle with that name doesn't exist.")

    private func realCLI() async throws -> WhiskyCLI {
        let status = await WhiskyLocator.live.locate(customPath: nil)
        guard case .ready(let install) = status else {
            throw TestFailure("Whisky not ready: \(status)")
        }
        #expect(install.bundleIdentifier == WhiskyLocator.forkBundleID)
        return WhiskyCLI(install: install)
    }

    @Test func unknownBottleIsATypedFailure() async throws {
        let cli = try await realCLI()
        await #expect(throws: Self.missingBottleError) { try await cli.games(bottle: Self.missingBottle) }
        await #expect(throws: Self.missingBottleError) { try await cli.launch(appId: 244210, bottle: Self.missingBottle) }
    }

    @Test func everyRegisteredBottleListsItsGames() async throws {
        let cli = try await realCLI()
        for bottle in cli.bottles() where bottle.isRegistered {
            let games = try await cli.games(bottle: try #require(bottle.name))
            print("bottle \(bottle.name ?? "?"): \(games.map { "\($0.appId) \($0.name)" })")
        }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
