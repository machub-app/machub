import SwiftUI

/// Full-window launch screen: the title's art, its logo, and only the steps MacHub can actually observe.
struct LaunchOverlay: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let id = store.presentedLaunch, let session = store.launchSessions[id], let state = store.launchStates[id] {
                LaunchScreen(session: session, state: state)
                    .id(id)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.03)))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.45), value: store.presentedLaunch)
    }
}

private struct LaunchScreen: View {
    let session: LibraryStore.LaunchSession
    let state: LibraryStore.LaunchState
    @Environment(LibraryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var title: Title { session.title }
    private var steps: [LaunchTimeline.Step] {
        LaunchTimeline.steps(for: session.route, steamAlreadyRunning: session.steamAlreadyRunning)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            VStack(alignment: .leading, spacing: 28) {
                LogoArt(title: title, maxHeight: 110, fallbackSize: 48)
                VStack(alignment: .leading, spacing: 10) {
                    Text(headline)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.opacity)
                        .accessibilityAddTraits([.isHeader, .updatesFrequently])
                    if let detail {
                        Text(detail)
                            .font(.title3)
                            .foregroundStyle(Theme.textPrimary.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                if state.isInProgress { SweepIndicator() }
                StepList(steps: steps, session: session, state: state)
                LongWaitNotice(session: session, state: state)
                actions
            }
            .padding(.horizontal, 64)
            .padding(.bottom, 64)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
        .ignoresSafeArea()
        .contentShape(.rect)
        .onAppear {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.6).delay(0.1)) { appeared = true }
        }
        .task(id: state) {
            // Once the game's process is seen, step aside after a moment: its window opens on top anyway.
            guard case .running = state else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, store.presentedLaunch == title.id { store.dismissLaunch() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var backdrop: some View {
        ZStack {
            ArtworkImage(title: title, artwork: .hero)
                .blur(radius: 18, opaque: true)
                .scaleEffect(appeared || reduceMotion ? 1.0 : 1.08)
                .animation(reduceMotion ? nil : .smooth(duration: 1.4), value: appeared)
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.55), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            switch state {
            case .running, .closed, .exited:
                Button("Back to MacHub") { store.dismissLaunch() }
                    .buttonStyle(PrimaryActionStyle())
                    .keyboardShortcut(.defaultAction)
            case .blocked, .notStarted, .failed, .crashedAtStart, .cancelled:
                Button {
                    store.retryLaunch(title.id)
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryActionStyle())
                .disabled(isBlockedForGood)
                if let log {
                    Button {
                        NSWorkspace.shared.open(URL(filePath: log))
                    } label: {
                        Label("Technical details", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(SecondaryActionStyle())
                }
                Button("Back to the title") { store.dismissLaunch() }
                    .buttonStyle(SecondaryActionStyle())
                    .keyboardShortcut(.cancelAction)
            default:
                Button("Stop waiting") { store.cancelLaunch(title.id) }
                    .buttonStyle(SecondaryActionStyle())
                Button("Hide") { store.dismissLaunch() }
                    .buttonStyle(SecondaryActionStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("The launch carries on; its progress stays on the title's page.")
            }
        }
    }

    /// A missing bottle or program won't fix itself by retrying.
    private var isBlockedForGood: Bool {
        if case .blocked(let problem) = state { problem != .whiskyNotReady } else { false }
    }

    private var log: String? {
        switch state {
        case .failed(_, let log), .notStarted(let log), .crashedAtStart(_, let log): log
        default: nil
        }
    }

    private var headline: LocalizedStringKey {
        let name = title.name
        switch state {
        case .running: return title.kind == .game ? "\(name) is running" : "\(name) is open"
        case .closed, .exited: return "\(name) closed"
        case .crashedAtStart: return "\(name) closed right after starting"
        case .notStarted: return "\(name) didn't start"
        case .blocked, .failed: return "Can't start \(name)"
        case .cancelled: return "Stopped waiting for \(name)"
        default: return "Starting \(name)"
        }
    }

    private var detail: LocalizedStringKey? {
        switch state {
        case .running(let exe?): return "Process \(exe) detected. Its window may take a few more seconds to appear."
        case .running(nil): return "Its process was detected. Its window may take a few more seconds to appear."
        case .crashedAtStart(let seconds, _): return "Its process stopped after \(seconds) s. It most likely crashed while starting; the technical details may say why."
        case .notStarted: return title.kind == .game
            ? "No process from the game's folder appeared in 3 minutes. Steam may be showing a message in its own window."
            : "The program's process never appeared."
        case .blocked(let problem): return problem.message
        case .failed(let message, _): return "Whisky reported: \(message)"
        case .cancelled: return "MacHub stopped watching. If the title still starts, it opens normally."
        case .closed: return "Its processes have ended."
        default: return nil
        }
    }
}

/// The checklist. A step is ticked only when the state proves it.
private struct StepList: View {
    let steps: [LaunchTimeline.Step]
    let session: LibraryStore.LaunchSession
    let state: LibraryStore.LaunchState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(steps, id: \.self) { step in
                let status = LaunchTimeline.status(of: step, in: steps, state: state, route: session.route)
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    StepMark(status: status).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(step)).font(.body.weight(status == .active ? .semibold : .regular))
                            .foregroundStyle(status == .pending ? Theme.textSecondary : Theme.textPrimary)
                        if status == .active || status == .failed, let note = note(step) {
                            Text(note).font(.callout).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if status == .active, step == .waitForGame || step == .startSteam || step == .handOff {
                        TimelineView(.periodic(from: session.stepStartedAt, by: 1)) { context in
                            Text(verbatim: "\(max(0, Int(context.date.timeIntervalSince(session.stepStartedAt)))) s")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(statusLabel(status))
            }
        }
        .animation(.snappy, value: state)
    }

    private func label(_ step: LaunchTimeline.Step) -> LocalizedStringKey {
        switch step {
        case .prepare: "Preparing the environment"
        case .checkBottle: "Checking the bottle"
        case .startSteam: "Starting Steam for Windows"
        case .handOff: "Starting the program"
        case .waitForGame: "Waiting for the game"
        case .running: session.title.kind == .game ? "Game started" : "Program started"
        }
    }

    private func note(_ step: LaunchTimeline.Step) -> LocalizedStringKey? {
        switch step {
        case .checkBottle: if let bottle = session.title.bottle { "Bottle “\(bottle)”" } else { nil }
        case .startSteam: "Steam wasn't running in this bottle. Its first start can take a minute."
        case .waitForGame: "Steam received the request. MacHub is watching for the game's own process."
        case .handOff: "Wine is opening the program."
        default: nil
        }
    }

    private func statusLabel(_ status: LaunchTimeline.StepStatus) -> Text {
        switch status {
        case .pending: Text("Not started")
        case .active: Text("In progress")
        case .done: Text("Done")
        case .failed: Text("Failed")
        }
    }
}

private struct StepMark: View {
    let status: LaunchTimeline.StepStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Compatibility.great.tint)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Compatibility.issues.tint)
        case .active:
            if reduceMotion {
                Image(systemName: "circle.dotted").foregroundStyle(Theme.textPrimary)
            } else {
                ProgressView().controlSize(.small).tint(Theme.textPrimary)
            }
        case .pending:
            Image(systemName: "circle").foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
    }
}

/// Indeterminate progress as a light sweeping along a hairline. No percentage: none is known.
private struct SweepIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let width: CGFloat = 280
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.textPrimary.opacity(0.14))
            if !reduceMotion {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    let eased = 0.5 - cos(t * .pi) / 2
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, Theme.textPrimary.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 90)
                        .offset(x: -90 + (width + 90) * eased)
                }
            }
        }
        .frame(width: width, height: 2)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

