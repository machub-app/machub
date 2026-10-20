import SwiftUI

/// Steam artwork for a title: the CDN library asset, then the store's own capsule, then a monogram plate.
struct ArtworkImage: View {
    let title: Title
    let artwork: Artwork

    var body: some View {
        Color.clear.overlay {
            if let appID = title.steamAppID {
                AsyncImage(url: artwork.url(appID: appID), transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                    case .failure: fallback
                    default: Theme.surface
                    }
                }
            } else {
                MonogramPlate(title: title)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var fallback: some View {
        if artwork == .hero, let background = title.backgroundURL {
            AsyncImage(url: background) { phase in
                if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fill) } else { capsule }
            }
        } else {
            capsule
        }
    }

    /// Store capsules are small and landscape: shown whole on a blurred copy of themselves, never stretched.
    @ViewBuilder
    private var capsule: some View {
        if let url = title.capsuleURL {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    // Overlays on a clear base: the card's frame sets the size, not the overflowing fill.
                    Color.clear
                        .overlay { image.resizable().aspectRatio(contentMode: .fill).blur(radius: 24).opacity(0.55) }
                        .overlay {
                            image.resizable().aspectRatio(contentMode: .fit)
                                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                                .padding(artwork == .cover ? 10 : 0)
                        }
                        .clipped()
                } else {
                    MonogramPlate(title: title)
                }
            }
        } else {
            MonogramPlate(title: title)
        }
    }
}

/// A title's own logo art, the display voice of the hero. Falls back to the name in the title face.
/// Dark logos (Assetto Corsa's black lettering, for one) get a soft light backing so they read on dark art.
struct LogoArt: View {
    let title: Title
    var maxHeight: CGFloat = 140
    var fallbackSize: CGFloat = 52
    @State private var logo: LoadedLogo?
    @State private var failed = false

    var body: some View {
        Group {
            if let logo {
                if logo.isDark {
                    // Dark (often two-tone) wordmarks sit on a light neutral plate, like their own cover art,
                    // so every colour of the mark reads over any artwork.
                    Image(nsImage: logo.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color(white: 0.93).opacity(0.9), in: .rect(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                } else {
                    Image(nsImage: logo.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                }
            } else if failed || title.steamAppID == nil {
                name
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: 460, maxHeight: maxHeight, alignment: .bottomLeading)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: title.name))
        .accessibilityAddTraits(.isHeader)
        .task(id: title.id) { await load() }
    }

    private var name: some View {
        Text(verbatim: title.name)
            .font(Theme.titleFont(fallbackSize))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func load() async {
        logo = nil
        failed = false
        guard let appID = title.steamAppID else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: Artwork.logo.url(appID: appID))
            guard let image = NSImage(data: data) else { failed = true; return }
            logo = LoadedLogo(image: image, isDark: LoadedLogo.isMostlyDark(image))
        } catch {
            failed = true
        }
    }
}

struct LoadedLogo {
    let image: NSImage
    let isDark: Bool

    /// Alpha-weighted mean luminance of the logo's visible pixels, sampled on a 24×24 grid.
    static func isMostlyDark(_ image: NSImage, threshold: Double = 0.35) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        var luminance = 0.0, weight = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0.1 else { continue }
            // Premultiplied: divide out alpha to get the colour, then weight by alpha.
            let r = Double(pixels[i]) / 255 / alpha, g = Double(pixels[i + 1]) / 255 / alpha, b = Double(pixels[i + 2]) / 255 / alpha
            luminance += (0.2126 * r + 0.7152 * g + 0.0722 * b) * alpha
            weight += alpha
        }
        return weight > 0 && luminance / weight < threshold
    }
}

/// Software and missing artwork: a solid field tinted per title, with initials in the title face.
struct MonogramPlate: View {
    let title: Title

