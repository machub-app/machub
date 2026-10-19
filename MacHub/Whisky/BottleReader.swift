import Foundation

struct BottleInfo: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String?
    let windowsVersion: String?
    /// Listed in the container's BottleVM.plist, i.e. visible to Whisky and WhiskyCmd.
    let isRegistered: Bool
    /// A Wine prefix has actually been created.
    let hasDriveC: Bool
    /// Whisky's "Controller & Input" options for this bottle (frankea fork); nil when the bottle predates them.
    var input: InputSettings? = nil
    /// Whisky bottle, or a prefix of MacHub's own runtime.
    var engine: EngineKind = .whisky
    var id: URL { url }

    /// Each option maps to an SDL variable Whisky sets when it starts Wine for this bottle.
    struct InputSettings: Equatable, Sendable {
        var compatibilityMode = false
        /// SDL_JOYSTICK_HIDAPI=0
        var disableHIDAPI = false
        /// SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1
        var allowBackgroundEvents = false
        /// SDL_GAMECONTROLLER_USE_BUTTON_LABELS=1
        var useButtonLabels = false
        var disableControllerMapping = false

        init(compatibilityMode: Bool = false, disableHIDAPI: Bool = false, allowBackgroundEvents: Bool = false,
             useButtonLabels: Bool = false, disableControllerMapping: Bool = false) {
            self.compatibilityMode = compatibilityMode
            self.disableHIDAPI = disableHIDAPI
            self.allowBackgroundEvents = allowBackgroundEvents
            self.useButtonLabels = useButtonLabels
            self.disableControllerMapping = disableControllerMapping
        }

        init?(plist: [String: Any]?) {
            guard let config = plist?["inputConfig"] as? [String: Any] else { return nil }
            compatibilityMode = config["controllerCompatibilityMode"] as? Bool ?? false
            disableHIDAPI = config["disableHIDAPI"] as? Bool ?? false
            allowBackgroundEvents = config["allowBackgroundEvents"] as? Bool ?? false
            useButtonLabels = config["useButtonLabels"] as? Bool ?? false
            disableControllerMapping = config["disableControllerMapping"] as? Bool ?? false
        }

        var isDefault: Bool { self == InputSettings() }
    }
}

/// Read-only view of a Whisky container. Never writes, moves or deletes anything.
enum BottleReader {
    static func containerURL(bundleID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Containers/\(bundleID)")
    }

    static func read(container: URL) -> [BottleInfo] {
        let fm = FileManager.default
        let registered = registeredPaths(in: container)
        let registeredKeys = Set(registered.map(key))
        let onDisk = ((try? fm.contentsOfDirectory(
            at: container.appending(path: "Bottles"), includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []).filter { fm.fileExists(atPath: $0.appending(path: "Metadata.plist").path) }

        var seen = Set<String>()
        return (registered + onDisk)
            .filter { seen.insert(key($0)).inserted }
            .map { url in
                let meta = metadata(at: url)
                return BottleInfo(
                    url: url,
                    name: meta.name,
                    windowsVersion: meta.windowsVersion,
                    isRegistered: registeredKeys.contains(key(url)),
                    hasDriveC: fm.fileExists(atPath: url.appending(path: "drive_c").path),
                    input: meta.input
                )
            }
            .sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
    }

    /// `paths` in BottleVM.plist holds encoded URLs: either `{relative = "file:///…"}` or plain strings.
    static func registeredPaths(in container: URL) -> [URL] {
        guard let plist = dictionary(at: container.appending(path: "BottleVM.plist")),
              let paths = plist["paths"] as? [Any]
        else { return [] }
        return paths.compactMap { item in
            let string = (item as? String) ?? ((item as? [String: Any])?["relative"] as? String)
            guard let string else { return nil }
            if string.hasPrefix("file://") { return URL(string: string) }
            return URL(filePath: string)
        }
    }

    private static func metadata(at bottle: URL) -> (name: String?, windowsVersion: String?, input: BottleInfo.InputSettings?) {
        let plist = dictionary(at: bottle.appending(path: "Metadata.plist"))
        let name = (plist?["info"] as? [String: Any])?["name"] as? String
        let windows = (plist?["wineConfig"] as? [String: Any])?["windowsVersion"] as? String
        return (name, windows, BottleInfo.InputSettings(plist: plist))
    }

    private static func dictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