/// After 45 s on a waiting step, say what may be happening instead of spinning silently.
private struct LongWaitNotice: View {
    let session: LibraryStore.LaunchSession
    let state: LibraryStore.LaunchState

    var body: some View {
        if state == .waitingForGame || state == .startingSteam || state == .startingProcess {
            TimelineView(.periodic(from: session.stepStartedAt, by: 5)) { context in
                if context.date.timeIntervalSince(session.stepStartedAt) > 45 {
                    Label {
                        Text(state == .startingSteam
                             ? "Taking longer than usual. Steam may be updating itself: check its window in the Dock."
                             : "Taking longer than usual. Steam may be updating the game, installing a prerequisite or waiting for you in its window. MacHub keeps watching for up to 3 minutes.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.callout)
                    .foregroundStyle(Compatibility.playable.tint)
                    .frame(maxWidth: 620, alignment: .leading)
                    .transition(.opacity)
                }
            }
        }
    }
}

extension LaunchProblem {
    var message: LocalizedStringKey {
        switch self {
        case .whiskyNotReady: "Whisky isn't ready. See Settings."
        case .bottleMissing(let name): "The bottle “\(name)” no longer exists in Whisky."
        case .bottleNotSetUp(let name): "The bottle “\(name)” has never been set up by Wine."
        case .executableMissing(let path): "The program is missing from its folder: \(path)"
        case .steamMissing(let name): "Steam for Windows isn't installed in the bottle “\(name)”."
        }
    }
}
