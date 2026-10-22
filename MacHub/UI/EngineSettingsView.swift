import SwiftUI
import UniformTypeIdentifiers

/// A binding to one engine option: changes are saved at once and apply to the next Windows program.
private extension LibraryStore {
    func engineBinding<Value>(_ keyPath: WritableKeyPath<EngineSettings, Value>) -> Binding<Value> {
        Binding(get: { self.engineSettings[keyPath: keyPath] }, set: { value in
            var settings = self.engineSettings
            settings[keyPath: keyPath] = value
            self.setEngineSettings(settings)
        })
    }
}

/// Settings › Windows Engine: the runtime MacHub ships (Wine, DXMT, DXVK), its versions and updates.
struct EngineSettingsSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var choosingArchive = false
    @State private var confirmingRemoval: String?

    var body: some View {
        Section {
            status
            if let update = store.runtimeUpdateAvailable {
                LabeledContent("Available") { Text(verbatim: update.version) }
                HStack {
                    if update.url != nil {
                        Button("Download Engine \(update.version)") { Task { await store.downloadRuntime() } }.disabled(isBusy)
                    }
                    Button("Install from File…") { choosingArchive = true }.disabled(isBusy)
                }
            }
            Button("Force Quit All Windows Programs", role: .destructive) {
                Task { await store.forceQuitAllWindowsPrograms() }
            }
            .help("Closes Steam, games and every other Windows program MacHub started, including ones that stopped responding.")
        } header: {
            Text("Windows Engine")
        } footer: {
            Text("MacHub runs Windows programs with its own Wine, built from the official open-source WineHQ code, plus DXMT and DXVK. Nothing is installed outside MacHub's folders, and Whisky isn't needed.")
        }
        .fileImporter(isPresented: $choosingArchive, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                Task {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    await store.installRuntime(from: url)
                }
            }
        }

        Section {
            ForEach(store.installedRuntimes.reversed(), id: \.version) { runtime in
                LabeledContent {
                    HStack {
                        if runtime.version == store.runtime?.version {
                            Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Use") { Task { await store.selectRuntime(runtime.version) } }
                            Button("Remove…", role: .destructive) { confirmingRemoval = runtime.version }
                        }
                    }
                } label: {
                    Text(verbatim: runtime.version)
                    Text(verbatim: runtime.info.components.first.map { "\($0.name) \($0.version)" } ?? "")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Installed Versions")
        } footer: {
            Text("Several versions can stay side by side: if a new one misbehaves, go back to the previous one in a click. Removed versions go to the Trash.")
        }
        .confirmationDialog("Move this engine version to the Trash?", isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let version = confirmingRemoval { Task { await store.removeRuntime(version) } }
            }
        }

        if let runtime = store.runtime {
            Section {
                ForEach(runtime.info.components, id: \.name) { component in
                    LabeledContent {
                        Text(verbatim: component.license)
                    } label: {
                        Text(verbatim: component.name)
                        Text(verbatim: component.version).foregroundStyle(.secondary)
                    }
                    .help(Text(verbatim: component.source))
                }
            } header: {
                Text("Components and Licenses")
            } footer: {
                Text("Open-source components, redistributed under their licenses. Their sources are published with each engine release. Apple's D3DMetal is never included.")
            }
        }
    }

    static let rosettaCommand = "softwareupdate --install-rosetta --agree-to-license"

    private var isBusy: Bool {
        if case .installing = store.engineState { true } else { false }
    }

    @ViewBuilder private var status: some View {
        switch store.engineState {
        case .checking:
            ProgressView()
        case .notInstalled:
            Label("Not installed", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
        case .installing(let received, let total):
            if received > 0, total > 0 {
                ProgressView(value: Double(received), total: Double(total)) {
                    Text("Downloading… \(received.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))")
                }
            } else {
                ProgressView { Text("Checking and installing…") }
            }
        case .ready(let version, let wine):
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            LabeledContent("Engine") { Text(verbatim: "\(version) · \(wine)") }
        case .needsRosetta:
            Label("Rosetta 2 is needed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Wine is built for Intel processors and runs through Rosetta 2, Apple's translator. Install it once by running this command in Terminal, then check again:")
                .foregroundStyle(.secondary)
            HStack {
                Text(verbatim: Self.rosettaCommand).font(.callout.monospaced()).textSelection(.enabled)
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.rosettaCommand, forType: .string)
                }
                .labelStyle(.iconOnly)
            }
            Button("Check Again") { Task { await store.refreshEngine() } }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Button("Check Again") { Task { await store.refreshEngine() } }
        }
    }
}

