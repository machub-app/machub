import SwiftUI

enum SidebarItem: Hashable, CaseIterable {
    case home, library, search, settings

    var label: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .library: "square.grid.2x2"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

/// Sidebar selection, owned by the app so menu commands (⌘1–3, ⌘F, ⌘,) can drive it.
@MainActor @Observable
final class AppNavigation {
    var selection: SidebarItem? = .home
}

struct RootView: View {
    @Bindable var navigation: AppNavigation
    @State private var store = LibraryStore()
    @State private var path = NavigationPath()
    @AppStorage("whiskyCmdPath") private var customPath = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                ForEach([SidebarItem.home, .library, .search], id: \.self) { item in
                    Label(item.label, systemImage: item.symbol).tag(item)
                }
                Section {
                    Label(SidebarItem.settings.label, systemImage: SidebarItem.settings.symbol).tag(SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                WhiskyStatusChip { navigation.selection = .settings }
                    .padding(12)
            }
        } detail: {
            NavigationStack(path: $path) {
                page
                    .navigationDestination(for: Title.self) { TitleDetailView(title: $0) }
            }
            .background { AmbientBackdrop(title: store.spotlight) }
        }
        .environment(store)
        .task(id: customPath) { await store.refresh(customPath: customPath) }
        #if DEBUG
        .onAppear(perform: openFromLaunchArgument)
        #endif
        .onChange(of: navigation.selection) { path = NavigationPath() }
    }

    #if DEBUG
    /// Debug-only deep link for screenshots: `--open library|search|settings|title:<id>`.
    private func openFromLaunchArgument() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--open"), i + 1 < args.count else { return }
        let target = args[i + 1]
        switch target {
        case "library": navigation.selection = .library
        case "search": navigation.selection = .search
        case "settings": navigation.selection = .settings
        default:
            if target.hasPrefix("title:"), let title = DemoLibrary.titles.first(where: { $0.id == String(target.dropFirst(6)) }) {
                path.append(title)
            }
        }
    }
    #endif

    @ViewBuilder
    private var page: some View {
        switch navigation.selection ?? .home {
        case .home: HomeView()
        case .library: LibraryView()
        case .search: SearchView()
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
        return bottles == 0 ? "No bottles yet" : "\(bottles) bottle(s) · \(store.realTitles.count) game(s)"
    }
}
