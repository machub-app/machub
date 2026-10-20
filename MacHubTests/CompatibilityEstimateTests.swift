import Foundation
import SwiftUI
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

@MainActor
struct TrailerPlayerTests {
    /// 0.3.1 aborted as soon as the trailer sheet was built (SwiftUI VideoPlayer); building and laying it out must work.
    @Test func trailerSheetRenders() {
        let trailer = StoreDetails.Trailer(id: 1, name: "Trailer", thumbnail: nil, stream: URL(string: "https://example.com/t.m3u8")!)
        let host = NSHostingView(rootView: TrailerPlayer(trailer: trailer).environment(LibraryStore()))
        host.frame = CGRect(x: 0, y: 0, width: 960, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }
}

struct HighballDBTests {
    static let curated = Data(#"""
    {"schema":1,"steam_appid":284160,"kind":"curated","license":"CC0-1.0","url":"https://gethighball.com/games/beamng-drive/",
     "status_meaning":"Community consensus","reports":7,"recipe":false,
     "game":{"title":"BeamNG.drive","status":"community","renderer":"d3dmetal","notes":"Plays at 40-60 fps.",
             "knownIssues":[{"symptom":"Story mode cannot generate a seed","cause":"not diagnosed","fix":"none known yet"}],
             "launchArgs":["-gfx","dx11"]}}
    """#.utf8)

    @Test func readsCuratedEntry() throws {
        guard case .curated(let game)? = HighballDB.parse(Self.curated) else { Issue.record("not curated"); return }
        #expect(game.status == "community" && game.renderer == "d3dmetal" && game.reports == 7)
        #expect(game.launchArgs == ["-gfx", "dx11"])
        #expect(game.knownIssues.first?.symptom == "Story mode cannot generate a seed")
        #expect(game.page?.absoluteString == "https://gethighball.com/games/beamng-drive/")
        #expect(game.graphicsChoice == .d3dmetal)
    }

    @Test func readsPredictionAndRejectsOthers() {
        let prediction = Data(#"{"kind":"prediction","label":"Likely playable","prediction":{"title":"Subnautica 2","protonTier":"gold","recentReports":467,"macPrediction":"likely"}}"#.utf8)
        guard case .prediction(let odds)? = HighballDB.parse(prediction) else { Issue.record("not a prediction"); return }
        #expect(odds.macPrediction == "likely" && odds.recentReports == 467)
        #expect(HighballDB.parse(Data("Not Found".utf8)) == nil)
    }

    @Test func highballVerdictsInOrder() {
        let blocked = HighballDB.Entry.curated(.init(title: "", status: "blocked-anticheat", statusMeaning: nil, renderer: nil, notes: nil,
                                                    provenance: nil, launchArgs: [], knownIssues: [], reports: 0, hasRecipe: false, nativeMac: nil, page: nil))
        let community = HighballDB.Entry.curated(.init(title: "", status: "community", statusMeaning: nil, renderer: "dxmt", notes: nil,
                                                      provenance: nil, launchArgs: [], knownIssues: [], reports: 3, hasRecipe: false, nativeMac: nil, page: nil))
        let d3dmetalOnly = HighballDB.Entry.curated(.init(title: "", status: "community", statusMeaning: nil, renderer: "d3dmetal", notes: nil,
                                                         provenance: nil, launchArgs: [], knownIssues: [], reports: 3, hasRecipe: false, nativeMac: nil, page: nil))
        let likely = HighballDB.Entry.prediction(.init(title: "", macPrediction: "likely", label: "Likely playable", protonTier: "gold", recentReports: 9, page: nil))
        func verdict(_ entry: HighballDB.Entry, directX: Int? = 11, native: Bool = false) -> CompatibilityEstimate.Verdict {
            CompatibilityEstimate.make(appID: 1, nativeMac: native, directX: directX, antiCheat: nil, protonTier: nil, protonReports: 0, highball: entry).verdict
        }
        #expect(verdict(blocked, native: true) == .antiCheat)
        #expect(verdict(community) == .community)
        #expect(verdict(d3dmetalOnly, directX: 12) == .directX12)
        #expect(verdict(d3dmetalOnly, directX: 11) == .community)   // BeamNG: D3DMetal reported, but DirectX 11 works too
        #expect(verdict(likely, directX: 12) == .directX12)         // Highball can run DX12; MacHub can't yet
        #expect(verdict(likely) == .likely)
    }

    @Test func oldTitleSettingsStillDecode() throws {
        let old = Data(#"{"graphics":"dxmt","arguments":"-gfx dx11"}"#.utf8)
        let settings = try JSONDecoder().decode(TitleSettings.self, from: old)
        #expect(settings.graphics == .dxmt && settings.arguments == "-gfx dx11" && settings.useRecommended)
    }
}
