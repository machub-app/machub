import SwiftUI

struct LibraryView: View {
    enum KindFilter: Hashable { case all, games, software }
    enum Sort: Hashable { case name, year, compatibility }

    @Environment(LibraryStore.self) private var store
    @AppStorage("showDemoTitles") private var showDemo = true
    @State private var kind = KindFilter.all
    @State private var compatibility: Compatibility?
    @State private var sort = Sort.name

    var body: some View {
        let titles = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(count: titles.count)
                if titles.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing matches", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Change the filters to see more titles.")
                    } actions: {
                        Button("Clear filters") { kind = .all; compatibility = nil }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    TitleGrid(titles: titles)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 28)
        }
        .scrollIndicators(.automatic)
        .navigationTitle("Library")
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Library").font(Theme.titleFont(34)).foregroundStyle(Theme.textPrimary)
                Text(verbatim: "\(count)").font(.title2).foregroundStyle(Theme.textSecondary)
                if showDemo { DemoTag() }
            }
            HStack(spacing: 12) {
                Picker("Type", selection: $kind) {
                    Text("All").tag(KindFilter.all)
                    Text("Games").tag(KindFilter.games)
                    Text("Software").tag(KindFilter.software)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Picker("Compatibility", selection: $compatibility) {
                    Text("Any compatibility").tag(Compatibility?.none)
                    Divider()
                    ForEach(Compatibility.allCases, id: \.self) { value in
                        Label(value.label, systemImage: value.symbol).tag(Compatibility?.some(value))
                    }
                }
                .fixedSize()

                Spacer()

                Picker("Sort by", selection: $sort) {
                    Text("Name").tag(Sort.name)
                    Text("Release year").tag(Sort.year)
                    Text("Compatibility").tag(Sort.compatibility)
                }
                .fixedSize()
            }
        }
    }

    private var filtered: [Title] {
        store.titles(includeDemo: showDemo)
            .filter {
                switch kind {
                case .all: true
                case .games: $0.kind == .game
                case .software: $0.kind == .software
                }
            }
            .filter { compatibility == nil || $0.compatibility == compatibility }
            .sorted {
                switch sort {
                case .name: $0.name.localizedStandardCompare($1.name) == .orderedAscending
                case .year: ($0.releaseYear ?? 0) > ($1.releaseYear ?? 0)
                case .compatibility:
                    (Compatibility.allCases.firstIndex(of: $0.compatibility) ?? 0)
                        < (Compatibility.allCases.firstIndex(of: $1.compatibility) ?? 0)
                }
            }
    }
}

struct TitleGrid: View {
    let titles: [Title]
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
            }
        }
    }
}

struct SearchView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("showDemoTitles") private var showDemo = true
    @State private var query = ""

    var body: some View {
        let all = store.titles(includeDemo: showDemo)
        let results = query.isEmpty ? [] : all.filter {
            $0.name.localizedStandardContains(query)
                || $0.genres.contains { $0.localizedStandardContains(query) }
                || ($0.developer?.localizedStandardContains(query) ?? false)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Search").font(Theme.titleFont(34)).foregroundStyle(Theme.textPrimary)
                if query.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Try").font(.headline).foregroundStyle(Theme.textSecondary)
                        FlowChips(items: Array(all.prefix(10))) { query = $0.name }
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    TitleGrid(titles: results)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Search")
        .toolbar(removing: .title)
        .searchable(text: $query, placement: .toolbar, prompt: Text("Games, software, studios"))
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

private struct FlowChips: View {
    let items: [Title]
    let pick: (Title) -> Void

    var body: some View {
        // Wrapping chips without a custom Layout: a fixed adaptive grid reads cleanly at these lengths.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(items) { title in
                Button { pick(title) } label: {
                    Text(verbatim: title.name)
                        .lineLimit(1)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.surfaceRaised, in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
