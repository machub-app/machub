import Foundation

/// highball-db, the open compatibility database behind the Highball project (github.com/gauthierpiarrette/highball-db),
/// read per game from its published JSON: `https://gethighball.com/data/steam/<appid>.json`.
///
/// Two kinds of entries, with different licences that MacHub shows next to the data:
/// - curated (CC0-1.0): a status with provenance, the renderer that worked, launch arguments, known issues and fixes,
///   player reports with their Mac and frame rate;
/// - prediction (ODbL-1.0, attribution required): recent ProtonDB verdicts crossed with anti-cheat data, odds for
///   macOS rather than a verdict.
enum HighballDB {
    static let base = URL(string: "https://gethighball.com/data/steam/")!

    enum Entry: Equatable, Sendable {
        case curated(Game)
        case prediction(Prediction)
    }

    struct Game: Equatable, Sendable {
        let title: String
        /// verified-local · reported-upstream · community · blocked-anticheat
        let status: String
        /// Plain-language meaning of the status, as the database words it.
        let statusMeaning: String?
        /// dxmt · d3dmetal · dxvk · wined3d
        let renderer: String?
        let notes: String?
        let provenance: String?
        let launchArgs: [String]
        let knownIssues: [KnownIssue]
        let reports: Int
        let hasRecipe: Bool
        let nativeMac: String?
        let page: URL?
    }

    struct KnownIssue: Equatable, Hashable, Sendable {
        let symptom: String
        let cause: String?
        let fix: String?
    }

    struct Prediction: Equatable, Sendable {
        let title: String
        /// likely · possible · unlikely · blocked…, as the database words it.
        let macPrediction: String
        let label: String
        let protonTier: String?
        let recentReports: Int
        let page: URL?
    }

    /// The entry for a Steam app, nil when the database has nothing on it (HTTP 404) or can't be reached.
    static func entry(appID: Int, http: SteamHTTP = .shared) async -> Entry? {
        guard let data = try? await http.get(base.appending(path: "\(appID).json"), ttl: 3 * 24 * 3600).data else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Entry? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let page = (root["url"] as? String).flatMap(URL.init(string:))
        switch root["kind"] as? String {
        case "curated":
            guard let game = root["game"] as? [String: Any], let status = game["status"] as? String else { return nil }
            let issues = (game["knownIssues"] as? [[String: Any]] ?? []).compactMap { issue -> KnownIssue? in
                guard let symptom = issue["symptom"] as? String else { return nil }
                return KnownIssue(symptom: symptom, cause: issue["cause"] as? String, fix: issue["fix"] as? String)
            }
            let native = game["nativeMac"] as? [String: Any]
            return .curated(Game(
                title: game["title"] as? String ?? "", status: status, statusMeaning: root["status_meaning"] as? String,
                renderer: game["renderer"] as? String, notes: game["notes"] as? String, provenance: game["provenance"] as? String,
                launchArgs: game["launchArgs"] as? [String] ?? [], knownIssues: issues, reports: root["reports"] as? Int ?? 0,
                hasRecipe: root["recipe"] as? Bool ?? false,
                nativeMac: native?["available"] as? Bool == true ? (native?["where"] as? String ?? "") : nil,
                page: page))
        case "prediction":
            guard let prediction = root["prediction"] as? [String: Any],
                  let verdict = prediction["macPrediction"] as? String else { return nil }
            return .prediction(Prediction(
                title: prediction["title"] as? String ?? "", macPrediction: verdict, label: root["label"] as? String ?? verdict,
                protonTier: prediction["protonTier"] as? String, recentReports: prediction["recentReports"] as? Int ?? 0,
                page: page))
        default:
            return nil
        }
    }
}

extension HighballDB.Game {
    /// The graphics layer MacHub can apply for the database's renderer (D3DMetal waits for MacHub's DX12 support).
    var graphicsChoice: GraphicsChoice? {
        switch renderer {
        case "dxmt": .dxmt
        case "dxvk": .dxvk
        case "wined3d": .wined3d
        case "d3dmetal": .d3dmetal
        default: nil
        }
    }
}
