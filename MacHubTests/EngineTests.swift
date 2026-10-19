import Foundation
import Testing
@testable import MacHub

@Suite struct EngineTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "machub-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A runtime folder with the same shape as the real archive: runtime.json and executable wine/wineserver.
    private func makeRuntimeFolder(_ url: URL, version: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appending(path: "wine/bin"), withIntermediateDirectories: true)
        for tool in ["wine", "wineserver"] {
            let path = url.appending(path: "wine/bin/\(tool)").path
            fm.createFile(atPath: path, contents: Data("#!/bin/sh\necho wine-11.0\n".utf8))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        let info = RuntimeInfo(version: version, components: [
            .init(name: "wine", version: "11.0_1", license: "LGPL-2.1-or-later", source: "https://example.invalid", sha256: "00"),
        ])
        try JSONEncoder().encode(info).write(to: url.appending(path: "runtime.json"))
    }

    private func makeArchive(version: String) async throws -> URL {
        let staging = root.appending(path: "staging-\(version)")
        try makeRuntimeFolder(staging.appending(path: "MacHubRuntime-\(version)"), version: version)
        let archive = root.appending(path: "MacHubRuntime-\(version).tar.xz")
        let result = try await ProcessRunner.run(URL(filePath: "/usr/bin/tar"),
                                                 ["-C", staging.path, "-cJf", archive.path, "MacHubRuntime-\(version)"], timeout: 30)
        #expect(result.status == 0)
        return archive
    }

    private func manifest(for archive: URL, version: String, sha: String? = nil) async throws -> RuntimeManifest {
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
        let digest: String
        if let sha { digest = sha } else { digest = try await RuntimeManager.sha256(of: archive) }
        return RuntimeManifest(version: version, archive: archive.lastPathComponent, sha256: digest, size: size)
    }

    @Test func manifestDecodesWithAndWithoutURL() throws {
        let local = try JSONDecoder().decode(RuntimeManifest.self, from: Data(#"{"version":"1.0.0","archive":"a.tar.xz","sha256":"ab","size":12}"#.utf8))
        #expect(local.url == nil && local.size == 12)
        let published = try JSONDecoder().decode(RuntimeManifest.self, from: Data(
            #"{"version":"1.0.0","archive":"a.tar.xz","sha256":"ab","size":12,"url":"https://github.com/o/r/releases/download/runtime-1.0.0/a.tar.xz"}"#.utf8))
        #expect(published.url?.host() == "github.com")
    }

    @Test func runtimeNeedsInfoAndExecutables() throws {
        let folder = root.appending(path: "rt")
        try makeRuntimeFolder(folder, version: "1.0.0")
        #expect(WineRuntime.load(at: folder)?.version == "1.0.0")
        try FileManager.default.removeItem(at: folder.appending(path: "wine/bin/wineserver"))
        #expect(WineRuntime.load(at: folder) == nil)
    }

    @Test func installVerifiesAndPlacesRuntime() async throws {
        let archive = try await makeArchive(version: "1.2.0")
        let manager = RuntimeManager(directory: root.appending(path: "Runtimes"))
        let runtime = try await manager.install(archive: archive, manifest: try await manifest(for: archive, version: "1.2.0"))
        #expect(runtime.root.lastPathComponent == "1.2.0")
        #expect(manager.installed().map(\.version) == ["1.2.0"])
        // No staging folder left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: manager.directory.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }

    @Test func installRefusesWrongChecksum() async throws {
        let archive = try await makeArchive(version: "1.0.0")
        let manager = RuntimeManager(directory: root.appending(path: "Runtimes"))
        await #expect(throws: RuntimeError.self) {
            try await manager.install(archive: archive, manifest: try await manifest(for: archive, version: "1.0.0", sha: String(repeating: "0", count: 64)))
        }
        #expect(manager.installed().isEmpty)
    }

    @Test func installRefusesVersionMismatch() async throws {
        let archive = try await makeArchive(version: "1.0.0")
        let manager = RuntimeManager(directory: root.appending(path: "Runtimes"))
        await #expect(throws: RuntimeError.versionMismatch(expected: "2.0.0", found: "1.0.0")) {
            try await manager.install(archive: archive, manifest: try await manifest(for: archive, version: "2.0.0"))
        }
    }

    @Test func currentPrefersSelectedThenNewest() throws {
        let manager = RuntimeManager(directory: root.appending(path: "Runtimes"))
        for version in ["1.9.0", "1.10.0"] { try makeRuntimeFolder(manager.directory.appending(path: version), version: version) }
        #expect(manager.current(selected: nil)?.version == "1.10.0")
        #expect(manager.current(selected: "1.9.0")?.version == "1.9.0")
        #expect(manager.current(selected: "0.1")?.version == "1.10.0")
    }

    @Test func badArchitectureIsRecognisedThroughUnderlyingErrors() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 86)
        #expect(RuntimeManager.isBadArchitecture(posix))
        #expect(RuntimeManager.isBadArchitecture(NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSUnderlyingErrorKey: posix])))
        #expect(!RuntimeManager.isBadArchitecture(NSError(domain: NSPOSIXErrorDomain, code: 2)))
    }

    @Test func prefixStoreReadsSettingsAndSkipsStrangers() throws {
        let store = PrefixStore(directory: root.appending(path: "Prefixes"))
        let settings = WinePrefix(id: UUID(), name: "Applications", role: .apps, runtimeVersion: "1.0.0", created: .now)
        let folder = store.directory.appending(path: settings.id.uuidString)
        try FileManager.default.createDirectory(at: folder.appending(path: "drive_c"), withIntermediateDirectories: true)
        try store.save(settings, at: folder)
        try FileManager.default.createDirectory(at: store.directory.appending(path: "not-a-prefix"), withIntermediateDirectories: true)

        let all = store.all()
        #expect(all.map(\.name) == ["Applications"])
        #expect(all[0].bottle.engine == .embedded && all[0].bottle.hasDriveC && all[0].bottle.isRegistered)
        #expect(store.prefix(named: "Applications")?.id == settings.id)
    }

    @Test func environmentCarriesPrefixAndSortedOverrides() throws {
        let folder = root.appending(path: "rt")
        try makeRuntimeFolder(folder, version: "1.0.0")
        let runtime = try #require(WineRuntime.load(at: folder))
        let prefix = InstalledPrefix(url: root.appending(path: "p"),
                                     settings: WinePrefix(id: UUID(), name: "P", role: .custom, runtimeVersion: "1.0.0", created: .now))
        var env = WineEnvironment(runtime: runtime, prefix: prefix)
        #expect(env.variables["WINEPREFIX"] == prefix.url.path)
        #expect(env.variables["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d")
        env.dllOverrides = ["dxgi": "n,b", "d3d11": "n,b"]
        #expect(env.variables["WINEDLLOVERRIDES"] == "d3d11=n,b;dxgi=n,b;winemenubuilder.exe=d")
    }

    @Test func commandsAndLogNames() {
        #expect(EmbeddedWineEngine.command(for: "/Users/me/Setup.MSI") == ["msiexec", "/i", "/Users/me/Setup.MSI"])
        #expect(EmbeddedWineEngine.command(for: #"C:\windows\system32\notepad.exe"#) == [#"C:\windows\system32\notepad.exe"#])
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 9, minute: 5, second: 7))!
        #expect(EmbeddedWineEngine.logName(for: #"C:\windows\system32\notepad.exe"#, date: date) == "2026-10-18-090507-notepad.exe.log")
    }

    @MainActor @Test func embeddedBottleIsCheckedLikeAnyBottle() {
        let bottle = BottleInfo(url: root, name: "Applications", windowsVersion: "win10", isRegistered: true, hasDriveC: false, engine: .embedded)
        var program = Title(id: "software:x", name: "Tool", kind: .software, steamAppID: nil)
        program.install = .init(bottle: "Applications", path: "/nonexistent/tool.exe", executables: ["tool.exe"])
        #expect(LibraryStore.problem(for: program, route: .program(path: "/nonexistent/tool.exe"), bottles: [bottle]) == .bottleNotSetUp("Applications"))
    }
}

