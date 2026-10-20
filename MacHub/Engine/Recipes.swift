import Foundation

/// highball-db's recipes (CC0): declarative fixes for a game, a launcher or a Windows component, e.g. Visual C++
/// runtimes, registry keys, environment variables, notes. MacHub reads them from the repository and applies the steps
/// it understands in the title's Windows environment; the others (winetricks, engine pins) are listed for the user to
/// do by hand, never skipped silently. Paths in recipes are relative to the prefix's C: drive.
struct Recipe: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    /// game · tweak · launcher
    let kind: String
    let requires: [String]
    let renderer: String?
    let steps: [Step]

    enum Step: Equatable, Sendable {
        case note(String)
        case environment(name: String, value: String)
        case registry(key: String, name: String, valueType: String, data: String)
        case installer(url: URL, sha256: String, arguments: [String], label: String, msi: Bool, slow: String?)
        /// `name=native,builtin`, or `name=` to disable a DLL.
        case dllOverride(String)
        case winver(String)
        case renderer(String)
        case sync(String)
        case file(path: String, contents: String)
        case dxvkConfig(exe: String, options: [String: String])
        /// `from` is relative to the engine (`engine/lib/wine/…`), `to` to the C: drive.
        case copy(from: String, to: String, asNative: Bool)
        case manual(type: String, summary: String)
    }
}

enum Recipes {
    static let raw = URL(string: "https://raw.githubusercontent.com/gauthierpiarrette/highball-db/main/recipes/")!
    /// Windows components offered for every environment (Settings › Windows Environments).
    static let components = ["vcrun2022", "corefonts", "xact", "dotnet48"]
    /// Recipes MacHub already covers itself (it installs and runs Steam for Windows).
    static let builtIn: Set<String> = ["steam"]

    /// A recipe by id: games/<id>.json, else tweaks/<id>.json, else launchers/<id>.json (cached a day).
    static func fetch(_ id: String, http: SteamHTTP = .shared) async -> Recipe? {
        for folder in ["games", "tweaks", "launchers"] {
            if let data = try? await http.get(raw.appending(path: "\(folder)/\(id).json"), ttl: 24 * 3600).data,
               let recipe = parse(data) {
                return recipe
            }
        }
        return nil
    }

