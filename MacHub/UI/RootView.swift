import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable {
    case home, discover, library, software, settings

    var label: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .discover: "Discover"
        case .library: "Library"
        case .software: "Software"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .discover: "sparkles.rectangle.stack"
        case .library: "square.grid.2x2"
        case .software: "macwindow"
        case .settings: "gearshape"
        }
    }
}

/// Sidebar selection and search focus, owned by the app so menu commands (⌘1–4, ⌘F, ⌘,) can drive them.
@MainActor @Observable
final class AppNavigation {
    /// `-startPage settings` (a launch argument, never saved) opens a page directly: used for screenshots and tests.
    var selection: SidebarItem? = UserDefaults.standard.string(forKey: "startPage").flatMap(SidebarItem.init(rawValue:)) ?? .home
    var searchFocusRequest = 0
    /// A Settings sub-page to open (the sidebar's controller chip, the Go menu).
    var settingsPageRequest: SettingsPage?
    /// ⌘O and the Software page's button: choose a Windows file to install or add.
    var installRequest = 0

    func open(_ page: SettingsPage) { settingsPageRequest = page }
}

struct RootView: View {
    @Bindable var navigation: AppNavigation
    @State private var store = LibraryStore()
    @State private var discover = DiscoverModel()
    @State private var controllers = ControllerMonitor()
    @State private var updater = AppUpdater.shared
    @State private var inbox = ImportInbox.shared
    @State private var nexusInbox = NexusLinkInbox.shared
    @State private var linkInbox = MacHubLinkInbox.shared
    @State private var importSession: InstallerImport?
    @State private var choosingInstaller = false
    @State private var path = NavigationPath()
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("whiskyCmdPath") private var customPath = ""

    // The window is built in stages: one long modifier chain is too much for the type checker.
    var body: some View {
        chrome
        .onAppear {
            controllers.start()
            // Volumes the user set stay applied from launch; otherwise nothing touches audio until Settings › Sound.
            if AppVolumeMixer.shared.hasSavedSettings { AppVolumeMixer.shared.start() }
        }
        .task {
            // `-installUpdateNow YES` (a launch argument, never saved): checks and installs at once. Used to test updates.
            if UserDefaults.standard.bool(forKey: "installUpdateNow") {
                await updater.check()
                await updater.install()
            } else {
                await updater.checkIfDue()
            }
        }
        .task(id: customPath) {
            await store.refresh(customPath: customPath)
            #if DEBUG
            playFromLaunchArgument()
            if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count,
               CommandLine.arguments[i + 1].hasPrefix("mods:") {
                let key = CommandLine.arguments[i + 1].dropFirst(5)
                if let title = store.library.first(where: { key == "minecraft" ? $0.id == ModSupport.minecraftTitleID : $0.steamAppID.map(String.init) == String(key) }) {
                    path.append(title)
                    path.append(ModsRoute(title: title))
                }
            }
            if let i = CommandLine.arguments.firstIndex(of: "--import"), i + 1 < CommandLine.arguments.count {
                inbox.receive([URL(filePath: CommandLine.arguments[i + 1])])
            }
            #endif
            openNextImport()
        }
        .onChange(of: store.steam.account) { Task { await store.refreshOwned() } }
        .onChange(of: store.steam.hasAPIKey) { Task { await store.refreshOwned() } }
        .onChange(of: navigation.searchFocusRequest) { searchFocused = true }
        .onAppear(perform: openFromLaunchArgument)
        .sheet(item: Binding(get: { store.pendingReport }, set: { store.pendingReport = $0 })) { ReportSheet(report: $0) }
        .onChange(of: navigation.selection) {
            path = NavigationPath()
            query = ""
            if let page = navigation.settingsPageRequest, navigation.selection == .settings {
                path.append(page)
                navigation.settingsPageRequest = nil
            }
        }
        .onChange(of: navigation.settingsPageRequest) {
            guard let page = navigation.settingsPageRequest else { return }
            if navigation.selection == .settings {
                query = ""
                path = NavigationPath([page])
                navigation.settingsPageRequest = nil
            } else {
                navigation.selection = .settings
            }
        }
    }

