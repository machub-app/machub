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
                PageHeader(title: "Discover", subtitle: "The Steam store, searched on demand. Being on Steam doesn't mean a game runs under Whisky.")
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
                PageHeader(title: "Library", subtitle: "Games you own on Steam and games installed in your Whisky bottles.")
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
        case .installed: "Install a game with Steam for Windows inside a Whisky bottle and it will appear here."
        default: "Connect Steam and add your Web API key to see the games you own, or install games in a Whisky bottle."
        }
    }
}

// MARK: - Windows software

struct SoftwareView: View {
    @Environment(LibraryStore.self) private var store
    @State private var importing = false
    @State private var chosenBottle = ""

    var body: some View {
        let bottles = store.registeredBottles.compactMap(\.name)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Software", subtitle: "Windows programs you added yourself, and programs pinned in Whisky.")
                HStack(spacing: 12) {
                    Picker("Bottle", selection: $chosenBottle) {
                        ForEach(bottles, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .fixedSize()
                    .disabled(bottles.isEmpty)
                    Button {
                        importing = true
                    } label: {
                        Label("Add a Windows program…", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryActionStyle())
                    .disabled(bottles.isEmpty)
                }
                if bottles.isEmpty {
                    NoticeCard(symbol: "shippingbox", title: "No bottle yet",
                               message: "Programs run inside a Whisky bottle. Create one in Whisky, then add your .exe here.")
                        .padding(.horizontal, -Theme.gutter)
                }
                if store.software.isEmpty {
                    ContentUnavailableView {
                        Label("No programs yet", systemImage: "macwindow")
                    } description: {
                        Text("Add a Windows .exe, or pin a program in Whisky: it shows up here.")
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
        .onAppear { if chosenBottle.isEmpty { chosenBottle = bottles.first ?? "" } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "exe") ?? .item]) { result in
            if case .success(let url) = result, !chosenBottle.isEmpty { store.importProgram(at: url, bottle: chosenBottle) }
        }
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
                .focusable(interactions: .activate)
                .focusEffectDisabled()
                .onHover { if $0 { store.spotlight = title } }
                .onAppear { onAppear?(title) }
            }
        }
    }
}