/// Settings › Graphics: which Direct3D layer titles use, overlays, Retina, and Apple's D3DMetal.
struct GraphicsSettingsSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var choosingToolkit = false
    @State private var toolkitError: String?
    @State private var toolkitRefresh = 0

    var body: some View {
        Section {
            Picker("Default for titles", selection: store.engineBinding(\.defaultGraphics)) {
                ForEach(GraphicsChoice.allCases.filter { $0 != .d3dmetal }, id: \.self) { Text($0.label).tag($0) }
            }
            Text(store.engineSettings.defaultGraphics.explanation).font(.callout).foregroundStyle(.secondary)
        } header: {
            Text("Direct3D")
        } footer: {
            Text("Automatic reads which DirectX version each game uses: DirectX 10/11 → DXMT, DirectX 9 and older → Wine's own renderer. Each game can override this on its page. MacHub puts the chosen DLLs next to the game and never replaces DLLs the game ships itself.")
        }

        Section {
            Toggle("Retina resolution", isOn: store.engineBinding(\.retinaMode))
            Toggle("Compile DXVK shaders in the background", isOn: store.engineBinding(\.dxvkAsync))
        } header: {
            Text("Display")
        } footer: {
            Text("Retina renders at the screen's full resolution: sharper, but up to four times more pixels for the GPU. Background shader compilation removes most DXVK stutter, at the cost of objects popping in for a moment.")
        }

        Section {
            Toggle("Metal performance overlay", isOn: store.engineBinding(\.metalHUD))
            Toggle("DXVK overlay", isOn: store.engineBinding(\.dxvkHUD))
        } header: {
            Text("Overlays")
        } footer: {
            Text("The Metal overlay shows frame rate and GPU time for every game (DXMT, DXVK and D3DMetal all draw through Metal). Useful to compare settings.")
        }

        Section {
            let gptk = GPTKStore.live
            let _ = toolkitRefresh
            if gptk.isInstalled {
                LabeledContent("D3DMetal") { Text(verbatim: gptk.version ?? "Imported") }
                Text("Imported. Routing DirectX 12 games to D3DMetal isn't enabled yet: MacHub will turn it on once it has been tested on real games. Until then they run on DXMT.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Remove", role: .destructive) { try? gptk.remove(); toolkitRefresh += 1 }
            } else {
                Text("DirectX 12 games need Apple's D3DMetal, part of the Game Porting Toolkit. Apple doesn't let MacHub include it: download it from Apple with your Apple Account (free), open the disk image, then point MacHub to it.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Link(destination: GPTKStore.downloadPage) { Label("Get it from Apple", systemImage: "arrow.up.right.square") }
                    Button("Import…") { choosingToolkit = true }
                }
            }
            if let toolkitError { Text(verbatim: toolkitError).foregroundStyle(Compatibility.issues.tint) }
        } header: {
            Text("DirectX 12 (D3DMetal)")
        }
        .fileImporter(isPresented: $choosingToolkit, allowedContentTypes: [.folder, .volume]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                toolkitError = store.importGPTK(from: url)
                toolkitRefresh += 1
            }
        }
    }
}

