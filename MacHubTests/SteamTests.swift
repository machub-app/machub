import CryptoKit
import Foundation
import Testing
@testable import MacHub

@Suite struct SteamOpenIDTests {
    let returnTo = URL(string: "http://127.0.0.1:51234/callback?state=s3cr3t")!
    let now = ISO8601DateFormatter().date(from: "2026-10-18T10:00:30Z")!

    /// Shape of a real Steam OpenID positive assertion.
    func assertion(_ overrides: [String: String?] = [:]) -> [String: String] {
        var p: [String: String] = [
            "state": "s3cr3t",
            "openid.ns": "http://specs.openid.net/auth/2.0",
            "openid.mode": "id_res",
            "openid.op_endpoint": "https://steamcommunity.com/openid/login",
            "openid.claimed_id": "https://steamcommunity.com/openid/id/76561197960287930",
            "openid.identity": "https://steamcommunity.com/openid/id/76561197960287930",
            "openid.return_to": "http://127.0.0.1:51234/callback?state=s3cr3t",
            "openid.response_nonce": "2026-10-18T10:00:00ZAbCdEfGhIjKlMn",
            "openid.assoc_handle": "1234567890",
            "openid.signed": "signed,op_endpoint,claimed_id,identity,return_to,response_nonce,assoc_handle",
            "openid.sig": "W0u5DRbtHE1GG0ZKXjerUZDUGmc=",
        ]
        for (key, value) in overrides { p[key] = value }
        return p
    }

    @Test func loginURLAsksForIdentifierSelect() throws {
        let url = SteamOpenID.loginURL(returnTo: returnTo, realm: URL(string: "http://127.0.0.1:51234/")!)
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(url.host() == "steamcommunity.com")
        #expect(items["openid.mode"] == "checkid_setup")
        #expect(items["openid.return_to"] == returnTo.absoluteString)
        #expect(items["openid.claimed_id"] == SteamOpenID.identifierSelect)
    }

    @Test func validAssertionYieldsSteamID() throws {
        #expect(try SteamOpenID.validate(assertion(), expectedReturnTo: returnTo, state: "s3cr3t", now: now) == "76561197960287930")
    }

    @Test(arguments: [
        ("state", "forged"),
        ("openid.return_to", "http://127.0.0.1:9999/callback?state=s3cr3t"),
        ("openid.op_endpoint", "https://evil.example/openid/login"),
        ("openid.claimed_id", "https://steamcommunity.com/openid/id/123"),
        ("openid.identity", "https://steamcommunity.com/openid/id/76561197960287931"),
        ("openid.signed", "op_endpoint,claimed_id,identity,return_to"),
        ("openid.response_nonce", "2026-10-18T09:00:00Zold"),
        ("openid.sig", ""),
        ("openid.mode", "setup_needed"),
    ])
    func tamperedAssertionsAreRefused(field: String, value: String) {
        #expect(throws: SteamOpenID.Failure.self) {
            try SteamOpenID.validate(assertion([field: value]), expectedReturnTo: returnTo, state: "s3cr3t", now: now)
        }
    }

    @Test func cancelIsReported() {
        #expect(throws: SteamOpenID.Failure.cancelled) {
            try SteamOpenID.validate(["openid.mode": "cancel"], expectedReturnTo: returnTo, state: "s3cr3t", now: now)
        }
    }

    @Test func steamVerdictParsing() {
        #expect(SteamOpenID.isValidResponse("ns:http://specs.openid.net/auth/2.0\nis_valid:true\n"))
        #expect(!SteamOpenID.isValidResponse("ns:http://specs.openid.net/auth/2.0\nis_valid:false\n"))
        #expect(!SteamOpenID.isValidResponse("<html>is_valid:true is not alone on its line</html>"))
    }

    @Test func checkAuthenticationBodyKeepsSignatureAndSwapsMode() {
        let body = SteamOpenID.formEncode(["openid.mode": "check_authentication", "openid.sig": "a+b/c="])
        #expect(body == "openid.mode=check_authentication&openid.sig=a%2Bb%2Fc%3D")
    }
}

@Suite struct LoopbackServerTests {
    @Test func receivesCallbackQueryAndAnswersThePage() async throws {
        let (server, port) = try await LoopbackServer.start(successPage: "<p>ok</p>")
        async let params = server.waitForCallback(timeout: .seconds(10))
        let url = URL(string: "http://127.0.0.1:\(port)/callback?state=abc&openid.mode=id_res")!
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "<p>ok</p>")
        let received = try await params
        #expect(received["state"] == "abc" && received["openid.mode"] == "id_res")
    }
}