    /// Sidebar and page stack.
    private var window: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                ForEach([SidebarItem.home, .discover, .library, .software], id: \.self) { item in
                    Label(item.label, systemImage: item.symbol).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    UpdateChip()
                    SetupChip { navigation.selection = .settings }
                    ControllerChip { navigation.selection = .settings }
                    ProfileBar(isInSettings: navigation.selection == .settings) { navigation.selection = .settings }
                }
                .padding(12)
                .animation(.snappy, value: controllers.controllers.count)
                .animation(.snappy, value: store.engineState)
                .animation(.snappy, value: store.steamPrefix?.url)
                .animation(.snappy, value: updater.state)
            }
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        page
                    } else {
                        GlobalSearchView(query: query) {
                            discover.term = query
                            query = ""
                            navigation.selection = .discover
                            Task { await discover.reload() }
                        }
                    }
                }
                .navigationDestination(for: Title.self) { TitleDetailView(title: $0) }
                .navigationDestination(for: ModsRoute.self) { ModsView(title: $0.title) }
                .navigationDestination(for: SettingsPage.self) { page in
                    switch page {
                    case .controllers: ControllersView()
                    }
                }
            }
            .background { AmbientBackdrop(title: store.spotlight) }
        }
    }

    /// Imports, Nexus and MacHub links, and the launch screen over the window.
    private var routedWindow: some View {
        window
        .overlay { LaunchOverlay() }
        .dropDestination(for: URL.self) { urls, _ in
            let windows = urls.filter(WindowsFile.isCandidate)
            inbox.receive(windows)
            return !windows.isEmpty
        }
        .sheet(item: $importSession, onDismiss: {
            Task { await store.refreshWhisky(customPath: customPath) }
            openNextImport()
        }) { session in
            InstallerImportView(session: session)
        }
        .fileImporter(isPresented: $choosingInstaller, allowedContentTypes: WindowsFile.contentTypes) { result in
            if case .success(let url) = result { inbox.receive([url]) }
        }
        .onChange(of: inbox.pending) { openNextImport() }
        .onChange(of: nexusInbox.pending) {
            let links = nexusInbox.pending
            nexusInbox.pending = []
            for link in links { Task { await store.handle(link) } }
        }
        .onChange(of: linkInbox.pending) { openNextLink() }
        // A shortcut can open MacHub cold: its link waits until the installed games are known.
        .onChange(of: store.report == nil) { openNextLink() }
        .onChange(of: navigation.installRequest) { choosingInstaller = true }
    }

    /// Toolbar, search and the shared models every page reads.
    private var chrome: some View {
        routedWindow
        .toolbar(store.presentedLaunch == nil ? .automatic : .hidden, for: .windowToolbar)
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search games and software"))
        .searchFocused($searchFocused)
        .environment(store)
        .environment(discover)
        .environment(navigation)
        .environment(controllers)
    }

    private func openNextImport() {
        guard importSession == nil, !inbox.pending.isEmpty, store.report != nil else { return }
        let url = inbox.pending.removeFirst()
        importSession = store.makeImport(url)
    }

    private func openNextLink() {
        guard store.report != nil, !linkInbox.pending.isEmpty else { return }
        let links = linkInbox.pending
        linkInbox.pending = []
        for case .play(let appID) in links { play(appID: appID) }
    }

    /// Opens the game's page and, when it is installed and launchable, runs the same launch path as its Play button.
    private func play(appID: Int) {
        query = ""
        if let title = store.library.first(where: { $0.steamAppID == appID && $0.canLaunch }) {
            path = NavigationPath([title])
            Task { await store.launch(title) }
        } else {
            let title = store.library.first { $0.steamAppID == appID }
                ?? Title(id: Title.steamID(appID), name: "", kind: .game, steamAppID: appID)
            path = NavigationPath([title])
        }
    }

    #if DEBUG
    /// Debug-only: `--play <steam app id>` behaves like a game shortcut's `machub://play/<id>` link.
    private func playFromLaunchArgument() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--play"), i + 1 < args.count, let appID = Int(args[i + 1]) else { return }
        play(appID: appID)
    }

    #endif

    /// Deep link for screenshots and checks, also in release builds (it only navigates):
    /// `--open discover|library|software|settings|title:<steam id>|search:<text>`.
    private func openFromLaunchArgument() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--open"), i + 1 < args.count else { return }
        let target = args[i + 1]
        switch target {
        case "discover": navigation.selection = .discover
        case "library": navigation.selection = .library
        case "software": navigation.selection = .software
        case "settings": navigation.selection = .settings
        case "controllers": navigation.open(.controllers)
        default:
            if target.hasPrefix("title:"), let id = Int(target.dropFirst(6)) {
                path.append(Title(id: Title.steamID(id), name: "", kind: .game, steamAppID: id))
            } else if target.hasPrefix("search:") {
                query = String(target.dropFirst(7))
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch navigation.selection ?? .home {
        case .home: HomeView()
        case .discover: DiscoverView()
        case .library: LibraryView()
        case .software: SoftwareView()
        case .settings: SettingsView()
        }
    }
}

