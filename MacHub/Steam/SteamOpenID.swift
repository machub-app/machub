import Foundation

/// Steam sign-in through OpenID 2.0, as Steam documents it: the user authenticates on
/// steamcommunity.com in their own browser; MacHub only receives a signed assertion,
/// which it re-checks directly with Steam (`check_authentication`) before trusting it.
/// No password, token or cookie ever reaches MacHub.
enum SteamOpenID {
    static let endpoint = URL(string: "https://steamcommunity.com/openid/login")!
    static let namespace = "http://specs.openid.net/auth/2.0"
    static let identifierSelect = "http://specs.openid.net/auth/2.0/identifier_select"

    enum Failure: Error, Equatable {
        case cancelled
        case malformed(String)
        case rejectedBySteam
        case network(String)
    }

    /// The browser URL. `returnTo` carries a one-time `state` that the callback must echo.
    static func loginURL(returnTo: URL, realm: URL) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "openid.ns", value: namespace),
            .init(name: "openid.mode", value: "checkid_setup"),
            .init(name: "openid.return_to", value: returnTo.absoluteString),
            .init(name: "openid.realm", value: realm.absoluteString),
            .init(name: "openid.identity", value: identifierSelect),
            .init(name: "openid.claimed_id", value: identifierSelect),
        ]
        return components.url!
    }

    /// Local checks on the assertion Steam redirected back with. Returns the SteamID64.
    /// Steam's own verdict is still required afterwards (`verifyWithSteam`).
    static func validate(_ params: [String: String], expectedReturnTo: URL, state: String, now: Date = .now) throws -> String {
        if params["openid.mode"] == "cancel" { throw Failure.cancelled }
        guard params["openid.mode"] == "id_res" else { throw Failure.malformed("mode") }
        guard params["openid.ns"] == namespace else { throw Failure.malformed("namespace") }
        guard params["openid.op_endpoint"] == endpoint.absoluteString else { throw Failure.malformed("op_endpoint") }
        guard params["state"] == state else { throw Failure.malformed("state") }
        guard params["openid.return_to"] == expectedReturnTo.absoluteString else { throw Failure.malformed("return_to") }

        let signed = Set((params["openid.signed"] ?? "").split(separator: ",").map(String.init))
        for field in ["op_endpoint", "claimed_id", "identity", "return_to", "response_nonce"] where !signed.contains(field) {
            throw Failure.malformed("unsigned \(field)")
        }
        guard params["openid.sig"]?.isEmpty == false, params["openid.assoc_handle"]?.isEmpty == false else {
            throw Failure.malformed("signature")
        }

        // Nonce: "YYYY-MM-DDTHH:MM:SSZ" + unique suffix. Refuse stale assertions (replays).
        guard let nonce = params["openid.response_nonce"], nonce.count >= 20,
              let issued = ISO8601DateFormatter().date(from: String(nonce.prefix(20))),
              abs(now.timeIntervalSince(issued)) < 5 * 60
        else { throw Failure.malformed("response_nonce") }

        guard let claimed = params["openid.claimed_id"], claimed == params["openid.identity"],
              let id = steamID(fromClaimedID: claimed)
        else { throw Failure.malformed("claimed_id") }
        return id
    }

    static func steamID(fromClaimedID claimed: String) -> String? {
        guard let match = claimed.wholeMatch(of: /https:\/\/steamcommunity\.com\/openid\/id\/(7656119\d{10})/) else { return nil }
        return String(match.1)
    }

    /// Asks Steam whether it really issued this assertion (OpenID 2.0 §11.4.2.1 direct verification).
    static func verifyWithSteam(_ params: [String: String], session: URLSession = .shared) async throws {
        var body = params.filter { $0.key.hasPrefix("openid.") }
        body["openid.mode"] = "check_authentication"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(body).data(using: .utf8)
        request.timeoutInterval = 20
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        guard isValidResponse(String(decoding: data, as: UTF8.self)) else { throw Failure.rejectedBySteam }
    }

    /// Key-value form response: lines of `key:value`; we need exactly `is_valid:true`.
    static func isValidResponse(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "is_valid:true" }
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&")
    }
}
