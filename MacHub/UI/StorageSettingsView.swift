import AppKit
import SwiftUI

/// Settings › Storage: what MacHub takes on disk, games folders on other drives, and removing everything MacHub keeps.
struct StorageSettingsSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var report: StorageReport?
    @State private var measuring = false
    @State private var adding = false
    @State private var pendingFolder: URL?
    @State private var addMessage: AddMessage?
    @State private var removing = false

    enum AddMessage: Equatable {
        case added(String)
        case failed(String)
    }

    var body: some View {
        diskUseSection
        gamesSection
        librariesSection
        Section {
            Button("Uninstall MacHub's Data…", role: .destructive) { removing = true }
        } header: {
            Text("Remove MacHub's Data")
        } footer: {
            Text("Moves MacHub's engines, Windows environments (with the games installed in them), logs, caches and settings to the Trash, and removes its keys from the Keychain. You choose after seeing the full list.")
        }
        .task { await measure() }
        .sheet(isPresented: $removing) { DataRemovalSheet().environment(store) }
        .confirmationDialog("Quit Steam for Windows to add this folder?", isPresented: Binding(get: { pendingFolder != nil }, set: { if !$0 { pendingFolder = nil } })) {
            Button("Quit Steam and Add Folder") {
                if let folder = pendingFolder { Task { await add(folder, quittingSteam: true) } }
            }
        } message: {
            Text("Steam rewrites its list of library folders when it quits, so MacHub can only add one while Steam is closed. Steam saves your cloud saves on the way out.")
        }
    }

    // MARK: Sections

    private var diskUseSection: some View {
        Section {
            if let report {
                LabeledContent("Total") { Text(verbatim: Storage.format(report.total)) }
                ForEach(report.prefixes) { item in
                    LabeledContent { Text(verbatim: Storage.format(item.bytes)) } label: {
                        Text("Windows environment “\(item.name)”")
                    }
                }
                ForEach(report.runtimes) { item in
                    LabeledContent { Text(verbatim: Storage.format(item.bytes)) } label: {
                        Text("Windows engine \(item.name)")
                    }
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("Disk Use")
                Spacer()
                Button("Measure Again", systemImage: "arrow.clockwise") { Task { await measure() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(measuring)
            }
        } footer: {
            Text("Games installed in a Windows environment are counted in that environment's size.")
        }
    }

    @ViewBuilder private var gamesSection: some View {
        if let report, !report.games.isEmpty {
            Section {
                ForEach(report.games) { game in
                    LabeledContent { Text(verbatim: Storage.format(game.bytes)) } label: {
                        Text(verbatim: game.name)
                        Text(verbatim: game.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            } header: {
                Text("Installed Games")
            } footer: {
                Text("Sizes as Steam for Windows records them. To uninstall a game, use its menu in the library or Steam itself.")
            }
        }
    }

    private var librariesSection: some View {
        Section {
            ForEach(report?.libraries ?? [], id: \.windowsPath) { folder in
                LabeledContent {
                    if folder.isAvailable {
                        if let free = Storage.availableSpace(at: folder.url) {
                            Text("\(Storage.format(free)) available")
                        }
                    } else {
                        Label("Drive not connected", systemImage: "externaldrive.badge.xmark").foregroundStyle(.orange)
                    }
                } label: {
                    Text(verbatim: folder.windowsPath)
                    Text(verbatim: folder.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack {
                Button("Add a Games Folder on Another Drive…") { chooseFolder() }
                    .disabled(store.steamPrefix == nil || adding)
                if adding { ProgressView().controlSize(.small) }
            }
            switch addMessage {
            case .added(let path)?:
                Label("Added as \(path). Steam for Windows lists it next time it starts.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message)?:
                Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
        } header: {
            Text("Steam Library Folders")
        } footer: {
            Text("A folder on an external drive becomes a Windows drive for Steam. Steam can then install new games there (it asks where when you install), or move one with the game's Properties › Installed Files › Move Install Folder. Keep the drive connected while you play those games.")
        }
    }

    // MARK: Actions

    private func measure() async {
        measuring = true
        report = await store.measureStorage()
        measuring = false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: "/Volumes")
        panel.message = String(localized: "Choose a folder on an external drive for Steam games.")
        panel.prompt = String(localized: "Use This Folder")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            if await store.isSteamForWindowsRunning { pendingFolder = folder } else { await add(folder, quittingSteam: false) }
        }
    }

    private func add(_ folder: URL, quittingSteam: Bool) async {
        adding = true
        addMessage = nil
        if quittingSteam { await store.stopSteam() }
        do {
            addMessage = .added(try await store.addGamesFolder(folder))
        } catch LibraryStore.GamesFolderError.steamRunning {
            addMessage = .failed(String(localized: "Steam for Windows is still running. Quit it, then try again."))
        } catch LibraryStore.GamesFolderError.noSteam {
            addMessage = .failed(String(localized: "Set up Steam for Windows first."))
        } catch SteamLibrary.AddFolderError.noFreeDriveLetter {
            addMessage = .failed(String(localized: "Every Windows drive letter is already in use."))
        } catch SteamLibrary.AddFolderError.unreadableLibraryFile {
            addMessage = .failed(String(localized: "MacHub couldn't read Steam's list of library folders. Start Steam for Windows once, quit it, then try again."))
        } catch {
            addMessage = .failed(LibraryStore.describe(error))
        }
        adding = false
        await measure()
    }
}

/// The confirmation for "Uninstall MacHub's data": every item that goes to the Trash with its size, then the result.
private struct DataRemovalSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var plan: DataRemoval?
    @State private var games: [StorageReport.Item] = []
    @State private var phase = Phase.reviewing

    enum Phase: Equatable {
        case reviewing
        case removing
        case done(failed: [String])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall MacHub's Data").font(.title2.bold())
            switch phase {
            case .reviewing, .removing: review
            case .done(let failed): result(failed)
            }
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 420)
        .task {
            async let report = store.measureStorage()
            plan = await store.planDataRemoval()
            games = await report.games.filter { $0.url.path.hasPrefix(PrefixStore.live.directory.path) }
        }
    }

    @ViewBuilder private var review: some View {
        Text("MacHub quits every Windows program, including Steam for Windows, then moves these items to the Trash. You can restore them from the Trash until you empty it.")
            .fixedSize(horizontal: false, vertical: true)
        if let plan {
            List {
                Section("Moved to the Trash") {
                    ForEach(plan.items) { item in
                        LabeledContent { Text(verbatim: Storage.format(item.bytes)) } label: {
                            label(for: item.url)
                            Text(verbatim: item.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        if item.url.lastPathComponent == "Prefixes" {
                            ForEach(games) { game in
                                LabeledContent { Text(verbatim: Storage.format(game.bytes)) } label: {
                                    Text("Includes the game \(game.name)")
                                }
                                .padding(.leading, 16)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent("Total") { Text(verbatim: Storage.format(plan.total)) }.bold()
                }
                Section("Removed from the Keychain") {
                    Text("Nexus Mods API key")
                    Text("Steam Web API key")
                }
                Section("Also removed") {
                    Text("MacHub's preferences (language, choices in Settings)")
                }
            }
            .frame(minHeight: 260)
            Text("Games in library folders on other drives stay there. The MacHub app itself stays in Applications: drag it to the Trash afterwards if you want it gone too.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("Measuring…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        }
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(phase == .removing)
            Button("Move to Trash", role: .destructive) { Task { await remove() } }
                .disabled(plan == nil || phase == .removing)
            if phase == .removing { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private func result(_ failed: [String]) -> some View {
        if failed.isEmpty {
            Label("MacHub's data is in the Trash.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Label("Some items couldn't be moved to the Trash:", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            ForEach(failed, id: \.self) { Text(verbatim: $0).font(.callout.monospaced()) }
        }
        Text("Quit MacHub now. To remove the app too, drag it from Applications to the Trash.")
            .fixedSize(horizontal: false, vertical: true)
        Spacer()
        HStack {
            Spacer()
            Button("Quit MacHub") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
        }
    }

    private func label(for url: URL) -> Text {
        switch url.lastPathComponent {
        case "Prefixes": Text("Windows environments")
        case "Runtimes": Text("Windows engines")
        case "GPTK": Text("Imported D3DMetal")
        case "mods": Text("Mod files and their backups")
        case "app.machub.MacHub" where url.path.contains("/Logs/"): Text("Logs")
        case "app.machub.MacHub": Text("Caches")
        default: url.pathExtension == "json" ? Text("Settings file \(url.lastPathComponent)") : Text(verbatim: url.lastPathComponent)
        }
    }

    private func remove() async {
        guard let plan else { return }
        phase = .removing
        let failed = await store.removeAllData(plan)
        phase = .done(failed: failed.map(\.url.path))
    }
}
