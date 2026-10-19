import SwiftUI
import UniformTypeIdentifiers

// MARK: - Discover (Steam store)

struct DiscoverView: View {
    @Environment(DiscoverModel.self) private var model
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Discover", subtitle: "The Steam store, searched on demand. Being on Steam doesn't mean a game runs on Mac.")
                HStack(spacing: 12) {
                    TextField("Search the Steam store", text: $model.term)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .onSubmit { Task { await model.reload() } }
                    Picker("Genre", selection: $model.genre) {
                        Text("All genres").tag(SteamStore.Genre?.none)
                        Divider()
                        ForEach(SteamStore.Genre.allCases, id: \.self) { Text($0.label).tag(SteamStore.Genre?.some($0)) }
                    }
                    .fixedSize()
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(SteamStore.Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    Spacer()
                }
                let titles = model.items.map { store.enriched(Title(store: $0)) }
                if !titles.isEmpty {
                    TitleGrid(titles: titles) { title in
                        if title.id == titles.last?.id { Task { await model.loadNext() } }
                    }
                }
                footer
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 28)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task { if model.state == .idle { await model.reload() } }
        .onChange(of: model.sort) { Task { await model.reload() } }
        .onChange(of: model.genre) { Task { await model.reload() } }
        .task(id: model.term) {
            // Reactive search: wait for typing to settle before asking Steam.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, model.state != .idle else { return }
            await model.reload()
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch model.state {
        case .loading:
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 24)
        case .empty:
            ContentUnavailableView.search(text: model.term)
        case .rateLimited:
            NoticeCard(symbol: "hourglass", title: "Steam store", message: "Steam is limiting requests right now. Try again in a few minutes.")
                .padding(.horizontal, -Theme.gutter)
        case .offline:
            NoticeCard(symbol: "wifi.slash", title: "Steam store", message: "Steam can't be reached. Check your connection.") {
                Button("Retry") { Task { await model.loadNext() } }.buttonStyle(SecondaryActionStyle())
            }
            .padding(.horizontal, -Theme.gutter)
        case .failed(let message):
            NoticeCard(symbol: "exclamationmark.triangle", title: "Steam store", message: "\(message)") {
                Button("Retry") { Task { await model.loadNext() } }.buttonStyle(SecondaryActionStyle())
            }
            .padding(.horizontal, -Theme.gutter)
        case .loaded where model.reachedEnd:
            Text("End of results").font(.callout).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity)
        default:
            EmptyView()
        }
    }
}

extension SteamStore.Sort {
    var label: LocalizedStringKey {
        switch self {
        case .relevance: "Relevance"
        case .released: "Release date"
        case .reviews: "User reviews"
        case .name: "Name"
        case .price: "Lowest price"
        }
    }
}

extension SteamStore.Genre {
    var label: LocalizedStringKey {
        switch self {
        case .action: "Action"
        case .adventure: "Adventure"
        case .rpg: "RPG"
        case .strategy: "Strategy"
        case .simulation: "Simulation"
        case .racing: "Racing"
        case .sports: "Sports"
        case .indie: "Indie"
        case .casual: "Casual"
        }
    }
}

// MARK: - My library

struct LibraryView: View {
    enum Filter: Hashable { case all, installed, owned, recent }

    @Environment(LibraryStore.self) private var store
    @AppStorage("showDemoTitles") private var showDemo = false
    @State private var filter = Filter.all

    var body: some View {
        let titles = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Library", subtitle: "Games you own on Steam and games installed on this Mac.")
                Picker("Show", selection: $filter) {
                    Text("All").tag(Filter.all)
                    Text("Installed").tag(Filter.installed)
                    Text("Owned").tag(Filter.owned)
                    Text("Recent").tag(Filter.recent)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if store.steam.account == nil {
                    SteamConnectCard().padding(.horizontal, -Theme.gutter)
                } else {
                    OwnedStateNotice().padding(.horizontal, -Theme.gutter)
                }
                if titles.isEmpty {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: "square.grid.2x2")
                    } description: {
                        Text(emptyMessage)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                } else {
                    TitleGrid(titles: titles)
                }
                if store.steam.account != nil, store.steamPrefix != nil {
                    // Shared games reach MacHub through Steam for Windows' library cache, which Steam only updates
                    // while it runs: after joining a family, it has to start once.
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Label("Missing games from your Steam Family? Start Steam for Windows once: it syncs the family library, and MacHub picks the shared games up within a minute.",
                              systemImage: "person.2")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Start Steam for Windows") { Task { await store.startSteam() } }
                            .controlSize(.small)
                    }
                }
                if showDemo {
                    Text("Sample games").font(.title2.weight(.bold)).padding(.top, 12)
                    TitleGrid(titles: DemoLibrary.titles.filter { $0.kind == .game })
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 28)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var filtered: [Title] {
        switch filter {
        case .all: store.library
        case .installed: store.library.filter { $0.availability == .installed }
        case .owned: store.library.filter { $0.owned != nil }
        case .recent: store.recent.filter { $0.kind == .game }
        }
    }

