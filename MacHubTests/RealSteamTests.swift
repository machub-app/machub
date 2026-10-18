import Foundation
import Testing
@testable import MacHub

/// Live checks against Steam's public endpoints (no account, no key). Opt-in, like RealWhiskyTests:
/// `TEST_RUNNER_MACHUB_INTEGRATION=1 xcodebuild … test -only-testing:MacHubTests/RealSteamTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACHUB_INTEGRATION"] == "1"), .serialized)
struct RealSteamTests {
    let http = SteamHTTP(directory: FileManager.default.temporaryDirectory.appending(path: "machub-live-\(UUID().uuidString)"))
    let locale = StoreLocale(language: "french", country: "FR")

    @Test func featuredCategoriesDecode() async throws {
        let featured = try await SteamStore.featured(http: http, locale: locale)
        #expect(!featured.topSellers.isEmpty && !featured.newReleases.isEmpty)
        print("top sellers:", featured.topSellers.prefix(3).map(\.name))
    }

    @Test func searchPagesDiffer() async throws {
        let first = try await SteamStore.search(term: "racing", page: 0, http: http, locale: locale)
        let second = try await SteamStore.search(term: "racing", page: 1, http: http, locale: locale)
        #expect(first.count == SteamStore.pageSize)
        #expect(Set(first.map(\.appID)).isDisjoint(with: second.map(\.appID)))
    }

    @Test func assettoCorsaDetails() async throws {
        let details = try #require(try await SteamStore.details(appID: 244210, http: http, locale: locale))
        #expect(details.name == "Assetto Corsa" && details.windows && !details.developers.isEmpty)
        print("genres:", details.genres, "mac:", details.mac)
    }

    @Test func publicProfile() async throws {
        let response = try await http.get(SteamProfile.url(for: "76561197960287930"), ttl: 0)
        let profile = try #require(SteamProfile.parse(response.data))
        #expect(profile.steamID64 == "76561197960287930" && profile.personaName?.isEmpty == false)
    }

    @Test func ownedGamesWithoutKeyIsUnauthorized() async throws {
        await #expect(throws: SteamHTTP.Failure.unauthorized) {
            try await http.get(URL(string: "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?steamid=76561197960287930")!, ttl: 0)
        }
    }
}
