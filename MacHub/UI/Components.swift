import SwiftUI

/// Steam artwork for a title. Falls back to a monogram plate when there is no App ID or the image fails.
struct ArtworkImage: View {
    let title: Title
    let artwork: Artwork

    var body: some View {
        Color.clear.overlay {
            if let appID = title.steamAppID {
                AsyncImage(url: artwork.url(appID: appID), transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                    case .failure: MonogramPlate(title: title)
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
            CompatibilityBadge(compatibility: title.compatibility, isDemo: title.isDemo)
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

/// Play / launch control. Disabled unless a real Whisky install exists; `PlayStatus` explains why.
struct PlayButton: View {
    let title: Title
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Button {
            Task { await store.launch(title) }
        } label: {
            switch store.launchStates[title.id] {
            case .launching:
                HStack(spacing: 8) { ProgressView().controlSize(.small).tint(.white); Text("Starting…") }
            case .handedToSteam:
                Label("Sent to Steam", systemImage: "checkmark")
            default:
                Label("Play", systemImage: "play.fill")
            }
        }
        .buttonStyle(PrimaryActionStyle())
        .disabled(!title.canLaunch || store.launchStates[title.id] == .launching)
    }
}

/// One honest line under the action row: demo, not supported yet, handed to Steam, or the failure.
struct PlayStatus: View {
    let title: Title
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if let caption {
            Label {
                Text(caption).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
            }
            .font(.callout)
            .foregroundStyle(isError ? Compatibility.issues.tint : Theme.textSecondary)
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    private var isError: Bool {
        if case .failed = store.launchStates[title.id] { true } else { false }
    }

    private var caption: LocalizedStringKey? {
        switch store.launchStates[title.id] {
        case .failed(let message): "Couldn't start: \(message)"
        case .handedToSteam: "Steam received the launch request. MacHub doesn't check yet whether the game window opened."
        case .launching: nil
        case nil:
            if title.isDemo { "Demo title. Install it in a Whisky bottle to play." }
            else if title.kind == .software { "Launching Windows software comes in a later step." }
            else { nil }
        }
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
                .overlay(alignment: .topLeading) {
                    if !title.isDemo, let bottle = title.bottle {
                        Label(bottle, systemImage: "shippingbox.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .floatingGlass(cornerRadius: 6)
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title.name)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                CompatibilityBadge(compatibility: title.compatibility, compact: true, isDemo: title.isDemo)
            }
            .frame(width: w, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: title.name))
        .accessibilityValue(Text(title.compatibility.label))
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