    private var emptyTitle: LocalizedStringKey {
        filter == .recent ? "Nothing launched yet" : "No games here yet"
    }

    private var emptyMessage: LocalizedStringKey {
        switch filter {
        case .recent: "Games you start from MacHub appear here."
        case .installed: "Install a game with Steam for Windows and it will appear here."
        default: "Connect Steam and add your Web API key to see the games you own, or install games with Steam for Windows."
        }
    }
}

// MARK: - Windows software

struct SoftwareView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @State private var recentDownloads: [URL]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Software", subtitle: "Windows programs you added yourself, and programs pinned in Whisky.")
                HStack(spacing: 12) {
                    Button {
                        navigation.installRequest += 1
                    } label: {
                        Label("Install a Windows program…", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryActionStyle())
                    .disabled(store.whiskyInstall == nil)
                    Button {
                        recentDownloads = DownloadsScanner.recentInstallers()
                    } label: {
                        Label("From Downloads", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(SecondaryActionStyle())
                    .disabled(store.whiskyInstall == nil)
                    .help("Lists the .exe and .msi files in your Downloads folder. MacHub only looks when you click.")
                    .popover(isPresented: Binding(get: { recentDownloads != nil }, set: { if !$0 { recentDownloads = nil } })) {
                        DownloadsPopover(files: recentDownloads ?? []) { url in
                            recentDownloads = nil
                            ImportInbox.shared.receive([url])
                        }
                    }
                }
                Text("You can also drag a .exe or .msi onto this window, or use Open With > MacHub in Finder.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                if store.whiskyInstall == nil {
                    NoticeCard(symbol: "shippingbox", title: "Whisky isn't ready",
                               message: "Programs run inside a Whisky bottle. See Settings to finish setting up Whisky.")
                        .padding(.horizontal, -Theme.gutter)
                }
                if store.software.isEmpty {
                    ContentUnavailableView {
                        Label("No programs yet", systemImage: "macwindow")
                    } description: {
                        Text("Install a Windows program, or pin one in Whisky: it shows up here.")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    TitleGrid(titles: store.software)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 28)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

private struct DownloadsPopover: View {
    let files: [URL]
    let pick: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows files in Downloads").font(.headline)
            if files.isEmpty {
                Text("No .exe or .msi file in your Downloads folder.").foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { url in
                Button {
                    pick(url)
                } label: {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                        Text(verbatim: url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

// MARK: - Global search

struct GlobalSearchView: View {
    let query: String
    let showAllOnSteam: () -> Void
    @Environment(LibraryStore.self) private var store
    @State private var steamResults: [StoreItem] = []
    @State private var steamState: DiscoverModel.State = .idle

    var body: some View {
        let local = store.titles(includeDemo: false).filter { $0.name.localizedStandardContains(query) }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(title: "Search", subtitle: nil)
                if !local.isEmpty {
                    Text("In your library").font(.title2.weight(.bold))
                    TitleGrid(titles: local)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("On Steam").font(.title2.weight(.bold))
                    Spacer()
                    Button("See all results in Discover", action: showAllOnSteam).buttonStyle(SecondaryActionStyle())
                }
                switch steamState {
                case .loading where steamResults.isEmpty:
                    ProgressView().frame(maxWidth: .infinity)
                case .offline, .rateLimited, .failed:
                    Text("Steam can't be searched right now.").foregroundStyle(Theme.textSecondary)
                case .empty:
                    ContentUnavailableView.search(text: query)
                default:
                    TitleGrid(titles: steamResults.map { store.enriched(Title(store: $0)) })
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 28)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            steamState = .loading
            do {
                steamResults = Array(try await SteamStore.search(term: query, page: 0).prefix(18))
                steamState = steamResults.isEmpty ? .empty : .loaded
            } catch {
                steamState = .offline
            }
        }
    }
}

// MARK: - Shared

struct PageHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.titleFont(34)).foregroundStyle(Theme.textPrimary)
            if let subtitle { Text(subtitle).foregroundStyle(Theme.textSecondary) }
        }
    }
}

struct TitleGrid: View {
    let titles: [Title]
    var onAppear: ((Title) -> Void)?
    @Environment(LibraryStore.self) private var store

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 22, alignment: .top)],
                  alignment: .leading, spacing: 30) {
            ForEach(titles) { title in
                NavigationLink(value: title) {
                    GeometryReader { proxy in
                        TitleCard(title: title, style: .portrait, width: proxy.size.width)
                    }
                    .aspectRatio(176 / 330, contentMode: .fit)
                }
                .buttonStyle(CardButtonStyle())
                .contextMenu { TitleActionsMenu.Items(title: title) }
                .focusable(interactions: .activate)
                .focusEffectDisabled()
                .onHover { if $0 { store.spotlight = title } }
                .onAppear { onAppear?(title) }
            }
        }
    }
}
