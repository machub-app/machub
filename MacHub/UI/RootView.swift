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
                    ControllerChip { navigation.open(.controllers) }
                    SteamAccountChip { navigation.selection = .settings }
                    WhiskyStatusChip { navigation.selection = .settings }
                }
                .padding(12)
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

/// Real Whisky state at a glance, at the foot of the sidebar.
/// MacHub's Windows engine at a glance; opens Settings › Windows Engine.
private struct WhiskyStatusChip: View {
    let action: () -> Void
    @Environment(LibraryStore.self) private var store
    @AppStorage("settings.category") private var category = SettingsCategory.general

    var body: some View {
        Button {
            category = .engine
            action()
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline).font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.surface, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Open the Windows engine settings")
    }

    private var color: Color {
        switch store.engineState {
        case .ready: store.steamPrefix == nil ? Compatibility.issues.tint : Compatibility.great.tint
        case .checking, .installing: Theme.textSecondary
        case .notInstalled, .needsRosetta, .failed: Compatibility.unsupported.tint
        }
    }

    private var headline: LocalizedStringKey {
        switch store.engineState {
        case .ready(let version, _): "Windows engine \(version)"
        case .checking: "Checking the engine…"
        case .installing: "Installing the engine…"
        case .notInstalled: "Windows engine not installed"
        case .needsRosetta: "Rosetta 2 needed"
        case .failed: "Windows engine problem"
        }
    }

    private var detail: LocalizedStringKey {
        guard case .ready = store.engineState else { return "Open Settings for details" }
        let environments = store.prefixes.count
        return store.steamPrefix == nil
            ? "\(environments) environment(s) · Steam not set up"
            : "\(environments) environment(s) · \(store.installedTitles.count) game(s)"
    }
}

/// Connected controller at a glance; opens Settings > Controllers. Always shown so the page is easy to find.
private struct ControllerChip: View {
    let action: () -> Void
    @Environment(ControllerMonitor.self) private var monitor

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: monitor.controllers.first?.family.symbol ?? "gamecontroller")
                    .font(.system(size: 14))
                    .foregroundStyle(monitor.controllers.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    if let first = monitor.controllers.first {
                        Text(verbatim: first.displayName).font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text("Controller connected").font(.caption2).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("Controllers").font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        Text("None connected").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.surface, in: .rect(cornerRadius: 10))
            .animation(.snappy, value: monitor.controllers.first?.id)
        }
        .buttonStyle(.plain)
        .help("Connect and test controllers")
    }
}

/// Who is signed in to Steam, at the foot of the sidebar. Only a verified OpenID sign-in shows a name.
private struct SteamAccountChip: View {
    let action: () -> Void
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let steam = store.steam
        Button(action: action) {
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
