import Foundation

/// Settings › Storage: measuring, games folders on other drives, removing MacHub's data.
extension LibraryStore {
    /// Measures games, environments and engines off the main thread.
    func measureStorage() async -> StorageReport {
        let prefixes = prefixes, runtimes = installedRuntimes
        return await Task.detached(priority: .utility) { StorageReport.measure(prefixes: prefixes, runtimes: runtimes) }.value
    }

    var isSteamForWindowsRunning: Bool {
        get async { !ProcessWatch.matches(in: await ProcessWatch.snapshot(), target: .executable(LaunchPlan.steamExecutable)).isEmpty }
    }

    enum GamesFolderError: Error, Equatable {
        case noSteam
        case steamRunning
    }

    /// Adds `folder` as a Steam library of the Steam environment. Steam must be closed: it rewrites
    /// `libraryfolders.vdf` when it quits and would drop the new entry. Returns the Windows path Steam shows.
    func addGamesFolder(_ folder: URL) async throws -> String {
        guard let prefix = steamPrefix, let root = SteamLibrary.steamRoot(inPrefix: prefix.url) else { throw GamesFolderError.noSteam }
        guard await !isSteamForWindowsRunning else { throw GamesFolderError.steamRunning }
        let path = try SteamLibrary.addLibraryFolder(folder, steamRoot: root, prefix: prefix.url)
        refreshSteamGames()
        return path
    }

    /// Lists what "Uninstall MacHub's data" would move to the Trash, measured off the main thread.
    func planDataRemoval() async -> DataRemoval {
        let directory = LocalData.directory
        return await Task.detached(priority: .utility) { DataRemoval.plan(dataDirectory: directory) }.value
    }

    /// Quits every Windows program, moves `plan`'s items to the Trash, removes MacHub's Keychain items and
    /// preferences. Returns the items that couldn't be moved (nothing is ever deleted outright).
    func removeAllData(_ plan: DataRemoval) async -> [DataRemoval.Item] {
        await forceQuitAllWindowsPrograms()
        let failed = await Task.detached(priority: .userInitiated) { plan.perform() }.value
        NexusKeyStore.delete()
        SteamAPIKeyStore.delete()
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        await refreshEngine()
        return failed
    }
}
