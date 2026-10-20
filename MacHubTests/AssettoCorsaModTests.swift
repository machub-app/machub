import Foundation
import Testing
@testable import MacHub

/// Assetto Corsa mods through the Nexus installer: layouts, archives, folders, disable, remove. Fake game folders only.
@Suite struct AssettoCorsaModTests {
    private let fm = FileManager.default

    private func temp(_ label: String) throws -> URL {
        let url = fm.temporaryDirectory.appending(path: "machub-ac-\(label)-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Zips `folder`'s contents with macOS's own ditto, as a downloaded mod would be.
    private func zip(_ folder: URL) async throws -> URL {
        let archive = folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + ".zip")
        let result = try await ProcessRunner.run(URL(filePath: "/usr/bin/ditto"), ["-c", "-k", folder.path, archive.path], timeout: 30)
        #expect(result.status == 0)
        return archive
    }

    private func installer(game: URL) throws -> NexusModInstaller {
        NexusModInstaller(layout: .assettoCorsa(game), dataFolder: try temp("data"))
    }

    @Test func assettoCorsaUsesItsOwnLayout() {
        let layout = NexusModInstaller.layout(appID: 244210, installPath: "/games/assettocorsa", prefix: URL(filePath: "/bottle"))
        #expect(layout == .assettoCorsa(URL(filePath: "/games/assettocorsa")))
        #expect(NexusMods.domains[244210] == "assettocorsa")
    }

    @Test func archiveLaidOutLikeTheGameIsMerged() async throws {
        let game = try temp("game"), mod = try temp("mod")
        try write("{}", to: mod.appending(path: "content/cars/ks_test/ui/ui_car.json"))
        try write("data", to: mod.appending(path: "content/cars/ks_test/data.acd"))
        let record = try await installer(game: game).install(archive: try await zip(mod), fileName: "ks_test.zip", modID: 1, fileID: 1, name: "Test car", version: "1")
        #expect(Set(record.files) == ["content/cars/ks_test/ui/ui_car.json", "content/cars/ks_test/data.acd"])
        #expect(fm.fileExists(atPath: game.appending(path: "content/cars/ks_test/data.acd").path))
    }

    @Test func bareCarAndTrackFoldersGoUnderContent() async throws {
        let game = try temp("game"), mod = try temp("mod")
        try write("{}", to: mod.appending(path: "my_car/ui/ui_car.json"))
        try write("{}", to: mod.appending(path: "my_track/ui/gp/ui_track.json"))
        let record = try await installer(game: game).install(archive: try await zip(mod), fileName: "pack.zip", modID: 2, fileID: 1, name: "Pack", version: "")
        #expect(Set(record.files) == ["content/cars/my_car/ui/ui_car.json", "content/tracks/my_track/ui/gp/ui_track.json"])
    }

    @Test func anUnpackedFolderInstallsToo() async throws {
        let game = try temp("game"), mod = try temp("folder")
        try write("{}", to: mod.appending(path: "content/tracks/club/ui/ui_track.json"))
        let record = try await installer(game: game).install(archive: mod, fileName: mod.lastPathComponent, modID: -5, fileID: 0,
                                                              name: "Club", version: "", source: "file")
        #expect(record.source == "file")
        #expect(fm.fileExists(atPath: game.appending(path: "content/tracks/club/ui/ui_track.json").path))
        #expect(fm.fileExists(atPath: mod.appending(path: "content/tracks/club/ui/ui_track.json").path), "the user's folder is copied, not moved")
    }

    @Test func disableHidesTheModAndEnableBringsItBack() async throws {
        let game = try temp("game"), mod = try temp("mod")
        try write("{}", to: mod.appending(path: "content/cars/c1/ui/ui_car.json"))
        let installer = try installer(game: game)
        let record = try await installer.install(archive: try await zip(mod), fileName: "c1.zip", modID: 3, fileID: 1, name: "C1", version: "")
        let live = game.appending(path: "content/cars/c1/ui/ui_car.json")
        try installer.setEnabled(record, false)
        #expect(!fm.fileExists(atPath: live.path))
        #expect(installer.installed().first?.enabled == false)
        try installer.setEnabled(record, true)
        #expect(fm.fileExists(atPath: live.path))
    }

    @Test func replacedFilesAreBackedUpAndRestored() async throws {
        let game = try temp("game"), mod = try temp("mod")
        let original = game.appending(path: "content/cars/abarth/data.acd")
        try write("original", to: original)
        try write("modded", to: mod.appending(path: "content/cars/abarth/data.acd"))
        let installer = try installer(game: game)
        let record = try await installer.install(archive: try await zip(mod), fileName: "abarth.zip", modID: 4, fileID: 1, name: "Abarth", version: "")
        #expect(try String(contentsOf: original, encoding: .utf8) == "modded")
        try installer.uninstall(record)
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(installer.installed().isEmpty)
    }

    @Test func otherFormatsAreRefusedClearly() async throws {
        let game = try temp("game"), dir = try temp("file")
        let exe = dir.appending(path: "setup.exe")
        try write("MZ", to: exe)
        await #expect(throws: NexusModInstaller.Failure.unsupportedFormat("exe")) {
            try await installer(game: game).install(archive: exe, fileName: "setup.exe", modID: 6, fileID: 1, name: "x", version: "")
        }
    }

    @Test func sevenZipAndRarAreAccepted() {
        #expect(Set(NexusModInstaller.archiveExtensions) == ["zip", "7z", "rar"])
    }
}

@MainActor @Suite struct DownloadsWatchTests {
    @Test func noticesANewFinishedArchive() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "machub-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appending(path: "old.zip"))
        let watch = DownloadsWatch(folder: folder, duration: .seconds(5), interval: .milliseconds(100))
        watch.start()
        try Data("partial".utf8).write(to: folder.appending(path: "car.zip.crdownload"))
        try Data("finished".utf8).write(to: folder.appending(path: "car.zip"))
        for _ in 0..<40 where watch.found == nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(watch.found?.lastPathComponent == "car.zip")
        #expect(!watch.isWatching)
    }

    @Test func stopsWhenAsked() {
        let watch = DownloadsWatch(folder: FileManager.default.temporaryDirectory, duration: .seconds(60))
        watch.start()
        #expect(watch.isWatching)
        watch.stop()
        #expect(!watch.isWatching)
    }
}
