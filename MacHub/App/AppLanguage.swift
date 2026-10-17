import SwiftUI

/// In-app language override. SwiftUI resolves `Text` literals and `LocalizedStringResource`
/// against `\.locale`; `String(localized:)` ignores it, so UI code must not use it.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, fr, ja
    case zhHans = "zh-Hans"

    static let storageKey = "appLanguage"

    var id: String { rawValue }

    var locale: Locale {
        self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue)
    }

    /// Each language names itself (endonym), so it stays findable whatever the current language.
    var label: Text {
        switch self {
        case .system: Text("System")
        case .en: Text(verbatim: "English")
        case .fr: Text(verbatim: "Français")
        case .ja: Text(verbatim: "日本語")
        case .zhHans: Text(verbatim: "简体中文")
        }
    }
}

extension View {
    /// Applies the language at the root; `.id` rebuilds the tree so cached strings re-resolve.
    func appLanguage(_ language: AppLanguage) -> some View {
        environment(\.locale, language.locale).id(language)
    }
}
