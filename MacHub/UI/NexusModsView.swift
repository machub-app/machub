import SwiftUI

/// Nexus Mods for one game: installed mods (enable, disable, remove) and the catalog (search, sort, install).
struct NexusModsSection: View {
    let title: Title
    let domain: String
    @Environment(LibraryStore.self) private var store
    @State private var query = ""
    @State private var sort: NexusMods.Sort = .endorsements
    @State private var results: [NexusMods.Mod] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var selected: NexusMods.Mod?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if store.nexusAccount == nil {
                if NexusKeyStore.load() == nil {
                    SourceBanner(text: "Browsing is open to everyone. To download, add your free Nexus Mods API key in Settings › Mods (nexusmods.com › Settings › API keys).")
                } else if let problem = store.nexusKeyProblem {
                    SourceBanner(text: LocalizedStringKey(problem))
                } else {
                    SourceBanner(text: "Checking your Nexus Mods account…")
                }
            }
            if domain == "beamngdrive" {
                SourceBanner(text: "Most BeamNG.drive mods live on BeamNG's own repository, which the game has built in (Mods in its main menu). Nexus has a smaller selection.")
            }
            InstalledNexusMods(title: title)
            OtherModSources(title: title)
            catalog
        }
        .task { if store.nexusAccount == nil { await store.refreshNexusAccount() } }
        .task(id: "\(query)|\(sort.rawValue)") { await search(reset: true) }
        .sheet(item: $selected) { mod in NexusModSheet(mod: mod, title: title) }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Catalog").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                Text(verbatim: total > 0 ? "\(total)" : "").foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("Sort", selection: $sort) {
                    Text("Most endorsed").tag(NexusMods.Sort.endorsements)
                    Text("Most downloaded").tag(NexusMods.Sort.downloads)
                    Text("Recently updated").tag(NexusMods.Sort.updatedAt)
                    Text("Newest").tag(NexusMods.Sort.createdAt)
                }
                .fixedSize()
            }
            TextField("Search Nexus Mods", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
            if let error { Text(verbatim: error).foregroundStyle(Compatibility.issues.tint) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 18)], alignment: .leading, spacing: 18) {
                ForEach(results) { mod in
                    Button { selected = mod } label: { NexusModCard(mod: mod) }
                        .buttonStyle(.plain)
                        .onAppear { if mod == results.last, results.count < total { Task { await search(reset: false) } } }
                }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            Text("Catalog by Nexus Mods (nexusmods.com). Mods are made by their authors; check each page for requirements.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private func search(reset: Bool) async {
        if reset { try? await Task.sleep(for: .milliseconds(350)) }   // debounce typing
        guard !Task.isCancelled, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await NexusMods.search(domain: domain, query: query, sort: sort, offset: reset ? 0 : results.count)
            results = reset ? page.mods : results + page.mods
            total = page.total
            error = nil
        } catch {
            self.error = LibraryStore.describeNexus(error)
        }
    }
}

private struct SourceBanner: View {
    let text: LocalizedStringKey

    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "info.circle") }
            .font(.callout).foregroundStyle(Theme.textSecondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: 12))
    }
}

private struct NexusModCard: View {
    let mod: NexusMods.Mod
    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The card sets the size; the picture fills it and is cropped to it, never wider than its own column.
            Color.black.opacity(0.2)
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .overlay {
                    AsyncImage(url: mod.pictureURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "puzzlepiece.extension").font(.title).foregroundStyle(Theme.textSecondary)
                    }
                }
                .clipShape(.rect(cornerRadius: 10))
            Text(verbatim: mod.name).font(.headline).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Text(verbatim: mod.summary).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
            HStack(spacing: 10) {
                Label(mod.endorsements.formatted(.number.notation(.compactName)), systemImage: "hand.thumbsup")
                Label(mod.downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
                if let progress = store.nexusProgress[mod.id] { ProgressView(value: progress).frame(width: 60) }
            }
            .font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: 14))
        .contentShape(.rect)
    }
}

/// A mod's details and files; "Install" downloads the chosen file with the user's account.
private struct NexusModSheet: View {
    let mod: NexusMods.Mod
    let title: Title
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var files: [NexusMods.File] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: mod.name).font(.title2.weight(.bold))
                    Text(verbatim: "\(mod.author) · \(mod.version)").foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: mod.pageURL) { Label("Nexus page", systemImage: "arrow.up.right.square") }
            }
            Text(verbatim: mod.summary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Files").font(.headline)
            if let error { Text(verbatim: error).foregroundStyle(.orange) }
            if files.isEmpty, error == nil { ProgressView() }
            List(files.filter { $0.category != "OLD_VERSION" && $0.category != "ARCHIVED" }) { file in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: file.name)
                        Text(verbatim: "\(file.category.capitalized) · \(file.version) · \(Int64(file.sizeKB * 1024).formatted(.byteCount(style: .file)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Install") { Task { await store.downloadNexusFile(file, of: mod, for: title) } }
                        .disabled(store.nexusProgress[mod.id] != nil)
                }
            }
            .frame(minHeight: 160)
            if let progress = store.nexusProgress[mod.id] { ProgressView(value: progress) { Text("Downloading…") } }
            if let message = store.nexusMessages[mod.id] { Text(verbatim: message).font(.callout).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 620, height: 560)
        .task {
            do { files = try await NexusMods.files(domain: mod.domain, modID: mod.id) } catch { self.error = LibraryStore.describeNexus(error) }
        }
    }
}

private struct InstalledNexusMods: View {
    let title: Title
    @Environment(LibraryStore.self) private var store
    @State private var removing: NexusModInstaller.Installed?

