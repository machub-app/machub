import SwiftUI
import UniformTypeIdentifiers

/// A game's Mods page. What it offers depends on what the game's sources really allow (see ModSupport).
struct ModsView: View {
    let title: Title
    @Environment(LibraryStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(title: "Mods", subtitle: "\(title.name)")
                switch ModSupport.support(for: title) {
                case .modrinth: MinecraftModsSection()
                case .archiveImport(let folder): AssettoCorsaModsSection(gameFolder: folder)
                case .externalOnly(let url): ExternalModsSection(url: url)
                case .nexus(let domain): NexusModsSection(title: title, domain: domain)
                case nil: Text("MacHub has no mod integration for this game.").foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 28)
            .frame(maxWidth: 1200, alignment: .leading)
        }
        .toolbar(removing: .title)
        .onAppear { store.spotlight = title.steamAppID == nil ? nil : title }
    }
}

/// One line in the detail page saying what kind of mod support a game has, linking to the Mods page.
struct ModsEntry: View {
    let title: Title

    var body: some View {
        if let support = ModSupport.support(for: title) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mods").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                NavigationLink(value: ModsRoute(title: title)) {
                    HStack(spacing: 14) {
                        Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 22)).foregroundStyle(Theme.textPrimary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(headline(support)).font(.headline).foregroundStyle(Theme.textPrimary)
                            Text(detail(support)).font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                    }
                    .padding(16)
                    .background(Theme.surface, in: .rect(cornerRadius: 12))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func headline(_ support: ModSupport) -> LocalizedStringKey {
        switch support {
        case .modrinth: "Browse and install mods"
        case .archiveImport: "Add cars and tracks"
        case .externalOnly: "Mods on the official site"
        case .nexus: "Browse and install mods from Nexus Mods"
        }
    }

    private func detail(_ support: ModSupport) -> LocalizedStringKey {
        switch support {
        case .modrinth: "Integrated with Modrinth: search, details, verified downloads, updates."
        case .archiveImport: "Manual import: download a .zip from a community site, MacHub installs it safely and can undo it."
        case .externalOnly: "External link only: MacHub doesn't install these mods yet."
        case .nexus: "Search the Nexus Mods catalog, install in one click, turn mods on and off, remove them cleanly."
        }
    }
}

// MARK: - Minecraft (Modrinth)

private struct MinecraftModsSection: View {
    @State private var model = MinecraftModsModel()
    @State private var tab = Tab.discover
    @State private var opened: ModProject?

    enum Tab: Hashable { case discover, installed }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SourceNote(symbol: "checkmark.seal", text: "Source: Modrinth, through its public API. Downloads come from Modrinth's servers and are checked against the SHA-512 it publishes. Download counts are Modrinth's own.")
            InstanceBar(model: model)
            if model.instance != nil {
                Picker("View", selection: $tab) {
                    Text("Discover").tag(Tab.discover)
                    Text("Installed (\(model.installed.count))").tag(Tab.installed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                switch tab {
                case .discover: discover
                case .installed: InstalledModsList(model: model)
                }
            }
        }
        .task {
            model.reload()
            if model.instance != nil { await model.search() }
        }
        .onChange(of: model.selectedInstanceID) {
            model.reloadInstalled()
            Task { await model.search() }
        }
        .sheet(item: $opened) { project in
            ModDetailSheet(project: project, model: model)
        }
    }

    private var discover: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                TextField("Search Modrinth", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { Task { await model.search() } }
                Picker("Category", selection: $model.category) {
                    Text("All categories").tag(String?.none)
                    Divider()
                    ForEach(Modrinth.categories, id: \.self) { Text(LocalizedStringKey(Self.categoryLabel($0))).tag(String?.some($0)) }
                }
                .fixedSize()
                Picker("Sort by", selection: $model.sort) {
                    Text("Relevance").tag(Modrinth.Sort.relevance)
                    Text("Downloads").tag(Modrinth.Sort.downloads)
                    Text("Recently updated").tag(Modrinth.Sort.updated)
                    Text("Newest").tag(Modrinth.Sort.newest)
                }
                .fixedSize()
                Spacer()
            }
            .onChange(of: model.category) { Task { await model.search() } }
            .onChange(of: model.sort) { Task { await model.search() } }
            .task(id: model.query) {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, model.searchState != .idle else { return }
                await model.search()
            }

