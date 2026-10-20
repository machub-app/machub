import AppKit
import Darwin
import Foundation

/// Puts Steam for Windows in MacHub's Steam prefix: Valve's own installer, run silently. The user signs in
/// inside Steam's window; MacHub never sees credentials and never bypasses Steam (DRM, updates, cloud saves).
enum SteamSetup {
    /// Valve's installer on Valve's CDN. HTTPS from Valve is the trust anchor; the file is also checked to be a PE executable.
    static let installerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
    static let steamExe = #"C:\Program Files (x86)\Steam\steam.exe"#

    enum Step: Equatable, Sendable {
        case creatingPrefix
        case downloadingInstaller
        case installing
        case starting
    }

    enum Failure: Error, Equatable {
        case downloadFailed(String)
        case notAnInstaller
        /// The installer returned, but steam.exe isn't in the prefix.
        case installFailed
    }

    static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "app.machub.MacHub")
    }

    /// Where a Windows environment (MacHub prefix or Whisky bottle) keeps steam.exe, if Steam for Windows is installed.
    static func hasSteam(inPrefix root: URL, fileManager: FileManager = .default) -> Bool {
        ["drive_c/Program Files (x86)/Steam/steam.exe", "drive_c/Program Files/Steam/steam.exe"]
            .contains { fileManager.fileExists(atPath: root.appending(path: $0).path) }
    }

    /// Valve's installer already on this Mac (MacHub's cache, or the copy an earlier MacHub kept in `installers/`),
    /// if it is still a Windows executable. Steam updates itself after installing, so an older copy is fine.
    static func cachedInstaller(in folder: URL = cache, fileManager: FileManager = .default) -> URL? {
        [folder.appending(path: "SteamSetup.exe"), folder.appending(path: "installers/SteamSetup.exe")].first { url in
            guard fileManager.fileExists(atPath: url.path), case .executable? = try? WindowsFile.inspect(url, fileManager: fileManager).kind
            else { return false }
            return true
        }
    }

    /// Downloads SteamSetup.exe into MacHub's cache, replacing an older copy.
    static func downloadInstaller() async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: installerURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let destination = cache.appending(path: "SteamSetup.exe")
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: temp, to: destination)
        guard case .executable = try? WindowsFile.inspect(destination).kind else { throw Failure.notAnInstaller }
        return destination
    }

    /// Runs the installer silently (`/S`) in the prefix and checks that steam.exe landed there.
    static func install(engine: CompatibilityEngine, prefix: InstalledPrefix, installer: URL) async throws {
        _ = try await engine.run(installer.path, bottle: prefix.name, arguments: ["/S"], timeout: 900)
        guard let root = SteamLibrary.steamRoot(inPrefix: prefix.url) else { throw Failure.installFailed }
        try? await installService(engine: engine, prefix: prefix, steamRoot: root)
    }

    /// Steam's service (installs and updates games, some anti-cheat) isn't set up by the silent installer: Steam then
    /// shows "Steam Service Error" before the first install. Wine runs everything as administrator, so the service's
    /// own installer works without a password. Not verified on a fresh prefix yet (the user clicked "Install Service"
    /// the first time, 2026-10-18).
    static func installService(engine: CompatibilityEngine, prefix: InstalledPrefix, steamRoot: URL) async throws {
        let installed = prefix.url.appending(path: "drive_c/Program Files (x86)/Common Files/Steam/SteamService.exe")
        guard !FileManager.default.fileExists(atPath: installed.path),
              FileManager.default.fileExists(atPath: steamRoot.appending(path: "bin/SteamService.exe").path) else { return }
        _ = try await engine.run(#"C:\Program Files (x86)\Steam\bin\SteamService.exe"#, bottle: prefix.name, arguments: ["/install"], timeout: 120)
    }

    /// Steam's UI is Chromium (steamwebhelper). Under wined3d its window stays black on macOS, so it gets DXVK.
    /// Chromium loads d3d11.dll from System32 only (never from its own folder: verified, the app-local copy was
    /// ignored), so DXVK goes to system32/syswow64 as *native* files, and only steamwebhelper.exe is told to
    /// prefer them. Every other program keeps Wine's builtin (the default order loads builtins first).
    /// Returns false while Steam hasn't unpacked its web helper yet (first start, during its self-update).
    static func prepareGraphics(runtime: WineRuntime, prefix: InstalledPrefix) async throws -> Bool {
        // Engines from 1.0.1/1.2.2 ship the shim, which fixes the black window on any Wine flavour.
        if FileManager.default.fileExists(atPath: runtime.steamShim.path) { return try await deployShim(runtime: runtime, prefix: prefix) }
        if runtime.info.component("winecx") != nil { return true }
        guard let root = SteamLibrary.steamRoot(inPrefix: prefix.url) else { return false }
        let helper = root.appending(path: "bin/cef/cef.win64")
        guard FileManager.default.fileExists(atPath: helper.appending(path: "steamwebhelper.exe").path) else { return false }
        let windows = prefix.url.appending(path: "drive_c/windows")
        // Remove the app-local copies an earlier build put next to the helper.
        for dll in GraphicsLayer.dxvk.dlls { try? FileManager.default.removeItem(at: helper.appending(path: "\(dll).dll")) }
        try GraphicsDeployment.deploy(.dxvk, runtime: runtime, programFolder: windows.appending(path: "syswow64"), is64Bit: false)
        let dlls = try GraphicsDeployment.deploy(.dxvk, runtime: runtime, programFolder: windows.appending(path: "system32"))
        try await GraphicsDeployment.writeOverrides(["steamwebhelper.exe": dlls], runtime: runtime, prefix: prefix)
        return true
    }

    /// Steam's UI stays black under Wine on macOS (cross-process GPU frames aren't implemented by winemac). The shim,
    /// standing in for winmm.dll for steamwebhelper.exe only, makes Chromium run in one process with software
    /// rendering. No Steam file is modified. Wine's real winmm is copied next to it as winmm_orig.dll.
    /// Deployed at every Steam start: `wineboot -u` rewrites system32's placeholder DLLs.
    static func deployShim(runtime: WineRuntime, prefix: InstalledPrefix) async throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: runtime.steamShim.path) else { return true }
        let system32 = prefix.url.appending(path: "drive_c/windows/system32")
        let shim = try Data(contentsOf: runtime.steamShim)
        let original = try Data(contentsOf: runtime.root.appending(path: "wine/lib/wine/x86_64-windows/winmm.dll"))
        if (try? Data(contentsOf: system32.appending(path: "winmm.dll"))) != shim {
            try shim.write(to: system32.appending(path: "winmm.dll"), options: .atomic)
        }
        if (try? Data(contentsOf: system32.appending(path: "winmm_orig.dll"))) != original {
            try original.write(to: system32.appending(path: "winmm_orig.dll"), options: .atomic)
        }
        try await GraphicsDeployment.writeOverrides(["steamwebhelper.exe": ["winmm"]], runtime: runtime, prefix: prefix)
        return true
    }

    /// Environment Steam's Chromium needs under Wine: a UTF-8 locale (ICU crashes otherwise) and async shader builds.
    /// Times and numbers in the C locale: ICU in Steam's Chromium fails to parse some localized formats.
    static let environment = ["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8", "LC_TIME": "C", "LC_NUMERIC": "C", "DXVK_ASYNC": "1"]

    /// Wine windows open behind MacHub (macOS doesn't let a background process take focus): bring them forward.
    /// MacHub yields activation first, which macOS 14+ requires for one app to hand focus to another.
    @MainActor static func bringWineToFront(runtime: WineRuntime) {
        for app in wineApps(runtime: runtime) {
            NSApp.yieldActivation(to: app)
            app.activate()
        }
    }

    @MainActor static func wineApps(runtime: WineRuntime) -> [NSRunningApplication] {
        let root = runtime.root.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.filter {
            $0.executableURL?.resolvingSymlinksInPath().path.hasPrefix(root) == true
        }
    }

    /// Whether a real window (not Wine's hidden 500×500 helpers or a menu strip) belongs to one of the runtime's
    /// processes. Window titles aren't used: macOS hides other apps' titles unless MacHub has Screen Recording
    /// permission (verified: the "Steam" title was invisible to MacHub, so the old title check always timed out).
    @MainActor static func visibleWineWindow(runtime: WineRuntime) -> Bool {
        let root = runtime.root.resolvingSymlinksInPath().path
        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            // Windows belong to helper processes (steamwebhelper) that aren't all NSRunningApplications: match by binary path.
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, executablePath(of: pid)?.hasPrefix(root) == true,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
            else { return false }
            return width >= 600 && height >= 400
        }
    }

    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(filePath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    /// Waits for Steam's window (it appears only after Steam's self-update), bringing it forward until it shows.
    @MainActor static func revealSteamWindow(runtime: WineRuntime, timeout: Duration = .seconds(300)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            bringWineToFront(runtime: runtime)
            try? await Task.sleep(for: .seconds(2))
            if visibleWineWindow(runtime: runtime) { return true }
        }
        return false
    }
}
