import AppKit
import Observation

/// Everything the UI reads. Each list has one real source, and its state says what is known:
/// installed = Steam manifests in MacHub's prefixes + `whisky games`, owned = Steam Web API, store = Steam store,
/// software = imports + Whisky pins.
@MainActor @Observable
final class LibraryStore {
    enum LaunchState: Equatable {
        /// Checking that Whisky is ready.
        case preparing
        /// Checking the bottle and the program on disk.
        case checkingBottle
        /// A check failed before anything ran.
        case blocked(LaunchProblem)
        /// Steam for Windows wasn't running in the bottle: waiting for steam.exe to appear.
        case startingSteam
        /// The program was handed to Wine (software); waiting for its process.
        case startingProcess
        /// Steam received the launch request; MacHub is watching for the game's own process.
        case waitingForGame
        /// A process of the title was actually seen (games: from its install folder; software: its own .exe).
        case running(String?)
        /// The title's processes were seen, then disappeared.
        case closed
        /// A Windows program started with `whisky run` exited with this code.
        case exited(Int32)
        case installRequested
        /// No process appeared in time.
        case notStarted(log: String?)
        /// The process appeared, then vanished within seconds: almost certainly a crash at startup.
        case crashedAtStart(seconds: Int, log: String?)
        /// The user stopped waiting. Whatever Steam or Wine was doing carries on.
        case cancelled
        case failed(String, log: String?)

        var isInProgress: Bool {
            switch self {
            case .preparing, .checkingBottle, .startingSteam, .startingProcess, .waitingForGame: true
            default: false
            }
        }
    }

    /// One launch shown on the launch screen: the title, its route and when the current step began.
    struct LaunchSession: Equatable {
        let title: Title
        let route: LaunchPlan.Route
        let steamAlreadyRunning: Bool
        var stepStartedAt: Date
        let startedAt: Date
    }

    enum OwnedState: Equatable {
        case signedOut, needsKey, loading, loaded, privateProfile, invalidKey
        /// No Web API key: the games come from Steam for Windows' own library cache on this Mac.
        case fromSteamClient
        case failed(String)
    }

    enum StoreState: Equatable {
        case idle, loading, loaded, stale, rateLimited, offline
    }

    let steam = SteamConnection()

    private(set) var report: DiagnosticsReport?
    /// Games Steam for Windows installed in MacHub's own prefixes (read from its manifests).
    private(set) var embeddedInstalled: [Title] = []
    /// Games found through `whisky games` in Whisky bottles (fallback engine).
    private(set) var whiskyInstalled: [Title] = []
    var installedTitles: [Title] { embeddedInstalled + whiskyInstalled }
    /// Games Steam is downloading in MacHub's prefixes, by App ID.
    private(set) var steamDownloads: [Int: SteamApp] = [:]
    /// Installed games with an update pending or running, or being verified, by App ID.
    private(set) var steamUpdates: [Int: SteamApp] = [:]
    private(set) var steamSetup: SteamSetupState?
    private var downloadWatch: Task<Void, Never>?
    private var libraryCacheWatch: Task<Void, Never>?
    private var libraryCacheCount = -1
    private(set) var ownedTitles: [Title] = []
    private(set) var ownedState: OwnedState = .signedOut
    private(set) var imported: [ImportedProgram] = LocalData.load([ImportedProgram].self, from: "software.json") ?? []
    private(set) var pinnedTitles: [Title] = []
    /// Native Mac games MacHub manages mods for (today: Minecraft: Java Edition, when installed).
    private(set) var nativeTitles: [Title] = []
    private(set) var featuredStore = SteamStore.Featured()
    private(set) var featuredState: StoreState = .idle
    private(set) var history: [String: Date] = LocalData.load([String: Date].self, from: "history.json") ?? [:]
    private(set) var details: [Int: StoreDetails] = [:]
    /// Compatibility estimates per Steam app, filled as cards and pages appear (see CompatibilityEstimate).
    private(set) var estimates: [Int: CompatibilityEstimate] = [:]
    private var estimating: Set<Int> = []
    private(set) var loadErrors: [String] = []
    private(set) var isLoading = false
    private(set) var launchStates: [Title.ID: LaunchState] = [:] {
        didSet {
            // Restart the step clock whenever a title moves to another step.
            for (id, state) in launchStates where oldValue[id] != state { launchSessions[id]?.stepStartedAt = .now }
        }
    }
    private(set) var launchSessions: [Title.ID: LaunchSession] = [:]
    /// The title whose launch screen covers the window, if any.
    var presentedLaunch: Title.ID?
    private var launchTasks: [Title.ID: Task<Void, Never>] = [:]
    /// The title whose artwork lights the window (hero, hovered card, open detail).
    var spotlight: Title?

    // MARK: Derived lists

    /// Steam games the user has: installed ∪ owned, merged per App ID.
    var library: [Title] {
        var byID: [String: Title] = [:]
        for t in installedTitles + ownedTitles + nativeTitles { byID[t.id] = byID[t.id].map { $0.merged(with: t) } ?? t }
        return byID.values.map(enriched).sorted { lastPlayed($0) > lastPlayed($1) }
    }

    var software: [Title] { imported.map(\.title) + pinnedTitles }

    /// Titles launched from MacHub, most recent first (local history only).
    var recent: [Title] {
        let all = library + software
        return history.sorted { $0.value > $1.value }.compactMap { entry in all.first { $0.id == entry.key } }
    }

    func titles(includeDemo: Bool) -> [Title] {
        library + software + (includeDemo ? DemoLibrary.titles : [])
    }

    /// Hero: the user's own recently played titles first, then what Steam features now.
    func featured(includeDemo: Bool) -> [Title] {
        let mine = Array((recent + library.filter { $0.availability == .installed || $0.owned?.lastPlayed != nil })
            .uniqued().prefix(3))
        let store = featuredStore.topSellers.map { enriched(Title(store: $0)) }.filter { t in !mine.contains { $0.id == t.id } }
        let picks = Array((mine + store).prefix(6))
        if picks.isEmpty, includeDemo {
            return DemoLibrary.featuredIDs.compactMap { id in DemoLibrary.titles.first { $0.id == id } }
        }
        return picks
    }

