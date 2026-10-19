import Foundation
import Testing
@testable import MacHub

struct CompatibilityEstimateTests {
    @Test func readsDirectXFromRequirements() {
        #expect(CompatibilitySources.directXVersion(inRequirements: "<li><strong>DirectX:</strong> Version 12<br></li>") == 12)
        #expect(CompatibilitySources.directXVersion(inRequirements: "<strong>DirectX:</strong> Version 9.0c") == 9)
        #expect(CompatibilitySources.directXVersion(inRequirements: "<strong>Graphics:</strong> GTX 1060") == nil)
    }

    @Test func readsProtonDBSummary() {
        let data = Data(#"{"tier":"gold","total":42,"confidence":"strong"}"#.utf8)
        #expect(CompatibilitySources.parseProtonDB(data)?.tier == "gold")
        #expect(CompatibilitySources.parseProtonDB(Data(#"{"tier":"pending","total":1}"#.utf8)) == nil)
    }

    @Test func readsAntiCheatList() {
        let data = Data(#"[{"name":"A","native":false,"status":"Denied","anticheats":["BattlEye"],"storeIds":{"steam":"100"}},{"name":"B","native":true,"status":"Broken","anticheats":[],"storeIds":{"steam":"200"}}]"#.utf8)
        let map = CompatibilitySources.parseAntiCheats(data)
        #expect(map[100]?.blocksWine == true)
        #expect(map[200] == nil)   // native Linux builds say nothing about Wine
    }

    @Test func strongestSignalWins() {
        let blocked = CompatibilityEstimate.AntiCheat(names: ["EAC"], status: "Broken")
        #expect(CompatibilityEstimate.make(appID: 284160, nativeMac: false, directX: 11, antiCheat: nil, protonTier: "gold", protonReports: 9).verdict == .tested)
        #expect(CompatibilityEstimate.make(appID: 1, nativeMac: true, directX: 12, antiCheat: blocked, protonTier: nil, protonReports: 0).verdict == .native)
        #expect(CompatibilityEstimate.make(appID: 1, nativeMac: false, directX: 11, antiCheat: blocked, protonTier: "platinum", protonReports: 9).verdict == .antiCheat)
        #expect(CompatibilityEstimate.make(appID: 1, nativeMac: false, directX: 12, antiCheat: nil, protonTier: "platinum", protonReports: 9).verdict == .directX12)
        #expect(CompatibilityEstimate.make(appID: 1, nativeMac: false, directX: 11, antiCheat: nil, protonTier: "silver", protonReports: 9).verdict == .issues)
        #expect(CompatibilityEstimate.make(appID: 1, nativeMac: nil, directX: nil, antiCheat: nil, protonTier: nil, protonReports: 0).verdict == .unknown)
    }

    @Test func toolsAreNotGames() {
        func details(_ name: String, _ genres: [String]) -> StoreDetails {
            StoreDetails(name: name, type: "game", shortDescription: "", developers: [], publishers: [], genres: [], releaseDate: nil,
                         comingSoon: false, isFree: true, windows: true, mac: false, headerImage: nil, background: nil,
                         screenshots: [], metacritic: nil, price: nil, genreIDs: genres)
        }
        #expect(details("Team Fortress 2", ["1", "37"]).isPlayableGame)
        #expect(!details("Source Filmmaker", ["51", "58"]).isPlayableGame)
        #expect(!details("SteamVR", []).isPlayableGame)
        #expect(!details("Resident Evil 6 Benchmark Tool", ["1"]).isPlayableGame)
    }

    @Test func listsCachedLibraryApps() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "machub-steam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["284160", "570", "not-an-app"] {
            try FileManager.default.createDirectory(at: root.appending(path: "appcache/librarycache/\(name)"), withIntermediateDirectories: true)
        }
        #expect(SteamLibrary.libraryCacheAppIDs(steamRoot: root) == [570, 284160])
    }
}

struct StoreTrailerTests {
    @Test func readsTrailersHighlightFirstWithMP4Fallback() throws {
        let json = #"""
        {"42": {"success": true, "data": {"name": "G", "type": "game",
          "pc_requirements": [],
          "movies": [
            {"id": 1, "name": "Old &amp; small", "thumbnail": "https://e.com/1.jpg", "mp4": {"480": "https://e.com/1-480.mp4", "max": "https://e.com/1.mp4"}},
            {"id": 2, "name": "Launch trailer", "thumbnail": "https://e.com/2.jpg", "hls_h264": "https://e.com/2.m3u8", "highlight": true},
            {"id": 3, "name": "No stream"}
          ]}}}
        """#
        let details = try #require(try SteamStore.parseDetails(Data(json.utf8), appID: 42))
        #expect(details.trailers.map(\.id) == [2, 1])
        #expect(details.trailers[0].stream.absoluteString == "https://e.com/2.m3u8")
        #expect(details.trailers[1].stream.absoluteString == "https://e.com/1.mp4")
        #expect(details.trailers[1].name == "Old & small")
        #expect(details.directX == nil)   // pc_requirements as an empty array must not break parsing
    }
}
