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
        guard let file = title.switchFile else { return }
        if await Astris.play(file) { recordLaunch(title) }
    }
}
