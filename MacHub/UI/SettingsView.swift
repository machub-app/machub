import SwiftUI

/// Settings, grouped by topic: a category column on the left, the category's options on the right.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, steamAccount, epic, sound, steamWindows, engine, graphics, performance, input, environments, storage, mods, controllers, whisky, diagnostics

    var id: Self { self }

    var label: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .steamAccount: "Steam Account"
        case .epic: "Epic Games"
        case .sound: "Sound"
        case .steamWindows: "Steam for Windows"
        case .engine: "Windows Engine"
        case .graphics: "Graphics"
        case .performance: "Performance"
        case .input: "Keyboard & Mouse"
        case .environments: "Windows Environments"
        case .storage: "Storage"
        case .mods: "Mods"
        case .controllers: "Controllers"
        case .whisky: "Whisky (Fallback)"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .steamAccount: "person.crop.circle"
        case .epic: "bag"
        case .sound: "speaker.wave.2"
        case .steamWindows: "arrow.down.app"
        case .engine: "cpu"
        case .graphics: "display"
        case .performance: "gauge.with.dots.needle.67percent"
        case .input: "keyboard"
        case .environments: "square.stack.3d.up"
        case .storage: "internaldrive"
        case .mods: "puzzlepiece.extension"
        case .controllers: "gamecontroller"
        case .whisky: "wineglass"
        case .diagnostics: "stethoscope"
        }
    }

    /// Groups in the category column.
    @MainActor static let groups: [(LocalizedStringKey, [SettingsCategory])] = [
        ("MacHub", [.general, .steamAccount, .epic, .mods, .controllers, .sound]),
        ("Windows Games", [.engine, .steamWindows, .graphics, .performance, .input, .environments, .storage]),
        ("Advanced", [.whisky, .diagnostics]),
    ]
}

struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("whiskyCmdPath") private var customPath = ""
    @AppStorage("settings.category") private var category = SettingsCategory.general

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { category }, set: { if let new = $0 { category = new } })) {
                ForEach(SettingsCategory.groups, id: \.1) { group in
                    Section(group.0) {
                        ForEach(group.1) { item in
                            Label(item.label, systemImage: item.symbol).tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 230)
            Divider()
            Form { detail }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .id(category)
        }
        .onAppear { store.spotlight = nil }
        .navigationTitle("Settings")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh(customPath: customPath) } }
                .disabled(store.isLoading)
            Button("Copy Report", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.report?.text ?? "", forType: .string)
            }
            .disabled(store.report == nil)
        }
    }

    @ViewBuilder private var detail: some View {
        switch category {
        case .general: GeneralSettingsSections()
        case .steamAccount: SteamSettingsSection()
        case .steamWindows: SteamEngineSection()
        case .engine: EngineSettingsSection()
        case .graphics: GraphicsSettingsSection()
        case .performance: PerformanceSettingsSection()
        case .input: InputSettingsSection()
        case .environments: EnvironmentsSettingsSection()
        case .storage: StorageSettingsSection()
        case .mods: ModsSettingsSection()
        case .epic: EpicSettingsSection()
        case .sound: SoundSettingsSection()
        case .controllers: ControllerSettingsSection()
        case .whisky: WhiskySettingsSections()
        case .diagnostics: DiagnosticsSettingsSection()
        }
    }
}

private struct GeneralSettingsSections: View {
    @AppStorage("showDemoTitles") private var showDemo = false
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system

