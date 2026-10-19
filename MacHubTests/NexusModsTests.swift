import Foundation
import Testing
@testable import MacHub

@Suite struct NexusModsTests {
    @Test func parsesModManagerLinks() throws {
        let link = try #require(NexusLink(URL(string: "nxm://cyberpunk2077/mods/107/files/12345?key=abc&expires=1760000000&user_id=9")!))
        #expect(link == NexusLink(URL(string: "nxm://CYBERPUNK2077/mods/107/files/12345?key=abc&expires=1760000000")!))
        #expect(link.domain == "cyberpunk2077" && link.modID == 107 && link.fileID == 12345 && link.key == "abc" && link.expires == "1760000000")
        #expect(NexusLink(URL(string: "nxm://cyberpunk2077/collections/abc")!) == nil)
        #expect(NexusLink(URL(string: "https://www.nexusmods.com/cyberpunk2077/mods/107")!) == nil)
    }

    @Test func parsesCatalogAndFiles() throws {
        let search = Data(#"{"data":{"mods":{"totalCount":24976,"nodes":[{"modId":107,"name":"Cyber Engine Tweaks","summary":"s","version":"1.37.1","author":"yamashi","pictureUrl":"https://x/y.png","endorsements":239137,"downloads":18544387,"fileSize":34401,"updatedAt":"2025-09-30T00:55:08Z","game":{"domainName":"cyberpunk2077"}}]}}}"#.utf8)
        let page = try NexusMods.parseSearch(search, domain: "cyberpunk2077")
        #expect(page.total == 24976 && page.mods.first?.name == "Cyber Engine Tweaks" && page.mods.first?.updatedAt != nil)
        #expect(page.mods.first?.filesPageURL.absoluteString == "https://www.nexusmods.com/cyberpunk2077/mods/107?tab=files")
        let files = Data(#"{"files":[{"file_id":1,"name":"Old","version":"1.0","category_name":"OLD_VERSION","size_kb":10,"file_name":"a.zip","uploaded_timestamp":1600000000},{"file_id":2,"name":"Main","version":"1.1","category_name":"MAIN","size_kb":20,"file_name":"b.zip","uploaded_timestamp":1700000000}]}"#.utf8)
        #expect(try NexusMods.parseFiles(files).map(\.id) == [2, 1])
    }

    private func zip(_ tree: [String: String], name: String) async throws -> URL {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "machub-nexus-src-\(UUID().uuidString)")
        for (path, content) in tree {
            let url = base.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        let out = fm.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
        let result = try await ProcessRunner.run(URL(filePath: "/usr/bin/ditto"), ["-c", "-k", base.path, out.path], timeout: 30)
        #expect(result.status == 0)
        return out
    }

    private func folder(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "machub-nexus-\(name)-\(UUID().uuidString)")
    }

    @Test func beamNGModsAreDroppedAsZips() async throws {
        let target = folder("beam")
        let installer = NexusModInstaller(layout: .zipIntoFolder(target), dataFolder: folder("data"))
        let direct = try await zip(["vehicles/bus/bus.jbeam": "{}"], name: "bus.zip")
        let record = try await installer.install(archive: direct, fileName: "bus.zip", modID: 1, fileID: 10, name: "Bus", version: "1")
        #expect(record.files == ["bus.zip"])
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "bus.zip").path))
        let inner = try await zip(["vehicles/car/car.jbeam": "{}"], name: "car.zip")
        let wrapper = try await zip(["Car Mod/car.zip": try String(contentsOf: inner, encoding: .isoLatin1)], name: "wrapper.zip")
        let wrapped = try await installer.install(archive: wrapper, fileName: "wrapper.zip", modID: 2, fileID: 20, name: "Car", version: "2")
        #expect(wrapped.files == ["car.zip"])
    }

    @Test func cyberpunkModsMergeAndRestoreWhatTheyReplaced() async throws {
        let game = folder("cp")
        let original = game.appending(path: "r6/scripts/thing.reds")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: original)
        let installer = NexusModInstaller(layout: .mergeIntoGame(game, roots: ["archive", "bin", "r6", "red4ext"]), dataFolder: folder("data"))
        let archive = try await zip(["Wrapper/r6/scripts/thing.reds": "mod", "Wrapper/archive/pc/mod/x.archive": "a"], name: "m.zip")
        let record = try await installer.install(archive: archive, fileName: "m.zip", modID: 3, fileID: 30, name: "M", version: "1")
        #expect(Set(record.files) == ["r6/scripts/thing.reds", "archive/pc/mod/x.archive"])
        #expect(try String(contentsOf: original, encoding: .utf8) == "mod")

        try installer.setEnabled(record, false)
        #expect(!FileManager.default.fileExists(atPath: game.appending(path: "archive/pc/mod/x.archive").path))
        try installer.setEnabled(record, true)
        #expect(FileManager.default.fileExists(atPath: game.appending(path: "archive/pc/mod/x.archive").path))

        try installer.uninstall(try #require(installer.installed().first))
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(installer.installed().isEmpty)
    }

    @Test func deadIsland2TakesOnlyPakFiles() async throws {
        let target = folder("di2")
        let installer = NexusModInstaller(layout: .paksInto(target), dataFolder: folder("data"))
        let archive = try await zip(["Mod/pakchunk99-Mod.pak": "p", "Mod/pakchunk99-Mod.utoc": "u", "Mod/readme.txt": "r"], name: "d.zip")
        let record = try await installer.install(archive: archive, fileName: "d.zip", modID: 4, fileID: 40, name: "D", version: "1")
        #expect(Set(record.files) == ["pakchunk99-Mod.pak", "pakchunk99-Mod.utoc"])
    }

    @Test func refusesOtherFormatsAndForeignLayouts() async throws {
        let installer = NexusModInstaller(layout: .mergeIntoGame(folder("cp2"), roots: ["archive"]), dataFolder: folder("data"))
        await #expect(throws: NexusModInstaller.Failure.unsupportedFormat("7z")) {
            try await installer.install(archive: URL(filePath: "/dev/null"), fileName: "x.7z", modID: 5, fileID: 50, name: "X", version: "1")
        }
        let archive = try await zip(["random/file.txt": "x"], name: "r.zip")
        await #expect(throws: NexusModInstaller.Failure.nothingRecognised) {
            try await installer.install(archive: archive, fileName: "r.zip", modID: 6, fileID: 60, name: "R", version: "1")
        }
    }
}
