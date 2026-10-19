import Foundation

/// Apple's D3DMetal (Game Porting Toolkit), which Apple doesn't allow MacHub to redistribute. The user downloads
/// the toolkit from Apple with their own Apple Account; MacHub then copies its redistributable libraries into its
/// own folder. Nothing is fetched from a third party.
struct GPTKStore: Sendable {
    let directory: URL

    static let live = GPTKStore(directory: LocalData.directory.appending(path: "GPTK"))
    /// Where Apple publishes the toolkit (Apple Account sign-in required).
    static let downloadPage = URL(string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit")!

    enum ImportError: Error, Equatable {
        /// The folder or disk image has no D3DMetal.framework.
        case notAToolkit
        case copyFailed(String)
    }

    var installedLibrary: URL { directory.appending(path: "lib") }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedLibrary.appending(path: "external/D3DMetal.framework").path)
    }

    /// D3DMetal is imported and checked, but MacHub doesn't route DirectX 12 titles to it yet: that needs its
    /// DLLs inside the runtime and a test on real hardware first. Until then DX12 titles run on DXMT.
    var canRunDirectX12: Bool { false }

    /// The toolkit's version, from the framework's Info.plist.
    var version: String? {
        let plist = installedLibrary.appending(path: "external/D3DMetal.framework/Resources/Info.plist")
        let info = (try? Data(contentsOf: plist)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        return info?["CFBundleShortVersionString"] as? String
    }

    /// Finds the toolkit's `redist/lib` (the folder holding `external/D3DMetal.framework`) under `root`:
    /// a mounted "Evaluation environment for Windows games" volume, or a folder the user picked.
    static func redistributableLibrary(under root: URL, fileManager: FileManager = .default) -> URL? {
        let direct = [root, root.appending(path: "lib"), root.appending(path: "redist/lib")]
        if let hit = direct.first(where: { fileManager.fileExists(atPath: $0.appending(path: "external/D3DMetal.framework").path) }) {
            return hit
        }
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == "D3DMetal.framework" {
            return url.deletingLastPathComponent().deletingLastPathComponent()
        }
        return nil
    }

    /// Copies the toolkit's libraries in, replacing an earlier import.
    func importToolkit(from root: URL) throws {
        guard let library = Self.redistributableLibrary(under: root) else { throw ImportError.notAToolkit }
        let fm = FileManager.default
        let staging = directory.appending(path: ".import-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.copyItem(at: library, to: staging)
            if fm.fileExists(atPath: installedLibrary.path) { try fm.removeItem(at: installedLibrary) }
            try fm.moveItem(at: staging, to: installedLibrary)
        } catch {
            try? fm.removeItem(at: staging)
            throw ImportError.copyFailed(error.localizedDescription)
        }
    }

    /// Removes the imported copy (the user's download is left alone).
    func remove() throws {
        if FileManager.default.fileExists(atPath: installedLibrary.path) { try FileManager.default.trashItem(at: installedLibrary, resultingItemURL: nil) }
    }
}
