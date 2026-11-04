import Foundation

/// Games with a native macOS build go through Steam for Mac instead of Wine: MacHub lists what Steam for Mac has
/// installed, starts those games through it and follows its downloads from the manifests.
extension LibraryStore {
    /// Installed Steam for Mac games, as library titles (merged with the same App ID from other sources).
    var macSteamTitles: [Title] {
        macSteamApps.values.filter(\.isInstalled).sorted { $0.appID < $1.appID }.map { app in
            var title = Title(id: Title.steamID(app.appID), name: app.name, kind: .game, steamAppID: app.appID)
            title.macInstall = app.installPath
            title.macAvailable = true
            title.owned = Title.Owned(playtimeMinutes: 0, lastPlayed: MacSteam.lastPlayed(appID: app.appID))
            return title
        }
    }

    /// Reads Steam for Mac's manifests (no call to Steam).
    func refreshMacSteam() {
        let apps = MacSteam.app == nil ? [] : MacSteam.apps()
        macSteamApps = Dictionary(apps.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
        macInstallRequests.subtract(apps.map(\.appID))
        for app in apps where launchStates[Title.steamID(app.appID)] == .installRequested { setLaunchState(nil, for: Title.steamID(app.appID)) }
        if !macInstallRequests.isEmpty || apps.contains(where: { !$0.isInstalled || $0.isUpdating }) { watchMacSteam() }
    }

    /// The Windows build can still be installed with MacHub's Steam for Windows (offered in the … menu).
    func canInstallWindowsVersion(_ title: Title) -> Bool {
        !title.isDemo && title.kind == .game && title.install == nil && title.macAvailable == true
            && steamBottle != nil && launchStates[title.id] != .installRequested
    }

    /// Fraction of a Steam for Mac download or update, nil when Steam hasn't said how much it needs.
    func macDownloadProgress(appID: Int) -> Double? {
        macSteamApps[appID].flatMap { SteamLibrary.progress(of: $0) }
    }

    /// Plays the game through Steam for Mac, which handles its DRM, cloud saves and updates.
    func playOnMac(_ title: Title) async {
        guard let appID = title.steamAppID else { return }
        let steamWasRunning = MacSteam.isRunning
        guard await MacSteam.open(.play, appID: appID) else { return }
        recordLaunch(title)
        guard let installPath = title.macInstall else { return }
        let id = title.id
        setLaunchState(.waitingForGame, for: id)
        Task { [weak self] in
            await MacSteam.waitForGameSession(installFolder: URL(filePath: installPath)) { running in
                Task { @MainActor in self?.setLaunchState(running ? .running(nil) : .closed, for: id) }
            }
            guard let self else { return }
            if launchStates[id] == .waitingForGame { setLaunchState(nil, for: id) }
            // Steam for Mac was started for this game: quit it once the game is closed, like Steam for Windows.
            if !steamWasRunning, LaunchersAfterGame.quitWhenGameCloses, !MacSteam.isAnyGameRunning(in: macSteamApps.values) {
                MacSteam.quit()
            }
        }
    }

    /// Asks Steam for Mac to install the game (Steam shows its own confirmation), or opens its store page when the
    /// account doesn't own it.
    func installOnMac(_ title: Title) async {
        guard let appID = title.steamAppID else { return }
        guard title.owned != nil else { _ = await MacSteam.open(.store, appID: appID); return }
        guard await MacSteam.open(.install, appID: appID), MacSteam.app != nil else { return }
        macInstallRequests.insert(appID)
        setLaunchState(.installRequested, for: title.id)
        watchMacSteam()
    }

    /// Polls Steam for Mac's manifests while it downloads, so progress and "Installed" appear by themselves.
    func watchMacSteam() {
        guard macSteamWatch == nil else { return }
        macSteamWatch = Task { [weak self] in
            var idle = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                let apps = MacSteam.apps()
                let busy = apps.contains { !$0.isInstalled || $0.isUpdating }
                self.macSteamApps = Dictionary(apps.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
                self.macInstallRequests.subtract(apps.map(\.appID))
                for app in apps where self.launchStates[Title.steamID(app.appID)] == .installRequested {
                    self.setLaunchState(nil, for: Title.steamID(app.appID))
                }
                // An install request with no manifest after 10 minutes was declined in Steam: stop following it.
                idle = busy ? 0 : idle + 1
                if !busy && (self.macInstallRequests.isEmpty || idle > 200) {
                    for id in self.macInstallRequests where self.launchStates[Title.steamID(id)] == .installRequested {
                        self.setLaunchState(nil, for: Title.steamID(id))
                    }
                    self.macInstallRequests = []
                    break
                }
            }
            self?.macSteamWatch = nil
        }
    }

    /// The Steam manifest of an installed game: MacHub's Windows environment first, else Steam for Mac.
    func manifest(for title: Title) -> SteamApp? {
        guard let appID = title.steamAppID else { return nil }
        if title.install != nil, let app = steamManifests[appID] { return app }
        if title.macInstall != nil { return macSteamApps[appID] }
        return nil
    }

    /// Loaded once per game and session (answers are cached on disk for an hour).
    func loadGameUpdates(appID: Int) async {
        guard gameUpdates[appID] == nil else { return }
        gameUpdates[appID] = await GameUpdates.load(appID: appID)
    }

    /// Asks the right Steam to update the game now (Steam for Windows in MacHub's environment, or Steam for Mac).
    func updateNow(_ title: Title) async {
        guard let appID = title.steamAppID else { return }
        if title.install != nil {
            await perform(.update, on: title)
        } else if title.macInstall != nil, await MacSteam.open(.install, appID: appID) {
            watchMacSteam()
        }
    }
}
