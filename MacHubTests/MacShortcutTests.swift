import CoreGraphics
import Foundation
import Testing
@testable import MacHub

@Suite struct MacShortcutTests {
    @Test func parsesPlayLinks() {
        #expect(MacHubLink(URL(string: "machub://play/284160")!) == .play(appID: 284160))
        #expect(MacHubLink(URL(string: "MACHUB://PLAY/284160/")!) == .play(appID: 284160))
        #expect(MacHubLink.play(appID: 284160).url.absoluteString == "machub://play/284160")
        #expect(MacHubLink(URL(string: "machub://play/abc")!) == nil)
        #expect(MacHubLink(URL(string: "machub://play/0")!) == nil)
        #expect(MacHubLink(URL(string: "machub://play/1/2")!) == nil)
        #expect(MacHubLink(URL(string: "machub://open/284160")!) == nil)
        #expect(MacHubLink(URL(string: "nxm://play/284160")!) == nil)
    }

    @Test func makesFinderSafeNames() {
        #expect(MacShortcut.bundleName(for: "BeamNG.drive") == "BeamNG.drive.app")
        #expect(MacShortcut.bundleName(for: "AC/DC: Live") == "AC-DC- Live.app")
        #expect(MacShortcut.bundleName(for: " .hidden ") == "hidden.app")
        #expect(MacShortcut.bundleName(for: "") == "Game.app")
    }

    @Test func writesAMinimalSignedBundle() async throws {
        let folder = try temporaryFolder()
        let app = try await MacShortcut.create(name: "BeamNG.drive", appID: 284160, artwork: try artwork(), in: folder)
        #expect(app.lastPathComponent == "BeamNG.drive.app")

        let info = try #require(NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any])
        #expect(info["CFBundleIdentifier"] as? String == "app.machub.shortcut.284160")
        #expect(info["CFBundleExecutable"] as? String == "launch")
        #expect(info["CFBundlePackageType"] as? String == "APPL")
        #expect(info["CFBundleIconFile"] as? String == "AppIcon")

        let script = app.appending(path: "Contents/MacOS/launch")
        #expect(try String(contentsOf: script, encoding: .utf8) == "#!/bin/sh\nexec /usr/bin/open \"machub://play/284160\"\n")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
        #expect(FileManager.default.fileExists(atPath: app.appending(path: "Contents/Resources/AppIcon.icns").path))

        let verify = try await ProcessRunner.run(URL(filePath: "/usr/bin/codesign"), ["--verify", "--strict", app.path], timeout: 30)
        #expect(verify.status == 0, "\(verify.stderr)")
        // Only the bundle and nothing else (no staging leftovers).
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["BeamNG.drive.app"])
    }

    @Test func replacesItsOwnShortcutsOnly() throws {
        let folder = try temporaryFolder()
        let first = try MacShortcut.write(name: "Game", appID: 1, artwork: nil, in: folder)
        let again = try MacShortcut.write(name: "Game", appID: 2, artwork: nil, in: folder)
        #expect(first == again)
        let info = try #require(NSDictionary(contentsOf: again.appending(path: "Contents/Info.plist")))
        #expect(info["CFBundleIdentifier"] as? String == "app.machub.shortcut.2")
        #expect(info["CFBundleIconFile"] == nil)

        // Someone else's app with the same name stays exactly as it is.
        let foreign = folder.appending(path: "Other.app/Contents")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.other"], format: .xml, options: 0)
        try plist.write(to: foreign.appending(path: "Info.plist"))
        #expect(throws: MacShortcutError.self) { try MacShortcut.write(name: "Other", appID: 3, artwork: nil, in: folder) }
        #expect(try Data(contentsOf: foreign.appending(path: "Info.plist")) == plist)
    }

    @Test func findsLocalLibraryArt() throws {
        let root = try temporaryFolder()
        let art = root.appending(path: "appcache/librarycache/284160/5b9d29c9/library_capsule.jpg")
        try FileManager.default.createDirectory(at: art.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: art)
        #expect(MacShortcut.localArtwork(appID: 284160, steamRoot: root)?.lastPathComponent == "library_capsule.jpg")
        #expect(MacShortcut.localArtwork(appID: 1, steamRoot: root) == nil)
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "machub-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func artwork() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 300, height: 450, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 450))
        return try #require(context.makeImage())
    }
}
