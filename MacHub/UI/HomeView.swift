import SwiftUI

struct HomeView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("showDemoTitles") private var showDemo = false
    @State private var viewportHeight: CGFloat = 900

    var body: some View {
        let featured = store.featured(includeDemo: showDemo)
        let installed = store.library.filter { $0.availability == .installed }
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                if featured.isEmpty {
                    FeaturedPlaceholder(state: store.featuredState)
                } else {
                    HeroCarousel(titles: featured, height: min(max(viewportHeight * 0.62, 480), 720))
                }
                if store.steam.account == nil { SteamConnectCard() }
                TitleRow(heading: "Continue", titles: store.recent, style: .landscape)
                if installed.isEmpty {
                    InstalledEmptyState()
                } else {
                    TitleRow(heading: "Installed in Whisky", titles: installed, style: .landscape)
                }
                if store.steam.account != nil {
                    if store.ownedState == .loaded {
                        TitleRow(heading: "Your Steam library", titles: store.library.filter { $0.owned != nil }, style: .portrait)
                    } else {
                        OwnedStateNotice()
                    }
                }
                StoreRows()
                if showDemo {
                    TitleRow(heading: "Sample games", titles: DemoLibrary.titles.filter { $0.kind == .game }, style: .portrait, isDemo: true)
                }
            }
            .padding(.bottom, 48)
        }
        .scrollIndicators(.never)
        .ignoresSafeArea(edges: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

// MARK: - Hero

struct HeroCarousel: View {
    let titles: [Title]
    let height: CGFloat
    @Environment(LibraryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var hovering = false
    /// 0→1 over the dwell time of the current slide; drawn on its thumbnail so changes never come unannounced.
    @State private var progress: CGFloat = 0

    private static let dwell: Double = 9

    var body: some View {
        let title = titles[min(index, titles.count - 1)]
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(title: title, artwork: .hero)
                .overlay {
                    // Legibility scrims, not decoration: text column on the left, thumbnails bottom right,
                    // and a corner shade so bright skies don't read as a white field.
                    LinearGradient(stops: [.init(color: .black.opacity(0.82), location: 0),
                                           .init(color: .black.opacity(0.45), location: 0.4),
                                           .init(color: .clear, location: 0.72)],
                                   startPoint: .leading, endPoint: .trailing)
                    RadialGradient(colors: [.black.opacity(0.5), .clear], center: .topTrailing, startRadius: 0, endRadius: 760)
                }
                .fadeOutBottom()
                .id(title.id)
                .transition(.opacity)

            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    LogoArt(title: title)
                    MetaLine(title: title)
                    if let summary = title.summary {
                        Text(verbatim: summary)
                            .font(.title3)
                            .foregroundStyle(Theme.textPrimary.opacity(0.88))
                            .lineLimit(3)
                            .frame(maxWidth: 520, alignment: .leading)
                    }
                    HStack(spacing: 12) {
                        PlayButton(title: title)
                        NavigationLink(value: title) {
                            Label("Details", systemImage: "info.circle")
                        }
                        .buttonStyle(SecondaryActionStyle())
                    }
                    PlayStatus(title: title)
                }
                .frame(maxWidth: 560, alignment: .leading)
                .layoutPriority(1)
                .id(title.id)
                .transition(.opacity)

                Spacer(minLength: 32)

                ViewThatFits(in: .horizontal) {
                    ThumbnailStrip(titles: titles, index: $index, progress: progress, thumbnail: CGSize(width: 112, height: 52))
                    ThumbnailStrip(titles: titles, index: $index, progress: progress, thumbnail: CGSize(width: 84, height: 39))
                    PageDots(count: titles.count, index: $index)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 64)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(.easeInOut(duration: 0.6), value: index)
        .focusable()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onHover { hovering = $0 }
        .onAppear { store.spotlight = title }
        .onChange(of: index) { store.spotlight = titles[min(index, titles.count - 1)] }
        .task(id: "\(index)-\(hovering)") {
            // Auto-advance; hovering pauses and rewinds the dwell, Reduce Motion turns it off.
            progress = 0
            guard !reduceMotion, !hovering, titles.count > 1 else { return }
            withAnimation(.linear(duration: Self.dwell)) { progress = 1 }
            try? await Task.sleep(for: .seconds(Self.dwell))
            guard !Task.isCancelled else { return }
            step(1)
        }
    }

    private func step(_ delta: Int) {
        index = (index + delta + titles.count) % titles.count
    }
}

private struct ThumbnailStrip: View {
    let titles: [Title]
    @Binding var index: Int
    let progress: CGFloat
    let thumbnail: CGSize

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(titles.enumerated()), id: \.element.id) { offset, title in
                Button {
                    index = offset
                } label: {
                    ArtworkImage(title: title, artwork: .header)
                        .frame(width: thumbnail.width, height: thumbnail.height)
                        .overlay(alignment: .bottom) {
                            if offset == index {
                                // Fixed-size bar scaled from the left: a purely visual animation that can't move layout.
                                Capsule().fill(.white.opacity(0.25))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(.white).scaleEffect(x: progress, y: 1, anchor: .leading)
                                    }
                                    .frame(width: thumbnail.width - 16, height: 3)
                                    .padding(.bottom, 7)
                            }
                        }
                        .clipShape(.rect(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(.white, lineWidth: offset == index ? 2 : 0)
                        }
                        .opacity(offset == index ? 1 : 0.6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: title.name))
                .accessibilityAddTraits(offset == index ? .isSelected : [])
                .help(Text(verbatim: title.name))
            }
        }
        .padding(8)
        .floatingGlass(cornerRadius: 14)
        .fixedSize()
    }
}

