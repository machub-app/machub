import Foundation
import Observation

/// One guided import of a Windows file: identify it, pick or create a bottle, confirm, run the installer
/// while watching its process, then let the user choose what to add to the library. Nothing runs unconfirmed.
@MainActor @Observable
final class InstallerImport: Identifiable {
    enum Mode: Hashable { case installer, program }

    enum Destination: Hashable {
        case existing(String)
        case new(String)
    }

    enum Phase: Equatable {
        /// File identified; the user picks mode, bottle and name.
        case review
        case creatingBottle(BottleProvisioner.Step)
        /// Last stop before anything Windows runs.
        case confirm
        case waitingForInstaller
        case installing(since: Date)
        case scanning
        /// Programs the installer added, best guess first.
        case choose([String])
        case done(Title.ID)
        case failed(Issue)
        case cancelled
    }

    enum Issue: Equatable {
        case inspection(WindowsFile.InspectionError)
        case bottle(String)
        case fileGone
        case installerNotStarted(log: String?)
        case installerFailed(String, log: String?)
        /// The installer finished but no new program appeared in the bottle's program folders.
        case nothingInstalled
    }

    struct Dependencies {
        var install: WhiskyInstall
        var bottles: @Sendable () -> [BottleInfo]
        var whiskyRunner: WhiskyCLI.Runner = { try await ProcessRunner.run($0, $1, timeout: $2) }
        var provisionRunner: BottleProvisioner.Runner? = nil
        var snapshot: ProcessWatch.Snapshot = ProcessWatch.snapshot
        var startTimeout: Duration = .seconds(90)
        var pollInterval: Duration = .seconds(1)
        var scan: @Sendable (URL) -> Set<String> = { InstalledProgramScanner.executables(in: $0) }
        var availableBytes: @Sendable (URL) -> Int64? = { url in
            (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        }
        var terminate: @Sendable (Int32) -> Void = { pid in _ = kill(pid, SIGTERM) }
    }

    nonisolated let id = UUID()
    let file: WindowsFile?
    private(set) var phase: Phase
    var mode: Mode
    var destination: Destination
    var name: String
    private(set) var lowDisk = false
    private var dependencies: Dependencies?
    private var task: Task<Void, Never>?
    private var installerTarget: ProcessWatch.Target?

    static let newBottleBase = "MacHub Apps"

    init(url: URL, dependencies: Dependencies?) {
        self.dependencies = dependencies
        let bottles = dependencies?.bottles().filter { $0.isRegistered && $0.hasDriveC }.compactMap(\.name) ?? []
        // Programs get their own bottle by default, so a game's Steam bottle is never the default target.
        let preferred = bottles.first { $0.hasPrefix(Self.newBottleBase) }
        destination = preferred.map(Destination.existing)
            ?? .new(BottleProvisioner.uniqueName(Self.newBottleBase, taken: dependencies?.bottles().compactMap(\.name) ?? []))
        do {
            let inspected = try WindowsFile.inspect(url)
            file = inspected
            mode = inspected.looksLikeInstaller ? .installer : .program
            let cleaned = inspected.displayName.replacing(/(?i)[-_ ]?(setup|installer|install|x64|x86|win64|win32)\b/, with: "")
                .trimmingCharacters(in: .whitespaces)
            name = cleaned.isEmpty ? inspected.displayName : cleaned
            phase = dependencies == nil ? .failed(.bottle("Whisky isn't ready.")) : .review
        } catch {
            file = nil
            mode = .installer
            name = url.deletingPathExtension().lastPathComponent
            phase = .failed(.inspection(error))
        }
        if let dependencies, let file {
            let container = BottleReader.containerURL(bundleID: dependencies.install.bundleIdentifier ?? WhiskyLocator.forkBundleID)
            // Installers unpack several times their own size; below 2 GB free, say so before starting.
            if let free = dependencies.availableBytes(FileManager.default.fileExists(atPath: container.path) ? container : FileManager.default.homeDirectoryForCurrentUser) {
                lowDisk = free < max(2 << 30, file.size * 4)
            }
        }
    }

    var bottleChoices: [String] {
        dependencies?.bottles().filter { $0.isRegistered && $0.hasDriveC }.compactMap(\.name) ?? []
    }

    var newBottleName: String {
        BottleProvisioner.uniqueName(Self.newBottleBase, taken: dependencies?.bottles().compactMap(\.name) ?? [])
    }

