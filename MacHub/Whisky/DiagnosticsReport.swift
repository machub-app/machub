import Foundation

struct ContainerReport: Identifiable, Equatable, Sendable {
    let bundleID: String
    let url: URL
    let exists: Bool
    let bottles: [BottleInfo]
    var id: String { bundleID }
}

/// Snapshot of the Whisky environment, shown in the app and printed by `MacHub --diagnose`.
struct DiagnosticsReport: Equatable, Sendable {
    /// The fork first; the archived original is listed so its bottles stay visible (read-only).
    static let containerIDs = [WhiskyLocator.forkBundleID, "com.isaacmarovitz.Whisky"]

    let status: WhiskyStatus
    let librariesPresent: Bool?
    let containers: [ContainerReport]

    static func make(customPath: String?, locator: WhiskyLocator = .live) async -> DiagnosticsReport {
        let status = await locator.locate(customPath: customPath)
        let containers = containerIDs.map { id in
            let url = BottleReader.containerURL(bundleID: id)
            let exists = FileManager.default.fileExists(atPath: url.path)
            return ContainerReport(bundleID: id, url: url, exists: exists, bottles: exists ? BottleReader.read(container: url) : [])
        }
        // Only a folder-presence hint: the exact Wine binary path is confirmed after the fork is installed.
        var libraries: Bool?
        if case .ready(let install) = status, let id = install.bundleIdentifier {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/\(id)/Libraries")
            libraries = FileManager.default.fileExists(atPath: dir.path)
        }
        return DiagnosticsReport(status: status, librariesPresent: libraries, containers: containers)
    }

    var text: String {
        var lines = ["MacHub diagnostics"]
        switch status {
        case .ready(let i):
            lines.append("Whisky: ready — \(Self.describe(i))")
        case .outdated(let i, let missing):
            lines.append("Whisky: too old — \(Self.describe(i)); missing commands: \(missing.joined(separator: ", "))")
        case .notFound(let searched):
            lines.append("Whisky: not found. Searched: \(searched.map(\.path).joined(separator: ", "))")
        case .invalidCustomPath(let url, let reason):
            lines.append("Whisky: custom path \(url.path) is unusable. \(reason)")
        }
        if let librariesPresent {
            lines.append("Wine Libraries folder: \(librariesPresent ? "present" : "missing")")
        }
        for c in containers {
            guard c.exists else {
                lines.append("\(c.bundleID): no container")
                continue
            }
            let registered = c.bottles.filter(\.isRegistered).count
            lines.append("\(c.bundleID): \(c.bottles.count) bottle folder(s), \(registered) registered")
            for b in c.bottles {
                let flags = [b.isRegistered ? "registered" : "orphan", b.hasDriveC ? "drive_c" : "no drive_c"]
                lines.append("  - \(b.name ?? "?") [\(b.windowsVersion ?? "?")] \(flags.joined(separator: ", ")) — \(b.url.lastPathComponent)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ i: WhiskyInstall) -> String {
        let app = i.appURL.map { "\($0.lastPathComponent) \(i.version ?? "?") (\(i.bundleIdentifier ?? "?"))" } ?? "standalone"
        return "\(app), cmd \(i.cmdURL.path), commands: \(i.subcommands.sorted().joined(separator: " "))"
    }
}
