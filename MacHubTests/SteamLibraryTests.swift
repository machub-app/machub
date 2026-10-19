import Foundation
import Testing
@testable import MacHub

@Suite struct SteamLibraryTests {
    let prefix: URL

    init() throws {
        prefix = FileManager.default.temporaryDirectory.appending(path: "machub-steamlib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    }

    // Same shape as the manifest Steam wrote for Assetto Corsa on the dev Mac (trimmed).
    static let assettoACF = """
    "AppState"
    {
    \t"appid"\t\t"244210"
    \t"Universe"\t\t"1"
    \t"name"\t\t"Assetto Corsa"
    \t"StateFlags"\t\t"4"
    \t"installdir"\t\t"assettocorsa"
    \t"SizeOnDisk"\t\t"44950000000"
    \t"BytesToDownload"\t\t"14370000000"
    \t"BytesDownloaded"\t\t"14370000000"
    \t"InstalledDepots"
    \t{
    \t\t"244211"
    \t\t{
    \t\t\t"manifest"\t\t"123"
    \t\t}
    \t}
    }
    """

    @Test func parsesNestedObjectsCaseInsensitively() throws {
        let vdf = try VDF.parse(Self.assettoACF)
        let state = try #require(vdf.child("appstate"))
        #expect(state["APPID"] == "244210")
        #expect(state.child("installeddepots")?.child("244211")?["manifest"] == "123")
    }

    @Test func handlesEscapesCommentsAndOrder() throws {
        let vdf = try VDF.parse(#"""
        // written by Steam
        "libraryfolders"
        {
            "0" { "path" "C:\\Program Files (x86)\\Steam" }
            "1" { "path" "D:\\Games\\SteamLibrary" "label" "say \"hi\"" }
        }
        """#)
        let list = try #require(vdf.child("libraryfolders"))
        #expect(list.order == ["0", "1"])
        #expect(list.child("0")?["path"] == #"C:\Program Files (x86)\Steam"#)
        #expect(list.child("1")?["label"] == #"say "hi""#)
    }

    @Test func rejectsUnbalancedBraces() {
        #expect(throws: VDF.ParseError.self) { try VDF.parse(#""a" { "b" "c""#) }
        #expect(throws: VDF.ParseError.self) { try VDF.parse(#""a" "b" }"#) }
    }

    @Test func mapsWindowsPathsIntoThePrefix() {
        #expect(SteamLibrary.macURL(forWindowsPath: #"C:\Program Files (x86)\Steam"#, prefix: prefix)?.path
                == prefix.appending(path: "drive_c/Program Files (x86)/Steam").path)
        #expect(SteamLibrary.macURL(forWindowsPath: "c:/", prefix: prefix)?.path == prefix.appending(path: "drive_c").path)
        #expect(SteamLibrary.macURL(forWindowsPath: "steamapps", prefix: prefix) == nil)
    }

    @Test func readsAppsFromEveryLibraryAndSkipsRedistributables() throws {
        let fm = FileManager.default
        let steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
        try fm.createDirectory(at: steam.appending(path: "steamapps"), withIntermediateDirectories: true)
        fm.createFile(atPath: steam.appending(path: "steam.exe").path, contents: Data())
        try Self.assettoACF.write(to: steam.appending(path: "steamapps/appmanifest_244210.acf"), atomically: true, encoding: .utf8)
        try #""AppState" { "appid" "228980" "name" "Steamworks Common Redistributables" "installdir" "Steamworks Shared" "StateFlags" "4" }"#
            .write(to: steam.appending(path: "steamapps/appmanifest_228980.acf"), atomically: true, encoding: .utf8)

        let second = prefix.appending(path: "drive_c/Games/Lib")
        try fm.createDirectory(at: second.appending(path: "steamapps/downloading/440"), withIntermediateDirectories: true)
        try #""AppState" { "appid" "440" "name" "Team Fortress 2" "installdir" "Team Fortress 2" "StateFlags" "1026" "BytesToDownload" "1000" "BytesDownloaded" "250" }"#
            .write(to: second.appending(path: "steamapps/appmanifest_440.acf"), atomically: true, encoding: .utf8)
        // Preallocated space in downloading/ must not count as progress.
        fm.createFile(atPath: second.appending(path: "steamapps/downloading/440/chunk").path, contents: Data(count: 900))
        try #"""
        "libraryfolders" { "0" { "path" "C:\\Program Files (x86)\\Steam" } "1" { "path" "C:\\Games\\Lib" } }
        """#.write(to: steam.appending(path: "steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)

        let root = try #require(SteamLibrary.steamRoot(inPrefix: prefix))
        let apps = SteamLibrary.apps(steamRoot: root, prefix: prefix)
        #expect(apps.map(\.appID) == [244210, 440])
        let assetto = apps[0], tf2 = apps[1]
        #expect(assetto.isInstalled && assetto.installPath.hasSuffix("steamapps/common/assettocorsa"))
        #expect(SteamLibrary.progress(of: assetto) == nil)
        #expect(!tf2.isInstalled)
        #expect(SteamLibrary.progress(of: tf2) == 0.25)
    }

    @Test func noSteamInPrefixMeansNoRoot() {
        #expect(SteamLibrary.steamRoot(inPrefix: prefix) == nil)
    }
}
