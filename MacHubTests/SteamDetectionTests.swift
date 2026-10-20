import Foundation
import Testing
@testable import MacHub

@Suite struct SteamDetectionTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "machub-steam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Smallest header WindowsFile accepts as a 32-bit Windows program.
    private var peExecutable: Data {
        var bytes = [UInt8](repeating: 0, count: 0x80)
        bytes[0] = 0x4D; bytes[1] = 0x5A               // MZ
        bytes[0x3C] = 0x40                              // PE header offset
        bytes[0x40...0x43] = [0x50, 0x45, 0, 0]         // PE\0\0
        bytes[0x44] = 0x4C; bytes[0x45] = 0x01          // machine: x86
        bytes[0x56] = 0x02; bytes[0x57] = 0x01          // characteristics: executable, 32-bit (not a DLL)
        return Data(bytes)
    }

    @Test func findsSteamInABottle() throws {
        let bottle = try temp()
        #expect(!SteamSetup.hasSteam(inPrefix: bottle))
        let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steam, withIntermediateDirectories: true)
        try Data().write(to: steam.appending(path: "steam.exe"))
        #expect(SteamSetup.hasSteam(inPrefix: bottle))
    }

    @Test func reusesTheInstallerAlreadyOnTheMac() throws {
        let cache = try temp()
        #expect(SteamSetup.cachedInstaller(in: cache) == nil)
        try FileManager.default.createDirectory(at: cache.appending(path: "installers"), withIntermediateDirectories: true)
        let older = cache.appending(path: "installers/SteamSetup.exe")
        try peExecutable.write(to: older)
        #expect(SteamSetup.cachedInstaller(in: cache)?.path == older.path)
    }

    @Test func ignoresACachedFileThatIsntAnInstaller() throws {
        let cache = try temp()
        try Data("<html>error page</html>".utf8).write(to: cache.appending(path: "SteamSetup.exe"))
        #expect(SteamSetup.cachedInstaller(in: cache) == nil)
    }

    // Engine 1.0.5 on macOS 26.5.2: wineboot dies with signal 11 and prints nothing (2026-10-20).
    @Test func explainsTheMissingPipe2Crash() {
        let crash = ProcessResult(status: 11, stdout: "", stderr: "")
        #expect(PrefixStore.describeExit(crash, systemHasPipe2: false).contains("pipe2"))
        #expect(!PrefixStore.describeExit(crash, systemHasPipe2: true).contains("pipe2"))
        #expect(!PrefixStore.describeExit(ProcessResult(status: 1, stdout: "", stderr: "x"), systemHasPipe2: false).contains("pipe2"))
    }

    @Test func thisMacLacksPipe2OnlyBeforeMacOS27() {
        #expect(WinePrefix.systemHasPipe2 == (ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27))
    }
}