    var body: some View {
        Section("Language") {
            Picker(selection: $language) {
                ForEach(AppLanguage.allCases) { $0.label.tag($0) }
            } label: {
                Text("Language")
            }
        }
        Section {
            Toggle("Show demo titles", isOn: $showDemo)
        } header: {
            Text("Library")
        } footer: {
            Text("Demo titles let you explore MacHub before your own games are installed. They are labelled and can't be launched.")
        }
        WindowsFilesSection()
        Section {
            Picker("When MacHub quits", selection: Binding(get: { WineShutdown.policy }, set: { WineShutdown.policy = $0 })) {
                Text("Ask").tag(WineShutdown.Policy.ask)
                Text("Quit Windows programs too").tag(WineShutdown.Policy.quit)
                Text("Leave them running").tag(WineShutdown.Policy.leave)
            }
        } header: {
            Text("Windows programs")
        } footer: {
            Text("Steam for Windows and games keep running if MacHub quits without them. Quitting them closes Steam properly first (cloud saves sync), then ends anything left.")
        }
        UpdatesSection()
        if !DiscordPresence.clientID.isEmpty {
            Section {
                Toggle("Show what I'm playing in Discord", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: DiscordPresence.enabledKey) as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: DiscordPresence.enabledKey) }))
            } header: {
                Text("Discord")
            } footer: {
                Text("While a game runs, your Discord friends see “Playing <game> · via MacHub” and for how long. It goes through the Discord app on this Mac; nothing is shown when Discord isn't open.")
            }
        }
    }
}

/// Settings › General › Updates: the running version, a manual check and the daily automatic one.
private struct UpdatesSection: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        Section {
            LabeledContent("Version") { Text(verbatim: AppUpdates.currentVersion) }
            Toggle("Check for updates automatically", isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 }))
            HStack {
                Button("Check for Updates") { Task { await updater.check() } }
                    .disabled(updater.state == .checking)
                if updater.state == .checking { ProgressView().controlSize(.small) }
                Spacer()
                status
            }
            if let release = updater.offered {
                HStack {
                    Button("Install MacHub \(release.version) and Relaunch") { Task { await updater.install() } }
                        .buttonStyle(.borderedProminent)
                    Link("What's New", destination: release.page)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("MacHub looks for new versions on its GitHub page (github.com/machub-app/machub) at most once a day. An update is checked against its published SHA-256, then MacHub replaces itself and relaunches.")
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .upToDate:
            Label("MacHub is up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let release):
            Text("MacHub \(release.version) is available").foregroundStyle(.secondary)
        case .installFailed(_, let message), .failed(let message):
            Text(verbatim: message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        default:
            if let last = updater.lastCheck {
                Text("Last checked \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
            }
        }
    }
}

/// The previous integration, kept as a fallback until MacHub's own engine has replaced it everywhere.
private struct WhiskySettingsSections: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("whiskyCmdPath") private var customPath = ""
    @State private var choosingFile = false

    var body: some View {
        Section {
            if let report = store.report {
                WhiskyStatusRow(status: report.status)
                if let present = report.librariesPresent {
                    LabeledContent("Wine runtime") { Text(present ? "Installed" : "Missing") }
                }
                ForEach(store.loadErrors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Compatibility.issues.tint)
                }
                DisclosureGroup("Diagnostics") {
                    if let install = report.status.install { InstallDetails(install: install) }
                    HStack {
                        TextField("Custom WhiskyCmd path", text: $customPath, prompt: Text("Automatic detection"))
                        Button("Choose…") { choosingFile = true }
                    }
                }
            } else {
                ProgressView()
            }
        } header: {
            Text("Whisky")
        } footer: {
            Text("Optional. MacHub no longer needs Whisky: its own engine runs Windows programs. Bottles you already have in Whisky keep working through it.")
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { customPath = url.path }
        }
        ForEach((store.report?.containers ?? []).filter(\.exists)) { container in
            Section {
                if container.bottles.isEmpty {
                    Text("No bottles yet.").foregroundStyle(.secondary)
                }
                ForEach(container.bottles) { BottleRow(bottle: $0) }
            } header: {
                Text(container.bundleID == WhiskyLocator.forkBundleID ? "Bottles · Whisky" : "Bottles · original Whisky (read only)")
            } footer: {
                if container.bundleID != WhiskyLocator.forkBundleID, !container.bottles.isEmpty {
                    Text("These bottles come from the original Whisky. “Not set up” means Wine never created the bottle's files, so it can't run anything. MacHub never changes them.")
                }
            }
        }
    }
}

