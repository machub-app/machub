import Foundation
import Observation

/// After the user opens a mod site from MacHub, watches the Downloads folder for a while for the archive they
/// download there, so it can be installed in one click. It starts only on that click, looks only at Downloads,
/// never opens or runs anything, and stops by itself.
@MainActor @Observable
final class DownloadsWatch {
    /// A finished download that looks like a mod (an archive), newest first.
    private(set) var found: URL?
    private(set) var isWatching = false
    private var task: Task<Void, Never>?

    nonisolated static let extensions = NexusModInstaller.archiveExtensions

    let folder: URL
    let duration: Duration
    let interval: Duration

    init(folder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
         duration: Duration = .seconds(15 * 60), interval: Duration = .seconds(2)) {
        self.folder = folder
        self.duration = duration
        self.interval = interval
    }

    func start() {
        task?.cancel()
        found = nil
        isWatching = true
        let before = Self.archives(in: folder)
        task = Task { [folder, duration, interval] in
            let deadline = ContinuousClock.now + duration
            var sizes: [URL: Int64] = [:]
            while ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: interval)
                for url in Self.archives(in: folder).subtracting(before) {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
                    // Finished when the size held steady across two looks.
                    if size > 0, sizes[url] == size { self.found = url; self.isWatching = false; return }
                    sizes[url] = size
                }
            }
            self.isWatching = false
        }
    }

    func stop() {
        task?.cancel()
        isWatching = false
    }

    func dismissFound() { found = nil }

    /// Partial downloads (.crdownload, Safari's .download folders) have other extensions, so they never match.
    nonisolated static func archives(in folder: URL) -> Set<URL> {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
        return Set(names.filter { extensions.contains($0.pathExtension.lowercased()) }.map(\.standardizedFileURL))
    }
}
