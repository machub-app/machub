import Foundation

enum EpicState: Equatable, Sendable {
    case signedOut
    case working(String)
    case ready(account: String)
    case failed(String)
}

extension LibraryStore {
    /// Reads the Epic library from Legendary when an account is signed in.
    func refreshEpic(refresh: Bool = false) async {
        guard Legendary.isInstalled, let account = Legendary.accountName() else {
            if case .working = epicState { return }
            epicState = .signedOut
            epicTitles = []
            return
        }
        do {
            async let gamesTask = Legendary.games(refresh: refresh)
            async let installedTask = Legendary.installed()
            let (games, installed) = try await (gamesTask, installedTask)
            epicTitles = games.map { game in
                let install = installed[game.appName].map { local in
                    Title.Install(bottle: Legendary.prefixName, path: local.installPath,
                                  executables: ExecutableScanner.executables(in: URL(filePath: local.installPath)))
                }
                return Title(epic: game, install: install)
            }
            epicState = .ready(account: account)
        } catch {
            epicState = .failed(Self.describe(error))
        }
    }

    func signInEpic(code: String) async {
        epicState = .working(String(localized: "Signing in to Epic…"))
        do {
            try await Legendary.signIn(code: code)
            epicState = .working(String(localized: "Reading your Epic library…"))
            await refreshEpic(refresh: true)
        } catch {
            epicState = .failed(Self.describe(error))
        }
    }

    func signOutEpic() async {
        await Legendary.signOut()
        epicTitles = []
        epicState = .signedOut
    }

    /// The Windows environment Epic games install into, created the first time.
    func epicPrefix() async throws -> InstalledPrefix {
        if let existing = prefixes.first(where: { $0.name == Legendary.prefixName }) { return existing }
        guard runtime != nil else { throw EngineError.runtimeMissing }
        guard let prefix = await createPrefix(name: Legendary.prefixName, role: .apps) else {
            throw Legendary.Failure.command(String(localized: "The Epic Games environment couldn't be created. See Settings › Windows Environments."))
        }
        return prefix
    }

    func installEpic(_ title: Title) async {
        guard let appName = title.epicAppName, epicInstalls[appName] == nil else { return }
        epicInstalls[appName] = 0
        epicErrors[appName] = nil
        defer { epicInstalls[appName] = nil }
        do {
            let prefix = try await epicPrefix()
            try await Legendary.install(appName, basePath: prefix.url.appending(path: "drive_c/Epic Games")) { fraction in
                Task { @MainActor in self.epicInstalls[appName] = fraction }
            }
            await refreshEpic()
        } catch {
            epicErrors[appName] = Self.describe(error)
        }
    }

    func uninstallEpic(_ title: Title) async {
        guard let appName = title.epicAppName else { return }
        do {
            try await Legendary.uninstall(appName)
            await refreshEpic()
        } catch {
            epicErrors[appName] = Self.describe(error)
        }
    }
}