    var body: some View {
        // Stable across launches, unlike hashValue.
        let hue = Double(title.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        ZStack(alignment: .bottomLeading) {
            Color(hue: hue, saturation: 0.45, brightness: 0.28)
            Text(verbatim: initials)
                .font(Theme.titleFont(64))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Image(systemName: title.kind == .software ? "macwindow" : "gamecontroller")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(10)
        }
    }

    private var initials: String {
        let words = title.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

/// Filled for a real verdict; outlined, with a flask, for an illustrative demo value.
struct CompatibilityBadge: View {
    let compatibility: Compatibility
    var compact = false
    var isDemo = false

    var body: some View {
        HStack(spacing: 5) {
            // On cards the per-cover flask mark already says "demo"; the outline alone carries it here.
            if isDemo && !compact { Image(systemName: "flask").foregroundStyle(Theme.textSecondary) }
            Image(systemName: compatibility.symbol)
            Text(compatibility.label)
        }
        .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
        .foregroundStyle(compatibility.tint)
        .padding(.horizontal, compact ? 7 : 10)
        .padding(.vertical, compact ? 3 : 5)
        .background(compatibility.tint.opacity(isDemo ? 0 : 0.14), in: .capsule)
        .overlay(Capsule().strokeBorder(compatibility.tint.opacity(isDemo ? 0.45 : 0), lineWidth: 1))
        .help(isDemo ? Text("Illustrative value for the demo. MacHub has no compatibility data source yet.") : Text(compatibility.label))
    }
}

/// Genres are catalogue keys, so known ones follow the app language; unknown ones show as-is.
struct GenreList: View {
    let genres: [String]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(genres.enumerated()), id: \.offset) { index, genre in
                if index > 0 { Text(verbatim: "·") }
                Text(LocalizedStringKey(genre))
            }
        }
    }
}

/// Marks sample content so it can never be mistaken for the user's real library.
struct DemoTag: View {
    var body: some View {
        Label("Demo data", systemImage: "flask")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
            .help("Sample content. Not installed and not launchable.")
    }
}

struct MetaLine: View {
    let title: Title

    var body: some View {
        HStack(spacing: 10) {
            if !title.isDemo { AvailabilityBadge(title: title) }
            if !title.isDemo, let appID = title.steamAppID {
                EstimateBadge(appID: appID)
            } else {
                CompatibilityBadge(compatibility: title.compatibility, isDemo: title.isDemo)
            }
            if let year = title.releaseYear {
                Text(verbatim: String(year))
            }
            if !title.genres.isEmpty {
                GenreList(genres: title.genres)
            }
            if title.isDemo { DemoTag() }
        }
        .font(.callout)
        .foregroundStyle(Theme.textSecondary)
    }
}

extension View {
    /// Fades the bottom of an image to transparent so it melts into the ambient backdrop.
    func fadeOutBottom(from start: CGFloat = 0.55) -> some View {
        mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: start),
                                    .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Buttons

struct PrimaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, fill: Theme.play, foreground: .white)
    }
}

struct SecondaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, fill: Theme.surfaceRaised, foreground: Theme.textPrimary)
    }
}

private struct StyledBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    let foreground: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 22)
            .frame(minHeight: 44)
            .background(fill.opacity(isEnabled ? (hovering ? 0.88 : 1) : 0.35), in: .capsule)
            .overlay(Capsule().strokeBorder(.white, lineWidth: isFocused ? 2.5 : 0).padding(-4))
            .opacity(isEnabled ? 1 : 0.55)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .onHover { hovering = $0 }
            .contentShape(.capsule)
    }
}

/// What a title's main button does, decided from verified state only.
enum TitleAction: Equatable {
    case play
    /// Native Mac game: its own launcher opens it.
    case openNative(URL)
    case install(bottle: String)
    /// Steam for Windows is downloading it in a MacHub prefix (fraction when known).
    case downloading(Double?)
    case unavailable
}

extension LibraryStore {
    func action(for title: Title) -> TitleAction {
        if let app = title.nativeApp { return .openNative(app) }
        if title.canLaunch, let bottle = title.bottle, engine(forBottle: bottle) != nil { return .play }
        if let appID = title.steamAppID, title.install == nil, steamDownloads[appID] != nil { return .downloading(downloadProgress(appID: appID)) }
        if let appID = title.steamAppID, let update = steamUpdates[appID], update.isUpdating {
            return .downloading(SteamLibrary.progress(of: update))
        }
        if !title.isDemo, title.kind == .game, title.install == nil, title.steamAppID != nil, let bottle = steamBottle?.name {
            return .install(bottle: bottle)
        }
        return .unavailable
    }
}

/// Uninstall, update, verify, folder and Steam properties for an installed Steam game in MacHub's engine.
struct TitleActionsMenu: View {
    let title: Title
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if title.install != nil, title.steamAppID != nil {
            Menu {
                Items(title: title)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(SecondaryActionStyle())
            .fixedSize()
            .help("Manage this game")
            .accessibilityLabel(Text("Manage this game"))
        }
    }

    struct Items: View {
        let title: Title
        @Environment(LibraryStore.self) private var store

