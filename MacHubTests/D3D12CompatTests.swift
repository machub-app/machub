import Foundation
import Testing
@testable import MacHub

/// BeamNG.drive 0.40.1 imports d3d12.dll; Whisky's DXMT mode disables it, so the game couldn't load (2026-10-21).
@Suite struct D3D12CompatTests {
    /// A minimal 64-bit PE whose import directory lists `dll`.
    private func pe(importing dll: String) -> Data {
        var b = [UInt8](repeating: 0, count: 0x400)
        func put16(_ v: Int, _ o: Int) { b[o] = UInt8(v & 0xFF); b[o + 1] = UInt8(v >> 8 & 0xFF) }
        func put32(_ v: Int, _ o: Int) { for i in 0..<4 { b[o + i] = UInt8(v >> (8 * i) & 0xFF) } }
        b[0] = 0x4D; b[1] = 0x5A; put32(0x40, 0x3C)
        b[0x40] = 0x50; b[0x41] = 0x45
        put16(0x8664, 0x44); put16(1, 0x46); put16(240, 0x54)
        let optional = 0x58
        put16(0x20B, optional)
        put32(0x1000, optional + 112 + 8); put32(40, optional + 112 + 12)       // import directory
        let section = optional + 240
        put32(0x200, section + 8); put32(0x1000, section + 12); put32(0x200, section + 16); put32(0x200, section + 20)
        put32(0x1100, 0x200 + 12)                                              // first descriptor's name RVA
        for (i, c) in dll.utf8.enumerated() { b[0x300 + i] = c }
        return Data(b)
    }

    @Test func spotsAnExecutableThatImportsD3D12() {
        #expect(D3D12Compat.importedDLLs(pe(importing: "D3D12.dll")) == ["d3d12.dll"])
        #expect(D3D12Compat.importedDLLs(pe(importing: "d3d11.dll")) == ["d3d11.dll"])
        #expect(D3D12Compat.importedDLLs(Data("not a program".utf8)).isEmpty)
    }

    @Test func readsTheFileOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "machub-d3d12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pe(importing: "d3d12.dll").write(to: dir.appending(path: "game.exe"))
        try pe(importing: "d3d11.dll").write(to: dir.appending(path: "launcher.exe"))
        #expect(D3D12Compat.importsD3D12(dir.appending(path: "game.exe")))
        #expect(!D3D12Compat.importsD3D12(dir.appending(path: "launcher.exe")))
    }

    @Test func overridesOnlyTheGivenExecutable() {
        #expect(D3D12Compat.regArguments(executable: "BeamNG.drive.x64.exe", dll: "d3d12") ==
                ["add", "HKCU\\Software\\Wine\\AppDefaults\\BeamNG.drive.x64.exe\\DllOverrides", "/v", "d3d12", "/d", "builtin", "/f"])
    }
}