private struct WhiskyStatusRow: View {
    let status: WhiskyStatus

    var body: some View {
        switch status {
        case .ready(let install):
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            LabeledContent("Version") { Text(verbatim: install.version ?? "—") }
        case .outdated(_, let missing):
            Label("This Whisky is too old for MacHub", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Missing commands: \(missing.joined(separator: ", ")). Install the maintained fork (frankea/Whisky).")
                .foregroundStyle(.secondary)
        case .notFound:
            Label("Whisky not found", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            Text("Install the maintained fork (frankea/Whisky) or set the WhiskyCmd path below.")
                .foregroundStyle(.secondary)
        case .invalidCustomPath(let url, let reason):
            Label("Custom path unusable", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            Text("\(url.path) — \(reason)").foregroundStyle(.secondary)
        }
    }
}

private struct InstallDetails: View {
    let install: WhiskyInstall

    var body: some View {
        if let app = install.appURL {
            LabeledContent("App", value: "\(app.lastPathComponent) \(install.version ?? "")")
            LabeledContent("Bundle ID", value: install.bundleIdentifier ?? "—")
        }
        LabeledContent("WhiskyCmd", value: install.cmdURL.path)
        LabeledContent("Commands", value: install.subcommands.sorted().joined(separator: " "))
    }
}

private struct BottleRow: View {
    let bottle: BottleInfo

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(bottle.isRegistered ? "Registered" : "Not registered")
                Text(verbatim: "·")
                Text(bottle.hasDriveC ? "Set up" : "Not set up")
                    .foregroundStyle(bottle.hasDriveC ? Color.secondary : Color.orange)
            }
        } label: {
            Text(verbatim: bottle.name ?? "—")
            // Same-named bottles stay distinguishable without hovering: short folder ID.
            Text(verbatim: "#" + bottle.url.lastPathComponent.suffix(6)).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .help(Text(verbatim: bottle.url.path))
    }
}

/// Steam: verified OpenID account and the optional Web API key (Keychain only).
struct SteamSettingsSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var keyDraft = ""
    @State private var keyRejected = false

