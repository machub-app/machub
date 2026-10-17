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

    var body: some Scene {
        WindowGroup {
            DiagnosticsView()
                .frame(minWidth: 640, minHeight: 480)
                .appLanguage(language)
        }
    }
}
