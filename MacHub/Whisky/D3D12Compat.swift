import Foundation

/// Whisky's "recommended" graphics mode (DXMT) disables d3d12.dll in the bottle's registry so games fall back to
/// Direct3D 11. A game whose executable *imports* d3d12.dll then can't even load: BeamNG.drive 0.40.1 stopped with
/// c0000135 ("Library d3d12.dll not found") on Johan's Mac, 2026-10-21, while it ran with d3d12 loadable.
/// The fix is per executable: Wine's AppDefaults key wins over the global DllOverrides Whisky re-imports before
/// every run, so other games keep Whisky's behaviour and keep falling back to Direct3D 11.
enum D3D12Compat {
    static let dlls = ["d3d12", "d3d12core"]

    /// The executable lists d3d12.dll among its load-time imports (not a delay-load, which only loads on use).
    static func importsD3D12(_ exe: URL) -> Bool {
        guard let data = try? Data(contentsOf: exe, options: .mappedIfSafe) else { return false }
        return importedDLLs(data).contains("d3d12.dll")
    }

    /// Names of the DLLs in a PE file's import directory, lowercased. Empty for anything that isn't a valid PE.
    static func importedDLLs(_ data: Data) -> Set<String> {
        func u16(_ o: Int) -> Int { data.count >= o + 2 ? Int(data.littleEndian(UInt16.self, at: o)) : 0 }
        func u32(_ o: Int) -> Int { data.count >= o + 4 ? Int(data.littleEndian(UInt32.self, at: o)) : 0 }
        guard data.count > 0x40, data.prefix(2) == Data([0x4D, 0x5A]) else { return [] }
        let pe = u32(0x3C)
        guard pe > 0, data.count > pe + 24, data[pe..<pe + 4].elementsEqual([0x50, 0x45, 0, 0]) else { return [] }
        let sections = u16(pe + 6), optional = pe + 24, optionalSize = u16(pe + 20)
        let directories = optional + (u16(optional) == 0x20B ? 112 : 96)
        let importRVA = u32(directories + 8)
        let table = optional + optionalSize
        func offset(_ rva: Int) -> Int? {
            for i in 0..<sections {
                let header = table + i * 40
                let virtual = u32(header + 12), size = max(u32(header + 8), u32(header + 16)), raw = u32(header + 20)
                if rva >= virtual, rva < virtual + size { return rva - virtual + raw }
            }
            return nil
        }
        guard importRVA > 0, var entry = offset(importRVA) else { return [] }
        var names = Set<String>()
        while entry + 20 <= data.count, names.count < 512 {
            let nameRVA = u32(entry + 12)
            guard nameRVA != 0, let start = offset(nameRVA), start < data.count else { break }
            let end = data[start...].firstIndex(of: 0) ?? data.endIndex
            names.insert(String(decoding: data[start..<end], as: UTF8.self).lowercased())
            entry += 20
        }
        return names
    }

    /// `reg add` arguments for one executable and DLL.
    static func regArguments(executable: String, dll: String) -> [String] {
        ["add", "HKCU\\Software\\Wine\\AppDefaults\\\(executable)\\DllOverrides", "/v", dll, "/d", "builtin", "/f"]
    }
}
