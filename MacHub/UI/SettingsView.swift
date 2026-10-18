import SwiftUI

/// Native grouped settings: language, demo content, and the real Whisky state (formerly the B2 diagnostics screen).
struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("whiskyCmdPath") private var customPath = ""
    @AppStorage("showDemoTitles") private var showDemo = false
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system
    @State private var choosingFile = false

    var body: some View {
        Form {
            SteamSettingsSection()
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

/// Steam: verified OpenID account and the optional Web API key (Keychain only).
private struct SteamSettingsSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var keyDraft = ""
    @State private var keyRejected = false

    var body: some View {
        let steam = store.steam
        Section {
            if let account = steam.account {
                HStack(spacing: 12) {
                    SteamAvatar(account: account, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: account.personaName ?? "—").font(.headline)
                        Text(verbatim: "SteamID64 \(account.steamID64)").font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Verified by Steam on \(account.verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link(destination: URL(string: "https://steamcommunity.com/profiles/\(account.steamID64)")!) {
                        Label("Profile", systemImage: "arrow.up.right.square")
                    }
                }
                LabeledContent("Profile visibility") { Text(account.visibility.label) }
                HStack {
                    Button("Sign in again") { Task { await steam.signIn() } }.disabled(steam.isBusy)
                    Button("Disconnect Steam", role: .destructive) { steam.signOut() }
                }
            } else {
                Text("Not connected. Sign in on Steam's own website: MacHub never sees your password, only your public SteamID, which it verifies with Steam.")
                    .foregroundStyle(.secondary)
                HStack {
                    if steam.isBusy {
                        ProgressView().controlSize(.small)
                        Text(steam.state == .verifying ? "Checking with Steam…" : "Waiting for the browser…")
                        Button("Cancel") { steam.cancelSignIn() }
                    } else {
                        Button("Sign in with Steam…") { Task { await steam.signIn() } }
                    }
                }
            }
            if case .failed(let problem) = steam.state {
                Label { Text(problem.message) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .foregroundStyle(Compatibility.issues.tint)
            }
        } header: {
            Text("Steam account")
        }

        Section {
            if steam.hasAPIKey {
                LabeledContent("Web API key") { Text("Saved in the Keychain") }
                LabeledContent("Library") { Text(ownedLabel) }
                Button("Remove key", role: .destructive) { steam.removeAPIKey(); keyDraft = "" }
            } else {
                SecureField("Web API key", text: $keyDraft, prompt: Text(verbatim: "0123456789ABCDEF…"))
                    .onSubmit(save)
                HStack {
                    Button("Save in Keychain", action: save).disabled(keyDraft.isEmpty)
                    Link(destination: URL(string: "https://steamcommunity.com/dev/apikey")!) {
                        Label("Get a key on Steam", systemImage: "arrow.up.right.square")
                    }
                }
                if keyRejected {
                    Text("That doesn't look like a Steam key (32 hexadecimal characters).").foregroundStyle(Compatibility.issues.tint)
                }
            }
        } header: {
            Text("Owned games (optional)")
        } footer: {
            Text("Signing in doesn't need a key. Steam only returns the list of games you own through its official Web API (IPlayerService/GetOwnedGames), which requires your personal key from steamcommunity.com/dev/apikey (for the domain, “localhost” is fine). MacHub keeps it in the macOS Keychain only and never writes it to files or logs. Your profile's “Game details” must also be public.")
        }
    }

    private var ownedLabel: LocalizedStringKey {
        switch store.ownedState {
        case .loaded: "\(store.ownedTitles.count) games"
        case .loading: "Loading…"
        case .privateProfile: "Game details are private"
        case .invalidKey: "Key refused by Steam"
        case .signedOut: "Connect Steam first"
        case .needsKey: "No key"
        case .failed: "Couldn't load"
        }
    }

    private func save() {
        keyRejected = !store.steam.saveAPIKey(keyDraft)
        if !keyRejected { keyDraft = "" }
    }
}

extension SteamAccount.Visibility {
    var label: LocalizedStringKey {
        switch self {
        case .public: "Public"
        case .friendsOnly: "Friends only"
        case .private: "Private"
        case .unknown: "Unknown"
        }
    }
}
