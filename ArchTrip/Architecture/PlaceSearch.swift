import MapKit

/// Which Apple Maps search a result came from. This describes the search, not the result:
/// a point of interest may lack a Place ID and an address may carry one, so whether a
/// result can be linked is decided separately, from its ID alone (`PlaceResult.linkIssue`).
nonisolated enum PlaceSearchKind: String, CaseIterable, Hashable, Sendable {
    case pointOfInterest
    case address
}

/// One Apple Maps search of one kind. Throws on failure (or `CancellationError`); should
/// stop when its task is cancelled, but `PlaceSearch` does not depend on it: a reply that
/// arrives after its request was superseded is ignored.
protocol PlaceSearching {
    func search(_ query: String, kind: PlaceSearchKind) async throws -> [PlaceResult]
}

/// Both searches for one query, each with its own outcome, shown while the Building editor
/// is open and then discarded. Nothing here is persisted.
///
/// - The query already in flight is not requested again (a repeated tap does nothing).
/// - A changed query, `cancel()` and `reset()` move the search on. Every request carries a
///   token from a sequence that is never reused, so a reply to an earlier request is
///   ignored however late it arrives, whether or not the searcher honoured cancellation.
/// - The two kinds complete independently: one failing leaves the other's results.
@Observable
final class PlaceSearch {
    enum SectionState: Equatable {
        case idle
        case searching
        case results([PlaceResult])
        case empty
        case failed
    }

    /// The trimmed query the sections belong to; empty when nothing is shown.
    private(set) var query = ""
    private(set) var sections = idleSections

    private let searcher: any PlaceSearching
    /// Incremented by every search, cancel and reset; a reply is applied only if its
    /// request's token is still the current one.
    private var token = 0
    private var tasks: [PlaceSearchKind: Task<Void, Never>] = [:]

    private static let idleSections = Dictionary(
        uniqueKeysWithValues: PlaceSearchKind.allCases.map { ($0, SectionState.idle) }
    )

    init(searcher: any PlaceSearching) {
        self.searcher = searcher
    }

    func state(of kind: PlaceSearchKind) -> SectionState {
        sections[kind] ?? .idle
    }

    var isSearching: Bool {
        sections.values.contains(.searching)
    }

    /// Whether there is a query whose sections are shown.
    var isActive: Bool {
        !query.isEmpty
    }

    /// Searches Apple Maps for `text`, both kinds at once. Repeating the query while it is
    /// in flight does nothing; repeating it after completion searches again (a retry).
    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed == query, isSearching { return }
        cancelInFlight()
        query = trimmed
        sections = Dictionary(uniqueKeysWithValues: PlaceSearchKind.allCases.map { ($0, SectionState.searching) })
        let current = token
        for kind in PlaceSearchKind.allCases {
            tasks[kind] = Task { [searcher] in
                let outcome: SectionState
                do {
                    let results = try await searcher.search(trimmed, kind: kind)
                    outcome = results.isEmpty ? .empty : .results(results)
                } catch is CancellationError {
                    return
                } catch {
                    outcome = .failed
                }
                self.apply(outcome, to: kind, token: current)
            }
        }
    }

    /// The query text changed: results for a different query are no longer shown and a
    /// request for it is abandoned. Retyping the same query keeps what is shown.
    func queryChanged(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query else { return }
        reset()
    }

    /// Stops any request in flight. Sections still searching go back to idle; completed
    /// sections keep what they show.
    func cancel() {
        cancelInFlight()
        for kind in PlaceSearchKind.allCases where sections[kind] == .searching {
            sections[kind] = .idle
        }
    }

    /// Stops any request in flight and shows nothing.
    func reset() {
        cancelInFlight()
        query = ""
        sections = Self.idleSections
    }

    private func cancelInFlight() {
        token += 1
        for task in tasks.values {
            task.cancel()
        }
        tasks = [:]
    }

    private func apply(_ outcome: SectionState, to kind: PlaceSearchKind, token: Int) {
        guard token == self.token else { return }
        sections[kind] = outcome
        tasks[kind] = nil
    }
}

/// Apple Maps search through MapKit: one `MKLocalSearch` per kind, cancelled with its task.
struct MapKitPlaceSearcher: PlaceSearching {
    func search(_ query: String, kind: PlaceSearchKind) async throws -> [PlaceResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = kind == .pointOfInterest ? .pointOfInterest : .address
        let search = SearchBox(MKLocalSearch(request: request))
        let response: MKLocalSearch.Response
        do {
            response = try await withTaskCancellationHandler {
                try await search.search.start()
            } onCancel: {
                search.cancel()
            }
        } catch let error where Self.isNoResults(error) {
            try Task.checkCancellation()
            return []
        }
        try Task.checkCancellation()
        return response.mapItems.map { PlaceResult($0, kind: kind) }
    }

    /// MapKit reports a search that found nothing as `MKError.placemarkNotFound` rather than
    /// an empty response (seen for the address search of a place name). That is "no
    /// results", not a failed search; every other error still fails the section.
    nonisolated static func isNoResults(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == MKErrorDomain && error.code == Int(MKError.Code.placemarkNotFound.rawValue)
    }

    private nonisolated final class SearchBox: @unchecked Sendable {
        let search: MKLocalSearch

        init(_ search: MKLocalSearch) {
            self.search = search
        }

        func cancel() {
            search.cancel()
        }
    }
}
