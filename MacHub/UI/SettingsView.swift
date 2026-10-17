import SwiftUI

/// Native grouped settings: language, demo content, and the real Whisky state (formerly the B2 diagnostics screen).
struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("whiskyCmdPath") private var customPath = ""
    @AppStorage("showDemoTitles") private var showDemo = true
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system
    @State private var choosingFile = false

    var body: some View {
        Form {
            Section("General") {
                Picker(selection: $language) {
                    ForEach(AppLanguage.allCases) { $0.label.tag($0) }
                } label: {
                    Text("Language")
                }
            }
            Section {
                Toggle("Show demo titles", isOn: $showDemo)
            } header: {
                Text("Library")
            } footer: {
                Text("Demo titles let you explore MacHub before your own games are installed. They are labelled and can't be launched.")
            }
            Section("Whisky") {
                if let report = store.report {
                    WhiskyStatusRow(status: report.status)
                    if let present = report.librariesPresent {
                        LabeledContent("Wine runtime") { Text(present ? "Installed" : "Missing") }
                    }
                    ForEach(store.loadErrors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Compatibility.issues.tint)
                    }
                    DisclosureGroup("Diagnostics") {
                        if let install = report.status.install { InstallDetails(install: install) }
                        HStack {
                            TextField("Custom WhiskyCmd path", text: $customPath, prompt: Text("Automatic detection"))
                            Button("Choose…") { choosingFile = true }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            ForEach((store.report?.containers ?? []).filter(\.exists)) { container in
                Section {
                    if container.bottles.isEmpty {
                        Text("No bottles yet. Create one in Whisky.").foregroundStyle(.secondary)
                    }
                    ForEach(container.bottles) { BottleRow(bottle: $0) }
                } header: {
                    Text(container.bundleID == WhiskyLocator.forkBundleID ? "Bottles · Whisky" : "Bottles · original Whisky (read only)")
                } footer: {
                    if container.bundleID != WhiskyLocator.forkBundleID, !container.bottles.isEmpty {
                        Text("These bottles come from the original Whisky. “Not set up” means Wine never created the bottle's files, so it can't run anything. MacHub never changes them.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { store.spotlight = nil }
        .navigationTitle("Settings")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh(customPath: customPath) } }
                .disabled(store.isLoading)
            Button("Copy Report", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.report?.text ?? "", forType: .string)
            }
            .disabled(store.report == nil)
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { customPath = url.path }
        }
    }
}

private struct WhiskyStatusRow: View {
    let status: WhiskyStatus

    var body: some View {
        switch status {
        case .ready(let install):
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            LabeledContent("Version") { Text(verbatim: install.version ?? "—") }
        case .outdated(_, let missing):
            Label("This Whisky is too old for MacHub", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Missing commands: \(missing.joined(separator: ", ")). Install the maintained fork (frankea/Whisky).")
                .foregroundStyle(.secondary)
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
                Text(bottle.isRegistered ? "Registered" : "Not registered")
                Text(verbatim: "·")
                Text(bottle.hasDriveC ? "Set up" : "Not set up")
                    .foregroundStyle(bottle.hasDriveC ? Color.secondary : Color.orange)
            }
        } label: {
            Text(verbatim: bottle.name ?? "—")
            // Same-named bottles stay distinguishable without hovering: short folder ID.
            Text(verbatim: "#" + bottle.url.lastPathComponent.suffix(6)).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .help(Text(verbatim: bottle.url.path))
    }
}