            switch model.searchState {
            case .loading where model.results.isEmpty:
                HStack { Spacer(); ProgressView(); Spacer() }.padding(40)
            case .failed(let message):
                NoticeCard(symbol: "wifi.exclamationmark", title: "Modrinth can't be reached", message: LocalizedStringKey(message))
                    .padding(.horizontal, -Theme.gutter)
            default:
                if model.results.isEmpty, model.searchState == .loaded {
                    Text("No mod matches for this Minecraft version.").foregroundStyle(Theme.textSecondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
                    ForEach(model.results) { project in
                        Button { opened = project } label: {
                            ModCard(project: project, installed: model.isInstalled(project.id), progress: model.progress[project.id])
                        }
                        .buttonStyle(.plain)
                    }
                }
                .opacity(model.searchState == .loading ? 0.5 : 1)
            }
        }
    }

    static func categoryLabel(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

/// Which MacHub profile mods go to, or the one-time setup of Fabric when there is none.
private struct InstanceBar: View {
    @Bindable var model: MinecraftModsModel
    @State private var release: String = ""
    @State private var confirming = false

    var body: some View {
        if !model.home.exists {
            NoticeCard(symbol: "cube", title: "Minecraft isn't installed", message: "Install the Minecraft Launcher from minecraft.net and play once: MacHub then manages mods for it.")
                .padding(.horizontal, -Theme.gutter)
        } else if model.instances.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Set up a modded profile").font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Text("Mods need the Fabric loader. MacHub creates a separate profile, “MacHub · Fabric”, with its own game folder: your current worlds and settings stay untouched.")
                    .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                if model.releases.isEmpty {
                    Text("Play a release once in the Minecraft Launcher first, so MacHub knows your game version.").foregroundStyle(Compatibility.issues.tint)
                } else {
                    HStack(spacing: 12) {
                        Picker("Minecraft version", selection: $release) {
                            ForEach(model.releases, id: \.self) { Text(verbatim: $0).tag($0) }
                        }
                        .fixedSize()
                        Button {
                            confirming = true
                        } label: {
                            if model.creatingInstance { HStack { ProgressView().controlSize(.small); Text("Creating…") } } else { Text("Create the Fabric profile…") }
                        }
                        .buttonStyle(SecondaryActionStyle())
                        .disabled(model.creatingInstance || release.isEmpty)
                    }
                }
                if let error = model.instanceError { Text(error).foregroundStyle(Compatibility.issues.tint) }
            }
            .padding(20)
            .background(Theme.surface, in: .rect(cornerRadius: 14))
            .onAppear { if release.isEmpty { release = model.releases.first ?? "" } }
            .confirmationDialog("Create “MacHub · Fabric \(release)”?", isPresented: $confirming) {
                Button("Create profile") { Task { await model.createInstance(gameVersion: release) } }
            } message: {
                Text("MacHub downloads Fabric's profile from meta.fabricmc.net, adds it to the Minecraft Launcher's versions, and adds one profile to launcher_profiles.json after saving a backup copy. Quit the Minecraft Launcher first.")
            }
        } else {
            HStack(spacing: 12) {
                Picker("Profile", selection: $model.selectedInstanceID) {
                    ForEach(model.instances) { Text(verbatim: $0.name).tag(String?.some($0.id)) }
                }
                .fixedSize()
                if let instance = model.instance {
                    Text("Minecraft \(instance.gameVersion) · Fabric \(instance.loaderVersion)").foregroundStyle(Theme.textSecondary)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([instance.modsDir])
                    } label: {
                        Label("Mods folder", systemImage: "folder")
                    }
                    .buttonStyle(.link)
                }
                Spacer()
            }
            Text("In the Minecraft Launcher, pick the “\(model.instance?.name ?? "")” profile to play with these mods.")
                .font(.callout).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct ModCard: View {
    let project: ModProject
    let installed: Bool
    let progress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ModIcon(url: project.iconURL, size: 56)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(verbatim: project.title).font(.headline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if installed {
                        Label("Installed", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                            .font(.caption.weight(.semibold)).foregroundStyle(Compatibility.great.tint)
                    }
                }
                if let author = project.author { Text("by \(author)").font(.caption).foregroundStyle(Theme.textSecondary) }
                Text(verbatim: project.summary).font(.callout).foregroundStyle(Theme.textPrimary.opacity(0.85)).lineLimit(2)
                HStack(spacing: 12) {
                    if let downloads = project.downloads {
                        Label { Text(downloads, format: .number.notation(.compactName)) } icon: { Image(systemName: "arrow.down.circle") }
                    }
                    if let updated = project.updated {
                        Label { Text(updated, format: .relative(presentation: .named)) } icon: { Image(systemName: "clock") }
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                if let progress { ProgressView(value: progress).controlSize(.small) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .contentShape(.rect)
    }
}

private struct ModIcon: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: .fit) } placeholder: {
            Image(systemName: "puzzlepiece.extension").foregroundStyle(Theme.textSecondary)
        }
        .frame(width: size, height: size)
        .background(Theme.surfaceRaised, in: .rect(cornerRadius: size * 0.2))
        .clipShape(.rect(cornerRadius: size * 0.2))
        .accessibilityHidden(true)
    }
}