@Suite struct GraphicsDeploymentTests {
    @Test func stripsOnlyTheBuiltinMarker() {
        var pe = Data(count: 0x40) + GraphicsDeployment.builtinMarker + Data([1, 2, 3])
        GraphicsDeployment.stripBuiltinMarker(&pe)
        #expect(pe.count == 0x40 + 16 + 3)
        #expect(pe.subdata(in: 0x40..<0x50) == Data(count: 16))
        #expect(pe.suffix(3) == Data([1, 2, 3]))
        var native = Data(repeating: 7, count: 0x60)
        GraphicsDeployment.stripBuiltinMarker(&native)
        #expect(native == Data(repeating: 7, count: 0x60))
    }

    @Test func overridesDocumentScopesEachExecutable() {
        let doc = GraphicsDeployment.overridesDocument(["steamwebhelper.exe": ["d3d11", "d3d10core"]])
        #expect(doc.hasPrefix("Windows Registry Editor Version 5.00\r\n"))
        #expect(doc.contains(#"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\steamwebhelper.exe\DllOverrides]"#))
        #expect(doc.contains("\"d3d10core\"=\"native,builtin\"\r\n\"d3d11\"=\"native,builtin\""))
    }
}

@Suite struct CrossOverProcessFormatTests {
    // Verbatim shape of `ps -axo pid=,command=` under WineCX 24.0.7 (2026-10-18).
    static let ps = """
    84618 /var/folders/w1/d4/T//winetemp-20355053-35392-1763558542-0/wine start.exe /exec
    84644 /var/folders/w1/d4/T//winetemp-20355053-35392-1763558542-0/notepad.exe C:\\windows\\system32\\notepad.exe
    84700 /var/folders/w1/d4/T//winetemp-1-2-3-0/AssettoCorsa.exe C:\\Program Files (x86)\\Steam\\steamapps\\common\\assettocorsa\\AssettoCorsa.exe -x
    84710 /bin/zsh -c grep notepad.exe C:\\windows\\system32\\notepad.exe
    """

