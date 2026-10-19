import Foundation

/// The engine options a user can change, applied to every Wine process MacHub starts (environment) and to each
/// prefix's registry (Mac driver keys). Defaults favour speed and match what CrossOver and Whisky ship.
struct EngineSettings: Codable, Equatable, Sendable {
    /// How Wine implements Windows synchronization objects. msync (Mach semaphores) is CrossOver's and the fastest
    /// on macOS; esync (eventfd) is the portable fallback; off uses wineserver round trips (slowest, most compatible).
    enum Sync: String, Codable, CaseIterable, Sendable {
        case msync, esync, off
    }

    enum LogLevel: String, Codable, CaseIterable, Sendable {
        /// Nothing: the least overhead.
        case off
        /// Wine's errors only (default): useful in a crash report, costs almost nothing.
        case errors
        /// Errors, warnings and loaded DLLs: for diagnosing a title. Slows it down.
        case verbose

        var winedebug: String {
            switch self {
            case .off: "-all"
            case .errors: "-all,err+all"
            case .verbose: "-all,err+all,warn+all,+loaddll"
            }
        }
    }

    var sync: Sync = .msync
    var logLevel: LogLevel = .errors
    /// Tells games under Rosetta that the CPU has AVX/AVX2 (Rosetta translates them since macOS 15).
    /// Off by default: with it (or the next option) on, Steam for Windows hung at 100 % CPU on its first update
    /// and never connected (verified 2026-10-18, Wine 11 + macOS 27); turning both off fixed it at once.
    var advertiseAVX = false
    /// Lets 32-bit games use 4 GB of memory instead of 2 GB. Off by default for the same reason (not yet isolated).
    var largeAddressAware = false
    /// Metal's performance overlay (frame rate, GPU time) in every window drawn through Metal.
    var metalHUD = false
    /// DXVK's overlay (frame rate, API) for titles running on DXVK.
    var dxvkHUD = false
    /// DXVK compiles shaders in the background instead of stuttering (async build of DXVK-macOS).
    var dxvkAsync = true
    /// Full Retina resolution for Windows programs (sharper, heavier on the GPU).
    var retinaMode = false
    /// Option keys act as Windows Alt (games bind Alt, macOS symbols are rarely needed in a game).
    var optionAsAlt = true
    /// Command keys act as Windows Ctrl, so ⌘C/⌘V work in Windows programs.
    var commandAsControl = false
    /// Hides other displays' content when a game goes fullscreen (CrossOver default: on).
    var captureDisplaysForFullscreen = true
    /// Graphics layer for titles without their own choice.
    var defaultGraphics: GraphicsChoice = .automatic

    static let fileName = "engine-settings.json"

    static func load() -> EngineSettings { LocalData.load(EngineSettings.self, from: fileName) ?? EngineSettings() }
    func save() { LocalData.save(self, to: Self.fileName) }

    /// Variables added to every Wine process.
    var environment: [String: String] {
        var env: [String: String] = ["WINEDEBUG": logLevel.winedebug, "WINEFSYNC": "0"]
        switch sync {
        case .msync: env["WINEMSYNC"] = "1"
        case .esync: env["WINEESYNC"] = "1"
        case .off: break
        }
        if advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        if largeAddressAware { env["WINE_LARGE_ADDRESS_AWARE"] = "1" }
        if metalHUD {
            // The HUD also logs a line every few seconds (frame number, memory): MacHub turns it into the session's
            // frame-rate summary. Logging needs the HUD on; its cost is a few log lines.
            env["MTL_HUD_ENABLED"] = "1"
            env["MTL_HUD_LOG_ENABLED"] = "1"
        }
        if dxvkHUD { env["DXVK_HUD"] = "fps,api" }
        if dxvkAsync { env["DXVK_ASYNC"] = "1" }
        return env
    }

    /// `HKCU\Software\Wine\Mac Driver`: the keys winemac.drv reads (names checked in the CrossOver 26.2 sources).
    var macDriverRegistry: String {
        func yn(_ value: Bool) -> String { value ? "\"y\"" : "\"n\"" }
        return [
            "Windows Registry Editor Version 5.00",
            "",
            #"[HKEY_CURRENT_USER\Software\Wine\Mac Driver]"#,
            "\"RetinaMode\"=\(yn(retinaMode))",
            "\"LeftOptionIsAlt\"=\(yn(optionAsAlt))",
            "\"RightOptionIsAlt\"=\(yn(optionAsAlt))",
            "\"LeftCommandIsCtrl\"=\(yn(commandAsControl))",
            "\"RightCommandIsCtrl\"=\(yn(commandAsControl))",
            "\"CaptureDisplaysForFullscreen\"=\(yn(captureDisplaysForFullscreen))",
            "",
        ].joined(separator: "\r\n")
    }
}

/// What a title draws with. `automatic` picks from the Direct3D DLLs the executable imports.
enum GraphicsChoice: String, Codable, CaseIterable, Sendable {
    case automatic
    /// DXMT: Direct3D 10/11 → Metal directly. The fastest path for DX11 on Apple silicon.
    case dxmt
    /// DXVK: Direct3D 9/10/11 → Vulkan → MoltenVK → Metal. Broader compatibility, a bit slower.
    case dxvk
    /// Wine's own wined3d (OpenGL). For old games (DirectX 8/9) and as a last resort.
    case wined3d
    /// Apple's D3DMetal (Game Porting Toolkit), only if the user installed it: the one path for DirectX 12.
    case d3dmetal
}
