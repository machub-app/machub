import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `machub://` links: today only `machub://play/<steam app id>`, opened by the game shortcuts MacHub creates.
enum MacHubLink: Equatable, Sendable {
    case play(appID: Int)

    static let scheme = "machub"

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host()?.lowercased() == "play" else { return nil }
        let parts = url.path().split(separator: "/")
        guard parts.count == 1, let appID = Int(parts[0]), appID > 0 else { return nil }
        self = .play(appID: appID)
    }

    var url: URL {
        switch self {
        case .play(let appID): URL(string: "\(Self.scheme)://play/\(appID)")!
        }
    }
}

/// machub:// links handed to MacHub by macOS (a game shortcut was double-clicked).
@MainActor @Observable
final class MacHubLinkInbox {
    static let shared = MacHubLinkInbox()
    var pending: [MacHubLink] = []

    func receive(_ urls: [URL]) {
        pending += urls.compactMap(MacHubLink.init)
    }
}

enum MacShortcutError: LocalizedError {
    /// Something that isn't a MacHub shortcut already uses that name: it is left alone.
    case nameTaken(String)
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .nameTaken(let path): String(localized: "Another app already uses this name: \(path). MacHub left it untouched.")
        case .signingFailed(let detail): String(localized: "macOS couldn't sign the shortcut: \(detail)")
        }
    }
}

/// A tiny Mac app per game, in `~/Applications/MacHub Games`, that opens `machub://play/<app id>`: the game then
/// starts through MacHub like its Play button. MacHub only ever replaces bundles it made itself.
enum MacShortcut {
    static let bundleIDPrefix = "app.machub.shortcut."

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/MacHub Games", directoryHint: .isDirectory)
    }

    /// A Finder-safe file name for the game: no slashes or colons, no leading dot.
    static func bundleName(for name: String) -> String {
        var clean = name.map { "/:".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix(".") { clean.removeFirst() }
        return (clean.isEmpty ? "Game" : clean) + ".app"
    }

    static func bundleID(appID: Int) -> String { bundleIDPrefix + String(appID) }

    /// Writes `<folder>/<name>.app`, replacing an earlier MacHub shortcut of the same name. Not signed yet.
    @discardableResult
    static func write(name: String, appID: Int, artwork: CGImage?, in folder: URL, fileManager: FileManager = .default) throws -> URL {
        let destination = folder.appending(path: bundleName(for: name), directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: destination.path), !isShortcut(destination) {
            throw MacShortcutError.nameTaken(destination.path)
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        // Built beside the destination, then swapped in, so a failure never leaves a half-written app.
        let staging = folder.appending(path: ".machub-\(UUID().uuidString).app", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        let contents = staging.appending(path: "Contents")
        let macOS = contents.appending(path: "MacOS")
        let resources = contents.appending(path: "Resources")
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleIdentifier": bundleID(appID: appID),
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": "launch",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
            // Only hands a link to MacHub: no Dock icon of its own.
            "LSUIElement": true,
            "MacHubSteamAppID": appID,
        ]
        if let artwork, let icns = icon(from: artwork) {
            try icns.write(to: resources.appending(path: "AppIcon.icns"))
            info["CFBundleIconFile"] = "AppIcon"
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))

        let script = macOS.appending(path: "launch")
        try Data("#!/bin/sh\nexec /usr/bin/open \"\(MacHubLink.play(appID: appID).url.absoluteString)\"\n".utf8).write(to: script)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        return destination
    }

    /// An app bundle MacHub made (its identifier says so): the only kind MacHub replaces.
    static func isShortcut(_ url: URL) -> Bool {
        let info = url.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String
        else { return false }
        return id.hasPrefix(bundleIDPrefix)
    }

    /// Ad-hoc signature, so macOS runs the shortcut like any locally built app.
    static func sign(_ app: URL) async throws {
        let result = try await ProcessRunner.run(URL(filePath: "/usr/bin/codesign"), ["--force", "--sign", "-", app.path], timeout: 30)
        guard result.status == 0 else { throw MacShortcutError.signingFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Writes, signs and returns the shortcut for an installed Steam game.
    static func create(name: String, appID: Int, artwork: CGImage?, in folder: URL = folder) async throws -> URL {
        let app = try write(name: name, appID: appID, artwork: artwork, in: folder)
        try await sign(app)
        // Finder caches icons per path: tell it this one changed.
        NSWorkspace.shared.noteFileSystemChanged(app.path)
        return app
    }

    // MARK: Icon

    /// The game's portrait library art inside the standard macOS icon shape, at every size an icns holds.
    static func icon(from artwork: CGImage) -> Data? {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.icns.identifier as CFString, sizes.count, nil) else { return nil }
        for size in sizes {
            guard let image = iconImage(artwork, size: size) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
        }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func iconImage(_ artwork: CGImage, size: Int) -> CGImage? {
        let side = CGFloat(size)
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        // macOS app icon grid: an 824/1024 rounded square, centred, with a soft drop shadow.
        let tile = CGRect(x: side * 100 / 1024, y: side * 100 / 1024, width: side * 824 / 1024, height: side * 824 / 1024)
        let shape = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -side * 10 / 1024), blur: side * 28 / 1024,
                          color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fillPath()
        context.restoreGState()

        // Aspect-fill, keeping the top of portrait art (where most covers put the game's name).
        context.addPath(shape)
        context.clip()
        let width = CGFloat(artwork.width), height = CGFloat(artwork.height)
        let scale = max(tile.width / width, tile.height / height)
        let drawn = CGSize(width: width * scale, height: height * scale)
        let origin = CGPoint(x: tile.midX - drawn.width / 2, y: tile.maxY - drawn.height)
        context.draw(artwork, in: CGRect(origin: origin, size: drawn))
        return context.makeImage()
    }

    /// The game's library art: Steam for Windows' local cache first, then Steam's CDN.
    static func artwork(appID: Int, steamRoot: URL?, fallback: URL?) async -> CGImage? {
        if let steamRoot, let local = localArtwork(appID: appID, steamRoot: steamRoot), let image = image(at: local) {
            return image
        }
        for url in [Artwork.cover.url(appID: appID), fallback, Artwork.header.url(appID: appID)].compactMap({ $0 }) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { continue }
            return image
        }
        return nil
    }

    /// `appcache/librarycache/<id>/…/library_capsule.jpg` (or the older `library_600x900.jpg`).
    static func localArtwork(appID: Int, steamRoot: URL, fileManager: FileManager = .default) -> URL? {
        let folder = steamRoot.appending(path: "appcache/librarycache/\(appID)")
        guard let files = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let found = files.compactMap { $0 as? URL }
        for name in ["library_capsule.jpg", "library_600x900.jpg", "library_header.jpg"] {
            if let url = found.first(where: { $0.lastPathComponent == name }) { return url }
        }
        return nil
    }

    private static func image(at url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}

extension LibraryStore {
    /// "Create Mac Shortcut": writes the game's shortcut app and shows it in Finder; explains any failure.
    func createMacShortcut(for title: Title) async {
        guard let appID = title.steamAppID else { return }
        let prefix = prefixes.first { $0.name == title.bottle } ?? steamPrefix
        let steamRoot = prefix.flatMap { SteamLibrary.steamRoot(inPrefix: $0.url) }
        let artwork = await MacShortcut.artwork(appID: appID, steamRoot: steamRoot, fallback: title.capsuleURL)
        do {
            let app = try await MacShortcut.create(name: title.name, appID: appID, artwork: artwork)
            NSWorkspace.shared.activateFileViewerSelecting([app])
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn't create the Mac shortcut")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