/// A mod's page: Modrinth's gallery and description, the version that fits this profile, and Install.
private struct ModDetailSheet: View {
    let project: ModProject
    @Bindable var model: MinecraftModsModel
    @Environment(\.dismiss) private var dismiss
    @State private var full: ModProject?
    @State private var version: ModVersion?
    @State private var dependencies: [String] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 16) {
                        ModIcon(url: project.iconURL, size: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: project.title).font(.title2.weight(.bold))
                            if let author = project.author { Text("by \(author)").foregroundStyle(Theme.textSecondary) }
                            Text(verbatim: project.summary).foregroundStyle(Theme.textPrimary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let gallery = full?.gallery, !gallery.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(gallery.prefix(6), id: \.self) { url in
                                    AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Theme.surface }
                                        .frame(width: 260, height: 146).clipShape(.rect(cornerRadius: 8))
                                }
                            }
                        }
                        .scrollIndicators(.never)
                    }
                    facts
                    compatibility
                }
                .padding(24)
            }
            Divider()
            HStack {
                if let url = project.pageURL {
                    Link(destination: url) { Label("Full page on Modrinth", systemImage: "arrow.up.right.square") }
                }
                Spacer()
                if let error = model.errors[project.id] {
                    Text(error).foregroundStyle(Compatibility.issues.tint).lineLimit(2).frame(maxWidth: 300, alignment: .trailing)
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                installButton
            }
            .padding(16)
            .controlSize(.large)
        }
        .frame(width: 680, height: 600)
        .background(Theme.ground)
        .task { await load() }
    }

    @ViewBuilder
    private var installButton: some View {
        if let progress = model.progress[project.id] {
            ProgressView(value: progress).frame(width: 140)
            Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
        } else if model.isInstalled(project.id), version?.id == model.installed.first(where: { $0.projectID == project.id })?.versionID {
            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(Compatibility.great.tint)
        } else if let version {
            Button(model.isInstalled(project.id) ? "Update" : "Install") {
                Task { await model.install(version, title: project.title) }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            if let updated = full?.updated ?? project.updated {
                GridRow { Text("Updated").foregroundStyle(Theme.textSecondary); Text(updated, format: .dateTime.day().month().year()) }
            }
            if let downloads = full?.downloads ?? project.downloads {
                GridRow { Text("Downloads on Modrinth").foregroundStyle(Theme.textSecondary); Text(downloads, format: .number) }
            }
            if let license = full?.license {
                GridRow { Text("License").foregroundStyle(Theme.textSecondary); Text(verbatim: license) }
            }
            if !project.categories.isEmpty {
                GridRow { Text("Categories").foregroundStyle(Theme.textSecondary); Text(verbatim: project.categories.joined(separator: ", ")) }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("For your profile").font(.headline)
            if loading {
                ProgressView().controlSize(.small)
            } else if let version, let instance = model.instance {
                Label("Version \(version.versionNumber) supports Minecraft \(instance.gameVersion) with Fabric (\(version.channel)).",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Compatibility.great.tint)
                if let file = version.primaryFile {
                    Text("\(file.filename) · \(Text(file.size, format: .byteCount(style: .file)))").font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                }
                if !dependencies.isEmpty {
                    Text("Also installs what it requires: \(dependencies.joined(separator: ", ")).").font(.callout).foregroundStyle(Theme.textSecondary)
                }
            } else {
                Label("No version for Minecraft \(model.instance?.gameVersion ?? "") with Fabric. MacHub won't install it.",
                      systemImage: "xmark.circle")
                    .foregroundStyle(Compatibility.issues.tint)
            }
        }
    }

    private func load() async {
        defer { loading = false }
        full = try? await Modrinth.project(project.id)
        guard let instance = model.instance,
              let versions = try? await Modrinth.versions(projectID: project.id, gameVersion: instance.gameVersion, loader: instance.loader)
        else { return }
        version = Modrinth.bestVersion(versions, gameVersion: instance.gameVersion, loader: instance.loader)
        var names: [String] = []
        for dependency in version?.dependencies ?? [] where dependency.kind == .required {
            guard let id = dependency.projectID, !model.isInstalled(id) else { continue }
            names.append((try? await Modrinth.project(id).title) ?? id)
        }
        dependencies = names
    }
}

private struct InstalledModsList: View {
    @Bindable var model: MinecraftModsModel
    @State private var removing: InstalledMod?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    Task { await model.checkUpdates() }
                } label: {
                    if model.checkingUpdates { HStack { ProgressView().controlSize(.small); Text("Checking…") } } else { Label("Check for updates", systemImage: "arrow.triangle.2.circlepath") }
                }
                .buttonStyle(SecondaryActionStyle())
                .disabled(model.checkingUpdates || model.installed.isEmpty)
                Spacer()
            }
            if model.installed.isEmpty {
                Text("No mod installed by MacHub in this profile yet.").foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 0) {
                ForEach(model.installed) { mod in
                    HStack(spacing: 14) {
                        Toggle(isOn: Binding(get: { mod.enabled }, set: { model.setEnabled(mod, $0) })) { EmptyView() }
                            .toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel(Text("Enable \(mod.title)"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: mod.title).font(.headline).foregroundStyle(mod.enabled ? Theme.textPrimary : Theme.textSecondary)
                            HStack(spacing: 6) {
                                Text(verbatim: mod.versionNumber)
                                if !mod.requiredBy.isEmpty { Text("· required by another mod") }
                                if !mod.enabled { Text("· disabled") }
                            }
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                            if let error = model.errors[mod.projectID] { Text(error).font(.caption).foregroundStyle(Compatibility.issues.tint) }
                        }
                        Spacer()
                        if let update = model.updates[mod.projectID] {
                            Button("Update to \(update.versionNumber)") { Task { await model.install(update, title: mod.title) } }
                                .disabled(model.progress[mod.projectID] != nil)
                        }
                        if let progress = model.progress[mod.projectID] { ProgressView(value: progress).frame(width: 80) }
                        Button("Uninstall", role: .destructive) { removing = mod }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    Divider().overlay(Theme.stroke)
                }
            }
            .background(Theme.surface, in: .rect(cornerRadius: 12))
            if !model.unmanaged.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Added outside MacHub").font(.headline)
                    Text("These files are in the mods folder but MacHub didn't install them. It never changes them.")
                        .font(.callout).foregroundStyle(Theme.textSecondary)
                    ForEach(model.unmanaged, id: \.self) { Text(verbatim: $0).font(.callout.monospaced()) }
                }
            }
        }
        .confirmationDialog("Uninstall \(removing?.title ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { mod in
            Button("Move to Trash", role: .destructive) { model.uninstall(mod) }
        } message: { mod in
            let dependents = model.dependents(of: mod).map(\.title)
            Text(dependents.isEmpty
                 ? "Its file goes to the Trash, so you can still get it back."
                 : "Its file goes to the Trash. These mods need it and may stop working: \(dependents.joined(separator: ", ")).")
        }
    }
}

