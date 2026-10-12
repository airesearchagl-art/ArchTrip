import Foundation
import MapKit
import Testing
@testable import ArchTrip

/// `PlaceSearch` without MapKit: a scripted searcher answers the point-of-interest and the
/// address search separately. Results are sectioned by the search that returned them, a
/// query in flight is not repeated, replies to abandoned requests are ignored however late
/// they arrive, and one search failing leaves the other's results.
@MainActor
struct PlaceSearchTests {
    struct FakeError: Error {}

    /// Scripted searches. `.hang` suspends until the task is cancelled; `.deferred`
    /// suspends and ignores cancellation until the test completes it (a late reply).
    final class FakeSearcher: PlaceSearching {
        struct Key: Hashable {
            let query: String
            let kind: PlaceSearchKind
        }

        enum Outcome { case results([PlaceResult]), failure, hang, deferred }

        private var outcomes: [Key: [Outcome]] = [:]
        private(set) var calls: [Key] = []
        private var deferred: [Key: [CheckedContinuation<[PlaceResult], Error>]] = [:]

        func script(_ query: String, _ kind: PlaceSearchKind, _ outcomes: Outcome...) {
            self.outcomes[Key(query: query, kind: kind)] = outcomes
        }

        func calls(_ query: String, _ kind: PlaceSearchKind) -> Int {
            calls.filter { $0 == Key(query: query, kind: kind) }.count
        }

        func search(_ query: String, kind: PlaceSearchKind) async throws -> [PlaceResult] {
            let key = Key(query: query, kind: kind)
            calls.append(key)
            var queue = outcomes[key] ?? []
            let outcome = queue.isEmpty ? Outcome.failure : queue.removeFirst()
            outcomes[key] = queue
            // Every search yields once, so a cancellation issued right after the request is seen.
            await Task.yield()
            switch outcome {
            case .results(let results):
                return results
            case .failure:
                throw FakeError()
            case .hang:
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    throw CancellationError()
                }
                throw FakeError()
            case .deferred:
                return try await withCheckedThrowingContinuation { continuation in
                    deferred[key, default: []].append(continuation)
                }
            }
        }

