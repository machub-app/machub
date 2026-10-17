import Foundation
import Observation

/// The library the UI reads: real games reported by Whisky, plus demo titles when enabled.
@MainActor @Observable
final class LibraryStore {
    enum LaunchState: Equatable {
        case launching
        /// WhiskyCmd handed the request to Steam. The game process itself is not verified yet.
        case handedToSteam
        case failed(String)
    }

    private(set) var report: DiagnosticsReport?
    private(set) var realTitles: [Title] = []
    private(set) var loadErrors: [String] = []
    private(set) var isLoading = false
    private(set) var launchStates: [Title.ID: LaunchState] = [:]
    /// The title whose artwork lights the window (hero, hovered card, open detail).
    var spotlight: Title?

    func titles(includeDemo: Bool) -> [Title] {
        realTitles + (includeDemo ? DemoLibrary.titles : [])
    }

    func featured(includeDemo: Bool) -> [Title] {
        let real = Array(realTitles.prefix(5))
        guard includeDemo, real.count < 5 else { return real }
        let demo = DemoLibrary.featuredIDs.compactMap { id in DemoLibrary.titles.first { $0.id == id } }
        return real + demo.prefix(5 - real.count)
    }

    var registeredBottles: [BottleInfo] {
        guard case .ready? = report?.status else { return [] }
        return report?.containers.first { $0.bundleID == WhiskyLocator.forkBundleID }?.bottles.filter(\.isRegistered) ?? []
    }

    func refresh(customPath: String?) async {
        isLoading = true
        defer { isLoading = false }
        let report = await DiagnosticsReport.make(customPath: customPath)
        self.report = report
        guard case .ready(let install) = report.status else {
            realTitles = []
            return
        }
        let cli = WhiskyCLI(install: install)
        var found: [Title] = []
        var errors: [String] = []
        for bottle in registeredBottles where bottle.hasDriveC {
            guard let name = bottle.name else { continue }
            do {
                found += try await cli.games(bottle: name).map { Title(game: $0, bottle: name) }
            } catch {
                errors.append("\(name): \(Self.describe(error))")
            }
        }
        realTitles = found
        loadErrors = errors
    }

    func launch(_ title: Title) async {
        guard title.canLaunch, let appID = title.steamAppID, let bottle = title.bottle,
              case .ready(let install)? = report?.status
        else { return }
        launchStates[title.id] = .launching
        do {
            _ = try await WhiskyCLI(install: install).launch(appId: appID, bottle: bottle)
            launchStates[title.id] = .handedToSteam
        } catch {
            launchStates[title.id] = .failed(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? WhiskyError {
        case .failure(let message), .invalidInvocation(let message): message
        case .programExit(let code, let log): "Exited with code \(code)" + (log.map { ". Log: \($0)" } ?? "")
        case .timedOut(let seconds): "No answer from Whisky after \(Int(seconds)) s"
        case .unexpectedOutput: "Whisky returned something MacHub could not read"
        case nil: error.localizedDescription
        }
    }
}
