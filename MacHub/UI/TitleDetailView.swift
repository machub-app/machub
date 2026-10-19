import SwiftUI

struct TitleDetailView: View {
    private let base: Title
    @Environment(LibraryStore.self) private var store
    @AppStorage("showDemoTitles") private var showDemo = false
    @State private var viewportHeight: CGFloat = 900
    @State private var detailsLoaded = false

    init(title: Title) { base = title }

    /// The title with everything known about it: installed/owned state and the store page once loaded.
    private var title: Title { store.enriched(base) }
    private var details: StoreDetails? { base.steamAppID.flatMap { store.details[$0] } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                backdrop
                HStack(alignment: .top, spacing: 48) {
                    VStack(alignment: .leading, spacing: 28) {
                        about
                        RequirementsPanel(title: title, details: details, detailsLoaded: detailsLoaded)
                        ModsEntry(title: title)
                        if title.install != nil, !title.isDemo { TitleGraphicsPanel(title: title) }
                        compatibility
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    InfoPanel(title: title, details: details)
                        .frame(width: 330)
                }
                .padding(.horizontal, Theme.gutter)

                if let shots = details?.screenshots, !shots.isEmpty {
                    ScreenshotRow(urls: shots)
                }
                TitleRow(heading: "More like this", titles: similar, style: .landscape, isDemo: similar.allSatisfy(\.isDemo))
            }
            .padding(.bottom, 48)
        }
        .scrollIndicators(.never)
        .ignoresSafeArea(edges: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear { store.spotlight = title }
        .task(id: base.id) {
            if let appID = base.steamAppID { await store.loadDetails(appID: appID) }
            detailsLoaded = true
        }
    }

    private var backdrop: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(title: title, artwork: .hero)
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.8), location: 0),
                                           .init(color: .clear, location: 0.62)],
                                   startPoint: .leading, endPoint: .trailing)
                    RadialGradient(colors: [.black.opacity(0.5), .clear], center: .topTrailing, startRadius: 0, endRadius: 760)
                }
                .fadeOutBottom(from: 0.5)
            VStack(alignment: .leading, spacing: 18) {
                LogoArt(title: title, maxHeight: 120)
                MetaLine(title: title)
                HStack(spacing: 12) {
                    PlayButton(title: title)
                        .keyboardShortcut(.defaultAction)
                    TitleActionsMenu(title: title)
                    if let appID = title.steamAppID {
                        Link(destination: URL(string: "https://store.steampowered.com/app/\(appID)")!) {
                            Label("Steam page", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(SecondaryActionStyle())
                    }
                    if let path = title.installPath {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                        } label: {
                            Label("Show files", systemImage: "folder")
                        }
                        .buttonStyle(SecondaryActionStyle())
                    }
                    if title.id.hasPrefix("software:") {
                        Button(role: .destructive) {
                            store.removeProgram(title)
                        } label: {
                            Label("Remove from MacHub", systemImage: "minus.circle")
                        }
                        .buttonStyle(SecondaryActionStyle())
                        .help("Removes the shortcut from MacHub only. The program's files are not touched.")
                    }
                }
                PlayStatus(title: title)
            }
            .padding(.leading, Theme.gutter)
            .padding(.bottom, 36)
        }
        .frame(height: min(max(viewportHeight * 0.6, 440), 660))
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
            Group {
                if let summary = title.summary, !summary.isEmpty {
                    Text(verbatim: summary)
                } else if title.steamAppID != nil, !detailsLoaded {
                    Text("Loading the Steam store page…")
                } else if title.steamAppID != nil {
                    Text("Steam has no store page for this title in your region.")
                } else {
                    Text("No description for this program.")
                }
            }
                .font(.title3)
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var compatibility: some View {
        CompatibilityPanel(title: title)
    }

    private var similar: [Title] {
        store.titles(includeDemo: showDemo)
            .filter { $0.id != title.id && $0.kind == title.kind && !Set($0.genres).isDisjoint(with: title.genres) }
    }
}