@Suite struct SteamDataTests {
    @Test func publicProfileXML() throws {
        // Verbatim structure of steamcommunity.com/profiles/<id>/?xml=1 (2026-10-18), plus a nested group.
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><profile>
        <steamID64>76561197960287930</steamID64>
        <steamID><![CDATA[Rabscuttle]]></steamID>
        <privacyState>friendsonly</privacyState>
        <avatarFull><![CDATA[https://avatars.fastly.steamstatic.com/c5d5_full.jpg]]></avatarFull>
        <groups><group><groupID64>103582791429521408</groupID64><steamID64>0</steamID64></group></groups>
        </profile>
        """
        let profile = try #require(SteamProfile.parse(Data(xml.utf8)))
        #expect(profile.steamID64 == "76561197960287930")
        #expect(profile.personaName == "Rabscuttle")
        #expect(profile.visibility == .friendsOnly)
        #expect(profile.avatarURL?.absoluteString == "https://avatars.fastly.steamstatic.com/c5d5_full.jpg")
    }

    @Test func profileNeverSetUp() throws {
        // Verbatim shape returned on 2026-10-18 for an account without a Community profile.
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><profile>
        <steamID64>76561198000000000</steamID64>
        <steamID><![CDATA[]]></steamID>
        <vacBanned>0</vacBanned>
        <privacyMessage>This user has not yet set up their Steam Community profile.<br />If you know this person, encourage them.</privacyMessage>
        </profile>
        """
        let profile = try #require(SteamProfile.parse(Data(xml.utf8)))
        #expect(profile.personaName == nil && profile.avatarURL == nil)
        #expect(profile.visibility == .notSetUp)
        let account = SteamAccount(steamID64: "76561198000000000", personaName: "", verifiedAt: .now)
        #expect(account.displayName == nil)
    }

    @Test func errorPageIsNotAProfile() {
        #expect(SteamProfile.parse(Data("<response><error>The specified profile could not be found.</error></response>".utf8)) == nil)
    }

    @Test func featuredKeepsAppsOnlyWithoutDuplicates() throws {
        let json = """
        {"top_sellers":{"name":"Top","items":[
          {"id":1091500,"type":0,"name":"Cyberpunk 2077","header_image":"https://cdn/h.jpg","mac_available":true,"final_price":5999,"currency":"EUR","discount_percent":0},
          {"id":1091500,"type":0,"name":"Cyberpunk 2077"},
          {"id":42,"type":2,"name":"A bundle"}]},
         "new_releases":{"items":[]}, "specials":{"items":[{"id":244210,"type":0,"name":"Assetto Corsa","discount_percent":75}]}}
        """
        let featured = try SteamStore.parseFeatured(Data(json.utf8))
        #expect(featured.topSellers.map(\.appID) == [1091500])
        #expect(featured.topSellers.first?.macAvailable == true)
        #expect(featured.specials.first?.discountPercent == 75)
        #expect(featured.comingSoon.isEmpty)
    }

    @Test func searchExtractsAppIDFromCapsulePath() throws {
        let json = """
        {"desc":"","items":[
          {"name":"BeamNG.drive","logo":"https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/284160/capsule_sm_120.jpg?t=1"},
          {"name":"A sub","logo":"https://shared.fastly.steamstatic.com/store_item_assets/steam/subs/999/capsule_sm_120.jpg"}]}
        """
        let items = try SteamStore.parseSearch(Data(json.utf8))
        #expect(items.map(\.appID) == [284160])
        #expect(items.first?.name == "BeamNG.drive")
    }

    @Test func appDetailsDecodeAndFailure() throws {
        let json = """
        {"244210":{"success":true,"data":{"type":"game","name":"Assetto Corsa","short_description":"Simulateur &quot;nouvelle génération&quot;<br>",
          "developers":["Kunos Simulazioni"],"publishers":["Kunos Simulazioni"],"genres":[{"id":"9","description":"Course automobile"}],
          "release_date":{"coming_soon":false,"date":"19 déc. 2014"},"is_free":false,"platforms":{"windows":true,"mac":false,"linux":false},
          "screenshots":[{"id":0,"path_thumbnail":"https://cdn/s1.jpg"}],"metacritic":{"score":85},"price_overview":{"final_formatted":"19,99€"}}}}
        """
        let details = try #require(try SteamStore.parseDetails(Data(json.utf8), appID: 244210))
        #expect(details.shortDescription == "Simulateur \"nouvelle génération\"")
        #expect(details.genres == ["Course automobile"] && !details.mac && details.windows)
        #expect(details.metacritic == 85 && details.price == "19,99€" && details.screenshots.count == 1)
        #expect(try SteamStore.parseDetails(Data(#"{"1":{"success":false}}"#.utf8), appID: 1) == nil)
    }

    @Test func ownedGamesAndPrivateProfiles() throws {
        let json = #"{"response":{"game_count":1,"games":[{"appid":244210,"name":"Assetto Corsa","playtime_forever":125,"rtime_last_played":1792000000}]}}"#
        guard case .games(let games) = try SteamWebAPI.parseOwned(Data(json.utf8)) else {
            Issue.record("expected games")
            return
        }
        #expect(games == [.init(appID: 244210, name: "Assetto Corsa", playtimeMinutes: 125, lastPlayed: Date(timeIntervalSince1970: 1_792_000_000))])
        #expect(try SteamWebAPI.parseOwned(Data(#"{"response":{}}"#.utf8)) == .privateOrEmpty)
    }

    @Test func apiKeyShape() {
        #expect(SteamAPIKeyStore.isPlausible("0123456789ABCDEF0123456789abcdef"))
        #expect(!SteamAPIKeyStore.isPlausible("not-a-key"))
    }

    @Test func httpCacheServesStaleWhenOffline() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "machub-http-\(UUID().uuidString)")
        let http = SteamHTTP(directory: dir, minimumInterval: .zero)
        let url = URL(string: "http://127.0.0.1:9/never")!  // discard port: connection refused
        // Seed the cache by pre-writing the file SteamHTTP derives from the cache key.
        let key = "seed-key"
        try Data("cached".utf8).write(to: dir.appending(path: Self.sha(key) + ".json"))
        let response = try await http.get(url, ttl: 0, cacheKey: key)
        #expect(response.isStale && String(decoding: response.data, as: UTF8.self) == "cached")
        await #expect(throws: SteamHTTP.Failure.offline) { try await http.get(url, ttl: 0, cacheKey: "nothing-cached") }
    }

    static func sha(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
