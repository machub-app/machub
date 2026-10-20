import AppKit
import Foundation

/// Closing every Windows program MacHub started, when MacHub quits. Steam gets a clean `-shutdown` first (it syncs
/// cloud saves on the way out), then each environment's wineserver is ended, then anything left is killed: a Wine
/// program whose wineserver is gone can't redraw or close (the black, frozen window seen on 2026-10-20).
enum WineShutdown {
    enum Policy: String, CaseIterable, Sendable {
        case ask, quit, leave
    }

    static let policyKey = "quit.windowsPrograms"

    static var policy: Policy {
        get { UserDefaults.standard.string(forKey: policyKey).flatMap(Policy.init(rawValue:)) ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: policyKey) }
    }

    static var runtimesRoot: URL { RuntimeManager.live.directory }

    /// Windows programs (and wineservers) of MacHub's engines still running.
    static var hasRunningPrograms: Bool { !ProcessWatch.runtimeProcesses(under: runtimesRoot).isEmpty }

    static func quitAll() async {
        guard let runtime = RuntimeManager.live.current() else { return await killLeftovers() }
        let engine = EmbeddedWineEngine(runtime: runtime)
        let prefixes = PrefixStore.live.all()
        if let steam = prefixes.first(where: { SteamLibrary.steamRoot(inPrefix: $0.url) != nil }),
           !ProcessWatch.matches(in: await ProcessWatch.snapshot(), target: .executable(LaunchPlan.steamExecutable)).isEmpty {
            _ = try? await engine.run(SteamSetup.steamExe, bottle: steam.name, arguments: ["-shutdown"], timeout: 20)
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline,
                  !ProcessWatch.matches(in: await ProcessWatch.snapshot(), target: .executable(LaunchPlan.steamExecutable)).isEmpty {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        for prefix in prefixes { try? await engine.stopAll(in: prefix.name) }
        try? await Task.sleep(for: .seconds(2))
        await killLeftovers()
    }

    static func killLeftovers() async {
        await ProcessWatch.terminate(ProcessWatch.runtimeProcesses(under: runtimesRoot).map(\.pid), grace: .seconds(2))
    }

    /// At launch: ends Windows programs an earlier session left without their wineserver. Never touches anything
    /// while a wineserver runs (a game started outside this session keeps running).
    static func cleanUpOrphans() async {
        await ProcessWatch.terminateOrphans(under: runtimesRoot)
    }

    /// What to do on quit, asking when the policy says so. Returns nil when the user cancels quitting.
    @MainActor static func decideOnQuit() -> Bool? {
        switch policy {
        case .quit: return true
        case .leave: return false
        case .ask: break
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit the Windows programs too?")
        alert.informativeText = String(localized: "Steam for Windows or a game is still running. Left open, they keep using memory and can end up frozen in a black window once MacHub is gone. Steam is closed properly first, so your cloud saves sync.")
        alert.addButton(withTitle: String(localized: "Quit Them Too"))
        alert.addButton(withTitle: String(localized: "Leave Them Running"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")
        let answer = alert.runModal()
        let quit: Bool?
        switch answer {
        case .alertFirstButtonReturn: quit = true
        case .alertSecondButtonReturn: quit = false
        default: quit = nil
        }
        if let quit, alert.suppressionButton?.state == .on { policy = quit ? .quit : .leave }
        return quit
    }
}