private struct InfoPanel: View {
    let title: Title
    let details: StoreDetails?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Developer", title.developer.map { Text(verbatim: $0) })
            row("Publisher", title.publisher.map { Text(verbatim: $0) })
            row("Released", title.releaseYear.map { Text(verbatim: String($0)) })
            if !title.genres.isEmpty {
                rowView("Genres") {
                    // One genre per line: long localized genres never break mid-word.
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(title.genres, id: \.self) { Text(LocalizedStringKey($0)) }
                    }
                }
            }
            row("Type", title.kind == .game ? Text("Game") : Text("Windows software"))
            row("Source", title.isDemo ? Text("Demo data") : nil)
            row("Bottle", title.bottle.map { Text(verbatim: $0) })
            row("Steam App ID", title.steamAppID.map { Text(verbatim: String($0)) })
            row("Price on Steam", details?.isFree == true ? Text("Free") : details?.price.map { Text(verbatim: $0) })
            row("Metacritic", details?.metacritic.map { Text(verbatim: String($0)) })
            row("Playtime", title.owned.map { Text("\($0.playtimeMinutes / 60) h \($0.playtimeMinutes % 60) min") })
            row("Release date", details?.releaseDate.map { Text(verbatim: $0) })
            row("Install folder", title.installPath.map { Text(verbatim: $0) }, monospaced: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(Theme.surface, in: .rect(cornerRadius: 14))
    }

    private func rowView(_ label: LocalizedStringKey, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 16)
            value().foregroundStyle(Theme.textPrimary)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    @ViewBuilder
    private func row(_ label: LocalizedStringKey, _ value: Text?, monospaced: Bool = false) -> some View {
        if let value {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 16)
                value
                    .foregroundStyle(Theme.textPrimary)
                    .font(monospaced ? .callout.monospaced() : .body)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
        }
    }
}

/// Each step between "on Steam" and "playable here", as verified facts. Nothing is assumed.
private struct RequirementsPanel: View {
    let title: Title
    let details: StoreDetails?
    let detailsLoaded: Bool
    @Environment(LibraryStore.self) private var store

