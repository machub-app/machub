import Foundation

/// Which build of a Steam game is out, and what its developer announced, to tell the player whether their copy is
/// current. Steam itself only exposes build numbers; version names (like "v0.40") come from announcement titles.
/// - Latest public build: `api.steamcmd.net/v1/info/<appid>` (a public mirror of Steam's app info, read-only).
/// - Announcements: Steam's own news API (`ISteamNews/GetNewsForApp`), community announcements only.
enum GameUpdates {
    struct Announcement: Equatable, Sendable {
        let title: String
        let date: Date
        let url: URL?
        /// "0.40", "1.2.3"… found in the title; nil when the title names no version.
        var version: String? { GameUpdates.version(in: title) }
    }

    struct Info: Equatable, Sendable {
        /// The build on Steam's public branch, 0 when unknown.
        var latestBuild = 0
        var latestBuildDate: Date?
        var announcements: [Announcement] = []
    }

    static func load(appID: Int, http: SteamHTTP = .shared) async -> Info {
        async let build = latestBuild(appID: appID, http: http)
        async let news = announcements(appID: appID, http: http)
        let (latest, items) = await (build, news)
        return Info(latestBuild: latest?.build ?? 0, latestBuildDate: latest?.date, announcements: items)
    }

    static func latestBuild(appID: Int, http: SteamHTTP = .shared) async -> (build: Int, date: Date?)? {
        guard let url = URL(string: "https://api.steamcmd.net/v1/info/\(appID)"),
              let data = try? await http.get(url, ttl: 3600).data else { return nil }
        return parseLatestBuild(data, appID: appID)
    }

    static func parseLatestBuild(_ data: Data, appID: Int) -> (build: Int, date: Date?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = (root["data"] as? [String: Any])?[String(appID)] as? [String: Any],
              let branch = ((app["depots"] as? [String: Any])?["branches"] as? [String: Any])?["public"] as? [String: Any],
              let build = (branch["buildid"] as? String).flatMap(Int.init) else { return nil }
        let time = (branch["timeupdated"] as? String).flatMap(TimeInterval.init)
        return (build, time.map { Date(timeIntervalSince1970: $0) })
    }

    static func announcements(appID: Int, http: SteamHTTP = .shared) async -> [Announcement] {
        guard let url = URL(string: "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=\(appID)&count=10&maxlength=1&feeds=steam_community_announcements"),
              let data = try? await http.get(url, ttl: 3600).data else { return [] }
        return parseAnnouncements(data)
    }

    static func parseAnnouncements(_ data: Data) -> [Announcement] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (root["appnews"] as? [String: Any])?["newsitems"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let title = item["title"] as? String, let seconds = item["date"] as? TimeInterval else { return nil }
            return Announcement(title: title, date: Date(timeIntervalSince1970: seconds), url: (item["url"] as? String).flatMap(URL.init(string:)))
        }
        .sorted { $0.date > $1.date }
    }

    /// A version number in an announcement title: "v0.40", "Update 1.2.3", "Patch 2.1" (not dates or prices).
    static func version(in title: String) -> String? {
        if let match = title.firstMatch(of: /(?i)\bv(\d+(?:\.\d+){1,3})\b/) { return String(match.1) }
        if let match = title.firstMatch(of: /(?i)\b(?:update|patch|version|hotfix(?:es)?(?: for)?)\s+v?(\d+(?:\.\d+){1,3})\b/) { return String(match.1) }
        return nil
    }

    /// The version the installed build most likely is: the newest announced version published before the build was
    /// installed (a day of slack, since a release and its announcement land within hours). An estimate, shown as such.
    static func likelyVersion(installedOn date: Date?, announcements: [Announcement]) -> Announcement? {
        guard let date else { return nil }
        return announcements.first { $0.version != nil && $0.date <= date.addingTimeInterval(24 * 3600) }
    }

    enum Status: Equatable {
        case upToDate
        /// A newer public build exists.
        case updateAvailable
        /// Steam already knows of an update (manifest flags) or is applying it.
        case pendingInSteam
        case unknown
    }

    static func status(installed: SteamApp, latestBuild: Int) -> Status {
        if installed.needsUpdate || installed.isUpdating || (installed.targetBuildID != 0 && installed.targetBuildID != installed.buildID) {
            return .pendingInSteam
        }
        guard latestBuild != 0, installed.buildID != 0 else { return .unknown }
        return latestBuild == installed.buildID ? .upToDate : (latestBuild > installed.buildID ? .updateAvailable : .upToDate)
    }
}
