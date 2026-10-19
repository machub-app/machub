import CryptoKit
import Foundation

/// What the app trusts before installing a runtime: produced by `scripts/build-runtime.sh` next to the archive.
struct RuntimeManifest: Codable, Equatable, Sendable {
    let version: String
    let archive: String
    let sha256: String
    let size: Int64
    /// Where the archive is published (a GitHub Release). Nil until the first release exists.
    var url: URL?

    /// The manifest shipped inside the app, if any.
    static var bundled: RuntimeManifest? {
        guard let url = Bundle.main.url(forResource: "runtime-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(RuntimeManifest.self, from: data)
    }
}

/// `runtime.json` at the root of an installed runtime: its version and the upstream components it carries.
struct RuntimeInfo: Codable, Equatable, Sendable {
    struct Component: Codable, Equatable, Sendable {
        let name: String
        let version: String
        let license: String
        let source: String
        let sha256: String
    }

    let version: String
    let components: [Component]

    func component(_ name: String) -> Component? { components.first { $0.name == name } }
}

/// One installed runtime: Wine plus the graphics layers, in its own versioned folder.
struct WineRuntime: Equatable, Sendable {
    let root: URL
    let info: RuntimeInfo

    var version: String { info.version }
    var wine: URL { root.appending(path: "wine/bin/wine") }
    var wineserver: URL { root.appending(path: "wine/bin/wineserver") }
    var dxmt: URL { root.appending(path: "dxmt") }
    var dxvk: URL { root.appending(path: "dxvk") }
    /// MacHub's Steam UI shim (tools/steam-cef-shim), shipped from engine 1.2.2.
    var steamShim: URL { root.appending(path: "shims/x86_64-windows/winmm.dll") }

    /// Reads a runtime folder; nil when it isn't a complete runtime.
    static func load(at root: URL, fileManager: FileManager = .default) -> WineRuntime? {
        guard let data = try? Data(contentsOf: root.appending(path: "runtime.json")),
              let info = try? JSONDecoder().decode(RuntimeInfo.self, from: data)
        else { return nil }
        let runtime = WineRuntime(root: root, info: info)
        guard fileManager.isExecutableFile(atPath: runtime.wine.path),
              fileManager.isExecutableFile(atPath: runtime.wineserver.path)
        else { return nil }
        return runtime
    }
}

enum RuntimeError: Error, Equatable {
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    /// The archive unpacked, but it isn't a MacHub runtime (no runtime.json or no Wine).
    case invalidArchive
    case versionMismatch(expected: String, found: String)
    case noDownloadURL
    case downloadFailed(String)
    /// macOS refused to start Wine's Intel binary: Rosetta 2 is not installed.
    case rosettaMissing
    case wineDoesNotStart(String)
}

/// Installs, lists and checks runtimes in `Application Support/app.machub.MacHub/Runtimes/<version>/`.
/// Several versions can sit side by side; installing never touches another version or any prefix.
struct RuntimeManager: Sendable {
    let directory: URL

    static let live = RuntimeManager(directory: LocalData.directory.appending(path: "Runtimes"))
    static let selectedVersionKey = "engine.runtimeVersion"

    func installed(fileManager: FileManager = .default) -> [WineRuntime] {
        let folders = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folders.compactMap { WineRuntime.load(at: $0, fileManager: fileManager) }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }

    /// The runtime the user picked, or the newest installed one.
    func current(selected: String? = UserDefaults.standard.string(forKey: selectedVersionKey)) -> WineRuntime? {
        let all = installed()
        return all.first { $0.version == selected } ?? all.last
    }

    /// Verifies the archive against the manifest, unpacks it in a staging folder and moves it into place.
    /// An already installed copy of the same version is kept as is.
    func install(archive: URL, manifest: RuntimeManifest) async throws -> WineRuntime {
        let actual = try await Self.sha256(of: archive)
        guard actual == manifest.sha256.lowercased() else {
            throw RuntimeError.checksumMismatch(expected: manifest.sha256, actual: actual)
        }
        let fm = FileManager.default
        let destination = directory.appending(path: manifest.version)
        if let existing = WineRuntime.load(at: destination) { return existing }

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let result = try await ProcessRunner.run(URL(filePath: "/usr/bin/tar"), ["-xf", archive.path, "-C", staging.path], timeout: 900)
        guard result.status == 0 else { throw RuntimeError.extractionFailed(result.stderr.suffix(400).description) }

        let unpacked = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        guard unpacked.count == 1, let runtime = WineRuntime.load(at: unpacked[0]) else { throw RuntimeError.invalidArchive }
        guard runtime.version == manifest.version else {
            throw RuntimeError.versionMismatch(expected: manifest.version, found: runtime.version)
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: unpacked[0], to: destination)
        guard let installed = WineRuntime.load(at: destination) else { throw RuntimeError.invalidArchive }
        return installed
    }

    /// Downloads the manifest's archive (reporting bytes received), then installs it.
    func download(_ manifest: RuntimeManifest, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> WineRuntime {
        guard let url = manifest.url else { throw RuntimeError.noDownloadURL }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appending(path: ".download-\(manifest.archive)")
        defer { try? fm.removeItem(at: partial) }

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RuntimeError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        fm.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        var buffer = Data(capacity: 1 << 20)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(received, manifest.size)
            }
        }
        try handle.write(contentsOf: buffer)
        received += Int64(buffer.count)
        try handle.close()
        progress(received, manifest.size)
        return try await install(archive: partial, manifest: manifest)
    }

    /// Starts the runtime's Wine once (`wine --version`). This is the only reliable Rosetta check:
    /// macOS refuses to spawn an Intel binary without it ("bad CPU type", errno 86).
    static func check(_ runtime: WineRuntime) async throws -> String {
        do {
            let result = try await ProcessRunner.run(runtime.wine, ["--version"], timeout: 30)
            guard result.status == 0 else { throw RuntimeError.wineDoesNotStart(result.stderr.suffix(300).description) }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as NSError where isBadArchitecture(error) {
            throw RuntimeError.rosettaMissing
        }
    }

    static func isBadArchitecture(_ error: NSError) -> Bool {
        let badCPU = 86 // EBADARCH
        if error.domain == NSPOSIXErrorDomain, error.code == badCPU { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isBadArchitecture(underlying) }
        return false
    }

    static func sha256(of file: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
