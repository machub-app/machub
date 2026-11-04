import AppKit
import SwiftUI

/// Settings › Emulators: Astris (Nintendo Switch), what MacHub reads from it, and where the game files are looked for.
struct EmulatorSettingsSection: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Section {
            if let app = Astris.app {
                LabeledContent("Astris") {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                LabeledContent("Switch games found") { Text(verbatim: String(store.switchGames.count)) }
                let missing = store.switchGames.filter { $0.file == nil }.count
                if missing > 0 {
                    LabeledContent("Without a game file") { Text(verbatim: String(missing)) }
                }
                HStack {
                    Button("Open Astris") { NSWorkspace.shared.openApplication(at: app, configuration: .init()) }
                    Button("Look Again") { store.refreshSwitch() }
                }
            } else {
                LabeledContent("Astris") { Text("Not installed").foregroundStyle(.secondary) }
            }
        } header: {
            Text("Nintendo Switch")
        } footer: {
            Text("MacHub lists the Switch games Astris knows and the game files in Astris' game folders, then opens them with Astris. It never provides games, firmware or console keys: use dumps of games you own.")
        }
        if Astris.app != nil {
            Section {
                let folders = Astris.libraryFolders()
                if folders.isEmpty {
                    Text("No game folder found. Add one in Astris, or put your games in a folder named Game in your home folder.")
                        .foregroundStyle(.secondary)
                }
                ForEach(folders, id: \.self) { folder in
                    LabeledContent {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    } label: {
                        Text(verbatim: folder.path).font(.callout.monospaced())
                    }
                }
            } header: {
                Text("Game Folders")
            } footer: {
                Text("The folders added in Astris' library. Change them in Astris, then choose Look Again.")
            }
        }
    }
}
