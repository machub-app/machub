import SwiftUI

/// Live store rows from Steam's featured categories (real data, labelled "On Steam" on each card).
struct StoreRows: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let f = store.featuredStore
        switch store.featuredState {
        case .rateLimited:
            NoticeCard(symbol: "hourglass", title: "Steam store",
                       message: "Steam is limiting requests right now. The store rows will come back in a few minutes.")
        case .offline where f.topSellers.isEmpty:
            NoticeCard(symbol: "wifi.slash", title: "Steam store",
                       message: "Steam can't be reached. Check your connection; your installed games still work.") {
                Button("Retry") { Task { await store.refreshFeatured() } }.buttonStyle(SecondaryActionStyle())
            }
        default:
            TitleRow(heading: "Top sellers on Steam", titles: store.storeRow(f.topSellers), style: .landscape)
            TitleRow(heading: "New on Steam", titles: store.storeRow(f.newReleases), style: .landscape)
            TitleRow(heading: "Steam specials", titles: store.storeRow(f.specials), style: .landscape)
            TitleRow(heading: "Coming soon", titles: store.storeRow(f.comingSoon), style: .landscape)
            if store.featuredState == .stale {
                Text("Shown from cache: Steam couldn't be reached.")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.gutter)
            }
        }
    }
}

/// Tells the truth about the Steam library when it can't be shown.
struct OwnedStateNotice: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        switch store.ownedState {
        case .needsKey:
            NoticeCard(symbol: "key", title: "Your Steam library",
                       message: store.steamPrefix == nil
                           ? "Install Steam for Windows and sign in: MacHub then reads your library from it, games shared through Steam Families included. Or add your personal Web API key."
                           : "Sign in to Steam for Windows and open its Library once: MacHub then reads your games from it. Or add your personal Web API key.") {
                if store.steamPrefix == nil {
                    Button("Install Steam for Windows") { Task { await store.setUpSteam() } }.buttonStyle(SecondaryActionStyle())
                }
                Button("Add a key in Settings") { navigation.selection = .settings }.buttonStyle(SecondaryActionStyle())
            }
        case .privateProfile:
            NoticeCard(symbol: "lock", title: "Your Steam library",
                       message: "Steam returned no games: your profile's “Game details” are private. Make them public in Steam's privacy settings, then refresh.") {
                Link(destination: URL(string: "https://steamcommunity.com/my/edit/settings")!) {
                    Label("Steam privacy settings", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(SecondaryActionStyle())
            }
        case .invalidKey:
            NoticeCard(symbol: "key.slash", title: "Your Steam library", message: "Steam refused the Web API key. Check or replace it in Settings.") {
                Button("Open Settings") { navigation.selection = .settings }.buttonStyle(SecondaryActionStyle())
            }
        case .failed(let message):
            NoticeCard(symbol: "exclamationmark.triangle", title: "Your Steam library", message: "Couldn't load your games: \(message)") {
                Button("Retry") { Task { await store.refreshOwned() } }.buttonStyle(SecondaryActionStyle())
            }
        case .loading:
            NoticeCard(symbol: "arrow.triangle.2.circlepath", title: "Your Steam library", message: "Loading your games from Steam…")
        case .fromSteamClient:
            Label("Read from Steam for Windows on this Mac, games shared through Steam Families included. Add a Web API key in Settings to also see playtime.",
                  systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, Theme.gutter)
        case .signedOut, .loaded:
            EmptyView()
        }
    }
}

struct SteamConnectCard: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let steam = store.steam
        NoticeCard(symbol: "person.badge.key", title: "Connect Steam", message: message(steam.state)) {
            if steam.isBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { steam.cancelSignIn() }.buttonStyle(SecondaryActionStyle())
                }
            } else {
                Button { Task { await steam.signIn() } } label: {
                    Label("Sign in with Steam", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(SecondaryActionStyle())
            }
        }
    }

    private func message(_ state: SteamConnection.State) -> LocalizedStringKey {
        switch state {
        case .waitingForBrowser: "Finish signing in on steampowered.com in your browser, then come back here."
        case .verifying: "Checking the sign-in with Steam…"
        case .failed(let problem): problem.message
        default: "Sign in on Steam's own website, in your browser. MacHub never sees your password: it only receives your public SteamID, verified with Steam."
        }
    }
}

extension SteamConnection.Problem {
    var message: LocalizedStringKey {
        switch self {
        case .cancelled: "Sign-in was cancelled on Steam."
        case .rejected: "Steam did not confirm this sign-in. Please try again."
        case .invalid: "The sign-in response was invalid and was ignored."
        case .network: "Steam couldn't be reached to confirm the sign-in."
        case .timedOut: "No answer from the browser after 5 minutes."
        case .receiver: "MacHub couldn't open its local sign-in receiver."
        case .other(let text): "Sign-in failed: \(text)"
        }
    }
}

/// Shared inline notice: an icon, a heading, one honest sentence and an optional action.
struct NoticeCard<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                Text(message).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            actions()
        }
        .padding(20)
        .background(Theme.surface, in: .rect(cornerRadius: 14))
        .padding(.horizontal, Theme.gutter)
    }
}

extension NoticeCard where Actions == EmptyView {
    init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

struct FeaturedPlaceholder: View {
    let state: LibraryStore.StoreState

    var body: some View {
        VStack(spacing: 14) {
            if state == .loading || state == .idle {
                ProgressView()
                Text("Loading what's on Steam…").foregroundStyle(Theme.textSecondary)
            } else {
                Image(systemName: "wifi.slash").font(.system(size: 30)).foregroundStyle(Theme.textSecondary)
                Text("Steam can't be reached and nothing is installed yet.").foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
        .padding(.top, 40)
    }
}
