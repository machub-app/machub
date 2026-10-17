import Foundation
import Testing
@testable import MacHub

@Suite struct BottleReaderTests {
    let container: URL

    init() throws {
        container = FileManager.default.temporaryDirectory.appending(path: "machub-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container.appending(path: "Bottles"), withIntermediateDirectories: true)
    }

    private func makeBottle(_ url: URL, name: String, windows: String, driveC: Bool) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Same shape as the Metadata.plist files written by Whisky 2.3.5.
        let metadata: [String: Any] = [
            "info": ["name": name, "pins": [], "blocklist": []],
            "wineConfig": ["windowsVersion": windows],
        ]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: url.appending(path: "Metadata.plist"))
        if driveC {
            try FileManager.default.createDirectory(at: url.appending(path: "drive_c"), withIntermediateDirectories: true)
        }
    }

    private func writeRegistry(_ paths: [Any]) throws {
        let plist: [String: Any] = ["fileVersion": ["major": 1, "minor": 0, "patch": 0], "paths": paths]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: container.appending(path: "BottleVM.plist"))
    }

    @Test func emptyRegistryLeavesFoldersAsOrphans() throws {
        // Mirrors the dev Mac: Bottles/ has folders with only Metadata.plist, BottleVM paths = [].
        try makeBottle(container.appending(path: "Bottles/AAA"), name: "asseto corsa", windows: "win10", driveC: false)
        try makeBottle(container.appending(path: "Bottles/BBB"), name: "steam", windows: "win11", driveC: false)
        try writeRegistry([])

        let bottles = BottleReader.read(container: container)
        #expect(bottles.map(\.name) == ["asseto corsa", "steam"])
        #expect(bottles.allSatisfy { !$0.isRegistered && !$0.hasDriveC })
        #expect(bottles.last?.windowsVersion == "win11")
    }

    @Test func registeredBottlesAnywhereAreIncludedOnce() throws {
        let inside = container.appending(path: "Bottles/CCC")
        let outside = container.appending(path: "External/Steam")
        try makeBottle(inside, name: "Steam", windows: "win10", driveC: true)
        try makeBottle(outside, name: "Tools", windows: "win10", driveC: true)
        try writeRegistry([["relative": inside.absoluteString + "/"], outside.path])

        let bottles = BottleReader.read(container: container)
        #expect(bottles.count == 2)
        #expect(bottles.allSatisfy { $0.isRegistered && $0.hasDriveC })
    }

    @Test func missingContainerReadsAsEmpty() {
        #expect(BottleReader.read(container: container.appending(path: "nope")).isEmpty)
    }
}