    func storeRow(_ items: [StoreItem]) -> [Title] { items.map { enriched(Title(store: $0)) } }

    /// A title as the user has it: store/search entries pick up owned/installed state and cached details.
    func enriched(_ title: Title) -> Title {
        var t = title
        for mine in (installedTitles + ownedTitles) where mine.id == title.id {
            t = mine.merged(with: t)
        }
        if let id = t.steamAppID, let d = details[id] { t.apply(d) }
        return t
    }

    var whiskyInstall: WhiskyInstall? {
        if case .ready(let install)? = report?.status { install } else { nil }
    }

    /// Whisky's registered bottles plus MacHub's own prefixes. Each says which engine runs it.
    var registeredBottles: [BottleInfo] {
        prefixes.map(\.bottle) + whiskyBottles
    }

    var whiskyBottles: [BottleInfo] {
        guard whiskyInstall != nil else { return [] }
        return report?.containers.first { $0.bundleID == WhiskyLocator.forkBundleID }?.bottles.filter(\.isRegistered) ?? []
    }

    // MARK: Embedded engine

    enum EngineState: Equatable {
        case checking
        case notInstalled
        case installing(received: Int64, total: Int64)
        case ready(version: String, wine: String)
        /// The runtime is installed, but macOS can't start Intel binaries until Rosetta 2 is installed.
        case needsRosetta
        case failed(String)
    }

    private(set) var runtime: WineRuntime?
    private(set) var engineSettings = EngineSettings.load()
    private(set) var titleSettings = TitleSettings.all()
    /// Frame-rate summaries of past sessions, per title (Metal HUD log, when the overlay is on).
    private(set) var performance = PerformanceLog.history()

    // Nexus Mods (see LibraryStore+Nexus.swift)
    var nexusAccount: NexusMods.Account?
    var nexusKeyProblem: String?
    /// Download/installation progress per Nexus mod ID, 0…1.
    var nexusProgress: [Int: Double] = [:]
    /// Last outcome per Nexus mod ID ("Installed 1.2", or an error).
    var nexusMessages: [Int: String] = [:]
    /// Mods for which the user opened Nexus's files page and MacHub waits for the nxm:// link.
    var awaitingNexusLinks: Set<Int> = []
    /// Bumped whenever a Nexus install changes, so lists reload.
    var nexusRevision = 0
    /// The layer each executable got at its last launch (shown on the title page).
    private(set) var lastGraphics: [Title.ID: [String: GraphicsLayer]] = [:]

    /// Saves the engine options at once (they apply to the next Wine process) and writes the Mac driver keys
    /// into every MacHub prefix in the background.
    func setEngineSettings(_ settings: EngineSettings) {
        let registryChanged = settings.macDriverRegistry != engineSettings.macDriverRegistry
        engineSettings = settings
        settings.save()
        guard registryChanged, let runtime else { return }
        let targets = prefixes.filter(\.hasDriveC)
        Task {
            for prefix in targets { try? await PrefixStore.live.applyMacDriverSettings(settings, to: prefix, runtime: runtime) }
        }
    }

    func settings(for title: Title) -> TitleSettings { titleSettings[title.id] ?? TitleSettings() }

    func updateSettings(_ settings: TitleSettings, for title: Title) {
        titleSettings[title.id] = settings
        TitleSettings.save(titleSettings)
    }

    /// The choice a launch uses: the title's own, else the engine default.
    func graphicsChoice(for title: Title) -> GraphicsChoice {
        let own = settings(for: title).graphics
        return own == .automatic ? engineSettings.defaultGraphics : own
    }
    private(set) var engineState: EngineState = .checking
    private(set) var prefixes: [InstalledPrefix] = []
    private(set) var creatingPrefix = false

    /// Something can run Windows programs: MacHub's engine (ready) or Whisky.
    var canRunWindows: Bool {
        if case .ready = engineState { return true }
        return whiskyInstall != nil
    }

    /// The engine that runs a bottle: MacHub's runtime for its own prefixes, Whisky for Whisky's bottles.
    func engine(forBottle name: String) -> CompatibilityEngine? {
        guard let bottle = registeredBottles.first(where: { $0.name == name }) else { return nil }
        switch bottle.engine {
        case .embedded: return runtime.map { EmbeddedWineEngine(runtime: $0) }
        case .whisky: return whiskyInstall.map { WhiskyEngine(cli: WhiskyCLI(install: $0)) }
        }
    }

    func refreshEngine() async {
        prefixes = PrefixStore.live.all()
        for prefix in prefixes { PrefixStore.isolateUserFolders(in: prefix.url) }
        refreshSteamGames()
        guard let current = RuntimeManager.live.current() else {
            runtime = nil
            engineState = .notInstalled
            return
        }
        runtime = current
        do {
            engineState = .ready(version: current.version, wine: try await RuntimeManager.check(current))
        } catch RuntimeError.rosettaMissing {
            engineState = .needsRosetta
        } catch {
            engineState = .failed(Self.describe(error))
        }
    }

    /// Closes every Windows program MacHub started, in every environment: wineserver -k per prefix, then whatever is
    /// still running from MacHub's runtimes. The user's explicit "Force Quit All".
    func forceQuitAllWindowsPrograms() async {
        if let runtime {
            let engine = EmbeddedWineEngine(runtime: runtime)
            for prefix in prefixes { try? await engine.stopAll(in: prefix.name) }
        }
        try? await Task.sleep(for: .seconds(3))
        await ProcessWatch.terminate(ProcessWatch.runtimeProcesses(under: RuntimeManager.live.directory).map(\.pid), grace: .seconds(2))
        for id in launchStates.keys where launchStates[id]?.isInProgress == true || { if case .running? = launchStates[id] { true } else { false } }() {
            launchStates[id] = .closed
        }
        steamSetup = nil
    }

