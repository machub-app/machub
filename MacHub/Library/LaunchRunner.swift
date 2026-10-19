import Foundation

/// What a launch will do, decided before anything runs.
struct LaunchPlan: Equatable, Sendable {
    enum Route: Equatable, Sendable {
        /// `steam.exe -applaunch <id>` inside the bottle; Steam then starts the game.
        case steam(appID: Int)
        /// `whisky run <bottle> <path>` for a program the user added.
        case program(path: String)
    }

    let route: Route
    let bottle: String
    /// The process that proves the title is really running.
    let target: ProcessWatch.Target

    static let steamExecutable = "steam.exe"
}

extension LaunchPlan.Route {
    var isSteam: Bool { if case .steam = self { true } else { false } }
}

/// Why a launch couldn't even start. Each case is a fact checked on disk, with its own fix.
enum LaunchProblem: Equatable, Sendable {
    case whiskyNotReady
    /// The bottle belongs to MacHub's own engine, but no runtime is installed (or Rosetta is missing).
    case engineNotReady
    case bottleMissing(String)
    case bottleNotSetUp(String)
    case executableMissing(String)
    case steamMissing(String)
}

/// Drives one launch from hand-off to exit and reports only what it observes in the process list.
/// No step is reported as done because a command returned: Wine and Steam return long before a game shows up.
struct LaunchRunner: Sendable {
    typealias Handoff = @Sendable (LaunchPlan) async throws -> Void

    var startTimeout: Duration = .seconds(180)
    var steamTimeout: Duration = .seconds(120)
    var pollInterval: Duration = .milliseconds(500)
    var exitInterval: Duration = .seconds(1)
    /// A process gone sooner than this almost certainly crashed while starting.
    var crashThreshold: Duration = .seconds(15)
    var snapshot: ProcessWatch.Snapshot = ProcessWatch.snapshot
    /// Processes from the title's folder that outlive the game (a launcher spinning after "bye!") are ended after this.
    var leftoverGrace: Duration = .seconds(20)
    var terminate: @Sendable ([Int32]) async -> Void = { await ProcessWatch.terminate($0) }
    var latestLog: @Sendable () -> String? = { ProcessWatch.latestWineLog()?.path }
    /// Hands the plan to Wine. For Steam it may only return when Steam quits, so it always runs detached.
    let handoff: Handoff

    func run(_ plan: LaunchPlan, update: @escaping @MainActor (LibraryStore.LaunchState) -> Void) async {
        let outcome = HandoffOutcome()
        let steamWasRunning: Bool
        if case .steam = plan.route {
            steamWasRunning = !ProcessWatch.matches(in: await snapshot(), target: .executable(LaunchPlan.steamExecutable)).isEmpty
        } else {
            steamWasRunning = false
        }

        if case .program = plan.route { await update(.startingProcess) }
        Task.detached {
            do { try await handoff(plan) } catch { await outcome.fail(error) }
        }

        // Steam for Windows takes a while to come up in a cold bottle: that's a step of its own.
        if case .steam = plan.route, !steamWasRunning {
            await update(.startingSteam)
            switch await poll(.executable(LaunchPlan.steamExecutable), timeout: steamTimeout, outcome: outcome) {
            case .found: break
            case .failed(let error): return await update(.failed(LibraryStore.describe(error), log: logPath(for: error)))
            case .cancelled: return await update(.cancelled)
            case .timedOut: return await update(.notStarted(log: latestLog()))
            }
        }

        await update(.waitingForGame)
        let found: [ProcessWatch.Match]
        switch await poll(plan.target, timeout: startTimeout, outcome: outcome) {
        case .found(let matches): found = matches
        case .failed(let error): return await update(.failed(LibraryStore.describe(error), log: logPath(for: error)))
        case .cancelled: return await update(.cancelled)
        case .timedOut: return await update(.notStarted(log: latestLog()))
        }

        let started = ContinuousClock.now
        await update(.running(found.first?.executable))
        await waitForExit(plan.target, initial: found)
        if Task.isCancelled { return }
        let lived = ContinuousClock.now - started
        await update(lived < crashThreshold
            ? .crashedAtStart(seconds: Int(lived.components.seconds), log: latestLog())
            : .closed)
    }

