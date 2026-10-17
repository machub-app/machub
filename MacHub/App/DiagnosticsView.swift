import SwiftUI

/// Raw environment check (step B2). Replaced by the real shell later; kept as a support screen.
struct DiagnosticsView: View {
    @AppStorage("whiskyCmdPath") private var customPath = ""
    @State private var report: DiagnosticsReport?
    @State private var choosingFile = false

    var body: some View {
        Form {
            LocalizationSpikeSection()
            Section("Whisky") {
                if let report {
                    WhiskyStatusRow(status: report.status)
                    if let present = report.librariesPresent {
                        LabeledContent("Wine Libraries folder", value: present ? "Present" : "Missing")
                    }
                } else {
                    ProgressView()
                }
                HStack {
                    TextField("Custom WhiskyCmd path", text: $customPath, prompt: Text("Automatic detection"))
                    Button("Choose…") { choosingFile = true }
                }
            }
            ForEach(report?.containers ?? []) { container in
                Section(container.bundleID) {
                    if !container.exists {
                        Text("No container on this Mac.").foregroundStyle(.secondary)
                    } else if container.bottles.isEmpty {
                        Text("No bottles.").foregroundStyle(.secondary)
                    }
                    ForEach(container.bottles) { BottleRow(bottle: $0) }
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
            Button("Copy Report", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report?.text ?? "", forType: .string)
            }
            .disabled(report == nil)
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { customPath = url.path }
        }
        .task(id: customPath) { await refresh() }
    }

    private func refresh() async {
        report = await DiagnosticsReport.make(customPath: customPath)
    }
}

/// Spike B5: shows which string APIs follow the in-app language. The last row is the expected
/// counter-example (`String(localized:)` reads Bundle.main and ignores `\.locale`).
private struct LocalizationSpikeSection: View {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system
    private let play: LocalizedStringResource = "Play"

    var body: some View {
        Section {
            Picker(selection: $language) {
                ForEach(AppLanguage.allCases) { $0.label.tag($0) }
            } label: {
                Text("Language")
            }
            LabeledContent { Text("Library") } label: { Text(verbatim: "Text literal") }
            LabeledContent { Text(play) } label: { Text(verbatim: "LocalizedStringResource") }
            LabeledContent { Text(verbatim: String(localized: "Settings")) } label: { Text(verbatim: "String(localized:) (control)") }
        } header: {
            Text(verbatim: "Localization spike")
        }
    }
}

private struct WhiskyStatusRow: View {
    let status: WhiskyStatus

    var body: some View {
        switch status {
        case .ready(let install):
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            InstallDetails(install: install)
        case .outdated(let install, let missing):
            Label("This Whisky is too old for MacHub", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Missing commands: \(missing.joined(separator: ", ")). Install the maintained fork (frankea/Whisky).")
                .foregroundStyle(.secondary)
            InstallDetails(install: install)
        case .notFound:
            Label("Whisky not found", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            Text("Install the maintained fork (frankea/Whisky) or set the WhiskyCmd path below.")
                .foregroundStyle(.secondary)
        case .invalidCustomPath(let url, let reason):
            Label("Custom path unusable", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            Text("\(url.path) — \(reason)").foregroundStyle(.secondary)
        }
    }
}

private struct InstallDetails: View {
    let install: WhiskyInstall

    var body: some View {
        if let app = install.appURL {
            LabeledContent("App", value: "\(app.lastPathComponent) \(install.version ?? "")")
            LabeledContent("Bundle ID", value: install.bundleIdentifier ?? "—")
        }
        LabeledContent("WhiskyCmd", value: install.cmdURL.path)
        LabeledContent("Commands", value: install.subcommands.sorted().joined(separator: " "))
    }
}

private struct BottleRow: View {
    let bottle: BottleInfo

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(bottle.isRegistered ? "Registered" : "Orphan")
                Text("·")
                Text(bottle.hasDriveC ? "Prefix ready" : "No drive_c")
                    .foregroundStyle(bottle.hasDriveC ? Color.secondary : Color.orange)
            }
        } label: {
            Text(bottle.name ?? "Unnamed")
            Text(bottle.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
        }
    }
}