    @Test func matchesWindowsPathAfterTheTemporaryLink() {
        #expect(ProcessWatch.matches(in: Self.ps, target: .executable("notepad.exe")) == [.init(pid: 84644, executable: "notepad.exe")])
        #expect(ProcessWatch.matches(in: Self.ps, target: .installFolder("assettocorsa")).map(\.pid) == [84700])
    }
}

@Suite struct EngineSettingsTests {
    @Test func defaultsFavourSpeed() {
        let env = EngineSettings().environment
        #expect(env["WINEMSYNC"] == "1" && env["WINEESYNC"] == nil && env["WINEFSYNC"] == "0")
        #expect(env["WINEDEBUG"] == "-all,err+all")
        #expect(env["ROSETTA_ADVERTISE_AVX"] == nil && env["WINE_LARGE_ADDRESS_AWARE"] == nil && env["DXVK_ASYNC"] == "1")
        #expect(env["MTL_HUD_ENABLED"] == nil && env["DXVK_HUD"] == nil)
    }

    @Test func choicesMapToVariables() {
        var s = EngineSettings()
        s.sync = .off; s.logLevel = .off; s.metalHUD = true; s.dxvkHUD = true; s.advertiseAVX = true
        let env = s.environment
        #expect(env["WINEMSYNC"] == nil && env["WINEESYNC"] == nil)
        #expect(env["WINEDEBUG"] == "-all" && env["MTL_HUD_ENABLED"] == "1" && env["DXVK_HUD"] == "fps,api")
        #expect(env["ROSETTA_ADVERTISE_AVX"] == "1")
    }

