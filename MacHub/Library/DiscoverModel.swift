import Foundation
import Observation

/// Browsing the Steam store page by page: only loaded pages live in memory, nothing is prefetched.
@MainActor @Observable
final class DiscoverModel {
    enum State: Equatable { case idle, loading, loaded, empty, rateLimited, offline, failed(String) }

    var term = ""
    var sort: SteamStore.Sort = .relevance
    var genre: SteamStore.Genre?
    private(set) var items: [StoreItem] = []
    private(set) var state: State = .idle
    private(set) var reachedEnd = false
    private var nextPage = 0
    private var generation = 0

    func reload() async {
        generation += 1
        items = []
        nextPage = 0
        reachedEnd = false
        state = .idle
        await loadNext()
    }

    func loadNext() async {
        guard state != .loading, !reachedEnd else { return }
        let request = generation
        state = .loading
        do {
            let page = try await SteamStore.search(term: term, page: nextPage, sort: sort, genre: genre)
            guard request == generation else { return }  // filters changed meanwhile
            let known = Set(items.map(\.appID))
            items += page.filter { !known.contains($0.appID) }
            nextPage += 1
            reachedEnd = page.count < SteamStore.pageSize
            state = items.isEmpty ? .empty : .loaded
        } catch {
            guard request == generation else { return }
            switch error {
            case SteamHTTP.Failure.rateLimited: state = .rateLimited
            case SteamHTTP.Failure.offline: state = .offline
            default: state = .failed(LibraryStore.describe(error))
            }
        }
    }
}