    var body: some View {
        let mods = { _ = store.nexusRevision; return store.nexusInstaller(for: title)?.installed() ?? [] }()
        VStack(alignment: .leading, spacing: 12) {
            Text("Installed").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
            if mods.isEmpty {
                Text("No mod installed by MacHub yet.").foregroundStyle(Theme.textSecondary)
            }
            ForEach(mods) { mod in
                HStack(spacing: 12) {
                    Toggle(isOn: Binding(get: { mod.enabled }, set: { store.setNexusMod(mod, enabled: $0, for: title) })) { EmptyView() }
                        .toggleStyle(.switch).labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: mod.name).foregroundStyle(Theme.textPrimary)
                        Group {
                            if mod.source == "file" {
                                Text("From a file · \(mod.files.count) files · \(mod.installedAt.formatted(date: .abbreviated, time: .omitted))")
                            } else {
                                Text(verbatim: "\(mod.version) · \(mod.files.count) files · \(mod.installedAt.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if let message = store.nexusMessages[mod.modID] { Text(verbatim: message).font(.caption).foregroundStyle(Theme.textSecondary) }
                    Button("Remove", role: .destructive) { removing = mod }
                }
                .padding(12)
                .background(Theme.surface, in: .rect(cornerRadius: 12))
            }
        }
        .confirmationDialog("Remove this mod?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Move to Trash", role: .destructive) { if let mod = removing { store.removeNexusMod(mod, for: title) } }
        } message: {
            Text("Its files go to the Trash, and any game file it replaced is put back.")
        }
    }
}

/// Sites without a download API (Overtake, AssettoCorsa.club, BeamNG's repository): MacHub opens them, then offers
/// to install what the user downloads there. Also takes any archive or folder the user already has.
private struct OtherModSources: View {
    let title: Title
    @Environment(LibraryStore.self) private var store
    @State private var watch = DownloadsWatch()
    @State private var choosing = false
    @State private var message: String?

    var body: some View {
        let sources = ModSupport.otherSources(appID: title.steamAppID)
        VStack(alignment: .leading, spacing: 12) {
            Text("Other sites").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
            Text(sources.isEmpty
                 ? "Downloaded a mod elsewhere? Add the archive (.zip, .7z, .rar) or the unpacked folder: MacHub puts it in the right place and can disable or remove it."
                 : "These sites have no download service MacHub may use. Download the mod there: MacHub notices the file in your Downloads folder and installs it in one click.")
                .font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(sources, id: \.url) { source in
                    Button {
                        watch.start()
                        NSWorkspace.shared.open(source.url)
                    } label: {
                        Label(source.name, systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(SecondaryActionStyle())
                }
                Button {
                    choosing = true
                } label: {
                    Label("Add a file or folder…", systemImage: "plus")
                }
                .buttonStyle(SecondaryActionStyle())
                .disabled(store.localModWork != nil)
            }
            if watch.isWatching {
                Label("Watching your Downloads folder for the next archive (15 minutes at most).", systemImage: "eye")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                Button("Stop watching") { watch.stop() }.buttonStyle(.link)
            }
            if let file = watch.found {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(Theme.textPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New download: \(file.lastPathComponent)").font(.headline).foregroundStyle(Theme.textPrimary)
                        Text("Install it in \(title.name)?").font(.callout).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Not this one") { watch.dismissFound() }
                    Button("Install") {
                        watch.dismissFound()
                        Task { message = await store.installLocalMod(file, for: title) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(14)
                .background(Theme.surfaceRaised, in: .rect(cornerRadius: 12))
            }
            if let work = store.localModWork {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Installing \(work)…") }
                    .font(.callout).foregroundStyle(Theme.textSecondary)
            }
            if let message { Text(verbatim: message).font(.callout).foregroundStyle(Theme.textSecondary) }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.zip, .folder, .data]) { result in
            guard case .success(let url) = result else { return }
            Task { message = await store.installLocalMod(url, for: title) }
        }
        .onDisappear { watch.stop() }
    }
}

/// Settings › Mods: the user's Nexus Mods account (personal API key, Keychain only).
struct ModsSettingsSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var keyDraft = ""

    var body: some View {
        Section {
            if NexusKeyStore.load() != nil {
                if let account = store.nexusAccount {
                    LabeledContent("Account") { Text(verbatim: account.name) }
                    LabeledContent("Membership") { Text(account.isPremium ? "Premium: direct downloads" : "Free: downloads via “Mod Manager Download”") }
                } else if let problem = store.nexusKeyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    ProgressView()
                }
                Button("Remove key", role: .destructive) { store.removeNexusKey(); keyDraft = "" }
            } else {
                SecureField("Nexus Mods API key", text: $keyDraft)
                HStack {
                    Button("Save in Keychain") { Task { if await store.saveNexusKey(keyDraft) { keyDraft = "" } } }
                        .disabled(keyDraft.isEmpty)
                    Link(destination: URL(string: "https://www.nexusmods.com/settings/api-keys")!) {
                        Label("Get my key", systemImage: "arrow.up.right.square")
                    }
                }
                if let problem = store.nexusKeyProblem { Text(verbatim: problem).foregroundStyle(Compatibility.issues.tint) }
            }
        } header: {
            Text("Nexus Mods")
        } footer: {
            Text("Your personal API key lets MacHub list a mod's files and download them with your account. It stays in the macOS Keychain. Free accounts click “Mod Manager Download” on the mod's page and MacHub installs the file; Premium accounts download directly from MacHub.")
        }
        .task { await store.refreshNexusAccount() }
    }
}
