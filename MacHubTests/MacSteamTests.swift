import Foundation
import Testing
@testable import MacHub

@Suite struct MacSteamTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "machub-macsteam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "steamapps"), withIntermediateDirectories: true)
    }

    @Test func readsUnixLibrariesAndLastPlayed() throws {
        let fm = FileManager.default
        // Same shape as Steam for Mac's manifest for Dead Island 2 on the dev Mac (trimmed).
        try #""AppState" { "appid" "934700" "name" "Dead Island 2" "StateFlags" "4" "installdir" "Dead Island 2" "LastPlayed" "1789569746" }"#
            .write(to: root.appending(path: "steamapps/appmanifest_934700.acf"), atomically: true, encoding: .utf8)
        let external = root.appending(path: "External Library")
        try fm.createDirectory(at: external.appending(path: "steamapps"), withIntermediateDirectories: true)
        try #""AppState" { "appid" "570" "name" "Dota 2" "StateFlags" "1026" "installdir" "dota 2 beta" "BytesToDownload" "400" "BytesDownloaded" "100" }"#
            .write(to: external.appending(path: "steamapps/appmanifest_570.acf"), atomically: true, encoding: .utf8)
        try """
        "libraryfolders" { "0" { "path" "\(root.path)" } "1" { "path" "\(external.path)" } "2" { "path" "/Volumes/Unplugged Disk" } }
        """.write(to: root.appending(path: "steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)

        #expect(MacSteam.libraryFolders(root: root).map(\.lastPathComponent) == [root.lastPathComponent, "External Library"])
        let apps = MacSteam.apps(root: root)
        #expect(apps.map(\.appID) == [934700, 570])
        #expect(apps[0].isInstalled && apps[0].installPath.hasSuffix("steamapps/common/Dead Island 2"))
        #expect(!apps[1].isInstalled && SteamLibrary.progress(of: apps[1]) == 0.25)
        #expect(MacSteam.lastPlayed(appID: 934700, root: root) == Date(timeIntervalSince1970: 1789569746))
        #expect(MacSteam.lastPlayed(appID: 570, root: root) == nil)
    }

    @Test func requestsUseSteamLinks() {
        #expect(MacSteam.Request.play.url(appID: 1091500).absoluteString == "steam://rungameid/1091500")
        #expect(MacSteam.Request.install.url(appID: 570).absoluteString == "steam://install/570")
        #expect(MacSteam.Request.store.url(appID: 570).absoluteString == "steam://store/570")
    }

    @Test func macInstallWinsOverWindowsWhenMerging() {
        var mac = Title(id: Title.steamID(934700), name: "Dead Island 2", kind: .game, steamAppID: 934700)
        mac.macInstall = "/Steam/steamapps/common/Dead Island 2"
        let owned = Title(owned: SteamWebAPI.OwnedGame(appID: 934700, name: "Dead Island 2", playtimeMinutes: 60, lastPlayed: nil))
        let merged = owned.merged(with: mac)
        #expect(merged.macInstall == mac.macInstall)
        #expect(merged.availability == .installed)
        #expect(merged.install == nil)
    }
}
