import Foundation
import Observation

/// Everything the UI reads. Each list has one real source, and its state says what is known:
/// installed = `whisky games`, owned = Steam Web API, store = Steam store, software = imports + Whisky pins.
@MainActor @Observable
final class LibraryStore {
    enum LaunchState: Equatable {
        case launching
        /// WhiskyCmd handed the request to Steam. The game process itself is not verified yet.
        case handedToSteam
        /// A Windows program started with `whisky run` and hasn't exited.
        case running
        case exited(Int32)
        case installRequested
        case failed(String)
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
    private(set) var featuredStore = SteamStore.Featured()
    private(set) var featuredState: StoreState = .idle
    private(set) var history: [String: Date] = LocalData.load([String: Date].self, from: "history.json") ?? [:]
    private(set) var details: [Int: StoreDetails] = [:]
    private(set) var loadErrors: [String] = []
    private(set) var isLoading = false
    private(set) var launchStates: [Title.ID: LaunchState] = [:]
    /// The title whose artwork lights the window (hero, hovered card, open detail).
    var spotlight: Title?

    // MARK: Derived lists

    /// Steam games the user has: installed ∪ owned, merged per App ID.
    var library: [Title] {
        var byID: [String: Title] = [:]
        for t in installedTitles + ownedTitles { byID[t.id] = byID[t.id].map { $0.merged(with: t) } ?? t }
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
        await refreshWhisky(customPath: customPath)
        _ = await (store, owned)
    }

    func refreshWhisky(customPath: String?) async {
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

    func launch(_ title: Title) async {
        guard title.canLaunch, let bottle = title.bottle, let install = whiskyInstall else { return }
        let cli = WhiskyCLI(install: install)
        launchStates[title.id] = .launching
        recordLaunch(title)
        do {
            if title.kind == .game, let appID = title.steamAppID {
                _ = try await cli.launch(appId: appID, bottle: bottle)
                launchStates[title.id] = .handedToSteam
            } else if let path = title.installPath {
                launchStates[title.id] = .running
                let result = try await cli.run(path, bottle: bottle, timeout: 24 * 3600)
                launchStates[title.id] = .exited(result.status)
            }
        } catch {
            launchStates[title.id] = .failed(Self.describe(error))
        }
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
            launchStates[title.id] = .failed(Self.describe(error))
        }
    }

    func importProgram(at url: URL, bottle: String) {
        imported.append(ImportedProgram(id: UUID(), name: url.deletingPathExtension().lastPathComponent, path: url.path, bottle: bottle))
        LocalData.save(imported, to: "software.json")
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