/// Settings › Performance: synchronization, CPU features, memory, logging.
struct PerformanceSettingsSection: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Section {
            Picker("Synchronization", selection: store.engineBinding(\.sync)) {
                Text("msync (fastest)").tag(EngineSettings.Sync.msync)
                Text("esync").tag(EngineSettings.Sync.esync)
                Text("Off (most compatible)").tag(EngineSettings.Sync.off)
            }
            if store.engineSettings.sync == .msync, store.runtime.map({ !$0.supportsMsync }) == true {
                Label("This engine version has no msync: esync is used instead.", systemImage: "info.circle").foregroundStyle(.secondary)
            }
        } header: {
            Text("Threads")
        } footer: {
            Text("Games wait on thousands of Windows events per second. msync answers them with macOS's own Mach semaphores instead of asking Wine's server each time. Switch to Off only if a game hangs.")
        }

        Section {
            Toggle("Expose AVX instructions", isOn: store.engineBinding(\.advertiseAVX))
            Toggle("4 GB memory for 32-bit games", isOn: store.engineBinding(\.largeAddressAware))
        } header: {
            Text("Processor and Memory")
        } footer: {
            Text("Rosetta translates AVX/AVX2 since macOS 15: some recent games refuse to start without them. 32-bit games are normally limited to 2 GB; modded games benefit from 4 GB. Both are off by default: with them on, Steam for Windows stopped connecting on this Mac. Turn them on only for a game that needs them.")
        }

        Section {
            Picker("Wine log", selection: store.engineBinding(\.logLevel)) {
                Text("Off").tag(EngineSettings.LogLevel.off)
                Text("Errors (recommended)").tag(EngineSettings.LogLevel.errors)
                Text("Detailed (slower)").tag(EngineSettings.LogLevel.verbose)
            }
        } header: {
            Text("Logging")
        } footer: {
            Text("Detailed logs help find why a game fails, but writing them costs frame rate. Logs stay on this Mac, in ~/Library/Logs/app.machub.MacHub.")
        }
    }
}

/// Settings › Keyboard & Mouse: how Mac keys map to Windows keys, fullscreen behaviour.
struct InputSettingsSection: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Section {
            Toggle("Option keys act as Alt", isOn: store.engineBinding(\.optionAsAlt))
            Toggle("Command keys act as Ctrl", isOn: store.engineBinding(\.commandAsControl))
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Games often bind Alt (Option on a Mac). With Command as Ctrl, ⌘C and ⌘V copy and paste in Windows programs, but ⌘Q and ⌘Tab reach the game instead of macOS.")
        }
        Section {
            Toggle("Capture displays in fullscreen", isOn: store.engineBinding(\.captureDisplaysForFullscreen))
        } header: {
            Text("Fullscreen")
        } footer: {
            Text("A fullscreen game takes over the display, like on Windows. Turn off to keep other displays and notifications visible.")
        }
    }
}

