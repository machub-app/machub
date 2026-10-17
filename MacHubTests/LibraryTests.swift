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

    @Test func realGameMapsToALaunchableTitle() {
        let game = SteamGame(appId: 244210, name: "Assetto Corsa", installPath: "/x/steamapps/common/assettocorsa")
        let title = Title(game: game, bottle: "Steam")
        #expect(title.id == "whisky:Steam:244210")
        #expect(title.canLaunch && !title.isDemo)
        #expect(title.bottle == "Steam" && title.installPath == game.installPath)
        #expect(title.compatibility == .unknown)
    }

    @MainActor @Test func featuredFallsBackToDemoOnlyWhenAllowed() {
        let store = LibraryStore()
        #expect(store.featured(includeDemo: false).isEmpty)
        #expect(store.featured(includeDemo: true).map(\.id) == DemoLibrary.featuredIDs)
        #expect(store.titles(includeDemo: false).isEmpty)
    }

    @Test func artworkURLsPointAtSteamCDN() {
        #expect(Artwork.hero.url(appID: 244210).absoluteString
            == "https://cdn.cloudflare.steamstatic.com/steam/apps/244210/library_hero.jpg")
    }
}
