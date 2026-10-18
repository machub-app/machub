import Foundation
import UniformTypeIdentifiers

/// A Windows file the user brought to MacHub, identified from its bytes (not just its extension).
struct WindowsFile: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A PE executable (.exe). `installer` names the setup engine when its marker is found.
        case executable(Architecture, installer: InstallerEngine?)
        /// A Windows Installer package (.msi), run through msiexec.
        case msi
    }

    enum Architecture: String, Sendable {
        case x86, x64, arm64, other
    }

    enum InstallerEngine: String, Sendable {
        case innoSetup = "Inno Setup"
        case nsis = "NSIS"
        case installShield = "InstallShield"
        case wix = "WiX"
    }

    enum InspectionError: Error, Equatable {
        case notFound
        case unreadable
        /// Not something MacHub can run: a DLL, a Mac file renamed .exe, an ARM-only build…
        case unsupported(String)
    }

    let url: URL
    let kind: Kind
    let size: Int64
    /// Where the browser says the file came from (kMDItemWhereFroms), when it recorded it.
    let downloadedFrom: String?
    /// macOS quarantine flag: the file came from the internet.
    let isQuarantined: Bool

    var name: String { url.lastPathComponent }
    var displayName: String { url.deletingPathExtension().lastPathComponent }

    /// An installer sets a program up and is then done with; a plain executable *is* the program.
    var looksLikeInstaller: Bool {
        switch kind {
        case .msi: return true
        case .executable(_, let engine):
            return engine != nil || displayName.range(of: #"(?i)(setup|install|installer)"#, options: .regularExpression) != nil
        }
    }

    static let contentTypes: [UTType] = [
        UTType("com.microsoft.windows-executable") ?? UTType(filenameExtension: "exe") ?? .data,
        UTType("com.microsoft.msi-installer") ?? UTType(filenameExtension: "msi") ?? .data,
    ]

    static func isCandidate(_ url: URL) -> Bool {
        ["exe", "msi"].contains(url.pathExtension.lowercased())
    }

    static func inspect(_ url: URL, fileManager: FileManager = .default) throws(InspectionError) -> WindowsFile {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { throw .notFound }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw .unreadable }
        defer { try? handle.close() }
        // The header plus enough of the file for the setup engine's marker strings.
        let head = (try? handle.read(upToCount: 4 << 20)) ?? Data()
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? Int64(head.count)
        let kind = try classify(head)
        return WindowsFile(url: url, kind: kind, size: size, downloadedFrom: whereFrom(url), isQuarantined: isQuarantined(url))
    }

    static func classify(_ data: Data) throws(InspectionError) -> Kind {
        let bytes = [UInt8](data.prefix(8))
        if bytes == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] { return .msi }
        guard data.count >= 0x40, bytes.starts(with: [0x4D, 0x5A]) else {
            throw .unsupported("This isn't a Windows program (no MZ header).")
        }
        let peOffset = Int(data.littleEndian(UInt32.self, at: 0x3C))
        guard peOffset > 0, peOffset + 24 <= data.count,
              data[peOffset..<peOffset + 4].elementsEqual([0x50, 0x45, 0x00, 0x00])
        else { throw .unsupported("This is an old DOS program, not a Windows one.") }
        let machine = data.littleEndian(UInt16.self, at: peOffset + 4)
        let characteristics = data.littleEndian(UInt16.self, at: peOffset + 22)
        if characteristics & 0x2000 != 0 { throw .unsupported("This is a library (DLL), not a program you can open.") }
        let architecture: Architecture = switch machine {
        case 0x014C: .x86
        case 0x8664: .x64
        case 0xAA64: .arm64
        default: .other
        }
        if architecture == .arm64 || architecture == .other {
            throw .unsupported("This program is built for a processor Whisky can't run (\(String(format: "0x%04X", machine))).")
        }
        return .executable(architecture, installer: engine(in: data))
    }

    /// Setup engines leave their name in the executable; finding it is a strong installer signal.
    static func engine(in data: Data) -> InstallerEngine? {
        let markers: [(String, InstallerEngine)] = [
            ("Inno Setup", .innoSetup), ("Nullsoft", .nsis), ("NSIS Error", .nsis),
            ("InstallShield", .installShield), ("WixBundle", .wix), ("WiX Toolset", .wix),
        ]
        for (marker, engine) in markers where data.range(of: Data(marker.utf8)) != nil { return engine }
        return nil
    }

    private static func whereFrom(_ url: URL) -> String? {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, name, &buffer, length, 0, 0) == length,
              let list = try? PropertyListSerialization.propertyList(from: Data(buffer), format: nil) as? [String]
        else { return nil }
        // First entry is the download URL; show its host only.
        return list.lazy.compactMap { URL(string: $0)?.host() }.first
    }

    private static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0
    }
}

extension Data {
    func littleEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return 0 }
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value |= T(self[startIndex + offset + i]) << (8 * i)
        }
        return value
    }
}

/// Executables inside a bottle's program folders, to spot what an installer added.
enum InstalledProgramScanner {
    nonisolated(unsafe) private static let ignored = /(?i)^(unins.*|uninstall.*|vc_?redist.*|dxsetup|dotnet.*|crash.*|.*update.*|.*helper.*|setup.*)\.exe$/

    /// Program Files (both) and each user's AppData/Local/Programs, where per-user installers go.
    static func roots(in bottle: URL, fileManager: FileManager = .default) -> [URL] {
        let users = bottle.appending(path: "drive_c/users")
        let perUser = ((try? fileManager.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appending(path: "AppData/Local/Programs") }
        return [bottle.appending(path: "drive_c/Program Files"), bottle.appending(path: "drive_c/Program Files (x86)")] + perUser
    }

    static func executables(in bottle: URL, fileManager: FileManager = .default) -> Set<String> {
        var found = Set<String>()
        for base in roots(in: bottle, fileManager: fileManager) {
            guard let walker = fileManager.enumerator(at: base, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                // Steam's game library and browser runtime are huge and never what the user just installed.
                if ["steamapps", "cef"].contains(url.lastPathComponent.lowercased()) { walker.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "exe" { found.insert(url.path) }
            }
        }
        return found
    }

    /// What appeared between two scans, best guesses first (the program named like the installer, then shallow paths).
    static func added(before: Set<String>, after: Set<String>, hint: String) -> [String] {
        let words = hint.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 2 && !["setup", "install", "installer", "win", "x64"].contains($0) }
        return after.subtracting(before)
            .filter { URL(filePath: $0).lastPathComponent.firstMatch(of: ignored) == nil }
            .sorted { a, b in
                let sa = score(a, words), sb = score(b, words)
                return sa != sb ? sa > sb : a.split(separator: "/").count < b.split(separator: "/").count
            }
    }

    private static func score(_ path: String, _ words: [String]) -> Int {
        let lower = path.lowercased()
        return words.filter { lower.contains($0) }.count
    }
}
