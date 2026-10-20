import Foundation

/// How likely a Windows game is to run in MacHub, from public signals. An estimate, never a promise: only MacHub's
/// own tests say "tested". Signals, strongest first:
/// 1. MacHub's tests on a real Mac;
/// 2. highball-db's curated verdict when it blocks the game (kernel anti-cheat);
/// 3. a native macOS version on Steam (then Wine isn't needed);
/// 4. highball-db's curated verdict (verified on a Mac, or reported by players), unless it needs D3DMetal for a
///    DirectX 12-only game, which MacHub doesn't route games to yet;
/// 5. the DirectX version from the store's system requirements (DirectX 12 needs D3DMetal);
/// 6. highball-db's prediction (ProtonDB × anti-cheat, macOS odds), else AreWeAntiCheatYet and ProtonDB directly.
struct CompatibilityEstimate: Equatable, Sendable {
    enum Verdict: String, Sendable {
        case tested, verified, community, native, likely, issues, unlikely, antiCheat, directX12, unknown
    }

    let verdict: Verdict
    var protonTier: String?
    var protonReports = 0
    var antiCheat: AntiCheat?
    var directX: Int?
    var highball: HighballDB.Entry?

    struct AntiCheat: Equatable, Sendable {
        let names: [String]
        /// AreWeAntiCheatYet's status on Linux: Supported, Running, Planned, Broken, Denied.
        let status: String
        var blocksWine: Bool { status == "Broken" || status == "Denied" }
    }

    var compatibility: Compatibility {
        switch verdict {
        case .tested, .verified, .native: .great
        case .community: .playable
        case .likely: protonTier == "platinum" ? .great : .playable
        case .issues: .issues
        case .unlikely, .antiCheat, .directX12: .unsupported
        case .unknown: .unknown
        }
    }

    /// Steam app IDs MacHub has played on a real Mac (see docs/ENGINE.md › État).
    static let testedPlayable: Set<Int> = [284160]   // BeamNG.drive, Direct3D 11 through DXMT

    static func make(appID: Int, nativeMac: Bool?, directX: Int?, antiCheat: AntiCheat?,
                     protonTier: String?, protonReports: Int, highball: HighballDB.Entry? = nil) -> CompatibilityEstimate {
        var curated: HighballDB.Game?
        var prediction: HighballDB.Prediction?
        switch highball {
        case .curated(let game)?: curated = game
        case .prediction(let odds)?: prediction = odds
        case nil: break
        }
        let needsD3DMetal = curated?.renderer == "d3dmetal" && (directX ?? 0) >= 12
        let verdict: Verdict
        if testedPlayable.contains(appID) {
            verdict = .tested
        } else if curated?.status == "blocked-anticheat" {
            verdict = .antiCheat
        } else if nativeMac == true || curated?.nativeMac != nil {
            verdict = .native
        } else if let curated, !needsD3DMetal {
            verdict = curated.status == "verified-local" ? .verified : .community
        } else if needsD3DMetal || (directX ?? 0) >= 12 {
            verdict = .directX12   // Highball runs DirectX 12 through D3DMetal; MacHub doesn't yet
        } else if antiCheat?.blocksWine == true {
            verdict = .antiCheat
        } else if let prediction {
            switch prediction.macPrediction {
            case "likely": verdict = .likely
            case "maybe", "possible": verdict = .issues
            default: verdict = .unlikely
            }
        } else if antiCheat != nil {
            verdict = .issues   // works on Linux, untested with macOS's Wine
        } else {
            switch protonTier {
            case "platinum", "gold": verdict = .likely
            case "silver", "bronze": verdict = .issues
            case "borked": verdict = .unlikely
            default: verdict = .unknown
            }
        }
        return CompatibilityEstimate(verdict: verdict, protonTier: prediction?.protonTier ?? protonTier,
                                     protonReports: prediction?.recentReports ?? protonReports,
                                     antiCheat: antiCheat, directX: directX, highball: highball)
    }
}

/// Fetches and caches the public signals behind an estimate.
enum CompatibilitySources {
    static let antiCheatList = URL(string: "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/master/games.json")!

    static func protonDBPage(appID: Int) -> URL { URL(string: "https://www.protondb.com/app/\(appID)")! }

    /// ProtonDB's tier and report count, or nil when nobody has reported the game.
    static func protonDB(appID: Int, http: SteamHTTP = .shared) async -> (tier: String, reports: Int)? {
        let url = URL(string: "https://www.protondb.com/api/v1/reports/summaries/\(appID).json")!
        guard let data = try? await http.get(url, ttl: 3 * 24 * 3600).data else { return nil }
        return parseProtonDB(data)
    }

    static func parseProtonDB(_ data: Data) -> (tier: String, reports: Int)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tier = json["tier"] as? String, tier != "pending" else { return nil }
        return (tier, json["total"] as? Int ?? 0)
    }

    /// Steam app ID → anti-cheat entry, from AreWeAntiCheatYet's list (refreshed weekly).
    static func antiCheats(http: SteamHTTP = .shared) async -> [Int: CompatibilityEstimate.AntiCheat] {
        if let cached = await AntiCheatCache.shared.value { return cached }
        guard let data = try? await http.get(antiCheatList, ttl: 7 * 24 * 3600).data else { return [:] }
        let parsed = parseAntiCheats(data)
        await AntiCheatCache.shared.store(parsed)
        return parsed
    }

    static func parseAntiCheats(_ data: Data) -> [Int: CompatibilityEstimate.AntiCheat] {
        guard let games = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var map: [Int: CompatibilityEstimate.AntiCheat] = [:]
        for game in games {
            guard game["native"] as? Bool != true,
                  let steam = (game["storeIds"] as? [String: Any])?["steam"] as? String, let id = Int(steam),
                  let status = game["status"] as? String else { continue }
            map[id] = .init(names: game["anticheats"] as? [String] ?? [], status: status)
        }
        return map
    }

    /// The DirectX version in a store page's system requirements ("DirectX: Version 12"), minimum first.
    static func directXVersion(inRequirements html: String) -> Int? {
        let text = html.replacing(/<[^>]+>/, with: " ")
        guard let match = text.firstMatch(of: /DirectX\s*:?\s*(?:Version\s*)?(\d{1,2})/) else { return nil }
        return Int(match.1)
    }
}

private actor AntiCheatCache {
    static let shared = AntiCheatCache()
    private(set) var value: [Int: CompatibilityEstimate.AntiCheat]?
    func store(_ map: [Int: CompatibilityEstimate.AntiCheat]) { value = map }
}
