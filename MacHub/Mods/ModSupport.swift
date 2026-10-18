import Foundation
import Observation

/// What MacHub can really do for a game's mods. Each case is an honest level of integration.
enum ModSupport: Equatable, Sendable {
    /// Search, details, verified download and install from Modrinth's documented API (Minecraft: Java Edition + Fabric).
    case modrinth
    /// No documented download API: MacHub installs archives the user downloaded, safely and reversibly.
    case archiveImport(gameFolder: URL)
    /// MacHub only points to the official source; installing is up to the game.
    case externalOnly(URL)

    static let minecraftTitleID = "native:minecraft-java"
    static let assettoCorsaAppID = 244210
    static let beamNGAppID = 284160

    static func support(for title: Title) -> ModSupport? {
        if title.id == minecraftTitleID { return .modrinth }
        if title.steamAppID == assettoCorsaAppID, let path = title.installPath { return .archiveImport(gameFolder: URL(filePath: path)) }
        if title.steamAppID == beamNGAppID { return .externalOnly(URL(string: "https://www.beamng.com/resources/")!) }
        return nil
    }

    /// Community sites for Assetto Corsa content. They have no public download API, so MacHub opens them in the browser.
    static let assettoCorsaSources: [(name: String, url: URL)] = [
        ("Overtake (formerly RaceDepartment)", URL(string: "https://www.overtake.gg/downloads/categories/assetto-corsa.7/")!),
        ("AssettoCorsa.club", URL(string: "https://assettocorsa.club/")!),
    ]
}

struct ModsRoute: Hashable {
    let title: Title
}

/// Live state of the Minecraft mods page: the chosen MacHub profile, search, installs in flight.
@MainActor @Observable
final class MinecraftModsModel {
    enum SearchState: Equatable { case idle, loading, loaded, failed(String) }

    let home = MinecraftHome.standard
    private(set) var instances: [MinecraftInstance] = []
    var selectedInstanceID: String?
    private(set) var releases: [String] = []

    var query = ""
    var category: String?
    var sort: Modrinth.Sort = .relevance
    private(set) var results: [ModProject] = []
    private(set) var total = 0
    private(set) var searchState: SearchState = .idle

    private(set) var installed: [InstalledMod] = []
    private(set) var unmanaged: [String] = []
    /// Download progress per project, 0…1, from real byte counts.
    private(set) var progress: [String: Double] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var updates: [String: ModVersion] = [:]
    private(set) var checkingUpdates = false
    private(set) var creatingInstance = false
    private(set) var instanceError: String?
    private var generation = 0

    var instance: MinecraftInstance? { instances.first { $0.id == selectedInstanceID } ?? instances.first }
    var installer: FolderModInstaller? { instance.map { FolderModInstaller(folder: $0.modsDir) } }

    func reload() {
        instances = home.instances()
        releases = home.installedReleases()
        if selectedInstanceID == nil || !instances.contains(where: { $0.id == selectedInstanceID }) { selectedInstanceID = instances.first?.id }
        reloadInstalled()
    }

    func reloadInstalled() {
        installed = installer?.installed().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } ?? []
        unmanaged = installer?.unmanagedFiles() ?? []
    }

    func search() async {
        generation += 1
        let mine = generation
        searchState = .loading
        do {
            let page = try await Modrinth.search(query: query, category: category, gameVersion: instance?.gameVersion,
                                                 loader: instance?.loader ?? "fabric", sort: sort, offset: 0)
            guard mine == generation else { return }
            results = page.hits
            total = page.total
            searchState = .loaded
        } catch {
            guard mine == generation else { return }
            searchState = .failed(LibraryStore.describe(error))
        }
    }

    func isInstalled(_ projectID: String) -> Bool { installed.contains { $0.projectID == projectID } }

    func createInstance(gameVersion: String) async {
        creatingInstance = true
        instanceError = nil
        defer { creatingInstance = false }
        do {
            let created = try await FabricSetup(home: home).createInstance(gameVersion: gameVersion, launcherRunning: MinecraftHome.isLauncherRunning)
            reload()
            selectedInstanceID = created.id
            reloadInstalled()
        } catch FabricSetup.Failure.launcherRunning {
            instanceError = "Quit the Minecraft Launcher first: it rewrites its profile list when it closes."
        } catch FabricSetup.Failure.noLoader(let version) {
            instanceError = "Fabric doesn't support Minecraft \(version) yet."
        } catch {
            instanceError = "Couldn't create the profile: \(error.localizedDescription)"
        }
    }

    /// Installs a version and, first, the mods it requires (resolved for the same game version and loader).
    func install(_ version: ModVersion, title: String) async {
        guard let installer, let instance else { return }
        errors[version.projectID] = nil
        progress[version.projectID] = 0
        defer { progress[version.projectID] = nil; reloadInstalled() }
        do {
            for dependency in version.dependencies where dependency.kind == .required {
                guard let depID = dependency.projectID, !isInstalled(depID) else { continue }
                let versions = try await Modrinth.versions(projectID: depID, gameVersion: instance.gameVersion, loader: instance.loader)
                guard let best = Modrinth.bestVersion(versions, gameVersion: instance.gameVersion, loader: instance.loader) else {
                    throw ModInstallError.noCompatibleVersion(depID)
                }
                let depTitle = (try? await Modrinth.project(depID).title) ?? depID
                _ = try await installer.install(best, title: depTitle, requiredBy: version.projectID) { [weak self] value in
                    Task { @MainActor in self?.progress[version.projectID] = value * 0.5 }
                }
                reloadInstalled()
            }
            _ = try await installer.install(version, title: title) { [weak self] value in
                Task { @MainActor in self?.progress[version.projectID] = value }
            }
            updates[version.projectID] = nil
        } catch {
            errors[version.projectID] = Self.describe(error)
        }
    }

    func setEnabled(_ mod: InstalledMod, _ enabled: Bool) {
        do { try installer?.setEnabled(mod, enabled) } catch { errors[mod.projectID] = Self.describe(error) }
        reloadInstalled()
    }

    func uninstall(_ mod: InstalledMod) {
        do { try installer?.uninstall(mod) } catch { errors[mod.projectID] = Self.describe(error) }
        updates[mod.projectID] = nil
        reloadInstalled()
    }

    /// Mods still installed that list `mod` as required.
    func dependents(of mod: InstalledMod) -> [InstalledMod] {
        installed.filter { mod.requiredBy.contains($0.projectID) }
    }

    func checkUpdates() async {
        guard let instance else { return }
        checkingUpdates = true
        defer { checkingUpdates = false }
        for mod in installed {
            guard let versions = try? await Modrinth.versions(projectID: mod.projectID, gameVersion: instance.gameVersion, loader: instance.loader),
                  let best = Modrinth.bestVersion(versions, gameVersion: instance.gameVersion, loader: instance.loader) else { continue }
            updates[mod.projectID] = best.id != mod.versionID ? best : nil
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ModInstallError.download(let message): "Download failed: \(message)"
        case ModInstallError.sizeMismatch: "The downloaded file doesn't have the size Modrinth announced. Nothing was installed."
        case ModInstallError.hashMismatch: "The downloaded file doesn't match Modrinth's SHA-512. Nothing was installed."
        case ModInstallError.unsafeFileName(let name): "Refused an unsafe file name: \(name)"
        case ModInstallError.foreignFileExists(let name): "\(name) is already in the mods folder and wasn't installed by MacHub. It was left alone."
        case ModInstallError.noCompatibleVersion: "No version for this Minecraft version and loader."
        case ModInstallError.notInstalled: "This mod isn't installed."
        default: LibraryStore.describe(error)
        }
    }
}
