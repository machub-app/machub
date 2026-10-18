import Foundation

/// MacHub's own small files in Application Support: imported programs and launch history.
enum LocalData {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "app.machub.MacHub")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String, in directory: URL = directory) -> T? {
        (try? Data(contentsOf: directory.appending(path: name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func save(_ value: some Encodable, to name: String, in directory: URL = directory) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(value).write(to: directory.appending(path: name), options: .atomic)
    }
}

/// A Windows program the user added by hand. Launched through `whisky run <bottle> <path>`.
struct ImportedProgram: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var bottle: String

    var title: Title {
        var t = Title(id: "software:\(id.uuidString)", name: name, kind: .software, steamAppID: nil)
        t.install = Title.Install(bottle: bottle, path: path, executables: [URL(filePath: path).lastPathComponent])
        return t
    }
}

/// Programs pinned inside Whisky (a bottle's Metadata.plist `info.pins`). Read-only.
enum WhiskyPins {
    static func titles(in bottle: BottleInfo) -> [Title] {
        guard let name = bottle.name,
              let data = try? Data(contentsOf: bottle.url.appending(path: "Metadata.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let pins = (plist["info"] as? [String: Any])?["pins"] as? [[String: Any]]
        else { return [] }
        return pins.compactMap { pin in
            let raw = (pin["url"] as? String) ?? ((pin["url"] as? [String: Any])?["relative"] as? String)
            guard let raw, let url = raw.hasPrefix("file://") ? URL(string: raw) : URL(filePath: raw) else { return nil }
            var t = Title(id: "pin:\(name):\(url.path)", name: (pin["name"] as? String) ?? url.deletingPathExtension().lastPathComponent,
                          kind: .software, steamAppID: nil)
            let exists = FileManager.default.fileExists(atPath: url.path)
            t.install = Title.Install(bottle: name, path: url.path, executables: exists ? [url.lastPathComponent] : [])
            return t
        }
    }
}
