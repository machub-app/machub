import Foundation
import Security

/// A Steam account proven by a verified OpenID sign-in. Not a secret: SteamID64 and public profile only.
struct SteamAccount: Codable, Equatable, Sendable {
    enum Visibility: String, Codable, Sendable {
        case `public`, friendsOnly, `private`, unknown
        /// The account never created its Steam Community profile: Steam publishes no name, avatar or privacy.
        case notSetUp
    }

    let steamID64: String
    var personaName: String?
    var avatarURL: URL?
    var visibility: Visibility = .unknown
    let verifiedAt: Date

    /// Public name, or nil when Steam has none (empty names are never shown).
    var displayName: String? { personaName.flatMap { $0.isEmpty ? nil : $0 } }

    private static let storageKey = "steamAccount"

    static func load(from defaults: UserDefaults = .standard) -> SteamAccount? {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(SteamAccount.self, from: $0) }
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.storageKey)
    }

    static func remove(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

/// Public community profile (`/profiles/<id>?xml=1`): name, avatar and privacy, with no API key.
struct SteamProfile: Equatable, Sendable {
    var steamID64: String?
    var personaName: String?
    var avatarURL: URL?
    var visibility: SteamAccount.Visibility = .unknown

    static func url(for steamID64: String) -> URL {
        URL(string: "https://steamcommunity.com/profiles/\(steamID64)/?xml=1")!
    }

    static func parse(_ data: Data) -> SteamProfile? {
        let delegate = ProfileXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let v = delegate.values
        guard v["steamID64"] != nil || v["steamID"] != nil else { return nil }
        let visibility: SteamAccount.Visibility = switch v["privacyState"] {
        case "public": .public
        case "friendsonly": .friendsOnly
        case "private": .private
        default: v["privacyMessage"] != nil ? .notSetUp : .unknown
        }
        let name = v["steamID"].flatMap { $0.isEmpty ? nil : $0 }
        return SteamProfile(
            steamID64: v["steamID64"], personaName: name,
            avatarURL: v["avatarFull"].flatMap(URL.init(string:)), visibility: visibility
        )
    }
}

private final class ProfileXMLDelegate: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var depth = 0
    private var current: String?
    private var buffer = ""
    private let wanted: Set = ["steamID64", "steamID", "avatarFull", "privacyState", "privacyMessage"]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        depth += 1
        // Only top-level children of <profile>: nested groups also contain <steamID64>.
        if depth == 2, wanted.contains(name) { current = name; buffer = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if current != nil { buffer += string } }

    func parser(_ parser: XMLParser, foundCDATA block: Data) { if current != nil { buffer += String(decoding: block, as: UTF8.self) } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == current {
            values[name] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            current = nil
        }
        depth -= 1
    }
}

/// The user's own Steam Web API key, kept in the macOS Keychain only (never in defaults, code or logs).
/// Needed solely for `IPlayerService` (owned / recently played games); sign-in does not need it.
enum SteamAPIKeyStore {
    private static let service = "app.machub.MacHub.steam-web-api"
    private static let account = "default"

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// Steam keys are 32 hexadecimal characters.
    static func isPlausible(_ key: String) -> Bool {
        key.wholeMatch(of: /[0-9A-Fa-f]{32}/) != nil
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
