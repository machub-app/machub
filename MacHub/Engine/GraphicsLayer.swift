import Foundation

/// Which Direct3D implementation a program gets. Wine's own wined3d (OpenGL) is the default; the others are
/// shipped in the runtime and deployed per program, so Steam's UI and each game can use their own.
enum GraphicsLayer: String, Codable, Sendable {
    /// Wine's built-in Direct3D over OpenGL. Nothing to deploy.
    case wined3d
    /// DXVK-macOS: Direct3D 10/11 → Vulkan → MoltenVK → Metal.
    case dxvk
    /// DXMT: Direct3D 10/11 → Metal. Its winemetal bridge stays a builtin inside the runtime.
    case dxmt
    /// Apple's D3DMetal, from a Game Porting Toolkit the user installed. Not deployed per program yet.
    case d3dmetal

    /// The DLLs the layer replaces next to a program. DXVK-macOS ships no dxgi.dll: Wine's own is the one it
    /// is built against. DXMT needs its own dxgi.
    var dlls: [String] {
        switch self {
        case .wined3d, .d3dmetal: []
        case .dxvk: ["d3d11", "d3d10core"]
        case .dxmt: ["d3d11", "dxgi", "d3d10core"]
        }
    }

    func folder(in runtime: WineRuntime, is64Bit: Bool) -> URL? {
        let arch = is64Bit ? "x86_64-windows" : "i386-windows"
        switch self {
        case .wined3d, .d3dmetal: return nil
        case .dxvk: return runtime.dxvk.appending(path: arch)
        case .dxmt: return runtime.dxmt.appending(path: arch)
        }
    }
}

/// Puts a layer's DLLs next to a program and tells Wine to prefer them for that program only
/// (`HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides`). Nothing global changes in the prefix, and a DLL the game
/// shipped itself is never touched: MacHub only replaces files it wrote, listed in `machub-graphics.json`.
enum GraphicsDeployment {
    /// winebuild writes this at offset 0x40 of every builtin PE. A DLL that carries it is taken by Wine's loader
    /// as "its own" and swapped for the runtime's builtin of the same name, so app-local copies must not have it.
    static let builtinMarker = Data("Wine builtin DLL".utf8)
    static let markerOffset = 0x40
    static let ledgerName = "machub-graphics.json"

    struct Ledger: Codable, Equatable {
        var layer: GraphicsLayer
        var dlls: [String]
    }

    /// Copies the layer's DLLs into `programFolder` as native PEs. Returns the DLL names deployed.
    @discardableResult
    static func deploy(_ layer: GraphicsLayer, runtime: WineRuntime, programFolder: URL, is64Bit: Bool = true) throws -> [String] {
        guard let source = layer.folder(in: runtime, is64Bit: is64Bit) else { return [] }
        for dll in layer.dlls {
            var data = try Data(contentsOf: source.appending(path: "\(dll).dll"))
            stripBuiltinMarker(&data)
            let destination = programFolder.appending(path: "\(dll).dll")
            if (try? Data(contentsOf: destination)) != data {
                try data.write(to: destination, options: .atomic)
            }
        }
        return layer.dlls
    }

    /// Switches one program folder to `layer`, keeping the game's own DLLs. Returns the DLLs now overridden.
    static func switchFolder(_ folder: URL, to layer: GraphicsLayer, runtime: WineRuntime, is64Bit: Bool) throws -> [String] {
        let fm = FileManager.default
        let ledgerURL = folder.appending(path: ledgerName)
        let previous = (try? Data(contentsOf: ledgerURL)).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) }
        let ours = Set(previous?.dlls ?? [])
        // Remove what MacHub put there before; never a file it didn't write.
        for dll in ours where !layer.dlls.contains(dll) { try? fm.removeItem(at: folder.appending(path: "\(dll).dll")) }
        let wanted = layer.dlls.filter { dll in ours.contains(dll) || !fm.fileExists(atPath: folder.appending(path: "\(dll).dll").path) }
        guard !wanted.isEmpty else {
            try? fm.removeItem(at: ledgerURL)
            return []
        }
        guard let source = layer.folder(in: runtime, is64Bit: is64Bit) else { return [] }
        for dll in wanted {
            var data = try Data(contentsOf: source.appending(path: "\(dll).dll"))
            stripBuiltinMarker(&data)
            try data.write(to: folder.appending(path: "\(dll).dll"), options: .atomic)
        }
        try JSONEncoder().encode(Ledger(layer: layer, dlls: wanted)).write(to: ledgerURL, options: .atomic)
        return wanted
    }

    static func stripBuiltinMarker(_ data: inout Data) {
        let range = markerOffset..<(markerOffset + builtinMarker.count)
        guard data.count >= range.upperBound, data.subdata(in: range) == builtinMarker else { return }
        data.replaceSubrange(range, with: Data(count: builtinMarker.count))
    }

    /// A .reg document: `native,builtin` for each listed DLL of each executable; an empty list clears the key
    /// (the program goes back to Wine's defaults).
    static func overridesDocument(_ programs: [String: [String]]) -> String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        for (exe, dlls) in programs.sorted(by: { $0.key < $1.key }) {
            let key = #"HKEY_CURRENT_USER\Software\Wine\AppDefaults\\#(exe)\DllOverrides"#
            if dlls.isEmpty {
                lines.append("[-\(key)]")
            } else {
                lines.append("[\(key)]")
                for dll in dlls.sorted() { lines.append("\"\(dll)\"=\"native,builtin\"") }
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    /// Imports the overrides into the prefix's registry (`regedit /S`).
    static func writeOverrides(_ programs: [String: [String]], runtime: WineRuntime, prefix: InstalledPrefix) async throws {
        guard !programs.isEmpty else { return }
        let file = prefix.url.appending(path: "drive_c/users/Public/machub-overrides.reg")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try overridesDocument(programs).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let env = WineEnvironment(runtime: runtime, prefix: prefix).variables
        let result = try await ProcessRunner.run(runtime.wine, ["regedit", "/S", file.path], timeout: 60, environment: env)
        guard result.status == 0 else { throw PrefixError.bootFailed("regedit: \(result.stderr.suffix(200))") }
    }

    /// Prepares every executable of an installed title for `choice` before it starts: each folder holding an .exe
    /// gets the resolved layer's DLLs, and each .exe its override. Returns the layer per executable name.
    @discardableResult
    static func prepare(installFolder: URL, executables: [String], choice: GraphicsChoice, d3dmetalAvailable: Bool,
                        runtime: WineRuntime, prefix: InstalledPrefix) async throws -> [String: GraphicsLayer] {
        var overrides: [String: [String]] = [:]
        var layers: [String: GraphicsLayer] = [:]
        for relative in executables {
            let exe = installFolder.appending(path: relative)
            let data = (try? Data(contentsOf: exe, options: .mappedIfSafe)) ?? Data()
            let api = GraphicsAPI(imports: PEImports.dlls(in: data))
            let layer = choice.resolved(for: api, d3dmetalAvailable: d3dmetalAvailable)
            let is64Bit = (try? WindowsFile.classify(data)).map { if case .executable(.x86, _) = $0 { false } else { true } } ?? true
            let dlls = try switchFolder(exe.deletingLastPathComponent(), to: layer, runtime: runtime, is64Bit: is64Bit)
            overrides[exe.lastPathComponent] = dlls
            layers[exe.lastPathComponent] = layer
        }
        try await writeOverrides(overrides, runtime: runtime, prefix: prefix)
        return layers
    }
}
