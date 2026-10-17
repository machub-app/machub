import Foundation

struct BottleInfo: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String?
    let windowsVersion: String?
    /// Listed in the container's BottleVM.plist, i.e. visible to Whisky and WhiskyCmd.
    let isRegistered: Bool
    /// A Wine prefix has actually been created.
    let hasDriveC: Bool
    var id: URL { url }
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
                    hasDriveC: fm.fileExists(atPath: url.appending(path: "drive_c").path)
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

    private static func metadata(at bottle: URL) -> (name: String?, windowsVersion: String?) {
        let plist = dictionary(at: bottle.appending(path: "Metadata.plist"))
        let name = (plist?["info"] as? [String: Any])?["name"] as? String
        let windows = (plist?["wineConfig"] as? [String: Any])?["windowsVersion"] as? String
        return (name, windows)
    }

    private static func dictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