/// Narrow windows: the featured strip collapses to page dots.
private struct PageDots: View {
    let count: Int
    @Binding var index: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Button { index = i } label: {
                    Capsule().fill(.white.opacity(i == index ? 1 : 0.35))
                        .frame(width: i == index ? 22 : 8, height: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(i + 1) / \(count)"))
            }
        }
        .padding(10)
        .floatingGlass(cornerRadius: 12)
        .fixedSize()
    }
}

/// Shown instead of the "Installed" row while Whisky reports no installed game. States the real reason.
private struct InstalledEmptyState: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text("Installed in Whisky").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                Text(reason).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(20)
        .background(Theme.surface, in: .rect(cornerRadius: 14))
        .padding(.horizontal, Theme.gutter)
    }

    private var reason: LocalizedStringKey {
        switch store.report?.status {
        case nil: "Checking Whisky…"
        case .ready:
            store.registeredBottles.isEmpty
                ? "Whisky is ready but has no bottle yet. Create a bottle named “Steam” in Whisky, install Steam and a game, and it will appear here."
                : "No installed Steam game found in your bottles yet. Games you install through Steam in Whisky appear here."
        case .outdated: "Your Whisky is too old for MacHub. Install the maintained fork (frankea/Whisky)."
        case .notFound, .invalidCustomPath: "Whisky wasn't found. Check Settings."
        }
    }
}

// MARK: - Rows

struct TitleRow: View {
    let heading: LocalizedStringKey
    let titles: [Title]
    let style: CardStyle
    var isDemo = false
    @Environment(LibraryStore.self) private var store
    @State private var position: Title.ID?

    var body: some View {
        if !titles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(heading).font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                    Text(verbatim: "\(titles.count)").font(.title3).foregroundStyle(Theme.textSecondary)
                    if isDemo { DemoTag() }
                    Spacer()
                    pager
                }
                .padding(.horizontal, Theme.gutter)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(titles) { title in
                            NavigationLink(value: title) {
                                TitleCard(title: title, style: style)
                            }
                            .buttonStyle(CardButtonStyle())
                .focusable(interactions: .activate)
                .focusEffectDisabled()
                            .onHover { if $0 { store.spotlight = title } }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, Theme.gutter)
                    .padding(.vertical, 14)
                }
                .scrollIndicators(.never)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $position, anchor: .leading)
            }
        }
    }

    private var pager: some View {
        HStack(spacing: 8) {
            pageButton("chevron.left", label: "Previous", step: -1)
            pageButton("chevron.right", label: "Next", step: 1)
        }
    }

    private func pageButton(_ symbol: String, label: LocalizedStringKey, step: Int) -> some View {
        Button {
            let current = titles.firstIndex { $0.id == position } ?? 0
            let jump = style == .portrait ? 5 : 3
            let target = min(max(current + step * jump, 0), titles.count - 1)
            withAnimation(.easeInOut(duration: 0.45)) { position = titles[target].id }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 32, height: 32)
                .background(Theme.surfaceRaised, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}