    var body: some View {
        let steam = store.steam
        Section {
            if let account = steam.account {
                HStack(spacing: 12) {
                    SteamAvatar(account: account, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        if let name = account.displayName {
                            Text(verbatim: name).font(.headline)
                        } else {
                            Text("Community profile not set up").font(.headline)
                        }
                        Text(verbatim: "SteamID64 \(account.steamID64)").font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Verified by Steam on \(account.verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link(destination: URL(string: "https://steamcommunity.com/profiles/\(account.steamID64)")!) {
                        Label("Profile", systemImage: "arrow.up.right.square")
                    }
                }
                LabeledContent("Profile visibility") { Text(account.visibility.label) }
                if account.visibility == .notSetUp {
                    Text("Your sign-in is valid, but this account has no Steam Community profile yet, so Steam publishes no name or avatar. Optional: set one up on Steam.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://steamcommunity.com/my/edit/info")!) {
                        Label("Set up my Steam profile", systemImage: "arrow.up.right.square")
                    }
                }
                HStack {
                    Button("Sign in again") { Task { await steam.signIn() } }.disabled(steam.isBusy)
                    Button("Disconnect Steam", role: .destructive) { steam.signOut() }
                }
            } else {
                Text("Not connected. Sign in on Steam's own website: MacHub never sees your password, only your public SteamID, which it verifies with Steam.")
                    .foregroundStyle(.secondary)
                HStack {
                    if steam.isBusy {
                        ProgressView().controlSize(.small)
                        Text(steam.state == .verifying ? "Checking with Steam…" : "Waiting for the browser…")
                        Button("Cancel") { steam.cancelSignIn() }
                    } else {
                        Button("Sign in with Steam…") { Task { await steam.signIn() } }
                    }
                }
            }
            if case .failed(let problem) = steam.state {
                Label { Text(problem.message) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .foregroundStyle(Compatibility.issues.tint)
            }
        } header: {
            Text("Steam account")
        }

        Section {
            if steam.hasAPIKey {
                LabeledContent("Web API key") { Text("Saved in the Keychain") }
                LabeledContent("Library") { Text(ownedLabel) }
                Button("Remove key", role: .destructive) { steam.removeAPIKey(); keyDraft = "" }
            } else {
                SecureField("Web API key", text: $keyDraft, prompt: Text(verbatim: "0123456789ABCDEF…"))
                    .onSubmit(save)
                HStack {
                    Button("Save in Keychain", action: save).disabled(keyDraft.isEmpty)
                    Link(destination: URL(string: "https://steamcommunity.com/dev/apikey")!) {
                        Label("Get a key on Steam", systemImage: "arrow.up.right.square")
                    }
                }
                if keyRejected {
                    Text("That doesn't look like a Steam key (32 hexadecimal characters).").foregroundStyle(Compatibility.issues.tint)
                }
            }
        } header: {
            Text("Owned games (optional)")
        } footer: {
            Text("Without a key, MacHub reads your library from Steam for Windows on this Mac once you are signed in there (games shared through Steam Families included). A personal key from steamcommunity.com/dev/apikey (for the domain, “localhost” is fine) adds playtime and the games Steam for Windows hasn't shown yet. MacHub keeps it in the macOS Keychain only and never writes it to files or logs.")
        }
    }

    private var ownedLabel: LocalizedStringKey {
        switch store.ownedState {
        case .loaded: "\(store.ownedTitles.count) games"
        case .loading: "Loading…"
        case .privateProfile: "Game details are private"
        case .invalidKey: "Key refused by Steam"
        case .signedOut: "Connect Steam first"
        case .needsKey: "No key"
        case .fromSteamClient: "\(store.ownedTitles.count) games, from Steam for Windows"
        case .failed: "Couldn't load"
        }
    }

    private func save() {
        keyRejected = !store.steam.saveAPIKey(keyDraft)
        if !keyRejected { keyDraft = "" }
    }
}

extension SteamAccount.Visibility {
    var label: LocalizedStringKey {
        switch self {
        case .public: "Public"
        case .friendsOnly: "Friends only"
        case .private: "Private"
        case .unknown: "Unknown"
        case .notSetUp: "Not set up"
        }
    }
}

/// Which app opens .exe and .msi files. MacHub only changes it when the user clicks, and can give it back.
private struct WindowsFilesSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var handler: URL?
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent("Open .exe and .msi files with") {
                if let handler {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: handler.path)).resizable().frame(width: 16, height: 16)
                        Text(verbatim: FileManager.default.displayName(atPath: handler.path))
                    }
                } else {
                    Text("No app")
                }
            }
            HStack {
                if isMacHub {
                    if let whisky = store.whiskyInstall?.appURL {
                        Button("Give them back to Whisky") { set(whisky) }
                    }
                } else {
                    Button("Open them with MacHub") { set(Bundle.main.bundleURL) }
                }
            }
            if let error { Text(verbatim: error).foregroundStyle(Compatibility.issues.tint) }
        } header: {
            Text("Windows files")
        } footer: {
            Text("Without changing this, Finder's Open With menu still offers MacHub, and you can drag files onto its window. MacHub never runs a file before you confirm.")
        }
        .onAppear(perform: reload)
    }

    private var isMacHub: Bool {
        handler.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
    }

    private func reload() {
        handler = WindowsFile.contentTypes.first.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    private func set(_ app: URL) {
        Task {
            do {
                for type in WindowsFile.contentTypes { try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            reload()
        }
    }
}
