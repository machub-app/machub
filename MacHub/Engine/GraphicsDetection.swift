import Foundation

/// Reads which DLLs a Windows executable imports (normal and delay-load import tables), straight from the PE file.
enum PEImports {
    static func dlls(in url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return dlls(in: data)
    }

    static func dlls(in data: Data) -> Set<String> {
        guard data.count > 0x40, data[data.startIndex] == 0x4D, data[data.startIndex + 1] == 0x5A else { return [] }
        let pe = Int(data.littleEndian(UInt32.self, at: 0x3C))
        guard pe > 0, pe + 24 < data.count, data.littleEndian(UInt32.self, at: pe) == 0x0000_4550 else { return [] }
        let sectionCount = Int(data.littleEndian(UInt16.self, at: pe + 6))
        let optionalSize = Int(data.littleEndian(UInt16.self, at: pe + 20))
        let optional = pe + 24
        let magic = data.littleEndian(UInt16.self, at: optional)
        let directories = optional + (magic == 0x20B ? 112 : 96)
        let sections = optional + optionalSize

        func offset(ofRVA rva: Int) -> Int? {
            for i in 0..<sectionCount {
                let s = sections + i * 40
                let virtualAddress = Int(data.littleEndian(UInt32.self, at: s + 12))
                let virtualSize = max(Int(data.littleEndian(UInt32.self, at: s + 8)), Int(data.littleEndian(UInt32.self, at: s + 16)))
                let raw = Int(data.littleEndian(UInt32.self, at: s + 20))
                if rva >= virtualAddress, rva < virtualAddress + virtualSize { return raw + rva - virtualAddress }
            }
            return nil
        }

        func string(atRVA rva: Int) -> String? {
            guard let start = offset(ofRVA: rva), start < data.count else { return nil }
            let end = data[(data.startIndex + start)...].prefix(256).firstIndex(of: 0) ?? data.endIndex
            return String(decoding: data[(data.startIndex + start)..<end], as: UTF8.self).lowercased()
        }

        var names = Set<String>()
        // Directory 1: imports (20-byte descriptors, name RVA at +12). Directory 13: delay imports (32 bytes, name at +4).
        for (index, size, nameField) in [(1, 20, 12), (13, 32, 4)] {
            let entry = directories + index * 8
            guard entry + 8 <= data.count else { continue }
            let rva = Int(data.littleEndian(UInt32.self, at: entry))
            guard rva != 0, var cursor = offset(ofRVA: rva) else { continue }
            for _ in 0..<512 {
                guard cursor + size <= data.count else { break }
                let nameRVA = Int(data.littleEndian(UInt32.self, at: cursor + nameField))
                if nameRVA == 0 { break }
                if let name = string(atRVA: nameRVA), !name.isEmpty { names.insert(name) }
                cursor += size
            }
        }
        return names
    }
}

/// The graphics API an executable uses, from its imports.
enum GraphicsAPI: String, Equatable, Sendable {
    case direct3d12, direct3d11, direct3d9, vulkan, opengl, unknown

    init(imports: Set<String>) {
        if imports.contains("d3d12.dll") { self = .direct3d12 }
        else if imports.contains("d3d11.dll") || imports.contains("d3d10.dll") || imports.contains("d3d10_1.dll") || imports.contains("dxgi.dll") { self = .direct3d11 }
        else if imports.contains("d3d9.dll") || imports.contains("d3d8.dll") { self = .direct3d9 }
        else if imports.contains("vulkan-1.dll") { self = .vulkan }
        else if imports.contains("opengl32.dll") { self = .opengl }
        else { self = .unknown }
    }
}

extension GraphicsChoice {
    /// The layer a title actually gets. DirectX 12 has a single working path on macOS (D3DMetal); without it the
    /// title stays on DXMT, which some DX12 games accept through their DX11 fallback.
    func resolved(for api: GraphicsAPI, d3dmetalAvailable: Bool) -> GraphicsLayer {
        switch self {
        case .dxmt: .dxmt
        case .dxvk: .dxvk
        case .wined3d: .wined3d
        case .d3dmetal: d3dmetalAvailable ? .d3dmetal : .dxmt
        case .automatic:
            switch api {
            case .direct3d12: d3dmetalAvailable ? .d3dmetal : .dxmt
            case .direct3d11, .unknown: .dxmt
            case .direct3d9, .vulkan, .opengl: .wined3d
            }
        }
    }
}

