import AppKit

/// Nexus Mods downloads and installs. The catalog itself is public; the account (personal API key) is only needed to
/// list a mod's files and to download.
extension LibraryStore {
    /// The installer for a title's mods, when the game is one MacHub knows and it lives in a MacHub prefix.
    func nexusInstaller(for title: Title) -> NexusModInstaller? {
        guard let appID = title.steamAppID, let domain = NexusMods.domains[appID], let install = title.install,
              let prefix = prefixes.first(where: { $0.name == install.bottle }),
              let layout = NexusModInstaller.layout(appID: appID, installPath: install.path, prefix: prefix.url)
        else { return nil }
        return NexusModInstaller(layout: layout, dataFolder: LocalData.directory.appending(path: "mods/nexus/\(domain)"))
    }

    func saveNexusKey(_ key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NexusKeyStore.isPlausible(trimmed), NexusKeyStore.save(trimmed) else {
            nexusKeyProblem = String(localized: "That doesn't look like a Nexus Mods API key.")
            return false
        }
        await refreshNexusAccount()
        return nexusAccount != nil
    }

    func removeNexusKey() {
        NexusKeyStore.delete()
        nexusAccount = nil
        nexusKeyProblem = nil
    }

    func refreshNexusAccount() async {
        guard NexusKeyStore.load() != nil else { nexusAccount = nil; return }
        do {
            nexusAccount = try await NexusMods.validate()
            nexusKeyProblem = nil
        } catch {
            nexusAccount = nil
            nexusKeyProblem = Self.describeNexus(error)
        }
    }

    /// Starts a download: Premium accounts get the file straight from the API; free accounts are sent to the mod's
    /// files page, where "Mod Manager Download" hands an nxm:// link back to MacHub (handled below).
    func downloadNexusFile(_ file: NexusMods.File, of mod: NexusMods.Mod, for title: Title) async {
        if nexusAccount?.isPremium == true {
            do {
                let links = try await NexusMods.downloadLinks(domain: mod.domain, modID: mod.id, fileID: file.id)
                await install(from: links, fileName: file.fileName, modID: mod.id, fileID: file.id, name: mod.name, version: file.version, title: title)
            } catch {
                nexusMessages[mod.id] = Self.describeNexus(error)
            }
        } else {
            awaitingNexusLinks.insert(mod.id)
            nexusMessages[mod.id] = String(localized: "On the Nexus page, click “Mod Manager Download” for this file: MacHub takes it from there.")
            NSWorkspace.shared.open(mod.filesPageURL)
        }
    }

    /// An nxm:// link arrived (the user clicked "Mod Manager Download"): download and install for the matching game.
    func handle(_ link: NexusLink) async {
        guard let appID = NexusMods.domains.first(where: { $0.value == link.domain })?.key,
              let title = installedTitles.first(where: { $0.steamAppID == appID })
        else {
            nexusMessages[link.modID] = String(localized: "This link is for a game MacHub doesn't manage mods for, or that isn't installed.")
            return
        }
        awaitingNexusLinks.remove(link.modID)
        do {
            let files = try await NexusMods.files(domain: link.domain, modID: link.modID)
            let file = files.first { $0.id == link.fileID }
            let links = try await NexusMods.downloadLinks(domain: link.domain, modID: link.modID, fileID: link.fileID, key: link.key, expires: link.expires)
            await install(from: links, fileName: file?.fileName ?? "mod-\(link.fileID).zip", modID: link.modID, fileID: link.fileID,
                          name: file?.name ?? "Mod \(link.modID)", version: file?.version ?? "", title: title)
        } catch {
            nexusMessages[link.modID] = Self.describeNexus(error)
        }
    }

    private func install(from links: [URL], fileName: String, modID: Int, fileID: Int, name: String, version: String, title: Title) async {
        guard let url = links.first, let installer = nexusInstaller(for: title) else {
            nexusMessages[modID] = String(localized: "Nexus returned no download link.")
            return
        }
        nexusProgress[modID] = 0
        defer { nexusProgress[modID] = nil }
        do {
            let downloaded = try await ModDownloader.download(url) { fraction in
                Task { @MainActor in self.nexusProgress[modID] = fraction }
            }
            defer { try? FileManager.default.removeItem(at: downloaded) }
            let record = try await installer.install(archive: downloaded, fileName: fileName, modID: modID, fileID: fileID, name: name, version: version)
            nexusMessages[modID] = String(localized: "Installed \(record.version.isEmpty ? record.name : record.version) (\(record.files.count) files)")
        } catch {
            nexusMessages[modID] = Self.describeNexus(error)
        }
        nexusRevision += 1
    }

    func setNexusMod(_ mod: NexusModInstaller.Installed, enabled: Bool, for title: Title) {
        do { try nexusInstaller(for: title)?.setEnabled(mod, enabled) } catch { nexusMessages[mod.modID] = Self.describeNexus(error) }
        nexusRevision += 1
    }

    func removeNexusMod(_ mod: NexusModInstaller.Installed, for title: Title) {
        do { try nexusInstaller(for: title)?.uninstall(mod) } catch { nexusMessages[mod.modID] = Self.describeNexus(error) }
        nexusRevision += 1
    }

    static func describeNexus(_ error: Error) -> String {
        switch error {
        case NexusMods.Failure.noKey: String(localized: "Add your Nexus Mods API key in Settings › Mods.")
        case NexusMods.Failure.invalidKey: String(localized: "Nexus Mods refused the API key. Check it in Settings › Mods.")
        case NexusMods.Failure.premiumRequired: String(localized: "Nexus Mods only allows direct downloads for Premium members. Use “Mod Manager Download” on the mod's page.")
        case NexusMods.Failure.http(let code): String(localized: "Nexus Mods answered HTTP \(code).")
        case NexusModInstaller.Failure.unsupportedFormat(let ext): String(localized: "This file is a .\(ext) archive. MacHub installs .zip files; for others, unpack it and copy it yourself.")
        case NexusModInstaller.Failure.unsafeEntry(let entry): String(localized: "The archive was refused: it tries to write outside the game (\(entry)).")
        case NexusModInstaller.Failure.nothingRecognised: String(localized: "MacHub didn't recognise this mod's layout for this game.")
        case NexusModInstaller.Failure.extraction(let detail): String(localized: "The archive couldn't be unpacked: \(detail)")
        default: error.localizedDescription
        }
    }
}
