import Foundation
import Testing
@testable import MacHub

@Suite struct LibraryTests {
    @Test func demoTitlesAreNeverLaunchable() {
        #expect(!DemoLibrary.titles.isEmpty)
        #expect(DemoLibrary.titles.allSatisfy { $0.isDemo && !$0.canLaunch && $0.bottle == nil })
    }

    @Test func demoIDsAreUniqueAndFeaturedOnesExist() {
        let ids = DemoLibrary.titles.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(DemoLibrary.featuredIDs.allSatisfy(ids.contains))
    }

    @Test func installedGameWithExecutableIsLaunchable() {
        let game = SteamGame(appId: 244210, name: "Assetto Corsa", installPath: "/x/steamapps/common/assettocorsa")
        let title = Title(game: game, bottle: "Steam", executables: ["AssettoCorsa.exe"])
        #expect(title.id == "steam:244210" && title.availability == .installed)
        #expect(title.canLaunch && !title.isDemo)
        #expect(title.bottle == "Steam" && title.installPath == game.installPath)
        #expect(title.compatibility == .unknown)
    }

    @Test func installedWithoutExecutableIsNotLaunchable() {
        let game = SteamGame(appId: 1, name: "Broken", installPath: "/x")
        #expect(!Title(game: game, bottle: "Steam", executables: []).canLaunch)
    }

    @Test func storeAndOwnedTitlesNeverLaunch() {
        let store = Title(store: StoreItem(appID: 1091500, name: "Cyberpunk 2077"))
        let owned = Title(owned: .init(appID: 1091500, name: "Cyberpunk 2077", playtimeMinutes: 60, lastPlayed: nil))
        #expect(store.availability == .store && !store.canLaunch)
        #expect(owned.availability == .owned && !owned.canLaunch)
        // Same App ID from two sources merges into one title that keeps both facts.
        let merged = owned.merged(with: store)
        #expect(merged.id == store.id && merged.owned != nil && merged.availability == .owned)
    }

    @Test func detailsFillDescriptiveFields() {
        var title = Title(store: StoreItem(appID: 244210, name: "Assetto Corsa"))
        title.apply(StoreDetails(name: "Assetto Corsa", type: "game", shortDescription: "Sim", developers: ["Kunos Simulazioni"],
                                 publishers: ["505"], genres: ["Course automobile"], releaseDate: "19 déc. 2014", comingSoon: false,
                                 isFree: false, windows: true, mac: false, headerImage: nil, background: nil, screenshots: [],
                                 metacritic: 85, price: nil))
        #expect(title.releaseYear == 2014 && title.developer == "Kunos Simulazioni" && title.macAvailable == false)
    }

    @Test func executableScannerSkipsInstallers() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "machub-exe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "bin"), withIntermediateDirectories: true)
        for name in ["AssettoCorsa.exe", "unins000.exe", "vc_redist.x64.exe", "readme.txt", "bin/acs.exe"] {
            FileManager.default.createFile(atPath: dir.appending(path: name).path, contents: Data())
        }
        #expect(ExecutableScanner.executables(in: dir) == ["AssettoCorsa.exe", "bin/acs.exe"])
    }

    @MainActor @Test func featuredFallsBackToDemoOnlyWhenAllowed() {
        let store = LibraryStore()
        #expect(store.featured(includeDemo: false).isEmpty)
        #expect(store.featured(includeDemo: true).map(\.id) == DemoLibrary.featuredIDs)
    }

    @Test func artworkURLsPointAtSteamCDN() {
        #expect(Artwork.hero.url(appID: 244210).absoluteString
            == "https://cdn.cloudflare.steamstatic.com/steam/apps/244210/library_hero.jpg")
    }
}