    @Test func msyncFallsBackToEsyncWithoutCrossOverWine() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "machub-sync-\(UUID().uuidString)")
        let prefix = InstalledPrefix(url: root, settings: WinePrefix(id: UUID(), name: "P", role: .custom, runtimeVersion: "1", created: .now))
        func runtime(_ component: String) -> WineRuntime {
            WineRuntime(root: root, info: RuntimeInfo(version: "1", components: [.init(name: component, version: "", license: "", source: "", sha256: "")]))
        }
        let plain = WineEnvironment(runtime: runtime("wine"), prefix: prefix, settings: EngineSettings()).variables
        #expect(plain["WINEMSYNC"] == nil && plain["WINEESYNC"] == "1")
        let cx = WineEnvironment(runtime: runtime("winecx"), prefix: prefix, settings: EngineSettings()).variables
        #expect(cx["WINEMSYNC"] == "1")
    }

    @Test func macDriverRegistryUsesWineKeyNames() {
        var s = EngineSettings()
        s.retinaMode = true; s.commandAsControl = true
        let reg = s.macDriverRegistry
        #expect(reg.contains(#"[HKEY_CURRENT_USER\Software\Wine\Mac Driver]"#))
        #expect(reg.contains("\"RetinaMode\"=\"y\"") && reg.contains("\"LeftCommandIsCtrl\"=\"y\"") && reg.contains("\"LeftOptionIsAlt\"=\"y\""))
    }

    @Test func roundTripsThroughJSON() throws {
        var s = EngineSettings(); s.defaultGraphics = .dxvk; s.sync = .esync
        let back = try JSONDecoder().decode(EngineSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

@Suite struct GraphicsSelectionTests {
    /// A minimal PE32+ executable importing D3D11.dll and KERNEL32.dll (one .idata section at RVA 0x1000).
    static func peImporting(_ names: [String]) -> Data {
        var d = Data(count: 0x400)
        func put32(_ v: UInt32, _ o: Int) { for i in 0..<4 { d[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
        func put16(_ v: UInt16, _ o: Int) { d[o] = UInt8(v & 0xFF); d[o + 1] = UInt8(v >> 8) }
        d[0] = 0x4D; d[1] = 0x5A; put32(0x40, 0x3C)
        put32(0x0000_4550, 0x40); put16(0x8664, 0x44); put16(1, 0x46); put16(0xF0, 0x54); put16(0x22, 0x56)
        put16(0x20B, 0x58)
        put32(0x1000, 0x58 + 112 + 8); put32(UInt32(20 * (names.count + 1)), 0x58 + 112 + 12)
        let section = 0x58 + 0xF0
        put32(0x200, section + 8); put32(0x1000, section + 12); put32(0x200, section + 16); put32(0x200, section + 20)
        for (i, name) in names.enumerated() {
            let nameRVA = 0x1100 + i * 0x20
            put32(UInt32(nameRVA), 0x200 + i * 20 + 12)
            for (j, b) in name.utf8.enumerated() { d[0x200 + (nameRVA - 0x1000) + j] = b }
        }
        return d
    }

    @Test func readsImportedDLLs() {
        let imports = PEImports.dlls(in: Self.peImporting(["D3D11.dll", "KERNEL32.dll"]))
        #expect(imports == ["d3d11.dll", "kernel32.dll"])
        #expect(GraphicsAPI(imports: imports) == .direct3d11)
        #expect(PEImports.dlls(in: Data("not a pe".utf8)).isEmpty)
    }

    @Test func automaticPicksTheFastestWorkingLayer() {
        #expect(GraphicsChoice.automatic.resolved(for: .direct3d11, d3dmetalAvailable: false) == .dxmt)
        #expect(GraphicsChoice.automatic.resolved(for: .direct3d9, d3dmetalAvailable: false) == .wined3d)
        #expect(GraphicsChoice.automatic.resolved(for: .direct3d12, d3dmetalAvailable: false) == .dxmt)
        #expect(GraphicsChoice.automatic.resolved(for: .direct3d12, d3dmetalAvailable: true) == .d3dmetal)
        #expect(GraphicsChoice.dxvk.resolved(for: .direct3d12, d3dmetalAvailable: true) == .dxvk)
        #expect(GraphicsChoice.d3dmetal.resolved(for: .direct3d11, d3dmetalAvailable: false) == .dxmt)
        #expect(GraphicsAPI(imports: ["d3d12.dll", "d3d11.dll"]) == .direct3d12)
    }

    @Test func switchingNeverTouchesTheGamesOwnDLLs() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "machub-gfx-\(UUID().uuidString)")
        let game = root.appending(path: "game")
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        // A fake runtime with DXMT and DXVK DLLs (builtin marker included).
        let marked = Data(count: 0x40) + GraphicsDeployment.builtinMarker + Data([9])
        for (layer, dlls) in [("dxmt", ["d3d11", "dxgi", "d3d10core"]), ("dxvk", ["d3d11", "d3d10core"])] {
            let dir = root.appending(path: "rt/\(layer)/x86_64-windows")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for dll in dlls { try marked.write(to: dir.appending(path: "\(dll).dll")) }
        }
        let runtime = WineRuntime(root: root.appending(path: "rt"), info: RuntimeInfo(version: "1", components: []))
        // The game ships its own dxgi.dll (e.g. a ReShade proxy).
        try Data("game's dxgi".utf8).write(to: game.appending(path: "dxgi.dll"))

        let dxmt = try GraphicsDeployment.switchFolder(game, to: .dxmt, runtime: runtime, is64Bit: true)
        #expect(dxmt == ["d3d11", "d3d10core"])
        #expect(try Data(contentsOf: game.appending(path: "dxgi.dll")) == Data("game's dxgi".utf8))
        #expect(try Data(contentsOf: game.appending(path: "d3d11.dll")).subdata(in: 0x40..<0x50) == Data(count: 16))

        let back = try GraphicsDeployment.switchFolder(game, to: .wined3d, runtime: runtime, is64Bit: true)
        #expect(back.isEmpty)
        #expect(!fm.fileExists(atPath: game.appending(path: "d3d11.dll").path))
        #expect(!fm.fileExists(atPath: game.appending(path: GraphicsDeployment.ledgerName).path))
        #expect(fm.fileExists(atPath: game.appending(path: "dxgi.dll").path))
    }

    @Test func clearingAnOverrideDeletesTheKey() {
        let doc = GraphicsDeployment.overridesDocument(["old.exe": []])
        #expect(doc.contains(#"[-HKEY_CURRENT_USER\Software\Wine\AppDefaults\old.exe\DllOverrides]"#))
    }

    @Test func findsTheToolkitLibraryInAMountedImage() throws {
        let fm = FileManager.default
        let volume = fm.temporaryDirectory.appending(path: "machub-gptk-\(UUID().uuidString)")
        try fm.createDirectory(at: volume.appending(path: "redist/lib/external/D3DMetal.framework"), withIntermediateDirectories: true)
        #expect(GPTKStore.redistributableLibrary(under: volume)?.lastPathComponent == "lib")
        #expect(GPTKStore.redistributableLibrary(under: fm.temporaryDirectory.appending(path: "nothing-\(UUID())")) == nil)
    }
}

@Suite struct PrefixIsolationTests {
    @Test func linksToMacFoldersBecomeRealFoldersAndTargetsAreUntouched() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "machub-iso-\(UUID().uuidString)")
        let mac = root.appending(path: "mac/Desktop")
        try fm.createDirectory(at: mac, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: mac.appending(path: "note.txt"))
        let user = root.appending(path: "prefix/drive_c/users/me")
        try fm.createDirectory(at: user.appending(path: "Saved Games"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: user.appending(path: "Desktop"), withDestinationURL: mac)
        try fm.createDirectory(at: user.appending(path: "Documents"), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: user.appending(path: "Documents/game.sav"))

        PrefixStore.isolateUserFolders(in: root.appending(path: "prefix"))

        #expect((try? fm.destinationOfSymbolicLink(atPath: user.appending(path: "Desktop").path)) == nil)
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: user.appending(path: "Desktop").path, isDirectory: &isDir) && isDir.boolValue)
        #expect(fm.fileExists(atPath: mac.appending(path: "note.txt").path))
        #expect(fm.fileExists(atPath: user.appending(path: "Documents/game.sav").path))
    }
}