    static func parse(_ data: Data) -> Recipe? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else { return nil }
        let steps = (json["steps"] as? [[String: Any]] ?? []).map(step)
        return Recipe(id: id, title: json["title"] as? String ?? id, kind: json["kind"] as? String ?? "",
                      requires: json["requires"] as? [String] ?? [], renderer: json["renderer"] as? String, steps: steps)
    }

    static func step(_ s: [String: Any]) -> Recipe.Step {
        let type = s["type"] as? String ?? "?"
        func string(_ key: String) -> String? {
            if let value = s[key] as? String { return value }
            if let value = s[key] as? NSNumber { return value.stringValue }
            return nil
        }
        switch type {
        case "note":
            return .note(string("text") ?? "")
        case "environment":
            if let name = string("name"), let value = string("value") { return .environment(name: name, value: value) }
        case "registry":
            if let key = string("key"), let name = string("name") {
                return .registry(key: key, name: name, valueType: string("valueType") ?? "REG_SZ", data: string("data") ?? "")
            }
        case "installer":
            if let url = string("url").flatMap(URL.init(string:)), let sha = string("sha256") {
                return .installer(url: url, sha256: sha.lowercased(), arguments: s["arguments"] as? [String] ?? [],
                                  label: string("label") ?? url.lastPathComponent, msi: s["msi"] as? Bool ?? false, slow: string("slow"))
            }
        case "dlloverride":
            if let value = string("value") { return .dllOverride(value) }
        case "winver":
            if let version = string("winver") { return .winver(version) }
        case "renderer":
            if let renderer = string("renderer") { return .renderer(renderer) }
        case "sync":
            if let sync = string("sync") { return .sync(sync) }
        case "file":
            if let path = string("path"), let contents = string("contents") { return .file(path: path, contents: contents) }
        case "dxvkconfig":
            if let exe = string("exe") {
                let options = (s["options"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
                return .dxvkConfig(exe: exe, options: options)
            }
        case "copy":
            if let from = string("from"), let to = string("to") { return .copy(from: from, to: to, asNative: s["asNative"] as? Bool ?? false) }
        case "winetricks":
            let verbs = (s["verbs"] as? [String] ?? []).joined(separator: " ")
            return .manual(type: type, summary: String(localized: "Run winetricks \(verbs) in this environment (MacHub doesn't include winetricks)."))
        case "pin":
            return .manual(type: type, summary: String(localized: "Highball pins a launcher here; in MacHub, add the program from Software instead."))
        default:
            break
        }
        return .manual(type: type, summary: String(localized: "Step “\(type)” isn't supported by MacHub yet."))
    }

    /// A .reg document for registry and DLL-override steps. `HKCU`/`HKLM` become their full names.
    static func registryDocument(_ steps: [Recipe.Step]) -> String? {
        var lines: [String] = []
        var current: String?
        func open(_ key: String) {
            let full = key.replacingOccurrences(of: #"^HKCU\\"#, with: #"HKEY_CURRENT_USER\\"#, options: .regularExpression)
                .replacingOccurrences(of: #"^HKLM\\"#, with: #"HKEY_LOCAL_MACHINE\\"#, options: .regularExpression)
            if current != full { lines.append(""); lines.append("[\(full)]"); current = full }
        }
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        for step in steps {
            switch step {
            case .registry(let key, let name, let type, let data):
                open(key)
                let label = name.isEmpty || name == "@" ? "@" : quoted(name)
                switch type.uppercased() {
                case "REG_DWORD":
                    let value = data.hasPrefix("0x") ? UInt32(data.dropFirst(2), radix: 16) : UInt32(data)
                    lines.append("\(label)=dword:\(String(format: "%08x", value ?? 0))")
                default:
                    lines.append("\(label)=\(quoted(data))")
                }
            case .dllOverride(let value):
                let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard let name = parts.first, !name.isEmpty else { continue }
                open(#"HKCU\Software\Wine\DllOverrides"#)
                lines.append("\(quoted(name))=\(quoted(parts.count > 1 ? parts[1] : ""))")
            default:
                continue
            }
        }
        return lines.isEmpty ? nil : "Windows Registry Editor Version 5.00\n" + lines.joined(separator: "\n") + "\n"
    }

    /// Environment variables a recipe asks for, including its sync choice (MacHub's engine has esync, not msync).
    static func environment(of steps: [Recipe.Step]) -> [String: String] {
        var env: [String: String] = [:]
        for step in steps {
            switch step {
            case .environment(let name, let value): env[name] = value
            case .sync(let sync):
                switch sync {
                case "none": env["WINEESYNC"] = "0"; env["WINEMSYNC"] = "0"
                default: env["WINEESYNC"] = "1"
                }
            default: continue
            }
        }
        return env
    }
}

/// What applying a recipe did, step by step, in words the user can read.
struct RecipeOutcome: Equatable, Sendable {
    var applied: [String] = []
    var manual: [String] = []
    var notes: [String] = []
    /// Variables the game must be started with (kept in its TitleSettings).
    var environment: [String: String] = [:]
    var failure: String?
}

/// Applies recipe steps in one prefix. Every download is checked against the recipe's SHA-256 before it runs.
struct RecipeRunner {
    let runtime: WineRuntime
    let prefix: InstalledPrefix
    /// The game's install folder, for steps that write next to its executable (dxvk.conf).
    var installFolder: URL?
    var progress: @Sendable (String) -> Void = { _ in }

    var driveC: URL { prefix.url.appending(path: "drive_c") }

    func apply(_ recipe: Recipe, into outcome: inout RecipeOutcome) async {
        let env = WineEnvironment(runtime: runtime, prefix: prefix).variables
        if let document = Recipes.registryDocument(recipe.steps) {
            progress(String(localized: "Writing registry settings…"))
            let file = driveC.appending(path: "users/Public/machub-recipe-\(recipe.id).reg")
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try document.write(to: file, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: file) }
                let result = try await ProcessRunner.run(runtime.wine, ["regedit", "/S", file.path], timeout: 120, environment: env)
                guard result.status == 0 else { outcome.failure = "regedit: \(result.stderr.suffix(200))"; return }
                outcome.applied.append(String(localized: "Registry settings"))
            } catch {
                outcome.failure = error.localizedDescription
                return
            }
        }
        outcome.environment.merge(Recipes.environment(of: recipe.steps)) { _, new in new }
        for step in recipe.steps {
            switch step {
            case .note(let text):
                outcome.notes.append(text)
            case .installer(let url, let sha, let arguments, let label, let msi, _):
                progress(String(localized: "Installing \(label)…"))
                do {
                    try await install(url: url, sha256: sha, arguments: arguments, msi: msi, env: env)
                    outcome.applied.append(label)
                } catch {
                    outcome.failure = String(localized: "\(label): \(error.localizedDescription)")
                    return
                }
            case .winver(let version):
                _ = try? await ProcessRunner.run(runtime.wine, ["winecfg", "-v", version], timeout: 120, environment: env)
                outcome.applied.append(String(localized: "Windows version: \(version)"))
            case .file(let path, let contents):
                let target = driveC.appending(path: path)
                do {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try contents.write(to: target, atomically: true, encoding: .utf8)
                    outcome.applied.append(target.lastPathComponent)
                } catch { outcome.failure = error.localizedDescription; return }
            case .dxvkConfig(let exe, let options):
                if let folder = executableFolder(named: exe) {
                    let lines = options.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
                    try? (lines.joined(separator: "\n") + "\n").write(to: folder.appending(path: "dxvk.conf"), atomically: true, encoding: .utf8)
                    outcome.applied.append("dxvk.conf")
                } else {
                    outcome.manual.append(String(localized: "Write dxvk.conf next to \(exe) (not found in the game's folder)."))
                }
            case .copy(let from, let to, let asNative):
                let source = runtime.root.appending(path: from.hasPrefix("engine/") ? "wine/" + from.dropFirst("engine/".count) : from)
                let target = driveC.appending(path: to)
                do {
                    var data = try Data(contentsOf: source)
                    if asNative { GraphicsDeployment.stripBuiltinMarker(&data) }
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target)
                    outcome.applied.append(target.lastPathComponent)
                } catch {
                    outcome.manual.append(String(localized: "Copy \(from) to C:\\\(to)."))
                }
            case .manual(_, let summary):
                outcome.manual.append(summary)
            case .registry, .dllOverride, .environment, .sync, .renderer:
                continue   // registry written above; environment kept for launches; renderer comes from highball-db
            }
        }
    }

    private func install(url: URL, sha256: String, arguments: [String], msi: Bool, env: [String: String]) async throws {
        let folder = driveC.appending(path: "users/Public/MacHub Downloads")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: url.lastPathComponent.isEmpty ? "installer.exe" : url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: file.path) {
            let (download, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RecipeError.download(url.host() ?? "") }
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: download, to: file)
        }
        let digest = try await RuntimeManager.sha256(of: file)
        guard digest == sha256 else {
            try? FileManager.default.removeItem(at: file)
            throw RecipeError.checksum
        }
        let command = msi ? ["msiexec", "/i", file.path] : [file.path]
        let result = try await ProcessRunner.run(runtime.wine, command + arguments, timeout: 3600, environment: env)
        // Visual C++ returns 1638 when a newer version is already there, 3010 when a reboot would be needed.
        guard [0, 1638, 3010].contains(result.status) else { throw RecipeError.installer(Int(result.status)) }
        _ = try? await ProcessRunner.run(runtime.wineserver, ["-w"], timeout: 120, environment: env)
    }

    private func executableFolder(named exe: String) -> URL? {
        guard let installFolder,
              let walker = FileManager.default.enumerator(at: installFolder, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent.caseInsensitiveCompare(exe) == .orderedSame {
            return url.deletingLastPathComponent()
        }
        return nil
    }
}

enum RecipeError: LocalizedError {
    case download(String)
    case checksum
    case installer(Int)

    var errorDescription: String? {
        switch self {
        case .download(let host): String(localized: "The download from \(host) failed.")
        case .checksum: String(localized: "The download doesn't match the recipe's SHA-256, so it wasn't run.")
        case .installer(let code): String(localized: "The installer stopped with code \(code).")
        }
    }
}

/// Recipes applied per Windows environment, so a component isn't installed twice and the game page can say so.
enum AppliedRecipes {
    static let fileName = "recipes-applied.json"

    static func all() -> [String: [String: Date]] { LocalData.load([String: [String: Date]].self, from: fileName) ?? [:] }

    static func date(_ recipe: String, in prefix: InstalledPrefix) -> Date? { all()[prefix.settings.id.uuidString]?[recipe] }

    static func record(_ recipe: String, in prefix: InstalledPrefix) {
        var everything = all()
        everything[prefix.settings.id.uuidString, default: [:]][recipe] = .now
        LocalData.save(everything, to: fileName)
    }
}
