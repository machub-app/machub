import SwiftUI

/// Screening-room palette: a dark theatre where artwork carries the colour.
enum Theme {
    static let ground = Color(red: 0.043, green: 0.043, blue: 0.051)          // #0B0B0D
    static let surface = Color.white.opacity(0.06)
    static let surfaceRaised = Color.white.opacity(0.10)
    static let stroke = Color.white.opacity(0.10)
    static let textPrimary = Color(white: 0.96)
    static let textSecondary = Color(white: 0.66)                               // ≈ 8:1 on ground
    /// The projector red: only Play and "running" states use it.
    static let play = Color(red: 0.898, green: 0.035, blue: 0.078)             // #E50914

    static let gutter: CGFloat = 44
    static let cardRadius: CGFloat = 10

    static func titleFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy).width(.expanded)
    }
}

extension Compatibility {
    var label: LocalizedStringKey {
        switch self {
        case .great: "Runs great"
        case .playable: "Playable"
        case .issues: "Known issues"
        case .unsupported: "Won't run"
        case .unknown: "Not verified"
        }
    }

    var symbol: String {
        switch self {
        case .great: "checkmark.seal.fill"
        case .playable: "checkmark.circle.fill"
        case .issues: "exclamationmark.triangle.fill"
        case .unsupported: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .great: Color(red: 0.19, green: 0.82, blue: 0.35)
        case .playable: Color(red: 1.0, green: 0.84, blue: 0.04)
        case .issues: Color(red: 1.0, green: 0.62, blue: 0.04)
        case .unsupported: Color(red: 1.0, green: 0.27, blue: 0.23)
        case .unknown: Theme.textSecondary
        }
    }
}

extension View {
    /// Liquid Glass on macOS 26, a system material before it. Used only for controls floating over artwork.
    @ViewBuilder
    func floatingGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}
