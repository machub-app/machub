import AppKit
import Foundation
import Observation

/// One published MacHub release on GitHub (tag `vX.Y.Z`), with the disk image to install it from.
struct AppRelease: Equatable, Sendable {
    let version: String
    let title: String
    let notes: String
    let page: URL
    let dmg: URL
    let dmgSize: Int64
    /// `MacHub-X.Y.Z.dmg.sha256`, published next to the image; checked before anything is installed.
    let checksum: URL?
}

/// MacHub's own updates, read from the public GitHub Releases of machub-app/machub. No third-party updater:
/// the releases API lists the versions, the release's disk image carries the app, and its published SHA-256 is
/// checked before MacHub replaces itself.
enum AppUpdates {
    static let releasesAPI = URL(string: "https://api.github.com/repos/machub-app/machub/releases?per_page=30")!
    static let automaticKey = "updates.automatic"
    static let lastCheckKey = "updates.lastCheck"

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    /// The newest app release in a GitHub releases listing: tag `vX.Y.Z`, published, not a prerelease, with a disk
    /// image. Engine releases (`runtime-…`) and drafts are ignored.
    static func newestRelease(in data: Data) throws -> AppRelease? {
        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let candidates: [AppRelease] = releases.compactMap { release in
            guard let tag = release["tag_name"] as? String, tag.hasPrefix("v"),
                  release["draft"] as? Bool != true, release["prerelease"] as? Bool != true,
                  let page = (release["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let version = String(tag.dropFirst())
            guard version.first?.isNumber == true else { return nil }
            let assets = release["assets"] as? [[String: Any]] ?? []
            func asset(_ name: String) -> [String: Any]? { assets.first { $0["name"] as? String == name } }
            guard let image = asset("MacHub-\(version).dmg") ?? asset("MacHub.dmg"),
                  let dmg = (image["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let checksum = (asset("MacHub-\(version).dmg.sha256")?["browser_download_url"] as? String).flatMap(URL.init(string:))
            return AppRelease(version: version, title: release["name"] as? String ?? "MacHub \(version)",
                              notes: release["body"] as? String ?? "", page: page, dmg: dmg,
                              dmgSize: (image["size"] as? NSNumber)?.int64Value ?? 0, checksum: checksum)
        }
        return candidates.max { isNewer($1.version, than: $0.version) }
    }

    static func fetchNewest() async throws -> AppRelease? {
        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacHub/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try newestRelease(in: data)
    }
}

enum UpdateError: Error, Equatable {
    case http(Int)
    case checksumMismatch
    case notAnUpdate(String)
    case unpackFailed(String)
    case cannotReplace
}

/// Downloads a release's disk image, checks it and prepares the new app; then swaps it in once MacHub has quit.
enum UpdateInstaller {
    /// Returns the verified new MacHub.app, staged in a temporary folder.
    static func stage(_ release: AppRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "machub-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let image = work.appending(path: "MacHub.dmg")

        let (bytes, response) = try await URLSession.shared.bytes(from: release.dmg)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        let total = max(release.dmgSize, response.expectedContentLength)
        fm.createFile(atPath: image.path, contents: nil)
        let handle = try FileHandle(forWritingTo: image)
        var buffer = Data(capacity: 1 << 18)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 18 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(Double(received) / Double(total)) }
            }
        }
        try handle.write(contentsOf: buffer)
        try handle.close()

        if let checksum = release.checksum {
            let (data, _) = try await URLSession.shared.data(from: checksum)
            let expected = String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init)?.lowercased()
            guard try await RuntimeManager.sha256(of: image) == expected else { throw UpdateError.checksumMismatch }
        }

        let mount = work.appending(path: "mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try await ProcessRunner.run(URL(filePath: "/usr/bin/hdiutil"),
                                                 ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path], timeout: 120)
        guard attach.status == 0 else { throw UpdateError.unpackFailed(attach.stderr) }
        let staged = work.appending(path: "MacHub.app")
        let copy = try await ProcessRunner.run(URL(filePath: "/usr/bin/ditto"), [mount.appending(path: "MacHub.app").path, staged.path], timeout: 300)
        _ = try? await ProcessRunner.run(URL(filePath: "/usr/bin/hdiutil"), ["detach", "-quiet", mount.path], timeout: 60)
        guard copy.status == 0 else { throw UpdateError.unpackFailed(copy.stderr) }

