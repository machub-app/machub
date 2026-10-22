import AppKit

/// Steam for Mac, for games that have a native macOS build. MacHub reads its library (same VDF/ACF files as the
/// Windows client, with plain Unix paths) and hands play, install and store requests to it through `steam://` links:
/// Steam for Mac downloads, updates and starts those games itself, with no Wine involved.
enum MacSteam {
    static let bundleID = "com.valvesoftware.steam"
    static let downloadPage = URL(string: "https://store.steampowered.com/about/")!

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Steam")
    }

    /// Steam.app, wherever Launch Services knows it (usually /Applications).
    static var app: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// The main Steam folder plus every library listed in `libraryfolders.vdf` that is on disk now.
    static func libraryFolders(root: URL, fileManager: FileManager = .default) -> [URL] {
        var folders = [root]
        if let text = try? String(contentsOf: root.appending(path: "steamapps/libraryfolders.vdf"), encoding: .utf8),
           let vdf = try? VDF.parse(text), let list = vdf.child("libraryfolders") {
            for key in list.order {
                guard let path = list.child(key)?["path"], !path.isEmpty else { continue }
                let url = URL(filePath: path, directoryHint: .isDirectory)
                if folders.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) { continue }
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { folders.append(url) }
            }
        }
        return folders
    }

    /// Every app with a manifest in Steam for Mac's libraries, installed or downloading.
    static func apps(root: URL = root, fileManager: FileManager = .default) -> [SteamApp] {
        var seen = Set<Int>()
        return libraryFolders(root: root, fileManager: fileManager).flatMap { library -> [SteamApp] in
            let steamapps = library.appending(path: "steamapps")
            let files = (try? fileManager.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { SteamLibrary.app(manifest: $0, steamapps: steamapps) }
        }
        .filter { !SteamLibrary.ignoredAppIDs.contains($0.appID) && seen.insert($0.appID).inserted }
    }

    /// Last time Steam for Mac started the game (`LastPlayed` in its manifest), nil when never.
    static func lastPlayed(appID: Int, root: URL = root) -> Date? {
        for library in libraryFolders(root: root) {
            let manifest = library.appending(path: "steamapps/appmanifest_\(appID).acf")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                  let seconds = (try? VDF.parse(text))?.child("AppState")?["LastPlayed"].flatMap(TimeInterval.init), seconds > 0
            else { continue }
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    /// Waits for the game's own process (anything running from its install folder) for up to 3 minutes, then for it
    /// to be gone for 10 s. Reports `true` when it appears and `false` when it closes.
    static func waitForGameSession(installFolder: URL, report: @escaping @Sendable (Bool) -> Void) async {
        var seen = false
        var goneSince: Date?
        let deadline = Date.now.addingTimeInterval(180)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            let running = !ProcessWatch.runtimeProcesses(under: installFolder).isEmpty
            if running {
                if !seen { seen = true; report(true) }
                goneSince = nil
            } else if seen {
                goneSince = goneSince ?? .now
                if Date.now.timeIntervalSince(goneSince!) >= 10 { report(false); return }
            } else if Date.now > deadline {
                return   // never started (Steam showed an update, a sign-in or an error): leave everything as it is
            }
        }
    }

    /// Any Steam for Mac game still running (its process lives in its install folder).
    static func isAnyGameRunning(in apps: some Sequence<SteamApp>) -> Bool {
        apps.contains { $0.isInstalled && !ProcessWatch.runtimeProcesses(under: URL(filePath: $0.installPath)).isEmpty }
    }

    /// Quits Steam for Mac the normal way (like ⌘Q): it syncs cloud saves before closing.
    @MainActor static func quit() {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
    }

    enum Request {
        case play, install, store, properties, uninstall

        func url(appID: Int) -> URL {
            switch self {
            case .play: URL(string: "steam://rungameid/\(appID)")!
            case .install: URL(string: "steam://install/\(appID)")!
            case .store: URL(string: "steam://store/\(appID)")!
            case .properties: URL(string: "steam://gameproperties/\(appID)")!
            case .uninstall: URL(string: "steam://uninstall/\(appID)")!
            }
        }
    }

    /// Sends a request to Steam for Mac. When Steam isn't running it starts minimized (`-silent`) so only the game,
    /// or Steam's install confirmation, comes forward. Without Steam for Mac, store requests open in the browser.
    @MainActor
    static func open(_ request: Request, appID: Int) async -> Bool {
        guard let app else {
            if request == .store {
                return NSWorkspace.shared.open(URL(string: "https://store.steampowered.com/app/\(appID)")!)
            }
            return NSWorkspace.shared.open(downloadPage)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        if !isRunning { configuration.arguments = ["-silent"] }
        return (try? await NSWorkspace.shared.open([request.url(appID: appID)], withApplicationAt: app, configuration: configuration)) != nil
    }
}
