import AppKit
import Foundation
import Observation

/// Steam sign-in state. "Connected" only ever means: Steam's OpenID endpoint signed an assertion
/// for this SteamID64 and Steam itself confirmed it (`is_valid:true`). Local files such as
/// loginusers.vdf are never treated as authentication.
@MainActor @Observable
final class SteamConnection {
    enum State: Equatable {
        case signedOut
        case waitingForBrowser
        case verifying
        case signedIn
        case failed(Problem)
    }

    enum Problem: Equatable {
        case cancelled, rejected, invalid, network, timedOut, receiver
        case other(String)
    }

    private(set) var account: SteamAccount?
    private(set) var state: State
    private(set) var hasAPIKey: Bool
    private var server: LoopbackServer?

    init() {
        let saved = SteamAccount.load()
        account = saved
        state = saved == nil ? .signedOut : .signedIn
        hasAPIKey = SteamAPIKeyStore.load() != nil
    }

    var isBusy: Bool { state == .waitingForBrowser || state == .verifying }

    func signIn() async {
        guard !isBusy else { return }
        state = .waitingForBrowser
        do {
            let nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
            let (server, port) = try await LoopbackServer.start(successPage: Self.successPage)
            self.server = server
            let realm = URL(string: "http://127.0.0.1:\(port)/")!
            let returnTo = URL(string: "http://127.0.0.1:\(port)/callback?state=\(nonce)")!
            NSWorkspace.shared.open(SteamOpenID.loginURL(returnTo: returnTo, realm: realm))

            let params = try await server.waitForCallback()
            state = .verifying
            let steamID = try SteamOpenID.validate(params, expectedReturnTo: returnTo, state: nonce)
            try await SteamOpenID.verifyWithSteam(params)

            var account = SteamAccount(steamID64: steamID, verifiedAt: .now)
            if self.account?.steamID64 == steamID {  // keep the known profile while it refreshes
                account.personaName = self.account?.personaName
                account.avatarURL = self.account?.avatarURL
            }
            self.account = account
            account.save()
            state = .signedIn
            await refreshProfile()
        } catch is CancellationError {
            state = account == nil ? .signedOut : .signedIn
        } catch {
            state = .failed(Self.problem(for: error))
        }
        server = nil
    }

    func cancelSignIn() {
        server?.stop()
    }

    func signOut() {
        server?.stop()
        SteamAccount.remove()
        account = nil
        state = .signedOut
    }

    /// Public profile: name, avatar, visibility. Works without an API key.
    func refreshProfile() async {
        guard var account else { return }
        guard let response = try? await SteamHTTP.shared.get(SteamProfile.url(for: account.steamID64), ttl: 3600),
              let profile = SteamProfile.parse(response.data), profile.steamID64 == account.steamID64
        else { return }
        account.personaName = profile.personaName
        account.avatarURL = profile.avatarURL
        account.visibility = profile.visibility
        self.account = account
        account.save()
    }

    @discardableResult
    func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SteamAPIKeyStore.isPlausible(trimmed), SteamAPIKeyStore.save(trimmed) else { return false }
        hasAPIKey = true
        return true
    }

    func removeAPIKey() {
        SteamAPIKeyStore.delete()
        hasAPIKey = false
    }

    static func problem(for error: Error) -> Problem {
        switch error {
        case SteamOpenID.Failure.cancelled: .cancelled
        case SteamOpenID.Failure.rejectedBySteam: .rejected
        case SteamOpenID.Failure.malformed: .invalid
        case SteamOpenID.Failure.network: .network
        case LoopbackServer.Failure.timedOut: .timedOut
        case LoopbackServer.Failure.couldNotStart: .receiver
        default: .other(error.localizedDescription)
        }
    }

    /// Shown in the browser tab once Steam redirects back. It says "received", not "connected":
    /// verification with Steam happens next, inside MacHub.
    static let successPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>MacHub</title>
    <style>body{background:#0b0b0d;color:#f5f5f7;font:16px -apple-system,system-ui;display:grid;place-items:center;height:100vh;margin:0}
    main{max-width:420px;text-align:center}h1{font-size:22px}p{color:#a8a8a8}</style></head>
    <body><main><h1>Steam → MacHub</h1><p>Sign-in received. MacHub is now verifying it with Steam.</p>
    <p>Connexion reçue : MacHub la vérifie auprès de Steam.</p><p>You can close this tab. Vous pouvez fermer cet onglet.</p></main></body></html>
    """
}
