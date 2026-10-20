import SwiftUI

/// The installed build of a Steam game, whether a newer one is out, and the developer's latest announcement.
struct GameVersionPanel: View {
    let title: Title
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if let appID = title.steamAppID, let installed = store.manifest(for: title) {
            let info = store.gameUpdates[appID]
            VStack(alignment: .leading, spacing: 12) {
                Text("Version").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                VStack(alignment: .leading, spacing: 0) {
                    statusRow(installed: installed, info: info)
                    if let likely = GameUpdates.likelyVersion(installedOn: installed.lastUpdated, announcements: info?.announcements ?? []),
                       let version = likely.version {
                        row("Version", Text(verbatim: "v\(version)"),
                            detail: Text("From the announcement of \(likely.date.formatted(date: .abbreviated, time: .omitted)), the latest before this build was installed."))
                    }
                    row("Installed build", Text(verbatim: installed.buildID == 0 ? "—" : String(installed.buildID)),
                        detail: installed.lastUpdated.map { Text("Updated \($0.formatted(date: .abbreviated, time: .shortened))") })
                    if let info, info.latestBuild != 0 {
                        row("Latest build on Steam", Text(verbatim: String(info.latestBuild)),
                            detail: info.latestBuildDate.map { Text("Published \($0.formatted(date: .abbreviated, time: .shortened))") })
                    }
                    if let latest = info?.announcements.first {
                        row("Latest announcement", Text(verbatim: latest.title),
                            detail: Text(latest.date.formatted(date: .abbreviated, time: .omitted)), link: latest.url)
                    }
                }
                .padding(.horizontal, 16)
                .background(Theme.surface, in: .rect(cornerRadius: 12))
            }
            .task(id: appID) { await store.loadGameUpdates(appID: appID) }
        }
    }

    @ViewBuilder
    private func statusRow(installed: SteamApp, info: GameUpdates.Info?) -> some View {
        let status = GameUpdates.status(installed: installed, latestBuild: info?.latestBuild ?? 0)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            switch status {
            case .upToDate:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Compatibility.great.tint).frame(width: 18)
                Text("Up to date").foregroundStyle(Theme.textPrimary)
            case .updateAvailable, .pendingInSteam:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Compatibility.playable.tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed.isUpdating ? "Steam is updating this game" : "An update is available").foregroundStyle(Theme.textPrimary)
                    Text(title.macInstall != nil
                         ? "Steam for Mac downloads it. Update Now starts it right away."
                         : "Steam applies it at the next launch, or right away with Update Now.")
                        .font(.callout).foregroundStyle(Theme.textSecondary)
                }
            case .unknown:
                Image(systemName: "questionmark.circle").foregroundStyle(Theme.textSecondary).frame(width: 18)
                Text(info == nil ? "Checking for updates…" : "Couldn't check for updates").foregroundStyle(Theme.textPrimary)
            }
            Spacer(minLength: 0)
            if status == .updateAvailable || (status == .pendingInSteam && !installed.isUpdating) {
                Button("Update Now") { Task { await store.updateNow(title) } }
                    .buttonStyle(SecondaryActionStyle())
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    private func row(_ label: LocalizedStringKey, _ value: Text, detail: Text? = nil, link: URL? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(Theme.textSecondary)
                if let detail { detail.font(.callout).foregroundStyle(Theme.textSecondary) }
            }
            Spacer(minLength: 12)
            if let link {
                Link(destination: link) { value.multilineTextAlignment(.trailing) }
            } else {
                value.foregroundStyle(Theme.textPrimary).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }
}