    /// Every runtime version on disk, oldest first.
    var installedRuntimes: [WineRuntime] { RuntimeManager.live.installed() }

    /// The manifest names a newer runtime than any installed one.
    var runtimeUpdateAvailable: RuntimeManifest? {
        guard let manifest = RuntimeManifest.bundled else { return nil }
        let newest = installedRuntimes.last?.version ?? "0"
        return manifest.version.compare(newest, options: .numeric) == .orderedDescending ? manifest : nil
    }

    /// Makes `version` the runtime every launch uses (roll back or forward). Prefixes made by another version get
    /// `wineboot -u` on their next start of a Windows program.
    func selectRuntime(_ version: String) async {
        UserDefaults.standard.set(version, forKey: RuntimeManager.selectedVersionKey)
        await refreshEngine()
    }

    /// Moves an unused runtime version to the Trash. The one in use stays.
    func removeRuntime(_ version: String) async {
        guard version != runtime?.version, let target = installedRuntimes.first(where: { $0.version == version }) else { return }
        try? FileManager.default.trashItem(at: target.root, resultingItemURL: nil)
        await refreshEngine()
    }

    /// Updates a prefix's Windows files after a runtime change (keeps every user file).
    func repairPrefix(_ prefix: InstalledPrefix) async {
        guard let runtime else { return }
        do { try await PrefixStore.live.repair(prefix, runtime: runtime) } catch { engineState = .failed(Self.describe(error)) }
        prefixes = PrefixStore.live.all()
    }

    /// Moves a prefix to the Trash (recoverable from Finder). Only on the user's explicit request.
    func trashPrefix(_ prefix: InstalledPrefix) async {
        if let runtime {
            try? await EmbeddedWineEngine(runtime: runtime).stopAll(in: prefix.name)
        }
        try? FileManager.default.trashItem(at: prefix.url, resultingItemURL: nil)
        prefixes = PrefixStore.live.all()
        refreshSteamGames()
    }

    /// Sets the Windows version Wine reports in a prefix (`winecfg -v`).
    func setWindowsVersion(_ version: String, for prefix: InstalledPrefix) async {
        guard let runtime else { return }
        let env = WineEnvironment(runtime: runtime, prefix: prefix).variables
        _ = try? await ProcessRunner.run(runtime.wine, ["winecfg", "-v", version], timeout: 60, environment: env)
        var settings = prefix.settings
        settings.windowsVersion = version
        try? PrefixStore.live.save(settings, at: prefix.url)
        prefixes = PrefixStore.live.all()
    }

    /// Opens one of Wine's own tools (winecfg, regedit, taskmgr, cmd…) in a prefix.
    func openWineTool(_ tool: String, in prefix: InstalledPrefix) {
        guard let runtime else { return }
        let engine = EmbeddedWineEngine(runtime: runtime)
        Task.detached { _ = try? await engine.run(tool, bottle: prefix.name, arguments: [], timeout: 24 * 3600) }
    }

    /// Imports Apple's Game Porting Toolkit from a folder or mounted disk image the user picked.
    func importGPTK(from url: URL) -> String? {
        do { try GPTKStore.live.importToolkit(from: url); return nil } catch { return Self.describe(error) }
    }

    /// Installs a runtime archive the user picked, checked against the manifest shipped in the app.
    func installRuntime(from archive: URL) async {
        guard let manifest = RuntimeManifest.bundled else {
            engineState = .failed(String(localized: "This build of MacHub has no runtime manifest."))
            return
        }
        engineState = .installing(received: 0, total: manifest.size)
        do {
            _ = try await RuntimeManager.live.install(archive: archive, manifest: manifest)
        } catch {
            engineState = .failed(Self.describe(error))
            return
        }
        await refreshEngine()
    }

    /// Downloads the runtime named by the app's manifest (GitHub Release), then installs it.
    func downloadRuntime() async {
        guard let manifest = RuntimeManifest.bundled else { return }
        engineState = .installing(received: 0, total: manifest.size)
        do {
            _ = try await RuntimeManager.live.download(manifest) { received, total in
                Task { @MainActor in self.engineState = .installing(received: received, total: total) }
            }
        } catch {
            engineState = .failed(Self.describe(error))
            return
        }
        await refreshEngine()
    }

    @discardableResult
    func createPrefix(name: String, role: WinePrefix.Role) async -> InstalledPrefix? {
        guard let runtime, !creatingPrefix else { return nil }
        creatingPrefix = true
        defer { creatingPrefix = false }
        do {
            let prefix = try await PrefixStore.live.create(name: name, role: role, runtime: runtime,
                                                           takenNames: whiskyBottles.compactMap(\.name))
            prefixes = PrefixStore.live.all()
            return prefix
        } catch {
            engineState = .failed(Self.describe(error))
            prefixes = PrefixStore.live.all()
            return nil
        }
    }

    /// First registered bottle that actually contains Steam for Windows (MacHub's own prefixes come first).
    var steamBottle: BottleInfo? {
        registeredBottles.first { bottle in
            ["Program Files (x86)/Steam/steam.exe", "Program Files/Steam/steam.exe"]
                .contains { FileManager.default.fileExists(atPath: bottle.url.appending(path: "drive_c/\($0)").path) }
        }
    }

    // MARK: Steam for Windows in MacHub's engine

    enum SteamSetupState: Equatable {
        case working(SteamSetup.Step)
        /// Steam is installed and running: the user signs in in its own window.
        case waitingForSignIn
        case failed(String)
    }

    /// MacHub's prefix that holds Steam for Windows, if set up.
    var steamPrefix: InstalledPrefix? {
        prefixes.first { $0.settings.role == .steam && SteamLibrary.steamRoot(inPrefix: $0.url) != nil }
    }