/// Settings › Windows Environments: each Wine prefix, with the tools to check, repair or remove it.
struct EnvironmentsSettingsSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var tests: [UUID: TestState] = [:]
    @State private var trashing: InstalledPrefix?

    enum TestState: Equatable {
        case running
        case passed
        case failed(String)
    }

    var body: some View {
        if store.prefixes.isEmpty {
            Section { Text("No Windows environment yet.").foregroundStyle(.secondary) }
        }
        ForEach(store.prefixes) { prefix in
            Section {
                PrefixDetails(prefix: prefix, test: tests[prefix.id], onTest: { Task { await test(prefix) } },
                              onTrash: { trashing = prefix })
            } header: {
                Text(verbatim: prefix.name)
            }
        }
        Section {
            Button(store.creatingPrefix ? "Setting Up…" : "Create Windows Environment") {
                Task { await store.createPrefix(name: "Applications", role: .apps) }
            }
            .disabled(store.runtime == nil || store.creatingPrefix || !isReady)
        } footer: {
            Text("Each environment is a separate Windows installation (a Wine prefix): settings, saves and installed programs stay inside it and never mix with another. Creating one takes about a minute.")
        }
        .confirmationDialog("Move this Windows environment to the Trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let prefix = trashing { Task { await store.trashPrefix(prefix) } }
            }
        } message: {
            Text("Everything inside it goes with it (installed programs, saves not synced to the cloud). You can still restore it from the Trash.")
        }
    }

    private var isReady: Bool {
        if case .ready = store.engineState { true } else { false }
    }

    /// Opens Notepad inside the environment and waits for its process: proof that Wine runs there.
    private func test(_ prefix: InstalledPrefix) async {
        guard let engine = store.engine(forBottle: prefix.name) else { return }
        tests[prefix.id] = .running
        let outcome = TestOutcome()
        Task.detached {
            do {
                _ = try await engine.run(#"C:\windows\system32\notepad.exe"#, bottle: prefix.name, arguments: [], timeout: 3600)
                await outcome.finish(nil)
            } catch {
                await outcome.finish(LibraryStore.describe(error))
            }
        }
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if !ProcessWatch.matches(in: await ProcessWatch.snapshot(), target: .executable("notepad.exe")).isEmpty {
                tests[prefix.id] = .passed
                return
            }
            if let ended = await outcome.result {
                tests[prefix.id] = .failed(ended ?? String(localized: "Notepad exited at once"))
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        tests[prefix.id] = .failed(String(localized: "Notepad didn't start within a minute"))
    }
}

/// Set once the test's Wine process has returned: nil message for a clean exit.
private actor TestOutcome {
    private(set) var result: String??
    func finish(_ message: String?) { result = .some(message) }
}

private struct PrefixDetails: View {
    @Environment(LibraryStore.self) private var store
    let prefix: InstalledPrefix
    let test: EnvironmentsSettingsSection.TestState?
    let onTest: () -> Void
    let onTrash: () -> Void

    static let windowsVersions: [(String, String)] = [
        ("win11", "Windows 11"), ("win10", "Windows 10"), ("win81", "Windows 8.1"), ("win7", "Windows 7"), ("winxp64", "Windows XP"),
    ]

    var body: some View {
        LabeledContent("Role") { Text(prefix.settings.role.label) }
        LabeledContent("Status") {
            Text(prefix.hasDriveC ? "Set up · engine \(prefix.settings.runtimeVersion)" : "Not set up")
        }
        if prefix.hasDriveC, let current = store.runtime?.version, current != prefix.settings.runtimeVersion {
            Label("Made with engine \(prefix.settings.runtimeVersion). Update it for engine \(current).", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
        }
        Picker("Windows version", selection: Binding(get: { prefix.settings.windowsVersion },
                                                     set: { new in Task { await store.setWindowsVersion(new, for: prefix) } })) {
            ForEach(Self.windowsVersions, id: \.0) { Text(verbatim: $0.1).tag($0.0) }
        }
        .disabled(!prefix.hasDriveC)
        WindowsComponentsRow(prefix: prefix)
        HStack {
            Button("Test with Notepad", action: onTest).disabled(test == .running || !prefix.hasDriveC)
            switch test {
            case .running: ProgressView().controlSize(.small)
            case .passed: Label("Notepad opened", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message): Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case nil: EmptyView()
            }
        }
        HStack {
            Menu("Windows Tools") {
                Button("Wine Configuration") { store.openWineTool("winecfg", in: prefix) }
                Button("Registry Editor") { store.openWineTool("regedit", in: prefix) }
                Button("Task Manager") { store.openWineTool("taskmgr", in: prefix) }
                Button("Command Prompt") { store.openWineTool("wineconsole", in: prefix) }
                Button("Game Controllers") { store.openWineTool("control", in: prefix) }
            }
            .fixedSize()
            Button("Update Windows Files") { Task { await store.repairPrefix(prefix) } }
                .help("wineboot -u: refreshes Windows's own files for the current engine. Your programs and saves stay.")
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([prefix.url.appending(path: "drive_c")]) }
            Spacer()
            Button("Move to Trash…", role: .destructive, action: onTrash)
        }
        .disabled(!prefix.hasDriveC)
    }
}

extension WinePrefix.Role {
    var label: LocalizedStringKey {
        switch self {
        case .steam: "Steam for Windows and its games"
        case .apps: "Windows software"
        case .custom: "Custom"
        }
    }
}

extension GraphicsChoice {
    var label: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic (recommended)"
        case .dxmt: "DXMT (Metal)"
        case .dxvk: "DXVK (Vulkan)"
        case .wined3d: "Wine (OpenGL)"
        case .d3dmetal: "D3DMetal (Apple)"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .automatic: "Picks per game from the DirectX version it uses."
        case .dxmt: "Direct3D 10/11 straight to Metal: the fastest path for DirectX 11 games on Apple silicon."
        case .dxvk: "Direct3D 10/11 through Vulkan and MoltenVK: try it when a game misbehaves on DXMT."
        case .wined3d: "Wine's own renderer over OpenGL: for DirectX 9 and older games."
        case .d3dmetal: "Apple's translator, required for DirectX 12. Needs the Game Porting Toolkit."
        }
    }
}