        /// Completes the oldest deferred request, long after anyone cared.
        func complete(_ query: String, _ kind: PlaceSearchKind, with result: Result<[PlaceResult], FakeError>) {
            let key = Key(query: query, kind: kind)
            guard var queue = deferred[key], !queue.isEmpty else { return }
            let continuation = queue.removeFirst()
            deferred[key] = queue
            continuation.resume(with: result)
        }
    }

    private let sampleID = "I63802885C8189B2B"

    private func result(_ name: String, kind: PlaceSearchKind, identifier: String?) -> PlaceResult {
        PlaceResult(
            kind: kind, name: name, address: "架空県架空市架空町一丁目",
            latitude: 43.0, longitude: 141.3, identifier: identifier
        )
    }

    /// Waits until `condition` holds, or fails after a generous bound.
    private func settle(_ label: String, timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), Comment(rawValue: label))
    }

    private func results(_ search: PlaceSearch, _ kind: PlaceSearchKind) -> [PlaceResult]? {
        if case .results(let results) = search.state(of: kind) { return results }
        return nil
    }

    // MARK: Sections

    @Test func resultsAreSectionedByTheSearchThatReturnedThem() async {
        let searcher = FakeSearcher()
        let poiWithID = result("Fixture hall", kind: .pointOfInterest, identifier: sampleID)
        let poiWithoutID = result("Fixture annex", kind: .pointOfInterest, identifier: nil)
        let addressWithID = result("Fixture street 1", kind: .address, identifier: "IFIXTUREADDRESS01")
        let addressWithoutID = result("Fixture street 2", kind: .address, identifier: nil)
        searcher.script("fixture", .pointOfInterest, .results([poiWithID, poiWithoutID]))
        searcher.script("fixture", .address, .results([addressWithID, addressWithoutID]))
        let search = PlaceSearch(searcher: searcher)

        search.search("  fixture ")
        #expect(search.query == "fixture", "the query is trimmed")
        #expect(search.isActive && search.isSearching)
        #expect(search.state(of: .pointOfInterest) == .searching && search.state(of: .address) == .searching)
        await settle("both sections complete") { !search.isSearching }

        #expect(results(search, .pointOfInterest) == [poiWithID, poiWithoutID])
        #expect(results(search, .address) == [addressWithID, addressWithoutID])
        // Whether a result can be linked comes from its ID, not from the section it is in.
        #expect(poiWithoutID.linkIssue == .noIdentifier)
        #expect(addressWithID.linkIssue == nil)
        #expect(searcher.calls(  "fixture", .pointOfInterest) == 1 && searcher.calls("fixture", .address) == 1)
    }

    @Test func emptyAndFailedSectionsAreReportedApart() async {
        let searcher = FakeSearcher()
        searcher.script("fixture", .pointOfInterest, .results([]))
        searcher.script("fixture", .address, .failure)
        let search = PlaceSearch(searcher: searcher)

        search.search("fixture")
        await settle("both sections complete") { !search.isSearching }
        #expect(search.state(of: .pointOfInterest) == .empty)
        #expect(search.state(of: .address) == .failed)
        #expect(search.isActive, "the query stays shown with its outcomes")
    }

    @Test func blankQueriesDoNothing() {
        let searcher = FakeSearcher()
        let search = PlaceSearch(searcher: searcher)
        search.search("   ")
        search.search("")
        #expect(!search.isActive && !search.isSearching)
        #expect(searcher.calls.isEmpty)
        #expect(search.state(of: .pointOfInterest) == .idle && search.state(of: .address) == .idle)
    }

    // MARK: One request per query

    @Test func aQueryInFlightIsNotRequestedAgain() async {
        let searcher = FakeSearcher()
        let place = result("Fixture hall", kind: .pointOfInterest, identifier: sampleID)
        searcher.script("fixture", .pointOfInterest, .deferred, .results([place]))
        searcher.script("fixture", .address, .deferred, .results([]))
        let search = PlaceSearch(searcher: searcher)

        search.search("fixture")
        search.search("fixture")
        search.search(" fixture")
        await settle("requests sent") { searcher.calls.count == 2 }
        #expect(searcher.calls("fixture", .pointOfInterest) == 1, "a repeated tap does not repeat the request")
        #expect(searcher.calls("fixture", .address) == 1)

        searcher.complete("fixture", .pointOfInterest, with: .success([place]))
        searcher.complete("fixture", .address, with: .success([]))
        await settle("both sections complete") { !search.isSearching }
        #expect(results(search, .pointOfInterest) == [place])
        #expect(search.state(of: .address) == .empty)

        // After completion the same query may be searched again (a retry).
        search.search("fixture")
        await settle("retry sent") { searcher.calls("fixture", .pointOfInterest) == 2 && searcher.calls("fixture", .address) == 2 }
        await settle("retry complete") { !search.isSearching }
        #expect(results(search, .pointOfInterest) == [place])
    }

    // MARK: Abandoned requests

    @Test func aChangedQueryAbandonsTheOldRequestAndItsLateReply() async {
        let searcher = FakeSearcher()
        let old = result("Fixture old", kind: .pointOfInterest, identifier: sampleID)
        let new = result("Fixture new", kind: .pointOfInterest, identifier: "IFIXTURENEW000001")
        searcher.script("old", .pointOfInterest, .deferred)
        searcher.script("old", .address, .deferred)
        searcher.script("new", .pointOfInterest, .results([new]))
        searcher.script("new", .address, .results([]))
        let search = PlaceSearch(searcher: searcher)

        search.search("old")
        await settle("old requests sent") { searcher.calls.count == 2 }
        search.queryChanged("ol")
        #expect(!search.isActive && !search.isSearching, "a changed query shows nothing until searched")
        #expect(search.state(of: .pointOfInterest) == .idle && search.state(of: .address) == .idle)

        search.search("new")
        await settle("new sections complete") { !search.isSearching }
        #expect(results(search, .pointOfInterest) == [new])

        // The old request replies now: ignored, the new results stay.
        searcher.complete("old", .pointOfInterest, with: .success([old]))
        searcher.complete("old", .address, with: .failure(FakeError()))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(search.query == "new")
        #expect(results(search, .pointOfInterest) == [new])
        #expect(search.state(of: .address) == .empty)
    }

    @Test func retypingTheSameQueryKeepsWhatIsShown() async {
        let searcher = FakeSearcher()
        let place = result("Fixture hall", kind: .pointOfInterest, identifier: sampleID)
        searcher.script("fixture", .pointOfInterest, .results([place]))
        searcher.script("fixture", .address, .results([]))
        let search = PlaceSearch(searcher: searcher)

        search.search("fixture")
        await settle("complete") { !search.isSearching }
        search.queryChanged("fixture ")
        search.queryChanged(" fixture")
        #expect(results(search, .pointOfInterest) == [place])
        search.queryChanged("fixtures")
        #expect(!search.isActive)
    }

    @Test func cancelKeepsCompletedSectionsAndDropsLateReplies() async {
        let searcher = FakeSearcher()
        let place = result("Fixture hall", kind: .pointOfInterest, identifier: sampleID)
        let late = result("Fixture street", kind: .address, identifier: nil)
        searcher.script("fixture", .pointOfInterest, .results([place]))
        searcher.script("fixture", .address, .deferred)
        let search = PlaceSearch(searcher: searcher)

        search.search("fixture")
        await settle("places complete") { results(search, .pointOfInterest) == [place] }
        #expect(search.state(of: .address) == .searching)

        search.cancel()
        #expect(!search.isSearching)
        #expect(results(search, .pointOfInterest) == [place], "a completed section keeps its results")
        #expect(search.state(of: .address) == .idle, "a cancelled section is neither failed nor searching")

        searcher.complete("fixture", .address, with: .success([late]))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(search.state(of: .address) == .idle, "the late reply is ignored")
    }

    @Test func cancellingAHangingRequestIsNotAFailure() async {
        let searcher = FakeSearcher()
        searcher.script("fixture", .pointOfInterest, .hang)
        searcher.script("fixture", .address, .hang)
        let search = PlaceSearch(searcher: searcher)

        search.search("fixture")
        await settle("requests sent") { searcher.calls.count == 2 }
        search.cancel()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(search.state(of: .pointOfInterest) == .idle && search.state(of: .address) == .idle)
        #expect(search.isActive, "the query is still shown; a tap searches it again")
    }

    @Test func resetShowsNothingAndIgnoresLateReplies() async {
        let searcher = FakeSearcher()
        let late = result("Fixture hall", kind: .pointOfInterest, identifier: sampleID)
        searcher.script("fixture", .pointOfInterest, .deferred)
        searcher.script("fixture", .address, .deferred)
        let search = PlaceSearch(searcher: searcher)

        search.search("fixture")
        await settle("requests sent") { searcher.calls.count == 2 }
        search.reset()
        #expect(!search.isActive && !search.isSearching)

        searcher.complete("fixture", .pointOfInterest, with: .success([late]))
        searcher.complete("fixture", .address, with: .success([late]))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!search.isActive)
        #expect(search.state(of: .pointOfInterest) == .idle && search.state(of: .address) == .idle)
    }

    // MARK: Independence of the two kinds

    @Test func oneKindFailingLeavesTheOthersResults() async {
        let searcher = FakeSearcher()
        let place = result("Fixture hall", kind: .pointOfInterest, identifier: sampleID)
        let street = result("Fixture street", kind: .address, identifier: nil)
        searcher.script("fixture", .pointOfInterest, .failure, .results([place]))
        searcher.script("fixture", .address, .results([street]), .failure)
        let search = PlaceSearch(searcher: searcher)

        search.search("fixture")
        await settle("complete") { !search.isSearching }
        #expect(search.state(of: .pointOfInterest) == .failed)
        #expect(results(search, .address) == [street], "the address results survive the place failure")

        search.search("fixture")
        await settle("retry complete") { !search.isSearching }
        #expect(results(search, .pointOfInterest) == [place])
        #expect(search.state(of: .address) == .failed, "and the other way round")
    }

    @Test func aSlowKindDoesNotHoldBackTheOther() async {
        let searcher = FakeSearcher()
        let street = result("Fixture street", kind: .address, identifier: "IFIXTUREADDRESS01")
        searcher.script("fixture", .pointOfInterest, .deferred)
        searcher.script("fixture", .address, .results([street]))
        let search = PlaceSearch(searcher: searcher)

        search.search("fixture")
        await settle("addresses complete first") { results(search, .address) == [street] }
        #expect(search.state(of: .pointOfInterest) == .searching && search.isSearching)
        searcher.complete("fixture", .pointOfInterest, with: .success([]))
        await settle("places complete") { search.state(of: .pointOfInterest) == .empty }
        #expect(results(search, .address) == [street])
    }

    // MARK: Linking and saving rules

    /// A point of interest without an ID cannot be linked; an address with one can. The
    /// length bound is a different reason, kept apart from "no ID".
    @Test func linkabilityComesFromTheIdentifierNotTheKind() {
        #expect(result("Fixture", kind: .pointOfInterest, identifier: nil).linkIssue == .noIdentifier)
        #expect(result("Fixture", kind: .pointOfInterest, identifier: "").linkIssue == .noIdentifier)
        #expect(result("Fixture", kind: .pointOfInterest, identifier: sampleID).linkIssue == nil)
        #expect(result("Fixture", kind: .address, identifier: nil).linkIssue == .noIdentifier)
        #expect(result("Fixture", kind: .address, identifier: sampleID).linkIssue == nil)
        let tooLong = String(repeating: "A", count: Building.applePlaceIdMaxLength + 1)
        #expect(result("Fixture", kind: .address, identifier: tooLong).linkIssue == .identifierTooLong)
        #expect(result("Fixture", kind: .pointOfInterest, identifier: tooLong).linkIssue == .identifierTooLong)

        let withAlternates = PlaceResult(
            kind: .pointOfInterest, name: "Fixture", address: "", latitude: 0, longitude: 0,
            identifier: sampleID, alternateIdentifiers: ["IOLD0000000000001"]
        )
        #expect(withAlternates.allIdentifiers == [sampleID, "IOLD0000000000001"])
        #expect(result("Fixture", kind: .address, identifier: nil).allIdentifiers.isEmpty)
    }

    /// Saving a Building never depends on the search: with no place linked, a failed or
    /// empty search, or a result that cannot be linked, the existing rules alone apply.
    @Test func anUnlinkedBuildingSavesRegardlessOfTheSearch() async {
        let searcher = FakeSearcher()
        searcher.script("fixture", .pointOfInterest, .failure)
        searcher.script("fixture", .address, .results([result("Fixture street", kind: .address, identifier: nil)]))
        let search = PlaceSearch(searcher: searcher)
        search.search("fixture")
        await settle("complete") { !search.isSearching }
        #expect(search.state(of: .pointOfInterest) == .failed)

        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let unlinked = Building(id: "b1", name: "Fixture building", note: "Fixture note", createdAt: date)
        #expect(unlinked.applePlaceId == nil && !unlinked.hasPlace)
        #expect(unlinked.isValid && unlinked.isWritable)
        #expect(Building(id: "b2", name: "", createdAt: date).isWritable == false, "the existing name rule still applies")
    }

    // MARK: MapKit error mapping

    /// MapKit answers a search that found nothing with `MKError.placemarkNotFound`, not an
    /// empty list. That is the empty state ("No places/addresses found"), never the failed
    /// one; every other error, and cancellation, is left alone.
    @Test func mapKitNotFoundIsNoResultsNotAFailure() {
        let notFound = NSError(domain: MKErrorDomain, code: Int(MKError.Code.placemarkNotFound.rawValue))
        #expect(MapKitPlaceSearcher.isNoResults(notFound))
        #expect(MapKitPlaceSearcher.isNoResults(MKError(.placemarkNotFound)))
        #expect(!MapKitPlaceSearcher.isNoResults(MKError(.serverFailure)))
        #expect(!MapKitPlaceSearcher.isNoResults(MKError(.loadingThrottled)))
        #expect(!MapKitPlaceSearcher.isNoResults(MKError(.unknown)))
        #expect(!MapKitPlaceSearcher.isNoResults(URLError(.notConnectedToInternet)))
        #expect(!MapKitPlaceSearcher.isNoResults(NSError(domain: NSURLErrorDomain, code: 4)), "the code alone is not enough")
        #expect(!MapKitPlaceSearcher.isNoResults(CancellationError()))
    }
}
