import Foundation
import Testing
@testable import MacHub

@Suite struct GameUpdatesTests {
    @Test func readsVersionsFromAnnouncementTitles() {
        #expect(GameUpdates.version(in: "Get Comfy: Split the Screen in v0.40") == "0.40")
        #expect(GameUpdates.version(in: "Hotfixes for v0.39 Released") == "0.39")
        #expect(GameUpdates.version(in: "Update 2.31 is live") == "2.31")
        #expect(GameUpdates.version(in: "Patch 1.2.3 notes") == "1.2.3")
        #expect(GameUpdates.version(in: "Summer Sale: 50% off until 7.15") == nil)
        #expect(GameUpdates.version(in: "Community spotlight") == nil)
    }

    // Shapes of the real answers for BeamNG.drive (284160) on 2026-10-20, trimmed.
    @Test func parsesLatestBuildAndNews() throws {
        let build = Data(#"{"data":{"284160":{"depots":{"branches":{"public":{"buildid":"26043678","timebuildupdated":"1792399300","timeupdated":"1792415809"}}}}},"status":"success"}"#.utf8)
        let latest = try #require(GameUpdates.parseLatestBuild(build, appID: 284160))
        #expect(latest.build == 26043678 && latest.date == Date(timeIntervalSince1970: 1792415809))

        let news = Data(#"{"appnews":{"appid":284160,"newsitems":[{"title":"Hotfixes for v0.39 Released","date":1785398400,"url":"https://example.com/a"},{"title":"Get Comfy: Split the Screen in v0.40","date":1792400000,"url":"https://example.com/b"}]}}"#.utf8)
        let items = GameUpdates.parseAnnouncements(news)
        #expect(items.map(\.version) == ["0.40", "0.39"])
        // Installed shortly after the v0.40 announcement → v0.40; installed in August → v0.39.
        #expect(GameUpdates.likelyVersion(installedOn: Date(timeIntervalSince1970: 1792416826), announcements: items)?.version == "0.40")
        #expect(GameUpdates.likelyVersion(installedOn: Date(timeIntervalSince1970: 1786000000), announcements: items)?.version == "0.39")
    }

    @Test func statusComparesBuilds() throws {
        let acf = #""AppState" { "appid" "284160" "name" "BeamNG.drive" "StateFlags" "4" "installdir" "BeamNG.drive" "buildid" "26043678" "TargetBuildID" "26043678" "LastUpdated" "1792416826" }"#
        let app = try #require(SteamLibrary.app(acf: acf, steamapps: URL(filePath: "/tmp")))
        #expect(app.buildID == 26043678 && app.lastUpdated == Date(timeIntervalSince1970: 1792416826))
        #expect(GameUpdates.status(installed: app, latestBuild: 26043678) == .upToDate)
        #expect(GameUpdates.status(installed: app, latestBuild: 26100000) == .updateAvailable)
        #expect(GameUpdates.status(installed: app, latestBuild: 0) == .unknown)
        let pending = try #require(SteamLibrary.app(acf: acf.replacingOccurrences(of: #""StateFlags" "4""#, with: #""StateFlags" "6""#), steamapps: URL(filePath: "/tmp")))
        #expect(GameUpdates.status(installed: pending, latestBuild: 0) == .pendingInSteam)
    }
}
