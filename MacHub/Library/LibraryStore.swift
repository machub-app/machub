import Foundation
import Observation

/// Everything the UI reads. Each list has one real source, and its state says what is known:
/// installed = `whisky games`, owned = Steam Web API, store = Steam store, software = imports + Whisky pins.
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
        case failed(String)
    }

    enum StoreState: Equatable {
        case idle, loading, loaded, stale, rateLimited, offline
    }

    let steam = SteamConnection()

    private(set) var report: DiagnosticsReport?
    private(set) var installedTitles: [Title] = []
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

    var registeredBottles: [BottleInfo] {
        guard whiskyInstall != nil else { return [] }
        return report?.containers.first { $0.bundleID == WhiskyLocator.forkBundleID }?.bottles.filter(\.isRegistered) ?? []
    }

    /// First registered bottle that actually contains Steam for Windows.
    var steamBottle: BottleInfo? {
        registeredBottles.first { bottle in
            ["Program Files (x86)/Steam/steam.exe", "Program Files/Steam/steam.exe"]
                .contains { FileManager.default.fileExists(atPath: bottle.url.appending(path: "drive_c/\($0)").path) }
        }
    }

    // MARK: Loading

    func refresh(customPath: String?) async {
        isLoading = true
        defer { isLoading = false }
        async let store: Void = refreshFeatured()
        async let owned: Void = refreshOwned()
        async let profile: Void = steam.refreshProfile()
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
            installedTitles = []
            pinnedTitles = []
            return
        }
        let cli = WhiskyCLI(install: install)
        var found: [Title] = []
        var errors: [String] = []
        for bottle in registeredBottles where bottle.hasDriveC {
            guard let name = bottle.name else { continue }
            do {
                found += try await cli.games(bottle: name).map {
                    Title(game: $0, bottle: name, executables: ExecutableScanner.executables(in: URL(filePath: $0.installPath)))
                }
            } catch {
                errors.append("\(name): \(Self.describe(error))")
            }
        }
        installedTitles = found
        pinnedTitles = registeredBottles.flatMap(WhiskyPins.titles(in:))
        loadErrors = errors
    }

    func refreshOwned() async {
        guard let account = steam.account else { ownedState = .signedOut; ownedTitles = []; return }
        guard let key = SteamAPIKeyStore.load() else { ownedState = .needsKey; ownedTitles = []; return }
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
        guard let install = whiskyInstall else { launchStates[id] = .blocked(.whiskyNotReady); return }
        launchStates[id] = .checkingBottle
        if let problem = Self.problem(for: title, route: route, bottles: registeredBottles) {
            launchStates[id] = .blocked(problem)
            return
        }
        guard let bottle = title.bottle else { return }
        recordLaunch(title)
        let target: ProcessWatch.Target = switch route {
        case .steam: .installFolder(URL(filePath: title.installPath ?? "").lastPathComponent)
        case .program(let path): .executable(URL(filePath: path).lastPathComponent)
        }
        let cli = WhiskyCLI(install: install)
        let runner = LaunchRunner { plan in
            switch plan.route {
            case .steam(let appID):
                // `whisky launch` (3.7.0) reports "launched" without ever reaching Steam (verified 2026-10-18),
                // so ask the bottle's Steam directly. If Steam isn't running yet, this call *becomes* the
                // client and only returns when Steam quits: the runner never awaits it.
                _ = try await cli.run(#"C:\Program Files (x86)\Steam\steam.exe"#, bottle: plan.bottle,
                                      arguments: ["-applaunch", String(appID)], timeout: 24 * 3600)
            case .program(let path):
                _ = try await cli.run(path, bottle: plan.bottle, timeout: 24 * 3600)
            }
        }
        await runner.run(LaunchPlan(route: route, bottle: bottle, target: target)) { [weak self] state in
            guard let self, self.launchStates[id] != .cancelled || !state.isInProgress else { return }
            self.launchStates[id] = state
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
        guard let install = whiskyInstall else { return }
        let cli = WhiskyCLI(install: install)
        Task.detached {
            _ = try? await cli.run(#"C:\windows\system32\control.exe"#, bottle: bottle, arguments: ["joy.cpl"], timeout: 3600)
        }
        _ = await ProcessWatch.waitForProgram(named: "control.exe", timeout: .seconds(20), interval: .milliseconds(500))
    }

    /// Asks Steam for Windows inside the bottle to install the game (`steam://install/<id>`).
    func requestInstall(_ title: Title) async {
        guard let appID = title.steamAppID, let bottle = steamBottle?.name, let install = whiskyInstall else { return }
        launchStates[title.id] = .installRequested
        do {
            _ = try await WhiskyCLI(install: install).run(
                #"C:\Program Files (x86)\Steam\steam.exe"#, bottle: bottle, arguments: ["steam://install/\(appID)"], timeout: 24 * 3600
            )
        } catch {
            launchStates[title.id] = .failed(Self.describe(error), log: nil)
        }
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