/// The signature move: the spotlighted title's artwork bleeds, blurred, into the whole window ground.
struct AmbientBackdrop: View {
    let title: Title?

    var body: some View {
        ZStack {
            Theme.ground
            if let title, title.steamAppID != nil {
                ArtworkImage(title: title, artwork: .hero)
                    .blur(radius: 80, opaque: true)
                    .saturation(1.25)
                    .brightness(-0.15)
                    .opacity(0.22)
                    .id(title.id)
                    .transition(.opacity)
            }
            LinearGradient(colors: [Theme.ground.opacity(0.7), .clear, Theme.ground.opacity(0.85), Theme.ground],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.8), value: title?.id)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A newer MacHub on GitHub: install it in place and relaunch, or read what's new. Shown only while one is offered.
private struct UpdateChip: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        if let release = updater.offered {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(Theme.textPrimary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MacHub \(release.version) is available").font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        Text(detail).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(4)
                    }
                    Spacer(minLength: 0)
                }
                switch updater.state {
                case .downloading(_, let fraction):
                    if let fraction { ProgressView(value: fraction).controlSize(.small) } else { ProgressView().controlSize(.small) }
                case .installing:
                    ProgressView().controlSize(.small)
                default:
                    HStack(spacing: 6) {
                        Button("Install and Relaunch") { Task { await updater.install() } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Link("What's New", destination: release.page).font(.caption)
                    }
                }
            }
            .padding(10)
            .background(Theme.surface, in: .rect(cornerRadius: 10))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var detail: String {
        switch updater.state {
        case .downloading: String(localized: "Downloading…")
        case .installing: String(localized: "Restarting MacHub…")
        case .installFailed(_, let message): message
        default: String(localized: "You have \(AppUpdates.currentVersion).")
        }
    }
}

/// What still needs doing before a Windows game can run, at the foot of the sidebar: install the engine, then
/// Steam for Windows, each with its own button and progress. Hidden once both are ready, so the sidebar stays quiet.
private struct SetupChip: View {
    let action: () -> Void
    @Environment(LibraryStore.self) private var store
    @AppStorage("settings.category") private var category = SettingsCategory.general

