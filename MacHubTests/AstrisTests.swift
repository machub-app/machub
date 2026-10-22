import Foundation
import Testing
@testable import MacHub

@Suite struct AstrisTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "machub-astris-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Same shape as Astris' files on the dev Mac.
    func writeMetadata(_ id: String, _ json: String) throws {
        let gui = root.appending(path: "data/games/\(id)/gui")
        try FileManager.default.createDirectory(at: gui, withIntermediateDirectories: true)
        try json.write(to: gui.appending(path: "metadata.json"), atomically: true, encoding: .utf8)
    }

    @Test func readsMetadataAndMatchesFiles() throws {
        try writeMetadata("0100dca0064a6000", #"{"title": "Luigi's Mansion 3", "favorite": false, "timespan_played": "05:48:03", "last_played_utc": "2026-09-28T08:32:38.299835Z"}"#)
        try writeMetadata("0100f2c0115b6000", #"{"title": "The Legend of Zelda: Tears of the Kingdom", "timespan_played": "1.00:05:05"}"#)
        try writeMetadata("0100aaaa00000000", #"{"title": "Not On Disk"}"#)
        try writeMetadata("not-an-id", #"{"title": "Ignored"}"#)

        let games = root.appending(path: "Game")
        try FileManager.default.createDirectory(at: games.appending(path: "more"), withIntermediateDirectories: true)
        for name in ["Luigi's Mansion 3 [0100DCA0064A6000][v0](eShop).nsp", "The Legend of Zelda Tears of the Kingdom.nsp",
                     "more/Some Game [0100BBBB00002000][v0].xci", "more/Some Game [0100BBBB00002800][v65536].nsp", "notes.txt"] {
            FileManager.default.createFile(atPath: games.appending(path: name).path, contents: Data())
        }

        let metadata = Astris.metadata(dataDirectory: root.appending(path: "data"))
        #expect(metadata.map(\.titleID) == ["0100AAAA00000000", "0100DCA0064A6000", "0100F2C0115B6000"])
        let luigi = try #require(metadata.first { $0.titleID == "0100DCA0064A6000" })
        #expect(luigi.name == "Luigi's Mansion 3" && luigi.playtime == 5 * 3600 + 48 * 60 + 3)
        #expect(luigi.lastPlayed == Astris.date("2026-09-28T08:32:38.299Z"))
        #expect(metadata.first { $0.titleID == "0100F2C0115B6000" }?.playtime == 86705)

        let files = Astris.gameFiles(in: [games])
        #expect(files.count == 4)
        let found = Astris.games(metadata: metadata, files: files)
        #expect(found.first { $0.titleID == "0100DCA0064A6000" }?.file?.lastPathComponent.hasPrefix("Luigi's Mansion 3") == true)
        // No title ID in the name: matched on the title.
        #expect(found.first { $0.titleID == "0100F2C0115B6000" }?.file?.lastPathComponent == "The Legend of Zelda Tears of the Kingdom.nsp")
        #expect(found.first { $0.titleID == "0100AAAA00000000" }?.file == nil)
        // A base game Astris hasn't run yet is listed from its file; its update file is not a game.
        #expect(found.first { $0.titleID == "0100BBBB00002000" }?.name == "Some Game")
        #expect(!found.contains { $0.titleID == "0100BBBB00002800" })
    }

    @Test func libraryFoldersComeFromAstrisPreferences() throws {
        let defaults = try #require(UserDefaults(suiteName: "machub-tests-astris-\(UUID().uuidString)"))
        let folder = root.appending(path: "Switch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults.set([folder.absoluteString: Data(), "file:///Volumes/Gone/": Data()], forKey: "LibraryBookmarks")
        #expect(Astris.libraryFolders(defaults: defaults).map(\.lastPathComponent) == ["Switch"])
    }

    @Test func parsesNlib() throws {
        let json = Data(#"{"id":"0100F2C0115B6000","name":"The Legend of Zelda™: Tears of the Kingdom","publisher":"Nintendo","developer":null,"releaseDate":"2023-05-12","category":["Adventure","Action"],"description":"An epic adventure","icon":"http://api.nlib.cc/nx/0100F2C0115B6000/icon"}"#.utf8)
        let info = try #require(SwitchCatalog.parse(json, titleID: "0100F2C0115B6000"))
        #expect(info.name == "The Legend of Zelda: Tears of the Kingdom")
        #expect(info.releaseYear == 2023 && info.genres == ["Adventure", "Action"] && info.developer == nil)
        #expect(info.icon.absoluteString == "https://api.nlib.cc/nx/0100F2C0115B6000/icon")
    }

    @Test func titleIDsAndNames() {
        #expect(Astris.isBaseGame("0100DCA0064A6000") && !Astris.isBaseGame("0100DCA0064A6800") && !Astris.isBaseGame("0100DCA0064A7001"))
        #expect(Astris.titleID(inFileName: "Game [0100dca0064a6000][v0].nsp") == "0100DCA0064A6000")
        #expect(Astris.sameName("Pokémon: Legends", "Pokemon Legends [v0].nsp"))
    }
}

extension AstrisTests {
    @Test func timespans() {
        #expect(Astris.timespan("05:48:03") == 20883)
        #expect(Astris.timespan("1.00:05:05") == 86705)
        #expect(Astris.timespan("00:05:05.1234567") == 305)
        #expect(Astris.timespan("soon") == nil)
    }
}
