import Foundation
import Testing
@testable import MacHub

/// What MacHub compares every few seconds to notice installs and removals without a restart (2026-10-21).
@Suite struct SteamLibraryWatchTests {
    private let fm = FileManager.default

    private func environment() throws -> (prefix: URL, steam: URL) {
        let prefix = fm.temporaryDirectory.appending(path: "machub-watch-\(UUID().uuidString)")
        let steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
        try fm.createDirectory(at: steam.appending(path: "steamapps"), withIntermediateDirectories: true)
        try Data().write(to: steam.appending(path: "steam.exe"))
        return (prefix, steam)
    }

    private func manifest(_ id: Int, name: String, in steam: URL) throws {
        let text = """
        "AppState"
        {
        \t"appid"\t\t"\(id)"
        \t"name"\t\t"\(name)"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"\(name)"
        }
        """
        try Data(text.utf8).write(to: steam.appending(path: "steamapps/appmanifest_\(id).acf"))
    }

    @Test func changesWhenAGameIsInstalledDownloadedOrRemoved() throws {
        let (prefix, steam) = try environment()
        let empty = SteamLibrary.signature(steamRoot: steam, prefix: prefix)

        try manifest(284160, name: "BeamNG.drive", in: steam)
        let installed = SteamLibrary.signature(steamRoot: steam, prefix: prefix)
        #expect(installed != empty)
        #expect(SteamLibrary.signature(steamRoot: steam, prefix: prefix) == installed, "nothing changed, nothing to refresh")

        try fm.createDirectory(at: steam.appending(path: "steamapps/downloading/244210"), withIntermediateDirectories: true)
        let downloading = SteamLibrary.signature(steamRoot: steam, prefix: prefix)
        #expect(downloading != installed)

        try fm.removeItem(at: steam.appending(path: "steamapps/appmanifest_284160.acf"))
        #expect(SteamLibrary.signature(steamRoot: steam, prefix: prefix) != downloading)
    }

    @Test func gamesAreReadFromTheManifestsAsTheWatchSeesThem() throws {
        let (prefix, steam) = try environment()
        try manifest(284160, name: "BeamNG.drive", in: steam)
        try fm.createDirectory(at: steam.appending(path: "steamapps/common/BeamNG.drive"), withIntermediateDirectories: true)
        let apps = SteamLibrary.apps(steamRoot: steam, prefix: prefix)
        #expect(apps.map(\.appID) == [284160])
        #expect(apps.first?.isInstalled == true)
    }
}