    var body: some View {
        if let step {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    category = step.category
                    action()
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: step.symbol).font(.system(size: 14)).foregroundStyle(step.tint).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                            Text(step.detail).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(3)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Open the Windows engine settings")
                if let progress = step.progress {
                    ProgressView(value: progress).controlSize(.small)
                } else if step.isWorking {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
                } else if let label = step.buttonLabel {
                    Button(label) { Task { await step.run(store) } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .padding(10)
            .background(Theme.surface, in: .rect(cornerRadius: 10))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private struct Step {
        var title: LocalizedStringKey
        var detail: LocalizedStringKey
        var symbol = "cpu"
        var tint = Theme.textSecondary
        var category = SettingsCategory.engine
        var buttonLabel: LocalizedStringKey?
        var progress: Double?
        var isWorking = false
        var run: @MainActor (LibraryStore) async -> Void = { _ in }
    }

    private var step: Step? {
        switch store.engineState {
        case .checking:
            return nil
        case .notInstalled:
            return Step(title: "Windows engine needed", detail: "Installs once, about 240 MB. Needed to play Windows games.",
                        symbol: "arrow.down.circle", tint: Theme.textPrimary, buttonLabel: "Install",
                        run: { await $0.downloadRuntime() })
        case .installing(let received, let total):
            return Step(title: "Installing the Windows engine…",
                        detail: "\(received.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))",
                        symbol: "arrow.down.circle", progress: total > 0 ? Double(received) / Double(total) : nil, isWorking: true)
        case .needsRosetta:
            return Step(title: "Rosetta 2 needed", detail: "Open Settings to see the one command to run.",
                        symbol: "exclamationmark.triangle.fill", tint: Compatibility.unsupported.tint)
        case .failed where store.runtimeUpdateAvailable != nil, .ready where store.runtimeUpdateAvailable != nil:
            // A newer engine ships with this MacHub (1.0.6 fixed the crash on macOS 26): offer it before anything else.
            return Step(title: "Windows engine update", detail: "Engine \(store.runtimeUpdateAvailable?.version ?? "") fixes problems of the one installed. About 240 MB.",
                        symbol: "arrow.down.circle", tint: Theme.textPrimary, buttonLabel: "Download",
                        run: { await $0.downloadRuntime() })
        case .failed:
            return Step(title: "Windows engine problem", detail: "Open Settings for details.",
                        symbol: "exclamationmark.triangle.fill", tint: Compatibility.unsupported.tint, buttonLabel: "Try Again",
                        run: { await $0.refreshEngine() })
        case .ready:
            // Steam already installed (MacHub's environment or a Whisky bottle): nothing to set up.
            guard !store.hasSteamForWindows else { return nil }
            switch store.steamSetup {
            case .working?:
                return Step(title: "Setting up Steam for Windows…", detail: "This takes a minute or two the first time.",
                            symbol: "gearshape.2", category: .steamWindows, isWorking: true)
            case .failed?:
                return Step(title: "Steam for Windows couldn't be set up", detail: "Open Settings for the reason and the logs.",
                            symbol: "exclamationmark.triangle.fill", tint: Compatibility.unsupported.tint,
                            category: .steamWindows, buttonLabel: "Try Again", run: { await $0.setUpSteam() })
            case .waitingForSignIn?, nil:
                return Step(title: "Steam for Windows", detail: "Install it once to download and play your Windows games.",
                            symbol: "arrow.down.circle", tint: Theme.textPrimary, category: .steamWindows,
                            buttonLabel: "Install", run: { await $0.setUpSteam() })
            }
        }
    }
}

/// The connected controller, shown only while one is connected; opens Settings › Controllers.
private struct ControllerChip: View {
    let action: () -> Void
    @Environment(ControllerMonitor.self) private var monitor
    @AppStorage("settings.category") private var category = SettingsCategory.general

    var body: some View {
        if let first = monitor.controllers.first {
            Button {
                category = .controllers
                action()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: first.family.symbol)
                        .font(.system(size: 14)).foregroundStyle(Theme.textPrimary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: first.displayName).font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(monitor.controllers.count > 1 ? "\(monitor.controllers.count) controllers connected" : "Controller connected")
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Theme.surface, in: .rect(cornerRadius: 10))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Controller settings")
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

/// The foot of the sidebar: the Steam account (avatar, name and a dot for the connection) and the Settings gear.
/// The account opens Settings › Steam Account; the gear opens Settings where the user left it.
private struct ProfileBar: View {
    let isInSettings: Bool
    let openSettings: () -> Void
    @Environment(LibraryStore.self) private var store
    @AppStorage("settings.category") private var category = SettingsCategory.general

    var body: some View {
        let steam = store.steam
        HStack(spacing: 6) {
            Button {
                category = .steamAccount
                openSettings()
            } label: {
                HStack(spacing: 8) {
                    SteamAvatar(account: steam.account, size: 26)
                        .overlay(alignment: .bottomTrailing) {
                            Circle().fill(dotColor).frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                                .offset(x: 2, y: 2)
                        }
                    Group {
                        if let name = steam.account?.displayName { Text(verbatim: name) } else if steam.account != nil { Text("Steam account") } else { Text("Connect Steam") }
                    }
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(helpText)

            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(isInSettings ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(isInSettings ? Theme.surfaceRaised : .clear, in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel(Text("Settings"))
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
        .background(Theme.surface, in: .rect(cornerRadius: 10))
    }

    private var dotColor: Color {
        if store.steam.isBusy { return Compatibility.playable.tint }
        return store.steam.account != nil ? Compatibility.great.tint : Theme.textSecondary
    }

    private var helpText: Text {
        if store.steam.isBusy { return Text("Waiting for the browser…") }
        return store.steam.account != nil ? Text("Steam connected · Steam account settings") : Text("Not connected · Connect Steam")
    }
}

struct SteamAvatar: View {
    let account: SteamAccount?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let url = account?.avatarURL {
                AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: .fill) } placeholder: { Theme.surfaceRaised }
            } else {
                Image(systemName: account == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill")
                    .resizable().aspectRatio(contentMode: .fit).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }
}