        var body: some View {
            if title.install != nil, let appID = title.steamAppID {
                if store.steamUpdates[appID]?.needsUpdate == true {
                    Button("Update Now", systemImage: "arrow.down.circle") { Task { await store.perform(.update, on: title) } }
                }
                Button("Verify Game Files", systemImage: "checkmark.shield") { Task { await store.perform(.verify, on: title) } }
                Button("Show Game Folder", systemImage: "folder") { store.revealInstallFolder(title) }
                Button("Steam Properties…", systemImage: "slider.horizontal.3") { Task { await store.perform(.properties, on: title) } }
                if case .running? = store.launchStates[title.id] {
                    Button("Stop", systemImage: "stop.fill") { Task { await store.stop(title) } }
                }
                Divider()
                Button("Uninstall…", systemImage: "trash", role: .destructive) { Task { await store.perform(.uninstall, on: title) } }
            }
        }
    }
}

/// The main action. Red Play only when an installed, launchable copy and a ready engine exist.
struct PlayButton: View {
    let title: Title
    @Environment(LibraryStore.self) private var store

    var body: some View {
        switch store.action(for: title) {
        case .openNative(let app):
            Button {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
            } label: {
                Label("Open the launcher", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryActionStyle())
        case .install(let bottle):
            Button {
                Task { await store.requestInstall(title) }
            } label: {
                Label("Install in “\(bottle)”", systemImage: "arrow.down.circle")
            }
            .buttonStyle(SecondaryActionStyle())
            .disabled(store.launchStates[title.id] == .installRequested)
        case .downloading(let fraction):
            HStack(spacing: 10) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 140)
                    Text("Downloading in Steam… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Downloading in Steam…")
                }
            }
            .font(.callout)
        case .play, .unavailable:
            let state = store.launchStates[title.id]
            Button {
                if state?.isInProgress == true || state.isRunning {
                    store.presentedLaunch = title.id
                } else {
                    Task { await store.launch(title) }
                }
            } label: {
                switch state {
                case .preparing, .checkingBottle, .startingSteam, .startingProcess, .waitingForGame:
                    HStack(spacing: 8) { ProgressView().controlSize(.small).tint(.white); Text("Starting…") }
                case .running:
                    Label("Running", systemImage: "play.circle.fill")
                default:
                    Label("Play", systemImage: "play.fill")
                }
            }
            .buttonStyle(PrimaryActionStyle())
            // While starting or running, the button reopens the launch screen instead of launching twice.
            .disabled(store.action(for: title) != .play)
            if state.isRunning {
                Button {
                    Task { await store.stop(title) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(SecondaryActionStyle())
                .help("Closes every process of this title, and forces those that don't close within 8 seconds.")
            }
        }
    }
}

extension LibraryStore.LaunchState? {
    var isBusy: Bool { self?.isInProgress == true || isRunning }
    var isRunning: Bool { if case .running? = self { true } else { false } }
}