    /// Reads installed and downloading games from every MacHub prefix that has Steam. No Steam or Whisky call.
    func refreshSteamGames() {
        var installed: [Title] = []
        var downloads: [Int: SteamApp] = [:]
        var updates: [Int: SteamApp] = [:]
        for prefix in prefixes {
            guard let root = SteamLibrary.steamRoot(inPrefix: prefix.url) else { continue }
            for app in SteamLibrary.apps(steamRoot: root, prefix: prefix.url) {
                if app.isInstalled {
                    installed.append(Title(game: app.game, bottle: prefix.name,
                                           executables: ExecutableScanner.executables(in: URL(filePath: app.installPath))))
                    if app.needsUpdate || app.isUpdating || app.isValidating || app.isUninstalling { updates[app.appID] = app }
                } else {
                    downloads[app.appID] = app
                }
            }
        }
        embeddedInstalled = installed
        steamDownloads = downloads
        steamUpdates = updates
        pendingSteamActions = pendingSteamActions.filter { id in installed.contains { $0.steamAppID == id } }
        if !downloads.isEmpty || updates.values.contains(where: { $0.isUpdating || $0.isValidating || $0.isUninstalling }) { watchDownloads() }
        refreshOwnedIfSteamLibraryChanged()
    }

    /// Without a key the library comes from Steam for Windows' cache, which fills in once Steam is signed in and its
    /// library has been shown: reload the games whenever the number of cached apps changes.
    private func refreshOwnedIfSteamLibraryChanged() {
        guard steam.account != nil, !steam.hasAPIKey, let prefix = steamPrefix,
              let root = SteamLibrary.steamRoot(inPrefix: prefix.url) else { return }
        let count = SteamLibrary.libraryCacheAppIDs(steamRoot: root).count
        guard count != libraryCacheCount else { return }
        libraryCacheCount = count
        Task { await refreshOwned() }
    }