// MARK: - Assetto Corsa (manual import)

private struct AssettoCorsaModsSection: View {
    let gameFolder: URL
    @State private var importer: ArchiveModImporter
    @State private var installed: [ArchiveModImporter.Installed] = []
    @State private var pending: (source: URL, staging: URL, items: [ArchiveModImporter.Item])?
    @State private var choosing = false
    @State private var working = false
    @State private var message: String?
    @State private var removing: ArchiveModImporter.Installed?

    init(gameFolder: URL) {
        self.gameFolder = gameFolder
        _importer = State(initialValue: ArchiveModImporter(gameFolder: gameFolder))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SourceNote(symbol: "tray.and.arrow.down", text: "Manual import. Assetto Corsa's mod sites have no public download API, so MacHub doesn't search them: open one, download a car or track (.zip), then add it here. MacHub checks the archive, installs only into content/cars or content/tracks, and keeps a copy of anything it replaces.")
            HStack(spacing: 12) {
                Button {
                    choosing = true
                } label: {
                    Label("Add a car or track…", systemImage: "plus")
                }
                .buttonStyle(SecondaryActionStyle())
                .disabled(working)
                ForEach(ModSupport.assettoCorsaSources, id: \.url) { source in
                    Link(destination: source.url) { Label(source.name, systemImage: "arrow.up.right.square") }
                }
            }
            if working { ProgressView("Checking the archive…").controlSize(.small) }
            if let message { Text(message).foregroundStyle(Compatibility.issues.tint) }
            if let pending {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ready to install from \(pending.source.lastPathComponent)").font(.headline)
                    ForEach(pending.items, id: \.source) { item in
                        let replaces = FileManager.default.fileExists(atPath: importer.destination(for: item).path)
                        Label {
                            Text(verbatim: item.name)
                            Text(item.kind == .car ? "Car" : "Track").foregroundStyle(Theme.textSecondary)
                            if replaces { Text("replaces an existing folder (kept as a backup)").foregroundStyle(Compatibility.playable.tint) }
                        } icon: {
                            Image(systemName: item.kind == .car ? "car.fill" : "road.lanes")
                        }
                    }
                    HStack {
                        Button("Cancel") { self.pending = nil }
                        Button("Install") { install() }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
                .background(Theme.surface, in: .rect(cornerRadius: 12))
            }
            Text("Installed by MacHub").font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            if installed.isEmpty {
                Text("Nothing yet. Content you add appears here and can be removed in one click.").foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 0) {
                ForEach(installed) { item in
                    HStack {
                        Image(systemName: item.kind == .car ? "car.fill" : "road.lanes").frame(width: 24)
                        VStack(alignment: .leading) {
                            Text(verbatim: item.name).font(.headline)
                            Text("From \(item.archive)").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button(item.backup == nil ? "Remove" : "Remove and restore previous", role: .destructive) { removing = item }
                    }
                    .padding(14)
                    Divider().overlay(Theme.stroke)
                }
            }
            .background(Theme.surface, in: .rect(cornerRadius: 12))
            Text("Cars and tracks appear in the game's own launcher or in Content Manager. MacHub hasn't verified that a given mod runs well under Whisky.")
                .font(.callout).foregroundStyle(Theme.textSecondary)
        }
        .onAppear { installed = importer.installed() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.zip, .folder]) { result in
            guard case .success(let url) = result else { return }
            prepare(url)
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { item in
            Button("Move to Trash", role: .destructive) {
                do { try importer.uninstall(item) } catch { message = "Couldn't remove it: \(error.localizedDescription)" }
                installed = importer.installed()
            }
        } message: { item in
            Text(item.backup == nil ? "The folder goes to the Trash." : "The folder goes to the Trash and the one it replaced is put back.")
        }
    }

    private func prepare(_ url: URL) {
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                let prepared = try await importer.prepare(url)
                pending = (url, prepared.staging, prepared.items)
            } catch ArchiveModImporter.Failure.unsupportedFormat(let ext) {
                message = "MacHub reads .zip files and folders. For a .\(ext) archive, open it with Archive Utility first, then add the folder."
            } catch ArchiveModImporter.Failure.unsafeEntry(let entry) {
                message = "Refused: the archive contains a path that would write outside its folder (\(entry))."
            } catch ArchiveModImporter.Failure.symlink {
                message = "Refused: the archive contains links to other places on disk."
            } catch ArchiveModImporter.Failure.nothingRecognised {
                message = "No car or track folder found in it. It may need a custom installer or Content Manager."
            } catch {
                message = "Couldn't read it: \(error.localizedDescription)"
            }
        }
    }

    private func install() {
        guard let pending else { return }
        do {
            _ = try importer.install(pending.items, from: pending.source.lastPathComponent)
        } catch {
            message = "Couldn't install: \(error.localizedDescription)"
        }
        if pending.staging != pending.source { try? FileManager.default.removeItem(at: pending.staging) }
        self.pending = nil
        installed = importer.installed()
    }
}

private struct ExternalModsSection: View {
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SourceNote(symbol: "link", text: "External link only. This game's official mod repository has no documented API MacHub could use, so MacHub doesn't search or install from it.")
            Link(destination: url) { Label("Open the official mod repository", systemImage: "arrow.up.right.square") }
        }
    }
}

private struct SourceNote: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout)
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: 820, alignment: .leading)
    }
}
