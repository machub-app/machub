import SwiftUI

enum SidebarItem: Hashable, CaseIterable {
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
    var selection: SidebarItem? = .home
    var searchFocusRequest = 0
}

struct RootView: View {
    @Bindable var navigation: AppNavigation
    @State private var store = LibraryStore()
    @State private var discover = DiscoverModel()
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
            }
            .background { AmbientBackdrop(title: store.spotlight) }
        }
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search games and software"))
        .searchFocused($searchFocused)
        .environment(store)
        .environment(discover)
        .environment(navigation)
        .task(id: customPath) {
            await store.refresh(customPath: customPath)
            #if DEBUG
            playFromLaunchArgument()
            #endif
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
        }
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
private struct WhiskyStatusChip: View {
    let action: () -> Void
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Button(action: action) {
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
        .help("Open Whisky settings")
    }

    private var color: Color {
        switch store.report?.status {
        case .ready: store.registeredBottles.isEmpty ? Compatibility.issues.tint : Compatibility.great.tint
        case .outdated, .notFound, .invalidCustomPath: Compatibility.unsupported.tint
        case nil: Theme.textSecondary
        }
    }

    private var headline: LocalizedStringKey {
        switch store.report?.status {
        case .ready(let install): "Whisky \(install.version ?? "")"
        case .outdated: "Whisky too old"
        case .notFound: "Whisky not found"
        case .invalidCustomPath: "Whisky path invalid"
        case nil: "Checking Whisky…"
        }
    }

    private var detail: LocalizedStringKey {
        guard case .ready = store.report?.status else { return "Open Settings for details" }
        let bottles = store.registeredBottles.count
        return bottles == 0 ? "No bottles yet" : "\(bottles) bottle(s) · \(store.installedTitles.count) game(s)"
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