    /// While Steam for Windows waits for its first sign-in, look at its library cache every 15 s for 10 minutes.
    private func watchLibraryCache() {
        libraryCacheWatch?.cancel()
        libraryCacheWatch = Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.refreshOwnedIfSteamLibraryChanged()
            }
        }
    }

    /// Fraction of a Steam download, read from disk.
    func downloadProgress(appID: Int) -> Double? {
        steamDownloads[appID].flatMap { SteamLibrary.progress(of: $0) }
    }

    /// Polls Steam's manifests while something is downloading, so progress and "Installed" appear without a refresh.
    private func watchDownloads() {
        guard downloadWatch == nil else { return }
        downloadWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                let requested = self.launchStates.values.contains(.installRequested)
                self.refreshSteamGames()
                for title in self.embeddedInstalled where self.launchStates[title.id] == .installRequested {
                    self.launchStates[title.id] = nil
                }
                let busy = self.steamUpdates.values.contains { $0.isUpdating || $0.isValidating || $0.isUninstalling }
                    || self.pendingSteamActions.contains { id in self.embeddedInstalled.contains { $0.steamAppID == id } }
                if self.steamDownloads.isEmpty && !requested && !busy { break }
            }
            self?.downloadWatch = nil
        }
    }

    /// One click: Steam prefix → Valve's installer (silent) → Steam started for the user to sign in.
    func setUpSteam() async {
        guard let runtime else { steamSetup = .failed(Self.describe(EngineError.runtimeMissing)); return }
        let engine = EmbeddedWineEngine(runtime: runtime)
        do {
            var prefix = prefixes.first { $0.settings.role == .steam }
            if prefix == nil {
                steamSetup = .working(.creatingPrefix)
                prefix = try await PrefixStore.live.create(name: "Steam", role: .steam, runtime: runtime,
                                                           takenNames: whiskyBottles.compactMap(\.name))
                prefixes = PrefixStore.live.all()
            }
            guard let prefix else { return }
            if SteamLibrary.steamRoot(inPrefix: prefix.url) == nil {
                steamSetup = .working(.downloadingInstaller)
                let installer = try await SteamSetup.downloadInstaller()
                steamSetup = .working(.installing)
                try await SteamSetup.install(engine: engine, prefix: prefix, installer: installer)
            }
            prefixes = PrefixStore.live.all()
            await startSteam()
        } catch {
            prefixes = PrefixStore.live.all()
            steamSetup = .failed(Self.describe(error))
        }
    }

    /// Games inherit Steam's environment (they are its children), so a setting changed in MacHub (FPS overlay, sync,
    /// AVX…) only reaches them once Steam restarts with it. MacHub records what Steam was started with.
    func steamEnvironment(prefix: InstalledPrefix, runtime: WineRuntime) -> String {
        var env = WineEnvironment(runtime: runtime, prefix: prefix).variables
        env.merge(SteamSetup.environment) { _, steam in steam }
        env["MACHUB_RUNTIME"] = runtime.version
        return env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    private func steamEnvironmentFile(_ prefix: InstalledPrefix) -> URL { prefix.url.appending(path: "machub-steam-env.txt") }

    func recordSteamEnvironment(prefix: InstalledPrefix, runtime: WineRuntime) {
        try? steamEnvironment(prefix: prefix, runtime: runtime).write(to: steamEnvironmentFile(prefix), atomically: true, encoding: .utf8)
    }

    /// Restarts Steam when it runs with older settings than MacHub's, unless another title is running.
    func restartSteamIfSettingsChanged(prefix: InstalledPrefix, runtime: WineRuntime, launching id: Title.ID) async {
        let snapshot = await ProcessWatch.snapshot()
        guard !ProcessWatch.matches(in: snapshot, target: .executable(LaunchPlan.steamExecutable)).isEmpty else {
            recordSteamEnvironment(prefix: prefix, runtime: runtime)   // the launch will start Steam with the current settings
            return
        }
        let recorded = try? String(contentsOf: steamEnvironmentFile(prefix), encoding: .utf8)
        guard recorded != steamEnvironment(prefix: prefix, runtime: runtime) else { return }
        let othersRunning = launchStates.contains { entry in
            guard entry.key != id else { return false }
            if case .running = entry.value { return true }
            return entry.value.isInProgress
        }
        guard !othersRunning else { return }
        await stopSteam()
        recordSteamEnvironment(prefix: prefix, runtime: runtime)
    }

    /// Starts Steam for Windows in the Steam prefix and brings its window forward.
    func startSteam() async {
        guard let runtime, let prefix = steamPrefix else { return }
        let engine = EmbeddedWineEngine(runtime: runtime)
        steamSetup = .working(.starting)
        let graphicsReady = (try? await SteamSetup.prepareGraphics(runtime: runtime, prefix: prefix)) ?? false
        if ProcessWatch.matches(in: await ProcessWatch.snapshot(), target: .executable(LaunchPlan.steamExecutable)).isEmpty {
            recordSteamEnvironment(prefix: prefix, runtime: runtime)
            Task.detached {
                // Becomes the Steam client: returns only when Steam quits.
                _ = try? await engine.run(SteamSetup.steamExe, bottle: prefix.name, arguments: [], timeout: 7 * 24 * 3600)
            }
            guard await ProcessWatch.waitForProgram(named: LaunchPlan.steamExecutable, timeout: .seconds(120)) != nil else {
                steamSetup = .failed(String(localized: "Steam for Windows didn't start within 2 minutes"))
                return
            }
        }
        if !graphicsReady {
            // First start: Steam unpacks its web helper during its self-update. Give it DXVK once it's there,
            // then end the helper; Steam restarts it at once, now drawing through DXVK.
            let deadline = ContinuousClock.now + .seconds(600)
            while ContinuousClock.now < deadline {
                if (try? await SteamSetup.prepareGraphics(runtime: runtime, prefix: prefix)) == true {
                    _ = try? await engine.run(#"C:\windows\system32\taskkill.exe"#, bottle: prefix.name,
                                              arguments: ["/F", "/IM", "steamwebhelper.exe"], timeout: 30)
                    break
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        steamSetup = .waitingForSignIn
        watchLibraryCache()
        // Steam's window appears only after its self-update (a minute or more on first start).
        _ = await SteamSetup.revealSteamWindow(runtime: runtime)
    }

    /// Asks Steam to quit cleanly (it syncs cloud saves on the way out), then ends what's left in the prefix.
    func stopSteam() async {
        guard let runtime, let prefix = steamPrefix else { return }
        let engine = EmbeddedWineEngine(runtime: runtime)
        _ = try? await engine.run(SteamSetup.steamExe, bottle: prefix.name, arguments: ["-shutdown"], timeout: 60)
        await ProcessWatch.waitForExit(.executable(LaunchPlan.steamExecutable), interval: .seconds(2))
        try? await engine.stopAll(in: prefix.name)
        // Steam's single-process web helper can outlive wineserver (seen 2026-10-18: a black Steam window left open).
        try? await Task.sleep(for: .seconds(2))
        await ProcessWatch.terminateOrphans(under: RuntimeManager.live.directory)
        steamSetup = nil
    }

    /// Closes a running title the way Windows would (WM_CLOSE), then forces it if it's still there after 10 s.
    /// Every process of the title (games: anything from its install folder; software: its own .exe) is asked to close
    /// the Windows way (WM_CLOSE); whatever is still there after 8 s is ended, including processes Wine no longer
    /// lists, like a launcher spinning after its game quit.
    func stop(_ title: Title) async {
        guard let bottle = title.bottle, let engine = engine(forBottle: bottle), let path = title.installPath else { return }
        let target: ProcessWatch.Target = title.kind == .game && title.steamAppID != nil
            ? .installFolder(URL(filePath: path).lastPathComponent)
            : .executable(URL(filePath: path).lastPathComponent)
        let running = ProcessWatch.matches(in: await ProcessWatch.snapshot(), target: target)
        guard !running.isEmpty else { return }
        let taskkill = #"C:\windows\system32\taskkill.exe"#
        for exe in Set(running.map(\.executable)) {
            _ = try? await engine.run(taskkill, bottle: bottle, arguments: ["/IM", exe], timeout: 30)
        }
        try? await Task.sleep(for: .seconds(8))
        await ProcessWatch.terminate(ProcessWatch.matches(in: await ProcessWatch.snapshot(), target: target).map(\.pid))
    }

    // MARK: Loading

    func refresh(customPath: String?) async {
        isLoading = true
        defer { isLoading = false }
        async let store: Void = refreshFeatured()
        async let owned: Void = refreshOwned()
        async let profile: Void = steam.refreshProfile()
        await refreshEngine()
        await refreshWhisky(customPath: customPath)
        _ = await (store, owned, profile)
    }

    func refreshNative() {
        guard MinecraftHome.standard.exists else { nativeTitles = []; return }
        var minecraft = Title(id: ModSupport.minecraftTitleID, name: "Minecraft: Java Edition", kind: .game, steamAppID: nil)
        minecraft.nativeApp = MinecraftHome.launcherApp
        minecraft.developer = "Mojang Studios"
        minecraft.summary = "Runs natively on your Mac through the official Minecraft Launcher. MacHub manages Fabric mods for it from Modrinth."
        nativeTitles = [minecraft]
    }

    func refreshWhisky(customPath: String?) async {
        refreshNative()
        let report = await DiagnosticsReport.make(customPath: customPath)
        self.report = report
        guard let install = whiskyInstall else {
            whiskyInstalled = []
            pinnedTitles = []
            return
        }
        let cli = WhiskyCLI(install: install)
        var found: [Title] = []
        var errors: [String] = []
        for bottle in whiskyBottles where bottle.hasDriveC {
            guard let name = bottle.name else { continue }
            do {
                found += try await cli.games(bottle: name).map {
                    Title(game: $0, bottle: name, executables: ExecutableScanner.executables(in: URL(filePath: $0.installPath)))
                }
            } catch {
                errors.append("\(name): \(Self.describe(error))")
            }
        }
        whiskyInstalled = found
        pinnedTitles = whiskyBottles.flatMap(WhiskyPins.titles(in:))
        loadErrors = errors
    }

    func refreshOwned() async {
        guard let account = steam.account else { ownedState = .signedOut; ownedTitles = []; return }
        guard let key = SteamAPIKeyStore.load() else { await refreshOwnedFromSteamClient(); return }
        ownedState = .loading
        do {
            switch try await SteamWebAPI.ownedGames(steamID: account.steamID64, key: key) {
            case .games(let games):
                ownedTitles = games.map(Title.init(owned:))
                ownedState = .loaded
            case .privateOrEmpty:
                ownedTitles = []
                ownedState = .privateProfile
            }
        } catch SteamHTTP.Failure.unauthorized {
            ownedState = .invalidKey
        } catch {
            ownedState = .failed(Self.describe(error))
        }
    }

    /// Without a key, the signed-in Steam for Windows still knows the library: its artwork cache has one folder per
    /// app. The store tells which of them are games (DLC, demos, SDKs and redistributables are left out); answers
    /// are kept on disk so each app is asked about once.
    private func refreshOwnedFromSteamClient() async {
        guard let prefix = steamPrefix, let root = SteamLibrary.steamRoot(inPrefix: prefix.url) else {
            ownedState = .needsKey; ownedTitles = []; return
        }
        let ids = SteamLibrary.libraryCacheAppIDs(steamRoot: root)
        guard !ids.isEmpty else { ownedState = .needsKey; ownedTitles = []; return }
        if ownedTitles.isEmpty { ownedState = .loading }
        var known = LocalData.load([String: AppKind].self, from: Self.appKindsFile) ?? [:]
        let missing = ids.filter { known[String($0)] == nil }
        await withTaskGroup(of: (Int, AppKind?).self) { group in
            var next = missing.makeIterator()
            func add() {
                guard let id = next.next() else { return }
                group.addTask {
                    do {
                        guard let details = try await SteamStore.details(appID: id) else { return (id, AppKind(type: "unknown", name: "")) }
                        return (id, AppKind(type: details.isPlayableGame ? "game" : (details.type == "game" ? "software" : details.type), name: details.name))
                    } catch { return (id, nil) }   // offline or rate-limited: ask again next time
                }
            }
            for _ in 0..<4 { add() }
            for await (id, kind) in group {
                if let kind { known[String(id)] = kind }
                add()
            }
        }
        LocalData.save(known, to: Self.appKindsFile)
        let games = ids.compactMap { id -> SteamWebAPI.OwnedGame? in
            guard let kind = known[String(id)], kind.type == "game" else { return nil }
            return SteamWebAPI.OwnedGame(appID: id, name: kind.name, playtimeMinutes: 0, lastPlayed: nil)
        }
        ownedTitles = games.map(Title.init(owned:))
        ownedState = games.isEmpty ? .needsKey : .fromSteamClient
    }

    struct AppKind: Codable, Equatable, Sendable {
        let type: String
        let name: String
    }

    static let appKindsFile = "steam-app-kinds-v2.json"

    func refreshFeatured() async {
        featuredState = .loading
        do {
            featuredStore = try await SteamStore.featured()
            featuredState = featuredStore.isStale ? .stale : .loaded
        } catch SteamHTTP.Failure.rateLimited {
            featuredState = .rateLimited
        } catch {
            featuredState = .offline
        }
    }

    /// Store page details, fetched on demand and cached (memory here, disk in SteamHTTP).
    @discardableResult
    func loadDetails(appID: Int) async -> StoreDetails? {
        if let cached = details[appID] { return cached }
        guard let fetched = try? await SteamStore.details(appID: appID) else { return nil }
        details[appID] = fetched
        return fetched
    }

    /// Builds a title's compatibility estimate once: store details (native Mac, DirectX), anti-cheat, ProtonDB.
    func loadEstimate(appID: Int) async {
        guard estimates[appID] == nil, !estimating.contains(appID) else { return }
        estimating.insert(appID)
        defer { estimating.remove(appID) }
        async let detailsTask = loadDetails(appID: appID)
        async let antiCheatsTask = CompatibilitySources.antiCheats()
        async let protonTask = CompatibilitySources.protonDB(appID: appID)
        let (details, antiCheats, proton) = await (detailsTask, antiCheatsTask, protonTask)
        estimates[appID] = .make(appID: appID, nativeMac: details?.mac, directX: details?.directX,
                                 antiCheat: antiCheats[appID], protonTier: proton?.tier, protonReports: proton?.reports ?? 0)
    }

    // MARK: Actions

    /// Starts a title and shows the launch screen. Every step is checked; nothing is assumed.
    func launch(_ title: Title) async {
        guard title.canLaunch, !(launchStates[title.id]?.isInProgress ?? false) else { return }
        let route: LaunchPlan.Route = if title.kind == .game, let appID = title.steamAppID {
            .steam(appID: appID)
        } else {
            .program(path: title.installPath ?? "")
        }
        let steamRunning: Bool
        if case .steam = route {
            steamRunning = !ProcessWatch.matches(in: await ProcessWatch.snapshot(), target: .executable(LaunchPlan.steamExecutable)).isEmpty
        } else {
            steamRunning = false
        }
        launchSessions[title.id] = LaunchSession(title: title, route: route, steamAlreadyRunning: steamRunning, stepStartedAt: .now, startedAt: .now)
        presentedLaunch = title.id
        launchStates[title.id] = .preparing
        let task = Task { await runLaunch(title, route: route) }
        launchTasks[title.id] = task
        await task.value
        launchTasks[title.id] = nil
    }

    /// Stops waiting for a launch. Steam or Wine may still start the title; MacHub just stops watching.
    func cancelLaunch(_ id: Title.ID) {
        launchTasks[id]?.cancel()
        if launchStates[id]?.isInProgress == true { launchStates[id] = .cancelled }
    }

    func dismissLaunch() { presentedLaunch = nil }

    func retryLaunch(_ id: Title.ID) {
        guard let title = launchSessions[id]?.title else { return }
        launchStates[id] = nil
        Task { await launch(title) }
    }

    private func runLaunch(_ title: Title, route: LaunchPlan.Route) async {
        let id = title.id
        launchStates[id] = .checkingBottle
        if let problem = Self.problem(for: title, route: route, bottles: registeredBottles) {
            launchStates[id] = .blocked(problem)
            return
        }
        guard let bottle = title.bottle else { return }
        guard let engine = engine(forBottle: bottle) else {
            let isEmbedded = registeredBottles.first { $0.name == bottle }?.engine == .embedded
            launchStates[id] = .blocked(isEmbedded ? .engineNotReady : .whiskyNotReady)
            return
        }
        recordLaunch(title)
        let target: ProcessWatch.Target = switch route {
        case .steam: .installFolder(URL(filePath: title.installPath ?? "").lastPathComponent)
        case .program(let path): .executable(URL(filePath: path).lastPathComponent)
        }
        let options = settings(for: title).argumentList
        var runner = LaunchRunner { plan in
            switch plan.route {
            case .steam(let appID):
                // `whisky launch` (3.7.0) reports "launched" without ever reaching Steam (verified 2026-10-18),
                // so ask the bottle's Steam directly. If Steam isn't running yet, this call *becomes* the
                // client and only returns when Steam quits: the runner never awaits it.
                _ = try await engine.run(#"C:\Program Files (x86)\Steam\steam.exe"#, bottle: plan.bottle,
                                         arguments: ["-applaunch", String(appID)] + options, timeout: 24 * 3600)
            case .program(let path):
                _ = try await engine.run(path, bottle: plan.bottle, arguments: options, timeout: 24 * 3600)
            }
        }
        runner.latestLog = { engine.latestLog()?.path }
        if let embedded = engine as? EmbeddedWineEngine, let install = title.install,
           let prefix = prefixes.first(where: { $0.name == install.bottle }) {
            if route.isSteam { await restartSteamIfSettingsChanged(prefix: prefix, runtime: embedded.runtime, launching: id) }
            let folder = route.isSteam ? URL(filePath: install.path) : URL(filePath: install.path).deletingLastPathComponent()
            let executables = route.isSteam ? install.executables : [URL(filePath: install.path).lastPathComponent]
            do {
                lastGraphics[id] = try await GraphicsDeployment.prepare(
                    installFolder: folder, executables: executables, choice: graphicsChoice(for: title),
                    d3dmetalAvailable: GPTKStore.live.canRunDirectX12, runtime: embedded.runtime, prefix: prefix)
            } catch {
                launchStates[id] = .failed(Self.describe(error), log: nil)
                return
            }
        }
        let sessionStart = Date.now
        await runner.run(LaunchPlan(route: route, bottle: bottle, target: target)) { [weak self] state in
            guard let self, self.launchStates[id] != .cancelled || !state.isInProgress else { return }
            self.launchStates[id] = state
        }
        if engineSettings.metalHUD, let summary = await PerformanceLog.read(since: sessionStart) {
            performance = PerformanceLog.record(summary, for: id)
        }
    }

    /// The on-disk checks before a launch: bottle registered and set up, program present, Steam present.
    static func problem(for title: Title, route: LaunchPlan.Route, bottles: [BottleInfo], fileManager: FileManager = .default) -> LaunchProblem? {
        guard let name = title.bottle else { return .executableMissing(title.installPath ?? "") }
        guard let bottle = bottles.first(where: { $0.name == name }) else { return .bottleMissing(name) }
        guard bottle.hasDriveC else { return .bottleNotSetUp(name) }
        switch route {
        case .steam:
            let steam = bottle.url.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
            guard fileManager.fileExists(atPath: steam.path) else { return .steamMissing(name) }
            guard let path = title.installPath, fileManager.fileExists(atPath: path), title.hasExecutable else {
                return .executableMissing(title.installPath ?? "")
            }
        case .program(let path):
            guard fileManager.fileExists(atPath: path) else { return .executableMissing(path) }
        }
        return nil
    }

    /// Opens Wine's Game Controllers panel (joy.cpl) in a bottle: the Windows-side check that a controller
    /// is exposed to games. Read-only; returns once the panel has been handed to Wine.
    func openWindowsControllerPanel(bottle: String) async {
        guard let engine = engine(forBottle: bottle) else { return }
        Task.detached {
            _ = try? await engine.run(#"C:\windows\system32\control.exe"#, bottle: bottle, arguments: ["joy.cpl"], timeout: 3600)
        }
        _ = await ProcessWatch.waitForProgram(named: "control.exe", timeout: .seconds(20), interval: .milliseconds(500))
    }

    /// Asks Steam for Windows inside the bottle to install the game (`steam://install/<id>`).
    func requestInstall(_ title: Title) async {
        guard let appID = title.steamAppID, let bottle = steamBottle?.name, let engine = engine(forBottle: bottle) else { return }
        launchStates[title.id] = .installRequested
        do {
            _ = try await engine.run(
                #"C:\Program Files (x86)\Steam\steam.exe"#, bottle: bottle, arguments: ["steam://install/\(appID)"], timeout: 24 * 3600
            )
        } catch {
            launchStates[title.id] = .failed(Self.describe(error), log: nil)
        }
    }

    // MARK: Managing an installed game (Steam does the work; MacHub asks and watches the manifests)

    enum SteamGameAction: Sendable {
        case uninstall, verify, update, properties

        func url(appID: Int) -> String {
            switch self {
            case .uninstall: "steam://uninstall/\(appID)"
            case .verify: "steam://validate/\(appID)"
            case .update: "steam://install/\(appID)"
            case .properties: "steam://gameproperties/\(appID)"
            }
        }
    }

    /// Games for which an uninstall was asked and Steam hasn't removed the manifest yet: keeps the watcher alive.
    private(set) var pendingSteamActions: Set<Int> = []

    /// Hands an action to the game's Steam for Windows. Steam shows its own confirmation where it has one (uninstall).
    func perform(_ action: SteamGameAction, on title: Title) async {
        guard let appID = title.steamAppID, let bottle = title.bottle ?? steamBottle?.name, let engine = engine(forBottle: bottle) else { return }
        if action == .uninstall {
            // Take MacHub's graphics DLLs back first: Steam only removes its own files and would leave the folder behind.
            if let install = title.install, let runtime {
                for exe in install.executables {
                    let folder = URL(filePath: install.path).appending(path: exe).deletingLastPathComponent()
                    _ = try? GraphicsDeployment.switchFolder(folder, to: .wined3d, runtime: runtime, is64Bit: true)
                }
            }
            pendingSteamActions.insert(appID)
        }
        do {
            _ = try await engine.run(SteamSetup.steamExe, bottle: bottle, arguments: [action.url(appID: appID)], timeout: 120)
        } catch {
            launchStates[title.id] = .failed(Self.describe(error), log: nil)
        }
        try? await Task.sleep(for: .seconds(2))
        if let runtime { SteamSetup.bringWineToFront(runtime: runtime) }
        refreshSteamGames()
        watchDownloads()
    }

    /// Reveals the game's folder in Finder.
    func revealInstallFolder(_ title: Title) {
        guard let path = title.installPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    /// A guided import for a Windows file, wired to the live Whisky install and its bottles.
    func makeImport(_ url: URL) -> InstallerImport {
        let dependencies = whiskyInstall.map { install in
            let container = BottleReader.containerURL(bundleID: install.bundleIdentifier ?? WhiskyLocator.forkBundleID)
            return InstallerImport.Dependencies(install: install, bottles: { BottleReader.read(container: container) })
        }
        return InstallerImport(url: url, dependencies: dependencies)
    }

    @discardableResult
    func importProgram(at url: URL, bottle: String, name: String? = nil) -> Title {
        let program = ImportedProgram(id: UUID(), name: name ?? url.deletingPathExtension().lastPathComponent, path: url.path, bottle: bottle)
        imported.append(program)
        LocalData.save(imported, to: "software.json")
        return program.title
    }

    func removeProgram(_ title: Title) {
        imported.removeAll { "software:\($0.id.uuidString)" == title.id }
        LocalData.save(imported, to: "software.json")
    }

    private func recordLaunch(_ title: Title) {
        history[title.id] = .now
        LocalData.save(history, to: "history.json")
    }

    private func lastPlayed(_ title: Title) -> Date {
        max(history[title.id] ?? .distantPast, title.owned?.lastPlayed ?? .distantPast)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let whisky as WhiskyError:
            switch whisky {
            case .failure(let message), .invalidInvocation(let message): message
            case .programExit(let code, let log): "Exited with code \(code)" + (log.map { ". Log: \($0)" } ?? "")
            case .timedOut(let seconds): "No answer from Whisky after \(Int(seconds)) s"
            case .unexpectedOutput: "Whisky returned something MacHub could not read"
            }
        case let engine as EngineError:
            switch engine {
            case .runtimeMissing: String(localized: "MacHub's Windows engine isn't installed")
            case .prefixMissing(let name): String(localized: "The Windows environment “\(name)” no longer exists")
            case .programExit(let code, let log): String(localized: "Exited with code \(code). Log: \(log.path)")
            }
        case let runtime as RuntimeError:
            switch runtime {
            case .checksumMismatch: String(localized: "The engine archive doesn't match the expected fingerprint; it was not installed")
            case .extractionFailed(let detail): String(localized: "The engine archive couldn't be unpacked: \(detail)")
            case .invalidArchive: String(localized: "This file isn't a MacHub engine archive")
            case .versionMismatch(let expected, let found): String(localized: "Expected engine \(expected), the archive holds \(found)")
            case .noDownloadURL: String(localized: "No download address for the engine yet")
            case .downloadFailed(let detail): String(localized: "Download failed: \(detail)")
            case .rosettaMissing: String(localized: "Rosetta 2 isn't installed. Wine needs it to run on Apple silicon")
            case .wineDoesNotStart(let detail): String(localized: "Wine didn't start: \(detail)")
            }
        case SteamSetup.Failure.downloadFailed(let detail): String(localized: "Couldn't download Steam's installer: \(detail)")
        case SteamSetup.Failure.notAnInstaller: String(localized: "The file downloaded from Valve isn't a Windows installer")
        case SteamSetup.Failure.installFailed: String(localized: "Steam's installer finished, but Steam isn't in the Windows environment")
        case GPTKStore.ImportError.notAToolkit: String(localized: "No D3DMetal.framework in this folder. Choose the mounted “Evaluation environment for Windows games” disk image.")
        case GPTKStore.ImportError.copyFailed(let detail): String(localized: "Couldn't copy the toolkit: \(detail)")
        case PrefixError.bootFailed(let detail): String(localized: "Wine couldn't set up the Windows environment: \(detail)")
        case SteamHTTP.Failure.rateLimited: "Steam is rate-limiting requests; try again in a few minutes"
        case SteamHTTP.Failure.offline: "Steam can't be reached"
        case SteamHTTP.Failure.unauthorized: "Steam refused the request (key or permissions)"
        case SteamHTTP.Failure.http(let code): "Steam answered HTTP \(code)"
        default: error.localizedDescription
        }
    }
}

extension Array where Element: Identifiable {
    func uniqued() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}