    /// Returns once none of the title's processes is left. A launcher that started the game and is still there 20 s
    /// after every process started after it has gone (BeamNG's launcher logs "bye!" and then spins at 100 % CPU under
    /// Wine, verified 2026-10-18) is ended: it belongs to the title and has nothing left to do.
    private func waitForExit(_ target: ProcessWatch.Target, initial: [ProcessWatch.Match]) async {
        let first = Set(initial.map(\.pid))
        var seen = first
        var misses = 0
        var leftoverSince: ContinuousClock.Instant?
        while misses < 2, !Task.isCancelled {
            try? await Task.sleep(for: exitInterval)
            let now = ProcessWatch.matches(in: await snapshot(), target: target)
            if now.isEmpty { misses += 1; continue }
            misses = 0
            let pids = Set(now.map(\.pid))
            seen.formUnion(pids)
            let later = seen.subtracting(first)
            guard !later.isEmpty, pids.isDisjoint(with: later) else { leftoverSince = nil; continue }
            let since = leftoverSince ?? ContinuousClock.now
            leftoverSince = since
            if ContinuousClock.now - since >= leftoverGrace { await terminate(Array(pids)) }
        }
    }

    private enum PollResult {
        case found([ProcessWatch.Match])
        case failed(Error)
        case cancelled
        case timedOut
    }

    private func poll(_ target: ProcessWatch.Target, timeout: Duration, outcome: HandoffOutcome) async -> PollResult {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if Task.isCancelled { return .cancelled }
            let found = ProcessWatch.matches(in: await snapshot(), target: target)
            if !found.isEmpty { return .found(found) }
            if let error = await outcome.error { return .failed(error) }
            try? await Task.sleep(for: pollInterval)
        }
        return Task.isCancelled ? .cancelled : .timedOut
    }

    private func logPath(for error: Error) -> String? {
        if case WhiskyError.programExit(_, let path)? = error as? WhiskyError, let path { return path }
        if case EngineError.programExit(_, let log)? = error as? EngineError { return log.path }
        return latestLog()
    }
}

/// The hand-off's failure, if Wine refused the launch before any process appeared.
private actor HandoffOutcome {
    private(set) var error: Error?
    func fail(_ error: Error) { self.error = error }
}

/// The steps shown on the launch screen for a route, and where a given state puts each of them.
enum LaunchTimeline {
    enum Step: Equatable, Sendable {
        case prepare, checkBottle, startSteam, handOff, waitForGame, running
    }

    enum StepStatus: Equatable, Sendable { case pending, active, done, failed }

    static func steps(for route: LaunchPlan.Route, steamAlreadyRunning: Bool) -> [Step] {
        switch route {
        case .steam: [.prepare, .checkBottle] + (steamAlreadyRunning ? [] : [.startSteam]) + [.waitForGame, .running]
        case .program: [.prepare, .checkBottle, .handOff, .running]
        }
    }

    /// The step a state is on (or ended on).
    static func current(_ state: LibraryStore.LaunchState, route: LaunchPlan.Route) -> Step {
        switch state {
        case .preparing: .prepare
        case .checkingBottle, .blocked: .checkBottle
        case .startingSteam: .startSteam
        case .startingProcess: if case .program = route { .handOff } else { .waitForGame }
        case .waitingForGame, .notStarted, .cancelled, .failed: if case .program = route { .handOff } else { .waitForGame }
        case .running, .closed, .crashedAtStart, .exited: .running
        case .installRequested: .prepare
        }
    }

    static func status(of step: Step, in steps: [Step], state: LibraryStore.LaunchState, route: LaunchPlan.Route) -> StepStatus {
        let now = current(state, route: route)
        guard let index = steps.firstIndex(of: step), let currentIndex = steps.firstIndex(of: now) else { return .pending }
        if index < currentIndex { return .done }
        if index > currentIndex { return .pending }
        switch state {
        case .blocked, .notStarted, .failed, .crashedAtStart, .cancelled: return .failed
        case .running, .closed, .exited: return .done
        default: return .active
        }
    }
}
