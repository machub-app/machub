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
    @State private var importSession: InstallerImport?
    @State private var choosingInstaller = false
    @State private var path = NavigationPath()
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("whiskyCmdPath") private var customPath = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                ForEach([SidebarItem.home, .discover, .library, .software], id: \.self) { item in
                    Label(item.label, systemImage: item.symbol).tag(item)
                }
                Section {
                    Label(SidebarItem.settings.label, systemImage: SidebarItem.settings.symbol).tag(SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    UpdateChip()
                    SetupChip { navigation.selection = .settings }
                    ControllerChip { navigation.selection = .settings }
                    SteamAccountChip { navigation.selection = .settings }
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
        .onChange(of: navigation.installRequest) { choosingInstaller = true }
        .toolbar(store.presentedLaunch == nil ? .automatic : .hidden, for: .windowToolbar)
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search games and software"))
        .searchFocused($searchFocused)
        .environment(store)
        .environment(discover)
        .environment(navigation)
        .environment(controllers)
        .onAppear { controllers.start() }
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
        #if DEBUG
        .onAppear(perform: openFromLaunchArgument)
        #endif
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

    private func openNextImport() {
        guard importSession == nil, !inbox.pending.isEmpty, store.report != nil else { return }
        let url = inbox.pending.removeFirst()
        importSession = store.makeImport(url)
    }

    #if DEBUG
    /// Debug-only: `--play <steam app id>` opens the installed title and runs the same launch path as its Play button.
    private func playFromLaunchArgument() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--play"), i + 1 < args.count, let appID = Int(args[i + 1]),
              let title = store.library.first(where: { $0.steamAppID == appID && $0.canLaunch })
        else { return }
        path.append(title)
        Task { await store.launch(title) }
    }

    /// Debug-only deep link for screenshots: `--open discover|library|software|settings|title:<steam id>|search:<text>`.
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
    #endif

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
        case .failed:
            return Step(title: "Windows engine problem", detail: "Open Settings for details.",
                        symbol: "exclamationmark.triangle.fill", tint: Compatibility.unsupported.tint, buttonLabel: "Try Again",
                        run: { await $0.refreshEngine() })
        case .ready:
            guard store.steamPrefix == nil else { return nil }
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

private struct SteamAccountChip: View {
    let action: () -> Void
    @Environment(LibraryStore.self) private var store
    @AppStorage("settings.category") private var category = SettingsCategory.general

    var body: some View {
        let steam = store.steam
        Button {
            category = .steamAccount
            action()
        } label: {
            HStack(spacing: 8) {
                SteamAvatar(account: steam.account, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    if let account = steam.account {
                        Group {
                            if let name = account.displayName { Text(verbatim: name) } else { Text("Steam account") }
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text("Steam connected").font(.caption2).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("Steam").font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        Text(steam.isBusy ? "Waiting for the browser…" : "Not connected").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.surface, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Steam account settings")
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
