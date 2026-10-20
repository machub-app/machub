import Foundation
import Testing
@testable import MacHub

struct GameReportTests {
    func query(_ url: URL) -> [String: String] {
        Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
    }

    @Test func fillsHighballForm() {
        var report = GameReport(titleID: "steam:284160", titleName: "BeamNG.drive", steamAppID: 284160)
        report.rating = 4
        report.minutes = 25
        report.renderer = "dxmt"
        report.launchOptions = "-gfx dx11"
        report.engine = "machub-1.0.5"
        let q = query(report.highballURL)
        #expect(report.highballURL.host() == "github.com" && report.highballURL.path() == "/gauthierpiarrette/highball-db/issues/new")
        #expect(q["template"] == "report.yml" && q["title"] == "BeamNG.drive" && q["steam_appid"] == "284160")
        #expect(q["rating"] == "4 — playable, minor issues" && q["renderer"] == "dxmt" && q["engine"] == "machub-1.0.5")
        #expect(q["session"] == "Played for 25 min through MacHub." && q["settings"] == "Launch options: -gfx dx11")
    }

    @Test func fillsMacHubFormAndCrash() {
        var report = GameReport(titleID: "steam:1", titleName: "Game", steamAppID: 1)
        report.rating = 1
        report.crashedAtStart = true
        let q = query(report.macHubURL)
        #expect(q["template"] == "game-report.yml" && q["result"] == "Doesn't start" && q["graphics"] == "Don't know")
        #expect(report.sessionText.contains("within seconds"))
    }

    @Test func readsThisMac() {
        #expect(GameReport.chipName().contains("Apple"))
        #expect(GameReport.macOSVersion().split(separator: ".").count >= 2)
    }
}
