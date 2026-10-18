import SwiftUI

@main
enum Main {
    /// `MacHub --diagnose` prints the environment report and exits without opening a window.
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--diagnose") {
            let report = await DiagnosticsReport.make(customPath: UserDefaults.standard.string(forKey: "whiskyCmdPath"))
            print(report.text)
            exit(0)
        }
        MacHubApp.main()
    }
}

struct MacHubApp: App {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system
    @State private var navigation = AppNavigation()

    init() {
        // Steam artwork is large and reused across rows, hero and backdrop: keep it on disk between launches.
        URLCache.shared = URLCache(memoryCapacity: 128 << 20, diskCapacity: 1 << 30)
    }

    var body: some Scene {
        WindowGroup {
            // Dark by use scene: played in the evening, artwork-first, like a TV app; light would wash the art out.
            RootView(navigation: navigation)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
                .appLanguage(language)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { navigation.selection = .settings }
                    .keyboardShortcut(",")
            }
            CommandMenu("Go") {
                Button("Home") { navigation.selection = .home }.keyboardShortcut("1")
                Button("Discover") { navigation.selection = .discover }.keyboardShortcut("2")
                Button("Library") { navigation.selection = .library }.keyboardShortcut("3")
                Button("Software") { navigation.selection = .software }.keyboardShortcut("4")
                Divider()
                Button("Find…") { navigation.searchFocusRequest += 1 }.keyboardShortcut("f")
            }
        }
    }
}