    enum Status { case ok, missing, unknown, info }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Requirements").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 0) {
                if title.isDemo {
                    item(.info, "Demo title", "Sample content, not connected to Steam.")
                } else {
                    if title.kind == .game {
                        item(details != nil ? .ok : (detailsLoaded ? .missing : .unknown), "Listed on the Steam store",
                             details == nil && detailsLoaded ? "No store page returned for your region." : nil)
                        ownedItem
                    }
                    item(title.install != nil ? .ok : .missing, "Installed in a Windows environment",
                         title.bottle.map { "Environment “\($0)”" })
                    if title.install != nil {
                        let count = title.install?.executables.count ?? 0
                        item(count > 0 ? .ok : .missing, "Windows executable detected",
                             count > 0 ? (title.install?.executables.prefix(3).joined(separator: ", ")) : "No .exe found in the install folder.")
                    }
                    item(store.canRunWindows ? .ok : .missing, "Windows engine ready",
                         store.runtime.map { "MacHub engine \($0.version)" } ?? store.whiskyInstall?.version.map { "Whisky \($0) (fallback)" })
                    if title.kind == .game, title.install == nil {
                        item(store.steamBottle != nil ? .ok : .missing, "Steam for Windows in a bottle",
                             store.steamBottle?.name.map { "Environment “\($0)”" } ?? "Needed to install Windows games. Set it up in Settings › Windows Engine.")
                    }
                    item(.unknown, "Runs on Mac", "Not verified.")
                    if details?.mac == true {
                        item(.info, "Native macOS version", "Steam sells a Mac build of this game: Steam for Mac runs it without Wine.")
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(Theme.surface, in: .rect(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var ownedItem: some View {
        if title.owned != nil {
            item(.ok, "In your Steam library", nil)
        } else {
            switch store.ownedState {
            case .loaded: item(.missing, "In your Steam library", "Not in the games Steam reports for your account.")
            case .signedOut: item(.unknown, "In your Steam library", "Connect Steam to check.")
            case .needsKey: item(.unknown, "In your Steam library", "Add your Steam Web API key to check.")
            case .privateProfile: item(.unknown, "In your Steam library", "Your game details are private on Steam.")
            default: item(.unknown, "In your Steam library", "Couldn't be checked.")
            }
        }
    }

    private func item(_ status: Status, _ label: LocalizedStringKey, _ detail: String?) -> some View {
        let (symbol, tint): (String, Color) = switch status {
        case .ok: ("checkmark.circle.fill", Compatibility.great.tint)
        case .missing: ("xmark.circle", Compatibility.issues.tint)
        case .unknown: ("questionmark.circle", Theme.textSecondary)
        case .info: ("info.circle", Theme.textSecondary)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(Theme.textPrimary)
                if let detail { Text(LocalizedStringKey(detail)).font(.callout).foregroundStyle(Theme.textSecondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

private struct ScreenshotRow: View {
    let urls: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screenshots").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary).padding(.horizontal, Theme.gutter)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(urls, id: \.self) { url in
                        AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: .fill) } placeholder: { Theme.surface }
                            .frame(width: 320, height: 180)
                            .clipShape(.rect(cornerRadius: Theme.cardRadius))
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
            .scrollIndicators(.never)
        }
    }
}

/// The title's own graphics layer, applied at its next launch. Shows what the last launch actually used.
private struct TitleGraphicsPanel: View {
    let title: Title
    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Launch & Graphics").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 10) {
                TextField("Launch options", text: Binding(
                    get: { store.settings(for: title).arguments },
                    set: { new in
                        var settings = store.settings(for: title)
                        settings.arguments = new
                        store.updateSettings(settings, for: title)
                    }), prompt: Text(verbatim: title.steamAppID == ModSupport.beamNGAppID ? "-gfx dx11" : "-windowed"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 380)
                Text("Passed to the game at launch, like Steam's own launch options.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Picker("Direct3D", selection: Binding(
                    get: { store.settings(for: title).graphics },
                    set: { new in
                        var settings = store.settings(for: title)
                        settings.graphics = new
                        store.updateSettings(settings, for: title)
                    })) {
                    ForEach(GraphicsChoice.allCases.filter { $0 != .d3dmetal }, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 380)
                Text(store.settings(for: title).graphics.explanation).font(.callout).foregroundStyle(Theme.textSecondary)
                if let last = store.performance[title.id]?.first {
                    Label {
                        Text("Last session: \(Int(last.averageFPS.rounded())) FPS on average, lows \(Int(last.lowFPS.rounded())) FPS, \(Int((last.duration / 60).rounded())) min")
                    } icon: {
                        Image(systemName: "speedometer")
                    }
                    .font(.callout).foregroundStyle(Theme.textPrimary)
                    if let sessions = store.performance[title.id], sessions.count > 1 {
                        Text("Previous: \(sessions.dropFirst().prefix(4).map { "\(Int($0.averageFPS.rounded()))" }.joined(separator: " · ")) FPS")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                } else if !store.engineSettings.metalHUD {
                    Text("Turn on the Metal performance overlay in Settings › Graphics to measure frame rates: MacHub then shows a summary here after each session.")
                        .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                if let used = store.lastGraphics[title.id], !used.isEmpty {
                    Text("Last launch: \(used.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value.rawValue)" }.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    if used.values.contains(where: { $0 == .dxmt || $0 == .dxvk }) {
                        Text("Some games warn about “third-party libraries” (d3d11.dll, dxgi.dll) next to their executable: those are MacHub's graphics layer. The warning is safe to dismiss.")
                            .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: 12))
        }
    }
}
