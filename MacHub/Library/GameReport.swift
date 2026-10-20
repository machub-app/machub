import Foundation

/// A compatibility report about one session, pre-filled from what MacHub knows (Mac, macOS, engine, renderer,
/// session length, frame rate) so the player only adds a rating and a line. Nothing is sent by MacHub: the report
/// opens as a pre-filled GitHub issue in the browser, where the player reviews and submits it with their own account.
struct GameReport: Equatable, Identifiable, Sendable {
    var id: String { titleID }
    let titleID: String
    let titleName: String
    let steamAppID: Int?
    var rating = 4
    var issues = ""
    var notes = ""
    var renderer: String?
    var minutes: Int?
    var averageFPS: Int?
    var launchOptions: String?
    var environment: [String: String] = [:]
    var engine: String?
    var chip = GameReport.chipName()
    var macOS = GameReport.macOSVersion()
    var app = "MacHub \(AppUpdates.currentVersion)"
    /// The launch ended within seconds: a crash at start rather than a played session.
    var crashedAtStart = false

    static let ratings = [
        5: "5 — perfect",
        4: "4 — playable, minor issues",
        3: "3 — playable with workarounds",
        2: "2 — launches, not playable",
        1: "1 — does not launch",
    ]

    /// highball-db's report form (CC0 database), filled through GitHub's issue-form query parameters.
    var highballURL: URL {
        var components = URLComponents(string: "https://github.com/gauthierpiarrette/highball-db/issues/new")!
        var items: [URLQueryItem] = [
            .init(name: "template", value: "report.yml"),
            .init(name: "labels", value: "report"),
            // `title` is both the issue's title and the form's "Game or launcher" field: the game's name fits both.
            .init(name: "rating", value: Self.ratings[rating]),
            .init(name: "chip", value: chip),
            .init(name: "macos", value: macOS),
            .init(name: "version", value: app),
        ]
        if let steamAppID { items.append(.init(name: "steam_appid", value: String(steamAppID))) }
        items.append(.init(name: "title", value: titleName))
        if !issues.isEmpty { items.append(.init(name: "issues", value: issues)) }
        if let renderer { items.append(.init(name: "renderer", value: renderer)) }
        if let engine { items.append(.init(name: "engine", value: engine)) }
        if !settingsText.isEmpty { items.append(.init(name: "settings", value: settingsText)) }
        items.append(.init(name: "session", value: sessionText))
        items.append(.init(name: "notes", value: notesText))
        components.queryItems = items
        return components.url!
    }

    /// MacHub's own "Game report" form, for results that concern MacHub rather than the game.
    var macHubURL: URL {
        var components = URLComponents(string: "https://github.com/machub-app/machub/issues/new")!
        let result = switch rating {
        case 5: "Plays well"
        case 3, 4: "Plays with issues"
        case 2: "Starts but can't play"
        default: "Doesn't start"
        }
        components.queryItems = [
            .init(name: "template", value: "game-report.yml"),
            .init(name: "title", value: "[Game] \(titleName)"),
            .init(name: "game", value: titleName),
            .init(name: "result", value: result),
            .init(name: "graphics", value: renderer.map(Self.graphicsLabel) ?? "Don't know"),
            .init(name: "mac", value: "\(chip), macOS \(macOS)"),
            .init(name: "engine", value: [app, engine].compactMap { $0 }.joined(separator: ", ")),
            .init(name: "notes", value: [issues, notesText].filter { !$0.isEmpty }.joined(separator: "\n\n")),
        ]
        return components.url!
    }

    var sessionText: String {
        if crashedAtStart { return "Closed within seconds of starting, launched from MacHub." }
        guard let minutes else { return "Launched from MacHub." }
        return "Played for \(minutes) min through MacHub."
    }

    var notesText: String {
        var lines: [String] = []
        if !notes.isEmpty { lines.append(notes) }
        if let averageFPS { lines.append("Average \(averageFPS) fps (Metal HUD log).") }
        lines.append("Engine: MacHub's Wine 11.0 build (WineHQ sources + patches), DXMT 0.80, DXVK 1.10.3, under Rosetta 2.")
        return lines.joined(separator: "\n")
    }

    var settingsText: String {
        var lines: [String] = []
        if let launchOptions, !launchOptions.isEmpty { lines.append("Launch options: \(launchOptions)") }
        lines += environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return lines.joined(separator: "\n")
    }

    static func graphicsLabel(_ renderer: String) -> String {
        switch renderer {
        case "dxmt": "DXMT"
        case "dxvk": "DXVK"
        case "wined3d": "Wine (OpenGL)"
        case "d3dmetal": "D3DMetal"
        default: "Automatic"
        }
    }

    static func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
