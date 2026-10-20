import SwiftUI

extension CompatibilityEstimate {
    var shortLabel: LocalizedStringKey {
        switch verdict {
        case .tested: "Tested: plays"
        case .verified: "Verified on Mac"
        case .community: "Players report it runs"
        case .native: "Mac version"
        case .likely: "Likely to run"
        case .issues: antiCheat != nil ? "Anti-cheat: uncertain" : "May have issues"
        case .unlikely: "Unlikely to run"
        case .antiCheat: "Blocked by anti-cheat"
        case .directX12: "Needs DirectX 12"
        case .unknown: "No reports yet"
        }
    }

    var explanation: LocalizedStringKey {
        switch verdict {
        case .tested: "MacHub has played this game on a real Mac."
        case .verified: "Verified running on a Mac by the Highball project (highball-db)."
        case .community: "Players report it runs on Apple silicon with Wine (highball-db). See their notes and known issues below."
        case .native: "Steam has a native macOS version: play it with Steam for Mac, without Wine."
        case .likely: "Players report it runs well with Wine (ProtonDB). Linux has more graphics paths than macOS, so this is a good sign, not a guarantee."
        case .issues:
            antiCheat != nil
                ? "It uses anti-cheat that accepts Linux, but MacHub hasn't seen it work with macOS's Wine. Online modes may refuse to start."
                : "Players report it runs with Wine, with problems (ProtonDB). Expect glitches or extra steps."
        case .unlikely: "Players report it doesn't run with Wine (ProtonDB)."
        case .antiCheat: "Its anti-cheat refuses Wine, so it won't start, or will be blocked online."
        case .directX12: "It needs DirectX 12, which MacHub can't run yet (Apple's D3DMetal is needed and isn't wired in)."
        case .unknown: "No compatibility reports for this game yet."
        }
    }
}

/// The estimate as a small glass pill on a cover; loads it when the card appears.
struct EstimatePill: View {
    let appID: Int
    @Environment(LibraryStore.self) private var store

    var body: some View {
        // A zero-size base so the view exists (and loads) before there is anything to show.
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(width: 0, height: 0)
            if let estimate = store.estimates[appID], estimate.verdict != .unknown {
                HStack(spacing: 5) {
                    Circle().fill(estimate.compatibility.tint).frame(width: 7, height: 7)
                    Text(estimate.shortLabel).lineLimit(1)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.62), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .padding(8)
                .help(Text(estimate.explanation))
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: store.estimates[appID])
        .task(id: appID) { await store.loadEstimate(appID: appID) }
    }
}

/// The estimate as a badge in a title's header line ("Not verified" until it has loaded).
struct EstimateBadge: View {
    let appID: Int
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let estimate = store.estimates[appID]
        let compatibility = estimate?.compatibility ?? .unknown
        HStack(spacing: 5) {
            Image(systemName: compatibility.symbol)
            if let estimate { Text(estimate.shortLabel) } else { Text(Compatibility.unknown.label) }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(compatibility.tint)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(compatibility.tint.opacity(0.14), in: .capsule)
        .help(estimate.map { Text($0.explanation) } ?? Text(Compatibility.unknown.label))
        .task(id: appID) { await store.loadEstimate(appID: appID) }
    }
}

/// The game page's compatibility panel: the verdict, why, and the signals behind it with their sources.
struct CompatibilityPanel: View {
    let title: Title
    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac compatibility").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 14) {
                if let appID = title.steamAppID, let estimate = store.estimates[appID] {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: estimate.compatibility.symbol).font(.system(size: 26)).foregroundStyle(estimate.compatibility.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(estimate.shortLabel).font(.headline).foregroundStyle(Theme.textPrimary)
                            Text(estimate.explanation).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let entry = estimate.highball {
                        Divider()
                        highballSection(entry)
                    }
                    Divider()
                    signals(estimate, appID: appID)
                    Text("An estimate from public reports, not a promise. Tried it? Report how it ran on MacHub's GitHub page.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                } else if title.steamAppID != nil {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Checking compatibility reports…").foregroundStyle(Theme.textSecondary) }
                } else {
                    Text("No compatibility reports for this program.").foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: 12))
        }
        .task(id: title.steamAppID) { if let id = title.steamAppID { await store.loadEstimate(appID: id) } }
    }

    @ViewBuilder
    private func highballSection(_ entry: HighballDB.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch entry {
            case .curated(let game):
                if let renderer = game.renderer {
                    row("Renderer players used", value: renderer == "d3dmetal" ? "D3DMetal" : renderer.uppercased())
                }
                if !game.launchArgs.isEmpty {
                    row("Launch options", value: game.launchArgs.joined(separator: " "))
                }
                if game.reports > 0 { row("Player reports", value: "\(game.reports)") }
                if let notes = game.notes, !notes.isEmpty {
                    Text(verbatim: notes).font(.callout).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(8)
                }
                if !game.knownIssues.isEmpty {
                    Text("Known issues").font(.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    ForEach(game.knownIssues, id: \.self) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Label { Text(verbatim: issue.symptom) } icon: { Image(systemName: "exclamationmark.triangle") }
                                .foregroundStyle(Theme.textPrimary)
                            if let fix = issue.fix { Text(verbatim: "→ " + fix).foregroundStyle(Theme.textSecondary).padding(.leading, 26) }
                        }
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                attribution(page: game.page, text: "Compatibility data from highball-db (CC0), the open database of the Highball project.")
            case .prediction(let odds):
                row("Prediction", value: odds.label)
                attribution(page: odds.page, text: "Prediction from highball-db: ProtonDB reports (ODbL) crossed with anti-cheat data. Odds for macOS, not a verdict.")
            }
        }
    }

    private func attribution(page: URL?, text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text).font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let page {
                Link(destination: page) { Image(systemName: "arrow.up.right.square") }.help("Open the game's Highball page")
            }
        }
    }

    @ViewBuilder
    private func signals(_ estimate: CompatibilityEstimate, appID: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Tested by MacHub", value: CompatibilityEstimate.testedPlayable.contains(appID) ? "Plays" : "Not yet")
            row("DirectX", value: estimate.directX.map { "\($0)" } ?? String(localized: "Not listed"))
            if let antiCheat = estimate.antiCheat {
                row("Anti-cheat", value: "\(antiCheat.names.joined(separator: ", ")) · \(antiCheat.status) on Linux")
            } else {
                row("Anti-cheat", value: String(localized: "None listed"))
            }
            HStack {
                row("Wine reports (ProtonDB)", value: estimate.protonTier.map { "\($0.capitalized) · \(estimate.protonReports) reports" } ?? String(localized: "None yet"))
                Link(destination: CompatibilitySources.protonDBPage(appID: appID)) { Image(systemName: "arrow.up.right.square") }
                    .help("Open the game's ProtonDB page")
            }
        }
        .font(.callout)
    }

    private func row(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textSecondary).frame(width: 190, alignment: .leading)
            Text(verbatim: value).foregroundStyle(Theme.textPrimary)
        }
    }
}
