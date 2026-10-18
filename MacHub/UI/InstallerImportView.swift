import SwiftUI
import UniformTypeIdentifiers

/// The guided import sheet. Every step that runs something has its own explicit button.
struct InstallerImportView: View {
    @Bindable var session: InstallerImport
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pickedPath: String?
    @State private var choosingManually = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileHeader(file: session.file, fallbackName: session.name)
                .padding(24)
            Divider()
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220)
            Divider()
            footer.padding(16)
        }
        .frame(width: 640)
        .frame(minHeight: 420)
        .background(Theme.ground)
        .interactiveDismissDisabled(session.isWorking)
        .fileImporter(isPresented: $choosingManually, allowedContentTypes: [WindowsFile.contentTypes[0]]) { result in
            if case .success(let url) = result { session.choose(url.path, register: register) }
        }
    }

    // MARK: Content per phase

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .review: review
        case .creatingBottle(let step):
            ProgressRow(title: step == .creating ? "Creating the bottle…" : "Wine is preparing Windows in the bottle…",
                        note: "This takes about a minute the first time. Nothing else on your Mac changes.")
        case .confirm: confirm
        case .waitingForInstaller:
            ProgressRow(title: "Starting the installer…", note: "Its window opens on your Mac in a moment.")
        case .installing(let since):
            VStack(alignment: .leading, spacing: 14) {
                ProgressRow(title: "Installer running", note: "Follow the installer's own window to the end. MacHub waits until it closes.")
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(since)), format: .time(pattern: .minuteSecond))
                        .font(.callout.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            }
        case .scanning:
            ProgressRow(title: "Looking for what was installed…", note: "MacHub compares the bottle's program folders with how they were before.")
        case .choose(let paths): choose(paths)
        case .done:
            ResultRow(symbol: "checkmark.circle.fill", tint: Compatibility.great.tint, title: "Added to Software",
                      message: "\(session.name) is in your library. Play opens it in its bottle.")
        case .failed(let issue): failure(issue)
        case .cancelled:
            ResultRow(symbol: "stop.circle", tint: Theme.textSecondary, title: "Stopped",
                      message: "Nothing was added to MacHub. If the installer had started copying files, they stay in the bottle.")
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What is this file?").font(.headline)
                Picker("What is this file?", selection: $session.mode) {
                    Text("An installer").tag(InstallerImport.Mode.installer)
                    Text("The program itself").tag(InstallerImport.Mode.program)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(session.mode == .installer
                     ? "MacHub runs it in a bottle, then adds the program it installs."
                     : "MacHub adds it as it is, from where it is now. Keep the file in place.")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Name in MacHub").font(.headline)
                TextField("Name in MacHub", text: $session.name).textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 320)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Bottle").font(.headline)
                Picker("Bottle", selection: $session.destination) {
                    Text("New bottle “\(session.newBottleName)”").tag(InstallerImport.Destination.new(session.newBottleName))
                    if !session.bottleChoices.isEmpty { Divider() }
                    ForEach(session.bottleChoices, id: \.self) { name in
                        Text(verbatim: name).tag(InstallerImport.Destination.existing(name))
                    }
                }
                .labelsHidden()
                .fixedSize()
                Text("A bottle is a separate Windows environment managed by Whisky. A dedicated bottle keeps programs apart from your games.")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
            }
            if session.lowDisk {
                Label("Less than 2 GB is free on this disk. The installation may fail.", systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(Compatibility.issues.tint)
            }
            if session.file?.isQuarantined == true {
                Label("Downloaded from the internet. Only run installers from publishers you trust: a Windows program in a bottle can read your files.",
                      systemImage: "exclamationmark.shield")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var confirm: some View {
        if let file = session.file, case .existing(let bottle) = session.destination {
            VStack(alignment: .leading, spacing: 12) {
                Text("Run \(file.name) in “\(bottle)”?").font(.title3.weight(.semibold))
                Text("The installer's own window opens on your Mac. Answer its questions and let it finish; MacHub follows it and then shows what it installed.")
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Avoid ticking options that launch the program at the end: MacHub waits for the installer to close.")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choose(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which program should MacHub open?").font(.headline)
            Text("The installer added these programs. The first one is MacHub's best guess.")
                .font(.callout).foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(paths.prefix(8), id: \.self) { path in
                    Button {
                        pickedPath = path
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: (pickedPath ?? paths.first) == path ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle((pickedPath ?? paths.first) == path ? Color.accentColor : Theme.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: URL(filePath: path).lastPathComponent).foregroundStyle(Theme.textPrimary)
                                Text(verbatim: Self.windowsDisplayPath(path)).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Name in MacHub")
                TextField("Name in MacHub", text: $session.name).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
            }
        }
    }

    @ViewBuilder
    private func failure(_ issue: InstallerImport.Issue) -> some View {
        switch issue {
        case .inspection(.notFound), .fileGone:
            ResultRow(symbol: "questionmark.folder", tint: Compatibility.issues.tint, title: "File not found",
                      message: "The file was moved or deleted. Download it again or choose it from its new place.")
        case .inspection(.unreadable):
            ResultRow(symbol: "lock", tint: Compatibility.issues.tint, title: "Can't read this file",
                      message: "macOS didn't let MacHub open it. Check that it's fully downloaded.")
        case .inspection(.unsupported(let reason)):
            ResultRow(symbol: "xmark.octagon", tint: Compatibility.unsupported.tint, title: "Not a supported Windows file",
                      message: LocalizedStringKey(reason))
        case .bottle(let message):
            ResultRow(symbol: "shippingbox", tint: Compatibility.issues.tint, title: "The bottle isn't ready", message: LocalizedStringKey(message))
        case .installerNotStarted(let log):
            ResultRow(symbol: "exclamationmark.triangle", tint: Compatibility.issues.tint, title: "The installer didn't start",
                      message: "No installer process appeared within 90 seconds.", log: log)
        case .installerFailed(let message, let log):
            ResultRow(symbol: "exclamationmark.triangle", tint: Compatibility.issues.tint, title: "The installer stopped with an error",
                      message: LocalizedStringKey(message), log: log)
        case .nothingInstalled:
            ResultRow(symbol: "magnifyingglass", tint: Compatibility.playable.tint, title: "No new program found",
                      message: "The installer closed, but no new program appeared in Program Files. It may have been cancelled, or installed somewhere else: you can choose the program yourself.")
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch session.phase {
            case .review:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(continueLabel) { session.proceed(register: register) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.name.trimmingCharacters(in: .whitespaces).isEmpty)
            case .confirm:
                Button("Cancel") { session.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run installer") { session.runInstaller() }.keyboardShortcut(.defaultAction)
            case .creatingBottle, .scanning:
                Button("Cancel") {}.disabled(true)
            case .waitingForInstaller, .installing:
                Button("Stop installer", role: .destructive) { session.cancel() }
            case .choose(let paths):
                Button("Choose another…") { choosingManually = true }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to MacHub") { session.choose(pickedPath ?? paths[0], register: register) }
                    .keyboardShortcut(.defaultAction)
            case .failed(.nothingInstalled):
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose the program…") { choosingManually = true }.keyboardShortcut(.defaultAction)
            case .done, .failed, .cancelled:
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private var continueLabel: LocalizedStringKey {
        if case .new(let name) = session.destination { return "Create “\(name)” and continue" }
        return session.mode == .installer ? "Continue" : "Add to MacHub"
    }

    private func register(_ url: URL, _ bottle: String, _ name: String) -> Title.ID {
        store.importProgram(at: url, bottle: bottle, name: name).id
    }

    static func windowsDisplayPath(_ path: String) -> String {
        guard let range = path.range(of: "/drive_c/") else { return path }
        return "C:\\" + path[range.upperBound...].replacingOccurrences(of: "/", with: "\\")
    }
}

private struct FileHeader: View {
    let file: WindowsFile?
    let fallbackName: String

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file?.url.path ?? ""))
                .resizable().frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: file?.name ?? fallbackName).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if let file {
                    HStack(spacing: 6) {
                        Text(kindLabel(file))
                        Text(verbatim: "·")
                        Text(file.size, format: .byteCount(style: .file))
                        if let host = file.downloadedFrom {
                            Text(verbatim: "·")
                            Text("from \(host)")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func kindLabel(_ file: WindowsFile) -> LocalizedStringKey {
        switch file.kind {
        case .msi: "Windows Installer package"
        case .executable(let arch, let engine?): "\(engine.rawValue) installer, \(arch == .x64 ? "64-bit" : "32-bit")"
        case .executable(let arch, nil): arch == .x64 ? "Windows program, 64-bit" : "Windows program, 32-bit"
        }
    }
}

private struct ProgressRow: View {
    let title: LocalizedStringKey
    let note: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ProgressView().controlSize(.small).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(note).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ResultRow: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var log: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                if let log {
                    Button {
                        NSWorkspace.shared.open(URL(filePath: log))
                    } label: {
                        Label("Show Wine log", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }
}

/// Files opened from Finder ("Open With > MacHub") or dropped on the window, waiting for the import sheet.
@MainActor @Observable
final class ImportInbox {
    static let shared = ImportInbox()
    var pending: [URL] = []

    func receive(_ urls: [URL]) {
        pending += urls.filter(WindowsFile.isCandidate)
    }
}

/// Windows installers in the Downloads folder, read only when the user asks. No background watching.
enum DownloadsScanner {
    static func recentInstallers(limit: Int = 8, fileManager: FileManager = .default) -> [URL] {
        guard let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return [] }
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let files = (try? fileManager.contentsOfDirectory(at: downloads, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        func date(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast
        }
        return files.filter(WindowsFile.isCandidate).sorted { date($0) > date($1) }.prefix(limit).map { $0 }
    }
}
