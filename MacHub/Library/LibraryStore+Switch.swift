import Foundation

/// Nintendo Switch games played in Astris: read from Astris' own files, artwork and details from nlib.
extension LibraryStore {
    var switchTitles: [Title] {
        switchGames.map { Title(switch: $0, info: switchInfo[$0.titleID]) }
    }

    /// Reads Astris' games and library folders (no call to Astris), then fetches missing details in the background.
    func refreshSwitch() {
        switchGames = Astris.games()
        let missing = switchGames.map(\.titleID).filter { switchInfo[$0] == nil }
        guard !missing.isEmpty else { return }
        Task {
            for id in missing {
                if let info = await SwitchCatalog.info(titleID: id) { switchInfo[id] = info }
            }
        }
    }

    /// Opens the game's file with Astris. Astris shows its own window; MacHub notes the launch for Recent.
    func playSwitch(_ title: Title) async {
        guard let file = title.switchFile, let titleID = title.switchTitleID else { return }
        let astrisWasRunning = Astris.isRunning
        let before = Astris.playtime(titleID: titleID)
        guard await Astris.play(file) else { return }
        recordLaunch(title)
        let id = title.id
        setLaunchState(.running(nil), for: id)
        Task { [weak self] in
            // Astris writes the game's play time when emulation stops; Astris closing ends the session too.
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled, Astris.isRunning, Astris.playtime(titleID: titleID) == before {
                try? await Task.sleep(for: .seconds(3))
            }
            guard let self else { return }
            setLaunchState(.closed, for: id)
            refreshSwitch()
            if !astrisWasRunning, LaunchersAfterGame.quitWhenGameCloses, Astris.isRunning { Astris.quit() }
        }
    }
}