@Suite struct LeftoverLauncherTests {
    /// BeamNG's shape: the launcher (pid 10) starts the game (pid 20); the game quits; the launcher keeps spinning.
    @MainActor @Test func launcherLeftAloneAfterTheGameIsEnded() async {
        let folder = #"C:\Program Files (x86)\Steam\steamapps\common\BeamNG.drive"#
        let launcher = "10 \(folder)\\BeamNG.drive.exe"
        let game = "20 \(folder)\\Bin64\\BeamNG.drive.x64.exe"
        final class Box: @unchecked Sendable { var step = 0; var killed: [Int32] = [] }
        let box = Box()
        var runner = LaunchRunner { _ in }
        runner.pollInterval = .milliseconds(10)
        runner.exitInterval = .milliseconds(10)
        runner.leftoverGrace = .milliseconds(50)
        runner.crashThreshold = .zero
        runner.snapshot = {
            box.step += 1
            if !box.killed.isEmpty { return "" }
            switch box.step {
            case 1...3: return launcher
            case 4...6: return launcher + "\n" + game
            default: return launcher
            }
        }
        runner.terminate = { pids in box.killed = pids }
        var states: [LibraryStore.LaunchState] = []
        await runner.run(LaunchPlan(route: .program(path: "x"), bottle: "Steam", target: .installFolder("BeamNG.drive"))) { states.append($0) }
        #expect(box.killed == [10])
        #expect(states.last == .closed)
    }
}