    /// From review: creates the bottle if asked, then either confirms the installer or registers the program.
    func proceed(register: @escaping (URL, String, String) -> Title.ID) {
        guard let dependencies, file != nil else { return }
        task = Task {
            var bottleName: String
            switch destination {
            case .existing(let name): bottleName = name
            case .new(let name):
                let provisioner = BottleProvisioner(install: dependencies.install, bottles: dependencies.bottles, runner: dependencies.provisionRunner)
                do {
                    _ = try await provisioner.provision(name: name) { step in
                        await MainActor.run { self.phase = .creatingBottle(step) }
                    }
                } catch {
                    phase = .failed(.bottle(Self.describe(error)))
                    return
                }
                bottleName = name
                destination = .existing(name)
            }
            switch mode {
            case .installer: phase = .confirm
            case .program:
                guard let file, FileManager.default.fileExists(atPath: file.url.path) else { phase = .failed(.fileGone); return }
                phase = .done(register(file.url, bottleName, name))
            }
        }
    }

    /// The user confirmed: run the installer in the bottle and follow it until it exits.
    func runInstaller() {
        guard let dependencies, let file, case .existing(let bottleName) = destination,
              let bottle = dependencies.bottles().first(where: { $0.name == bottleName }) else { return }
        guard FileManager.default.fileExists(atPath: file.url.path) else { phase = .failed(.fileGone); return }
        phase = .waitingForInstaller
        let target: ProcessWatch.Target = switch file.kind {
        case .msi: .executableWithArgument("msiexec.exe", file.name)
        case .executable: .executable(file.name)
        }
        installerTarget = target
        let cli = WhiskyCLI(install: dependencies.install, runner: dependencies.whiskyRunner)
        task = Task {
            let before = await Task.detached { dependencies.scan(bottle.url) }.value
            let outcome = HandoffResult()
            Task.detached {
                do {
                    switch file.kind {
                    case .msi:
                        // Wine maps the Mac's root to Z:, so the package keeps its own path.
                        _ = try await cli.run(#"C:\windows\system32\msiexec.exe"#, bottle: bottleName,
                                              arguments: ["/i", Self.windowsPath(file.url)], timeout: 6 * 3600)
                    case .executable:
                        _ = try await cli.run(file.url.path, bottle: bottleName, timeout: 6 * 3600)
                    }
                } catch {
                    await outcome.fail(error)
                }
            }
            let clock = ContinuousClock()
            let deadline = clock.now + dependencies.startTimeout
            var seen = false
            while clock.now < deadline, !Task.isCancelled {
                if !ProcessWatch.matches(in: await dependencies.snapshot(), target: target).isEmpty { seen = true; break }
                if let error = await outcome.error {
                    phase = .failed(.installerFailed(Self.describe(error), log: Self.log(error)))
                    return
                }
                try? await Task.sleep(for: dependencies.pollInterval)
            }
            guard !Task.isCancelled else { return }
            guard seen else { phase = .failed(.installerNotStarted(log: ProcessWatch.latestWineLog()?.path)); return }
            phase = .installing(since: .now)
            await ProcessWatch.waitForExit(target, interval: dependencies.pollInterval, snapshot: dependencies.snapshot)
            guard !Task.isCancelled else { return }
            phase = .scanning
            let after = await Task.detached { dependencies.scan(bottle.url) }.value
            let added = InstalledProgramScanner.added(before: before, after: after, hint: file.displayName)
            phase = added.isEmpty ? .failed(.nothingInstalled) : .choose(added)
        }
    }

    /// Registers the program the user picked among what the installer added.
    func choose(_ path: String, register: (URL, String, String) -> Title.ID) {
        guard case .existing(let bottle) = destination else { return }
        phase = .done(register(URL(filePath: path), bottle, name))
    }

    /// Before the installer runs this just stops; while it runs, it asks the installer's processes to quit.
    func cancel() {
        task?.cancel()
        if case .installing = phase, let target = installerTarget, let dependencies {
            Task {
                for match in ProcessWatch.matches(in: await dependencies.snapshot(), target: target) {
                    dependencies.terminate(match.pid)
                }
            }
        } else if phase == .waitingForInstaller, let target = installerTarget, let dependencies {
            Task {
                for match in ProcessWatch.matches(in: await dependencies.snapshot(), target: target) {
                    dependencies.terminate(match.pid)
                }
            }
        }
        phase = .cancelled
    }

    var isWorking: Bool {
        switch phase {
        case .creatingBottle, .waitingForInstaller, .installing, .scanning: true
        default: false
        }
    }

    nonisolated static func windowsPath(_ url: URL) -> String {
        "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case BottleProvisioner.Failure.createFailed(let message): "Whisky couldn't create the bottle: \(message)"
        case BottleProvisioner.Failure.bootFailed(let message): "Wine couldn't set up the bottle: \(message)"
        case BottleProvisioner.Failure.notRegistered(let name): "The bottle “\(name)” doesn't appear in Whisky."
        default: LibraryStore.describe(error)
        }
    }

    private static func log(_ error: Error) -> String? {
        if case WhiskyError.programExit(_, let path)? = error as? WhiskyError { return path }
        return nil
    }
}

private actor HandoffResult {
    private(set) var error: Error?
    func fail(_ error: Error) { self.error = error }
}