/// A title's own choices, kept by MacHub (never written into the game's folder except the graphics DLLs).
struct TitleSettings: Codable, Equatable, Sendable {
    var graphics: GraphicsChoice = .automatic
    /// Extra command-line arguments for programs MacHub starts directly.
    var arguments = ""
    /// Follow highball-db's renderer and launch options while the title's own are left on Automatic / empty.
    var useRecommended = true
    /// Variables the game is started with (from applied recipes or the user's advanced settings).
    var environment: [String: String] = [:]
    /// Per-game overrides of the engine's settings (nil = follow Settings › Windows Games).
    var advanced = TitleAdvanced()
    /// The game's own renderer when it picks one by launch option (`GameRenderers`), nil = automatic.
    var gameRenderer: String?

    init(graphics: GraphicsChoice = .automatic, arguments: String = "", useRecommended: Bool = true,
         environment: [String: String] = [:]) {
        self.graphics = graphics
        self.arguments = arguments
        self.useRecommended = useRecommended
        self.environment = environment
    }

    /// Settings saved by older versions lack the newer keys: each falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        graphics = try c.decodeIfPresent(GraphicsChoice.self, forKey: .graphics) ?? .automatic
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        useRecommended = try c.decodeIfPresent(Bool.self, forKey: .useRecommended) ?? true
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        advanced = try c.decodeIfPresent(TitleAdvanced.self, forKey: .advanced) ?? TitleAdvanced()
        gameRenderer = try c.decodeIfPresent(String.self, forKey: .gameRenderer)
    }

    static let fileName = "title-settings.json"

    /// The launch options as separate arguments: split on spaces, with "double quotes" keeping spaces together.
    var argumentList: [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var hasToken = false
        for character in arguments {
            if character == "\"" { quoted.toggle(); hasToken = true }
            else if character.isWhitespace && !quoted {
                if hasToken { result.append(current); current = ""; hasToken = false }
            } else { current.append(character); hasToken = true }
        }
        if hasToken { result.append(current) }
        return result
    }

    static func all() -> [String: TitleSettings] { LocalData.load([String: TitleSettings].self, from: fileName) ?? [:] }
    static func save(_ all: [String: TitleSettings]) { LocalData.save(all, to: fileName) }
}

/// A game's own engine settings, each one optional so the global setting applies until the user picks something.
struct TitleAdvanced: Codable, Equatable, Sendable {
    var sync: EngineSettings.Sync?
    var advertiseAVX: Bool?
    var largeAddressAware: Bool?
    var metalHUD: Bool?
    /// Wine virtual desktop for the game's executables, "1920x1080"; nil = the game's own windows.
    var virtualDesktop: String?
    /// Extra Wine DLL overrides, as WINEDLLOVERRIDES writes them: "dinput8=n,b;xinput1_3=b".
    var dllOverrides = ""

    var isDefault: Bool { self == TitleAdvanced() }

    /// The variables these overrides set (MSYNC/ESYNC, AVX, 4 GB, Metal HUD, DLL overrides).
    func environment(supportsMsync: Bool) -> [String: String] {
        var env: [String: String] = [:]
        if let sync {
            env["WINEMSYNC"] = "0"; env["WINEESYNC"] = "0"
            switch sync {
            case .msync: env[supportsMsync ? "WINEMSYNC" : "WINEESYNC"] = "1"
            case .esync: env["WINEESYNC"] = "1"
            case .off: break
            }
        }
        if let advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = advertiseAVX ? "1" : "0" }
        if let largeAddressAware { env["WINE_LARGE_ADDRESS_AWARE"] = largeAddressAware ? "1" : "0" }
        if let metalHUD {
            env["MTL_HUD_ENABLED"] = metalHUD ? "1" : "0"
            env["MTL_HUD_LOG_ENABLED"] = metalHUD ? "1" : "0"
        }
        let overrides = dllOverrides.trimmingCharacters(in: .whitespaces)
        if !overrides.isEmpty { env["WINEDLLOVERRIDES"] = overrides }
        return env
    }

    static let desktopSizes = ["1280x720", "1440x900", "1600x900", "1920x1080", "2560x1440"]

    /// Registry for the virtual desktop of each executable: a named desktop, or the key removed.
    static func desktopDocument(executables: [String], size: String?) -> String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        if let size {
            lines += [#"[HKEY_CURRENT_USER\Software\Wine\Explorer\Desktops]"#, "\"MacHub\"=\"\(size)\"", ""]
        }
        for exe in executables.sorted() {
            let key = #"HKEY_CURRENT_USER\Software\Wine\AppDefaults\\#(exe)\Explorer"#
            lines += size == nil ? ["[-\(key)]", ""] : ["[\(key)]", #""Desktop"="MacHub""#, ""]
        }
        return lines.joined(separator: "\n")
    }
}