/// Settings › Diagnostics: where logs are, and a report to share when asking for help.
struct DiagnosticsSettingsSection: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Section {
            LabeledContent("Wine logs") {
                Button("Show in Finder", systemImage: "folder") {
                    let logs = EmbeddedWineEngine.logDirectory
                    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([logs])
                }
            }
            if let log = store.runtime.flatMap({ EmbeddedWineEngine(runtime: $0).latestLog() }) {
                LabeledContent("Latest") {
                    Button(log.lastPathComponent) { NSWorkspace.shared.open(log) }.buttonStyle(.link)
                }
            }
            LabeledContent("MacHub data") {
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([LocalData.directory]) }
            }
        } header: {
            Text("Files")
        } footer: {
            Text("Logs and settings stay on this Mac. MacHub sends nothing anywhere.")
        }
        Section {
            Button("Copy Report", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.report?.text ?? "", forType: .string)
            }
            .disabled(store.report == nil)
        } header: {
            Text("Report")
        } footer: {
            Text("A text summary of the Mac, the engine and Whisky (no account data) to paste in a bug report.")
        }
    }
}

/// Steam for Windows inside MacHub's engine: one button to set it up, then start or quit it.
struct SteamEngineSection: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage(LibraryStore.quitSteamAfterGameKey) private var quitSteamAfterGame = true

    var body: some View {
        Section {
            switch store.steamSetup {
            case .working(let step)?:
                ProgressView { Text(label(for: step)) }
            case .waitingForSignIn?:
                Label("Steam is running. Sign in in Steam's own window.", systemImage: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.green)
            case .failed(let message)?:
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .textSelection(.enabled)
                Button("Show Wine Logs", systemImage: "doc.text.magnifyingglass") {
                    let logs = EmbeddedWineEngine.logDirectory
                    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(logs)
                }
            case nil:
                if let prefix = store.steamPrefix {
                    LabeledContent("Steam for Windows") { Text(verbatim: "Installed · \(prefix.name)") }
                } else if let bottle = store.whiskySteamBottle {
                    LabeledContent("Steam for Windows") { Text("Found in the Whisky bottle “\(bottle.name ?? "")”") }
                    Text("MacHub uses this copy as it is: no download, and the bottle isn't changed.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Not installed").foregroundStyle(.secondary)
                }
            }
            HStack {
                if store.steamPrefix == nil, store.whiskySteamBottle != nil {
                    Button("Start Steam") { Task { await store.startSteam() } }
                        .disabled(isWorking || store.whiskyInstall == nil)
                } else if store.steamPrefix == nil {
                    Button("Install Steam for Windows") { Task { await store.setUpSteam() } }
                        .disabled(!isReady || isWorking)
                } else {
                    Button("Start Steam") { Task { await store.startSteam() } }
                        .disabled(!isReady || isWorking)
                    Button("Quit Steam") { Task { await store.stopSteam() } }
                        .disabled(isWorking)
                }
            }
            if store.steamPrefix != nil {
                Toggle("Quit Steam when the game closes", isOn: $quitSteamAfterGame)
                Text("When MacHub started Steam for a game, it quits Steam once the game closes so it stops using memory and battery. Steam syncs your cloud saves on the way out, and it stays open during downloads.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !store.steamDownloads.isEmpty {
                ForEach(store.steamDownloads.values.sorted { $0.name < $1.name }, id: \.appID) { app in
                    LabeledContent(app.name) {
                        if let fraction = store.downloadProgress(appID: app.appID) {
                            ProgressView(value: fraction).frame(width: 160)
                        } else {
                            Text("Waiting for Steam").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Steam for Windows")
        } footer: {
            Text("Windows games need Steam's own client for downloads, updates, cloud saves and DRM. MacHub installs Valve's official installer in a separate Windows environment and never sees your password: you sign in in Steam's window.")
        }
    }

    private var isReady: Bool {
        if case .ready = store.engineState { true } else { false }
    }

    private var isWorking: Bool {
        if case .working? = store.steamSetup { true } else { false }
    }

    private func label(for step: SteamSetup.Step) -> LocalizedStringKey {
        switch step {
        case .creatingPrefix: "Creating the Steam environment…"
        case .downloadingInstaller: "Downloading Steam's installer from Valve…"
        case .installing: "Installing Steam for Windows…"
        case .starting: "Starting Steam…"
        }
    }
}