@Suite struct LaunchOptionsTests {
    @Test func splitsLikeAShellWithQuotes() {
        var s = TitleSettings()
        s.arguments = #"  -gfx dx11   -level "west coast usa" -x"#
        #expect(s.argumentList == ["-gfx", "dx11", "-level", "west coast usa", "-x"])
        s.arguments = ""
        #expect(s.argumentList.isEmpty)
        s.arguments = #"-name """#
        #expect(s.argumentList == ["-name", ""])
    }
}

@Suite struct PerformanceLogTests {
    // Shape of `log show --style compact` for the Metal HUD (BeamNG.drive, 2026-10-19), plus a mirrored line.
    static let log = """
    2026-10-19 15:35:40.029 Df wine[54032:6eb5e7] (libMTLHud.dylib) metal-HUD: 1316,711.58,2307.44<private>
    2026-10-19 15:35:40.030 Df wine[54032:6eb5e7] [com.apple.metal.hud:Logging] metal-HUD: 1316,711.58,2307.44<private>
    2026-10-19 15:35:45.030 Df wine[54032:6eb5e7] [com.apple.metal.hud:Logging] metal-HUD: 1466,716.95,2319.84<private>
    2026-10-19 15:35:50.030 Df wine[54032:6eb5e7] [com.apple.metal.hud:Logging] metal-HUD: 1516,720.10,2319.84<private>
    2026-10-19 15:35:45.000 Df wine[54017:6eb5e7] [com.apple.metal.hud:Logging] metal-HUD: 10,50.0,1.0<private>
    2026-10-19 15:35:50.000 Df wine[54017:6eb5e7] [com.apple.metal.hud:Logging] metal-HUD: 12,50.0,1.0<private>
    """

    @Test func parsesOnlyTheLoggingCategory() {
        let samples = PerformanceLog.samples(fromCompactLog: Self.log)
        #expect(samples.count == 5)
        #expect(samples.first == .init(pid: 54032, time: samples[0].time, frame: 1316, memoryMB: 711.58))
    }

    @Test func summarisesTheProcessThatDrewMost() throws {
        let summary = try #require(PerformanceLog.summarize(PerformanceLog.samples(fromCompactLog: Self.log)))
        #expect(abs(summary.duration - 10) < 0.01)
        #expect(abs(summary.averageFPS - 20) < 0.01)   // (1516 - 1316) frames in 10 s
        #expect(abs(summary.worstFPS - 10) < 0.01)     // 50 frames in the second 5 s
        #expect(summary.peakMemoryMB == 720.10)
    }
}

struct WinebootFailureTests {
    @Test func silentFailureSaysSo() {
        let text = PrefixStore.describeExit(ProcessResult(status: 1, stdout: "", stderr: "\n  \n"))
        #expect(text.contains("1") && !text.contains("\n"))
    }

    @Test func keepsWinesLastLines() {
        let text = PrefixStore.describeExit(ProcessResult(status: 3, stdout: "", stderr: "a\nb\nc\nd\ne\nwine: could not load ntdll.so\n"))
        #expect(text.hasSuffix("wine: could not load ntdll.so"))
        #expect(!text.contains("\na\n"))
    }
}