        // Same app, the announced version, and an intact signature.
        let info = NSDictionary(contentsOf: staged.appending(path: "Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError.notAnUpdate(info?["CFBundleShortVersionString"] as? String ?? "?")
        }
        let verify = try await ProcessRunner.run(URL(filePath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", staged.path], timeout: 120)
        guard verify.status == 0 else { throw UpdateError.unpackFailed(verify.stderr) }
        return staged
    }

    /// MacHub can replace itself only from a writable folder, and not from the read-only copy macOS runs an app
    /// from when it was opened straight from a download (App Translocation).
    static func canReplace(_ bundle: URL = Bundle.main.bundleURL) -> Bool {
        !bundle.path.contains("/AppTranslocation/")
            && FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    /// Waits for `pid` to exit, swaps the bundles (putting the old one back if anything fails) and opens the result.
    static func swapScript(old: URL, new: URL, pid: Int32) -> String {
        func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let oldPath = quote(old.path), newPath = quote(new.path), backup = quote(old.path + ".previous")
        return """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(backup)
        if mv \(oldPath) \(backup) && mv \(newPath) \(oldPath); then rm -rf \(backup); else [ -e \(oldPath) ] || mv \(backup) \(oldPath); fi
        open \(oldPath)
        """
    }

    /// Starts the swap in the background, then quits MacHub so it can happen.
    @MainActor static func relaunch(replacing old: URL = Bundle.main.bundleURL, with new: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", swapScript(old: old, new: new, pid: ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }
}

/// Checks for a new MacHub at launch (at most once a day, unless turned off) and installs it on request.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(AppRelease, Double?)
        case installing(AppRelease)
        /// The download or the swap failed; the release stays on offer, with its page as a way out.
        case installFailed(AppRelease, String)
        case failed(String)
    }

    private(set) var state = State.idle

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: AppUpdates.automaticKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: AppUpdates.automaticKey) }
    }

    var lastCheck: Date? { UserDefaults.standard.object(forKey: AppUpdates.lastCheckKey) as? Date }

    /// The release on offer, while there is one (for the sidebar card).
    var offered: AppRelease? {
        switch state {
        case .available(let release), .downloading(let release, _), .installing(let release), .installFailed(let release, _): release
        default: nil
        }
    }

    func checkIfDue() async {
        guard automatic else { return }
        if let lastCheck, Date.now.timeIntervalSince(lastCheck) < 24 * 3600, offered == nil { return }
        await check(quietly: true)
    }

    func check(quietly: Bool = false) async {
        if case .downloading = state { return }
        state = .checking
        do {
            let newest = try await AppUpdates.fetchNewest()
            UserDefaults.standard.set(Date.now, forKey: AppUpdates.lastCheckKey)
            if let newest, AppUpdates.isNewer(newest.version, than: AppUpdates.currentVersion) {
                state = .available(newest)
            } else {
                state = .upToDate
            }
        } catch {
            // A failed automatic check (offline…) stays silent; a manual one says why.
            state = quietly ? .idle : .failed(String(localized: "Couldn't reach GitHub. Check your connection and try again."))
        }
    }

    func install() async {
        guard let release = offered else { return }
        switch state {
        case .available, .installFailed: break
        default: return
        }
        guard UpdateInstaller.canReplace() else {
            state = .installFailed(release, String(localized: "MacHub can't replace itself from this folder. Move it to Applications, or download the new version from its page."))
            return
        }
        state = .downloading(release, nil)
        do {
            let staged = try await UpdateInstaller.stage(release) { fraction in
                Task { @MainActor in
                    if case .downloading(let current, _) = self.state { self.state = .downloading(current, fraction) }
                }
            }
            state = .installing(release)
            try UpdateInstaller.relaunch(with: staged)
        } catch UpdateError.checksumMismatch {
            state = .installFailed(release, String(localized: "The downloaded update doesn't match its published fingerprint, so it wasn't installed."))
        } catch {
            state = .installFailed(release, String(localized: "The update couldn't be installed. You can download it from its page."))
        }
    }
}
