import Foundation
import Testing
@testable import MacHub

@Suite struct StorageTests {
    let root: URL
    let prefix: URL
    let steam: URL

    // Same shape as the file Steam for Windows wrote in the dev Mac's Steam prefix (2026-10-20).
    static let libraryFolders = #"""
    "libraryfolders"
    {
    	"0"
    	{
    		"path"		"C:\\Program Files (x86)\\Steam"
    		"label"		""
    		"contentid"		"577116700756813959"
    		"totalsize"		"0"
    		"update_clean_bytes_tally"		"2149126969"
    		"time_last_update_verified"		"1792341168"
    		"apps"
    		{
    			"228980"		"128606066"
    			"284160"		"56069340831"
    		}
    	}
    }

    """#

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(path: "machub-storage-\(UUID().uuidString)")
        prefix = root.appending(path: "prefix")
        steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
        try fm.createDirectory(at: steam.appending(path: "steamapps"), withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appending(path: "dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: prefix.appending(path: "dosdevices/c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: prefix.appending(path: "dosdevices/z:").path, withDestinationPath: "/")
        fm.createFile(atPath: steam.appending(path: "steam.exe").path, contents: Data())
        try Self.libraryFolders.write(to: SteamLibrary.libraryFoldersFile(steamRoot: steam), atomically: true, encoding: .utf8)
    }

    @Test func writesSteamsOwnFileBackUnchanged() throws {
        #expect(try VDF.parse(Self.libraryFolders).text() == Self.libraryFolders)
    }

    @Test func roundTripsAnAddedLibrary() throws {
        let added = SteamLibrary.addingLibrary(#"E:\"#, contentID: "42", to: try VDF.parse(Self.libraryFolders))
        let reread = try VDF.parse(added.text())
        let list = try #require(reread.child("libraryfolders"))
        #expect(list.order == ["0", "1"])
        #expect(list.child("0")?["path"] == #"C:\Program Files (x86)\Steam"#)
        #expect(list.child("0")?.child("apps")?["284160"] == "56069340831")
        #expect(list.child("1")?["path"] == #"E:\"#)
        #expect(list.child("1")?["contentid"] == "42")
        #expect(list.child("1")?.child("apps") == VDF())
        // Adding the same path again changes nothing.
        #expect(SteamLibrary.addingLibrary(#"e:"#, contentID: "7", to: reread).text() == reread.text())
    }

    @Test func escapesQuotesAndBackslashes() throws {
        var vdf = VDF()
        vdf["label"] = #"say "hi" in C:\Games"#
        #expect(try VDF.parse(vdf.text())["label"] == #"say "hi" in C:\Games"#)
    }

    @Test func picksTheFirstFreeDriveLetterFromE() throws {
        let fm = FileManager.default
        let dosdevices = prefix.appending(path: "dosdevices")
        let folder = root.appending(path: "Volume/Games")
        #expect(SteamLibrary.driveLetter(for: folder, prefix: prefix) == "e")
        // Wine's mount manager: `e:` for a volume it saw, `f::` for a raw device. Both are taken.
        try fm.createSymbolicLink(atPath: dosdevices.appending(path: "e:").path, withDestinationPath: "/Volumes/Other")
        try fm.createSymbolicLink(atPath: dosdevices.appending(path: "f::").path, withDestinationPath: "/dev/rdisk9s1")
        #expect(SteamLibrary.driveLetter(for: folder, prefix: prefix) == "g")
        // A letter already pointing at the folder is reused.
        try fm.createSymbolicLink(atPath: dosdevices.appending(path: "h:").path, withDestinationPath: folder.path)
        #expect(SteamLibrary.driveLetter(for: folder, prefix: prefix) == "h")
    }

    @Test func addsAFolderAsADriveAndLibrary() throws {
        let fm = FileManager.default
        let folder = root.appending(path: "Volume/Games")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let path = try SteamLibrary.addLibraryFolder(folder, steamRoot: steam, prefix: prefix)
        #expect(path == #"E:\"#)
        #expect(try fm.destinationOfSymbolicLink(atPath: prefix.appending(path: "dosdevices/e:").path) == folder.standardizedFileURL.path)
        #expect(fm.fileExists(atPath: folder.appending(path: "steamapps").path))
        let marker = try VDF.parse(String(contentsOf: folder.appending(path: "libraryfolder.vdf"), encoding: .utf8))
        let file = SteamLibrary.libraryFoldersFile(steamRoot: steam)
        #expect(try String(contentsOf: file.appendingPathExtension("machub-backup"), encoding: .utf8) == Self.libraryFolders)
        let list = try #require(try VDF.parse(String(contentsOf: file, encoding: .utf8)).child("libraryfolders"))
        #expect(list.child("1")?["contentid"] == marker.child("libraryfolder")?["contentid"])

        let entries = SteamLibrary.libraryFolderEntries(steamRoot: steam, prefix: prefix)
        #expect(entries.map(\.windowsPath) == [#"C:\Program Files (x86)\Steam"#, #"E:\"#])
        #expect(entries.allSatisfy { $0.isAvailable })
        #expect(SteamLibrary.libraryFolders(steamRoot: steam, prefix: prefix).count == 2)

        // Twice is a no-op: same letter, same list.
        #expect(try SteamLibrary.addLibraryFolder(folder, steamRoot: steam, prefix: prefix) == #"E:\"#)
        #expect(try VDF.parse(String(contentsOf: file, encoding: .utf8)).child("libraryfolders")?.order == ["0", "1"])
    }

    @Test func keepsAnUnpluggedDriveListedButUnavailable() throws {
        let fm = FileManager.default
        let folder = root.appending(path: "Volume/Games")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try SteamLibrary.addLibraryFolder(folder, steamRoot: steam, prefix: prefix)
        try fm.removeItem(at: root.appending(path: "Volume"))

        let entries = SteamLibrary.libraryFolderEntries(steamRoot: steam, prefix: prefix)
        #expect(entries.count == 2)
        #expect(entries[1].url.path == folder.standardizedFileURL.path)
        #expect(entries[1].isAvailable == false)
        #expect(SteamLibrary.libraryFolders(steamRoot: steam, prefix: prefix) == [steam])
        #expect(SteamLibrary.apps(steamRoot: steam, prefix: prefix).isEmpty)
    }

    @Test func refusesWithoutSteamsLibraryFile() throws {
        try FileManager.default.removeItem(at: SteamLibrary.libraryFoldersFile(steamRoot: steam))
        #expect(throws: SteamLibrary.AddFolderError.unreadableLibraryFile) {
            try SteamLibrary.addLibraryFolder(root, steamRoot: steam, prefix: prefix)
        }
        #expect(!FileManager.default.fileExists(atPath: prefix.appending(path: "dosdevices/e:").path))
    }

    @Test func formatsSizesLikeFinder() {
        let english = Locale(identifier: "en_US")
        #expect(Storage.format(0, locale: english) == "Zero kB")
        #expect(Storage.format(52_100_000_000, locale: english) == "52.1 GB")
        #expect(Storage.format(1_500_000, locale: english) == "1.5 MB")
        #expect(Storage.format(52_100_000_000, locale: Locale(identifier: "fr_FR")) == "52,1\u{202F}Go")
    }

    @Test func measuresWithoutFollowingDriveLinks() throws {
        let fm = FileManager.default
        try Data(count: 100_000).write(to: steam.appending(path: "big.bin"))
        let size = Storage.allocatedSize(of: prefix)
        // z: points at / : following it would count the whole disk.
        #expect(size >= 100_000 && size < 10_000_000)
        #expect(Storage.allocatedSize(of: root.appending(path: "missing")) == 0)
        #expect(fm.fileExists(atPath: prefix.path))
    }

    @Test func readsSizeOnDiskFromManifests() throws {
        try SteamLibraryTests.assettoACF.write(to: steam.appending(path: "steamapps/appmanifest_244210.acf"), atomically: true, encoding: .utf8)
        let app = try #require(SteamLibrary.apps(steamRoot: steam, prefix: prefix).first)
        #expect(app.sizeOnDisk == 44_950_000_000)
    }

    @Test func removalPlanListsEverythingAndOnlyTrashes() throws {
        let fm = FileManager.default
        let data = root.appending(path: "Application Support/app.machub.MacHub")
        let logs = root.appending(path: "Logs/app.machub.MacHub")
        let caches = root.appending(path: "Caches/app.machub.MacHub")
        for dir in ["Prefixes/A/drive_c", "Runtimes/1.0", "GPTK"] {
            try fm.createDirectory(at: data.appending(path: dir), withIntermediateDirectories: true)
        }
        try Data(count: 5000).write(to: data.appending(path: "Prefixes/A/drive_c/game.bin"))
        try Data("{}".utf8).write(to: data.appending(path: "engine-settings.json"))
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)

        let plan = DataRemoval.plan(dataDirectory: data, logsDirectory: logs, cachesDirectory: caches)
        #expect(plan.items.map(\.url.lastPathComponent) == ["Prefixes", "Runtimes", "GPTK", "engine-settings.json", "app.machub.MacHub"])
        #expect(plan.items[0].bytes >= 5000)

        let trash = root.appending(path: "Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let failed = plan.perform { url in
            if url.lastPathComponent == "GPTK" { throw CocoaError(.fileWriteNoPermission) }
            try fm.moveItem(at: url, to: trash.appending(path: UUID().uuidString))
        }
        #expect(failed.map(\.url.lastPathComponent) == ["GPTK"])
        #expect(try fm.contentsOfDirectory(atPath: data.path) == ["GPTK"])
        #expect(try fm.contentsOfDirectory(atPath: trash.path).count == 4)
    }
}