/// One honest line under the action row: why Play is (un)available, or what was actually observed.
struct PlayStatus: View {
    let title: Title
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if let caption {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(caption).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol)
                }
                .font(.callout)
                .foregroundStyle(isError ? Compatibility.issues.tint : (isRunning ? Compatibility.great.tint : Theme.textSecondary))
                if let log {
                    Button {
                        NSWorkspace.shared.open(URL(filePath: log))
                    } label: {
                        Label("Show Wine log", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private var isError: Bool {
        switch store.launchStates[title.id] {
        case .failed?, .notStarted?, .crashedAtStart?, .blocked?: true
        default: false
        }
    }

    private var isRunning: Bool {
        if case .running? = store.launchStates[title.id] { true } else { false }
    }

    private var symbol: String {
        isError ? "exclamationmark.triangle.fill" : (isRunning ? "checkmark.circle.fill" : "info.circle")
    }

    private var log: String? {
        switch store.launchStates[title.id] {
        case .failed(_, let log)?, .notStarted(let log)?, .crashedAtStart(_, let log)?: log
        default: nil
        }
    }

    private var caption: LocalizedStringKey? {
        switch store.launchStates[title.id] {
        case .failed(let message, _): return "Couldn't start: \(message)"
        case .blocked(let problem): return problem.message
        case .preparing, .checkingBottle: return "Checking the bottle…"
        case .startingSteam: return "Starting Steam for Windows in the bottle…"
        case .startingProcess: return "Starting the program in Wine…"
        case .cancelled: return "MacHub stopped waiting. If the title still starts, it opens normally."
        case .notStarted: return "No process of the game appeared within 3 minutes. The Wine log may explain why."
        case .waitingForGame: return "Steam received the launch request. MacHub is watching for the game's own process…"
        case .running(let exe?): return "Running: macOS sees \(exe) from the game's folder."
        case .running(nil): return "Running."
        case .closed: return "The game has closed."
        case .crashedAtStart(let seconds, _): return "The game started, then closed after \(seconds) s: it most likely crashed at startup. See the requirements and the Wine log."
        case .installRequested: return "Steam for Windows was asked to install this game. Confirm the install in Steam's window; MacHub follows the download."
        case .exited(let code): return "The program closed (exit code \(code))."
        case nil: break
        }
        if let appID = title.steamAppID, let state = store.steamUpdates[appID] {
            if state.isUninstalling { return "Steam is uninstalling this game…" }
            if state.isValidating { return "Steam is verifying the game's files…" }
            if state.isUpdating { return "Steam is updating this game. Play starts it once the update is done." }
            if state.needsUpdate { return "An update is available. Steam applies it at the next launch, or choose Update Now in the … menu." }
        }
        if title.isDemo { return "Demo title. It can't be installed or launched." }
        if title.nativeApp != nil { return "Native Mac game: it runs in its own launcher, without Wine." }
        if title.id == ModSupport.minecraftTitleID { return "The Minecraft Launcher isn't installed in Applications." }
        if title.macAvailable == true, title.install == nil { return "A native macOS version exists on Steam: use Steam for Mac rather than Wine." }
        if !store.canRunWindows { return "MacHub's Windows engine isn't ready. See Settings › Windows Engine." }
        if let install = title.install, install.executables.isEmpty { return "Installed, but no Windows executable was found in its folder." }
        if title.install != nil, title.steamAppID.flatMap({ store.estimates[$0] })?.verdict ?? .unknown == .unknown {
            return "Compatibility not verified: it may or may not run on Mac."
        }
        if title.kind == .game, store.steamBottle == nil { return "To play, set up Steam for Windows in Settings › Windows Engine." }
        if title.owned == nil { return "Not in your Steam library. Buy or add it on Steam first." }
        return nil
    }
}

/// Store / owned / installed, always shown on real titles.
struct AvailabilityBadge: View {
    let title: Title
    var compact = false

    var body: some View {
        let (label, symbol, fill, ink): (LocalizedStringKey, String, Color, Color) = switch title.availability {
        case .installed: ("Installed", "shippingbox.fill", Theme.textPrimary, Theme.ground)
        case .owned: ("Owned", "checkmark.circle", Theme.surfaceRaised, Theme.textPrimary)
        case .store: ("On Steam", "cart", .clear, Theme.textSecondary)
        }
        Label { Text(label) } icon: { Image(systemName: symbol) }
            .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .background(fill, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: title.availability == .store ? 1 : 0))
            .help(title.bottle.map { Text("Installed in bottle “\($0)”") } ?? Text(label))
    }
}

// MARK: - Cards

enum CardStyle {
    case landscape, portrait

    var size: CGSize {
        switch self {
        case .landscape: CGSize(width: 296, height: 138)
        case .portrait: CGSize(width: 176, height: 264)
        }
    }

    var artwork: Artwork { self == .landscape ? .header : .cover }
}

struct TitleCard: View {
    let title: Title
    let style: CardStyle
    var width: CGFloat?

    var body: some View {
        let size = style.size
        let w = width ?? size.width
        VStack(alignment: .leading, spacing: 10) {
            ArtworkImage(title: title, artwork: style.artwork)
                .frame(width: w, height: w * size.height / size.width)
                .clipShape(.rect(cornerRadius: Theme.cardRadius))
                .overlay(alignment: .bottomLeading) {
                    if !title.isDemo, title.nativeApp == nil, let appID = title.steamAppID { EstimatePill(appID: appID) }
                }
                .overlay(alignment: .topTrailing) {
                    if title.isDemo {
                        Image(systemName: "flask.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .floatingGlass(cornerRadius: 12)
                            .padding(8)
                            .help(Text("Sample content. Not installed and not launchable."))
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title.name)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if title.isDemo {
                    CompatibilityBadge(compatibility: title.compatibility, compact: true, isDemo: true)
                } else {
                    AvailabilityBadge(title: title, compact: true)
                }
            }
            .frame(width: w, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: title.name))
        .accessibilityValue(title.isDemo ? Text(title.compatibility.label) : Text(verbatim: ""))
    }
}

/// Lift on hover, white ring on keyboard focus (TV-style), dims while pressed.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let lifted = (hovering || isFocused) && !reduceMotion
            configuration.label
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: Theme.cardRadius + 3)
                        .strokeBorder(.white, lineWidth: isFocused ? 3 : 0)
                        .padding(-5)
                        .allowsHitTesting(false)
                }
                .scaleEffect(lifted ? 1.035 : 1, anchor: .bottom)
                .shadow(color: .black.opacity(lifted ? 0.55 : 0), radius: 18, y: 10)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: lifted)
                .onHover { hovering = $0 }
        }
    }
}
