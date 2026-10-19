import CryptoKit
import Foundation

/// A mod MacHub put in a folder, with enough to verify, update or remove exactly that file.
struct InstalledMod: Codable, Hashable, Identifiable, Sendable {
    var id: String { projectID }
    let source: String
    let projectID: String
    let versionID: String
    let title: String
    let versionNumber: String
    var fileName: String
    let sha512: String
    let installedAt: Date
    var enabled: Bool
    /// Installed only because another mod needs it.
    var requiredBy: [String] = []
}

enum ModInstallError: Error, Equatable {
    case download(String)
    case sizeMismatch(expected: Int64, got: Int64)
    case hashMismatch
    case unsafeFileName(String)
    /// A file with that name exists and MacHub didn't install it: never overwritten.
    case foreignFileExists(String)
    case noCompatibleVersion(String)
    case notInstalled
}

/// Downloads to a staging file, reporting progress from the real byte counts.
final class ModDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias Progress = @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: Progress?
    private let lock = NSLock()

    static func download(_ url: URL, progress: @escaping Progress) async throws -> URL {
        let delegate = ModDownloader()
        delegate.progress = progress
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                var request = URLRequest(url: url)
                request.setValue("MacHub (app.machub.MacHub)", forHTTPHeaderField: "User-Agent")
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns: move it somewhere we own first.
        let kept = FileManager.default.temporaryDirectory.appending(path: "machub-mod-\(UUID().uuidString)")
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        resume(with: Result {
            guard status == 200 else { throw ModInstallError.download("HTTP \(status)") }
            try FileManager.default.moveItem(at: location, to: kept)
            return kept
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { resume(with: .failure(ModInstallError.download(error.localizedDescription))) }
    }

    private func resume(with result: Result<URL, Error>) {
        lock.withLock {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}

/// Mods that are single files in one folder (Minecraft `mods/`). Writes only inside that folder,
/// keeps a manifest next to it, and disables mods by renaming them `.disabled` (what Fabric and Modrinth's app do).
struct FolderModInstaller: Sendable {
    typealias Download = @Sendable (URL, @escaping ModDownloader.Progress) async throws -> URL
    let folder: URL
    var download: Download = { try await ModDownloader.download($0, progress: $1) }

    var manifestURL: URL { folder.deletingLastPathComponent().appending(path: ".machub-mods.json") }

    func installed() -> [InstalledMod] {
        LocalData.load([InstalledMod].self, from: manifestURL.lastPathComponent, in: manifestURL.deletingLastPathComponent()) ?? []
    }

    private func save(_ mods: [InstalledMod]) {
        LocalData.save(mods, to: manifestURL.lastPathComponent, in: manifestURL.deletingLastPathComponent())
    }

    /// Jar files in the folder that MacHub didn't install (added by hand or another tool). Listed, never touched.
    func unmanagedFiles() -> [String] {
        let managed = Set(installed().flatMap { [$0.fileName, $0.fileName + ".disabled"] })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { ($0.hasSuffix(".jar") || $0.hasSuffix(".jar.disabled")) && !managed.contains($0) }.sorted()
    }

    /// A plain file name: no folders, no "..", no hidden files, the extension the loader expects.
    static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".") && name != ".."
            && name.lowercased().hasSuffix(".jar") && name.count < 200
    }

    /// Downloads, verifies size and SHA-512, then moves the file in. Replaces only a file MacHub itself installed.
    func install(_ version: ModVersion, title: String, requiredBy: String? = nil, progress: @escaping ModDownloader.Progress = { _ in }) async throws -> InstalledMod {
        guard let file = version.primaryFile else { throw ModInstallError.noCompatibleVersion(title) }
        guard Self.isSafe(file.filename) else { throw ModInstallError.unsafeFileName(file.filename) }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var mods = installed()
        let previous = mods.first { $0.projectID == version.projectID }
        let destination = folder.appending(path: file.filename)
        let ours = Set(mods.flatMap { [$0.fileName, $0.fileName + ".disabled"] })
        if fm.fileExists(atPath: destination.path), !ours.contains(file.filename) { throw ModInstallError.foreignFileExists(file.filename) }

        let staged = try await download(file.url, progress)
        defer { try? fm.removeItem(at: staged) }
        let size = (try? fm.attributesOfItem(atPath: staged.path)[.size] as? Int64) ?? -1
        if file.size > 0, size != file.size { throw ModInstallError.sizeMismatch(expected: file.size, got: size) }
        guard try Self.sha512(of: staged) == file.sha512.lowercased() else { throw ModInstallError.hashMismatch }

        // Verified: replace our previous version of this mod, if any, then move the new file in.
        if let previous {
            for name in [previous.fileName, previous.fileName + ".disabled"] {
                let url = folder.appending(path: name)
                if fm.fileExists(atPath: url.path) { try? fm.trashItem(at: url, resultingItemURL: nil) }
            }
        }
        if fm.fileExists(atPath: destination.path) { try? fm.trashItem(at: destination, resultingItemURL: nil) }
        try fm.moveItem(at: staged, to: destination)

        var record = InstalledMod(source: "modrinth", projectID: version.projectID, versionID: version.id, title: title,
                                  versionNumber: version.versionNumber, fileName: file.filename, sha512: file.sha512.lowercased(),
                                  installedAt: .now, enabled: true, requiredBy: previous?.requiredBy ?? [])
        if let requiredBy, !record.requiredBy.contains(requiredBy) { record.requiredBy.append(requiredBy) }
        mods.removeAll { $0.projectID == version.projectID }
        mods.append(record)
        save(mods)
        return record
    }

    func setEnabled(_ mod: InstalledMod, _ enabled: Bool) throws {
        var mods = installed()
        guard let index = mods.firstIndex(where: { $0.projectID == mod.projectID }) else { throw ModInstallError.notInstalled }
        let on = folder.appending(path: mods[index].fileName), off = folder.appending(path: mods[index].fileName + ".disabled")
        let fm = FileManager.default
        if enabled, fm.fileExists(atPath: off.path) { try fm.moveItem(at: off, to: on) }
        if !enabled, fm.fileExists(atPath: on.path) { try fm.moveItem(at: on, to: off) }
        mods[index].enabled = enabled
        save(mods)
    }

    /// Moves the mod's file to the Trash (recoverable) and forgets it.
    func uninstall(_ mod: InstalledMod) throws {
        var mods = installed()
        guard let record = mods.first(where: { $0.projectID == mod.projectID }) else { throw ModInstallError.notInstalled }
        for name in [record.fileName, record.fileName + ".disabled"] {
            let url = folder.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        }
        mods.removeAll { $0.projectID == mod.projectID }
        for i in mods.indices { mods[i].requiredBy.removeAll { $0 == mod.projectID } }
        save(mods)
    }

    /// The file on disk still matches what was downloaded.
    func isIntact(_ mod: InstalledMod) -> Bool {
        let url = folder.appending(path: mod.enabled ? mod.fileName : mod.fileName + ".disabled")
        return (try? Self.sha512(of: url)) == mod.sha512
    }

    static func sha512(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA512()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
