import Foundation
import Testing
@testable import ArchTrip

/// `PlaceDirectory` without MapKit: a scripted fetcher, a settable clock and short real
/// waits. Screen interest drives network work; document references drive retention.
@MainActor
struct PlaceDirectoryTests {
    /// Scripted lookups. A `.hang` outcome suspends until the task is cancelled.
    final class FakeFetcher: PlaceFetching {
        enum Outcome { case place(ResolvedPlace), failure(PlaceFetchFailure), hang }
        var outcomes: [String: [Outcome]] = [:]
        private(set) var calls: [String] = []
        private(set) var cancelled: [String] = []
        var fetchCount: Int { calls.count }

        func script(_ identifier: String, _ outcomes: Outcome...) {
            self.outcomes[identifier] = outcomes
        }

        func fetch(_ identifier: String) async throws -> ResolvedPlace {
            calls.append(identifier)
            var queue = outcomes[identifier] ?? []
            let outcome = queue.isEmpty ? Outcome.failure(.server) : queue.removeFirst()
            if queue.count > 0 { outcomes[identifier] = queue } else if outcomes[identifier] != nil { outcomes[identifier] = queue }
            // Every fetch yields once, so a cancellation issued right after the request is seen.
            await Task.yield()
            switch outcome {
            case .place(let place):
                return place
            case .failure(let failure):
                throw failure
            case .hang:
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.append(identifier)
                    throw CancellationError()
                }
                throw PlaceFetchFailure.server
            }
        }
    }

    final class Clock {
        var date = Date(timeIntervalSince1970: 1_790_000_000)
        func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    }

    private static func place(_ id: String, alternates: Set<String> = [], name: String = "Fixture place") -> ResolvedPlace {
        ResolvedPlace(identifier: id, alternateIdentifiers: alternates, name: name, address: "架空県架空市架空町一丁目", latitude: 43.0, longitude: 141.3)
    }

    /// Tiny delays so automatic retries happen within the test.
    private static func configuration(freshness: TimeInterval = 3600, retention: TimeInterval = 86_400, maxEntries: Int = 100) -> PlaceDirectory.Configuration {
        var configuration = PlaceDirectory.Configuration()
        configuration.freshness = freshness
        configuration.maxRetention = retention
        configuration.maxEntries = maxEntries
        configuration.minManualRetryInterval = 0
        configuration.retryDelays = [.offline: [0.01, 0.01, 0.01, 0.01], .throttled: [0.01, 0.01], .server: [0.01, 0.01], .notFound: []]
        return configuration
    }

    private func makeDirectory(_ fetcher: FakeFetcher, clock: Clock, configuration: PlaceDirectory.Configuration? = nil) -> PlaceDirectory {
        PlaceDirectory(fetcher: fetcher, configuration: configuration ?? Self.configuration(), now: { clock.date })
    }

    /// Waits until `condition` holds, or fails after a generous bound.
    private func settle(_ label: String, timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), Comment(rawValue: label))
    }

    private func isResolved(_ state: PlaceDirectory.State) -> Bool {
        if case .resolved = state { return true }
        return false
    }

    // MARK: On demand, interest and cache

    @Test func fetchesOnDemandAndKeepsTheValueAfterRelease() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .place(Self.place("A")))
        let directory = makeDirectory(fetcher, clock: clock)
        directory.updateDocumentReferences(["A"])
        #expect(fetcher.fetchCount == 0, "document references alone never fetch (no prefetch)")

        directory.retain("A")
        #expect(directory.state(for: "A") == .loading)
        await settle("resolved") { isResolved(directory.state(for: "A")) }
        #expect(directory.place(for: "A") == Self.place("A"))
        #expect(fetcher.fetchCount == 1)

        directory.release("A")
        #expect(directory.interest(in: "A") == 0)
        #expect(directory.place(for: "A") == Self.place("A"), "kept: a document still refers to it")
        directory.retain("A")
        await Task.yield()
        #expect(fetcher.fetchCount == 1, "a fresh value is not refetched")
        directory.release("A")
    }

    @Test func releaseAtZeroInterestCancelsTheRequestAndTheQueue() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .hang, .place(Self.place("A")))
        fetcher.script("B", .hang)
        fetcher.script("C", .hang)
        var configuration = Self.configuration()
        configuration.concurrency = 2
        let directory = makeDirectory(fetcher, clock: clock, configuration: configuration)
        directory.updateDocumentReferences(["A", "B", "C"])

        directory.retain("A")
        directory.retain("B")
        directory.retain("C")
        await settle("two running") { fetcher.fetchCount == 2 }
        #expect(directory.state(for: "C") == .loading, "queued behind the concurrency limit")

        directory.release("C")
        #expect(directory.state(for: "C") == .idle, "left the queue without ever fetching")
        directory.release("A")
        await settle("A cancelled") { fetcher.cancelled.contains("A") }
        #expect(directory.state(for: "A") == .idle)
        #expect(fetcher.fetchCount == 2, "freed slot is not used by C: C has no interest")

        // Re-shown: a new request is made.
        directory.retain("A")
        await settle("A resolved after re-retain") { isResolved(directory.state(for: "A")) }
        #expect(fetcher.fetchCount == 3)
        directory.release("A")
        directory.release("B")
        await settle("B cancelled") { fetcher.cancelled.contains("B") }
    }

    @Test func documentReferencesDecideRetentionIndependentlyOfInterest() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .place(Self.place("A")), .place(Self.place("A")))
        let directory = makeDirectory(fetcher, clock: clock)

        // No document refers to A yet (e.g. opened before the listener caught up): kept while shown...
        directory.retain("A")
        await settle("resolved") { isResolved(directory.state(for: "A")) }
        // ...and dropped as soon as nobody shows it either.
        directory.release("A")
        #expect(directory.state(for: "A") == .idle)

        // With a document reference, the value survives release and a later reference update.
        directory.updateDocumentReferences(["A"])
        directory.retain("A")
        await settle("resolved again") { isResolved(directory.state(for: "A")) }
        directory.release("A")
        #expect(isResolved(directory.state(for: "A")))
        directory.updateDocumentReferences(["A", "Z"])
        #expect(isResolved(directory.state(for: "A")))
        directory.updateDocumentReferences([])
        #expect(directory.state(for: "A") == .idle, "no document and no view: discarded")
        #expect(fetcher.fetchCount == 2)
    }

    /// Two Buildings linked to one place share one entry: one fetch, one failure, and the
    /// value survives as long as either a document or a view still refers to it.
    @Test func aPlaceSharedByTwoBuildingsIsFetchedOnceAndOutlivesOneOfThem() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .place(Self.place("A")))
        let directory = makeDirectory(fetcher, clock: clock)
        directory.updateDocumentReferences(["A"]) // two Buildings, one ID: the set has one element

        directory.retain("A") // row of Building 1
        directory.retain("A") // row of Building 2
        await settle("resolved") { isResolved(directory.state(for: "A")) }
        #expect(fetcher.fetchCount == 1)
        #expect(directory.interest(in: "A") == 2)

        directory.release("A") // Building 1's row gone
        #expect(isResolved(directory.state(for: "A")))
        // Building 1 deleted: the other document still refers to A, nothing changes.
        directory.updateDocumentReferences(["A"])
        #expect(isResolved(directory.state(for: "A")))
        // Building 2 deleted while its row is still on screen: kept until the view goes.
        directory.updateDocumentReferences([])
        #expect(isResolved(directory.state(for: "A")))
        directory.release("A")
        #expect(directory.state(for: "A") == .idle)
    }

    @Test func seedingSkipsTheFetchAndRespectsTheLimit() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        let directory = makeDirectory(fetcher, clock: clock, configuration: Self.configuration(maxEntries: 2))
        directory.updateDocumentReferences(["A", "B", "C"])
        directory.seed("A", with: Self.place("A"))
        directory.retain("A")
        await Task.yield()
        #expect(fetcher.fetchCount == 0)
        #expect(directory.place(for: "A") == Self.place("A"))
        directory.release("A")

        clock.advance(1)
        directory.seed("B", with: Self.place("B"))
        clock.advance(1)
        directory.seed("C", with: Self.place("C"))
        #expect(directory.state(for: "A") == .idle, "least recently used value evicted past the limit")
        #expect(isResolved(directory.state(for: "B")) && isResolved(directory.state(for: "C")))
    }

    // MARK: Failures and retries

    @Test func offlineFailuresRetryAutomaticallyThenWaitForAManualRetry() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .failure(.offline), .failure(.offline), .failure(.offline), .failure(.offline), .failure(.offline), .place(Self.place("A")))
        let directory = makeDirectory(fetcher, clock: clock)
        directory.updateDocumentReferences(["A"])
        directory.retain("A")

        await settle("automatic retries exhausted") {
            if case .failed(.offline, attempts: 5, nextRetryAt: nil) = directory.state(for: "A") { return true }
            return false
        }
        #expect(fetcher.fetchCount == 5, "first attempt plus four automatic retries")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fetcher.fetchCount == 5, "no further automatic retries")

        directory.retry("A")
        await settle("manual retry succeeds") { isResolved(directory.state(for: "A")) }
        #expect(fetcher.fetchCount == 6)
        directory.release("A")
    }

    @Test func notFoundIsNeverRetriedAutomatically() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .failure(.notFound), .place(Self.place("A")))
        let directory = makeDirectory(fetcher, clock: clock)
        directory.updateDocumentReferences(["A"])
        directory.retain("A")
        await settle("not found") { directory.state(for: "A") == .failed(.notFound, attempts: 1, nextRetryAt: nil) }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(fetcher.fetchCount == 1)
        directory.handleForeground()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(fetcher.fetchCount == 1, "foreground does not retry a not-found place")
        directory.retry("A")
        await settle("manual retry") { isResolved(directory.state(for: "A")) }
        directory.release("A")
    }

    @Test func throttledAndServerFailuresHaveTheirOwnShorterSchedules() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("T", .failure(.throttled), .failure(.throttled), .failure(.throttled), .place(Self.place("T")))
        fetcher.script("S", .failure(.server), .failure(.server), .failure(.server), .place(Self.place("S")))
        let directory = makeDirectory(fetcher, clock: clock)
        directory.updateDocumentReferences(["T", "S"])
        directory.retain("T")
        directory.retain("S")
        await settle("both exhausted") {
            directory.state(for: "T") == .failed(.throttled, attempts: 3, nextRetryAt: nil)
                && directory.state(for: "S") == .failed(.server, attempts: 3, nextRetryAt: nil)
        }
        #expect(fetcher.calls.filter { $0 == "T" }.count == 3 && fetcher.calls.filter { $0 == "S" }.count == 3)
        directory.release("T")
        directory.release("S")
    }

    @Test func releaseCancelsAPendingRetryWait() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .failure(.offline), .place(Self.place("A")))
        var configuration = Self.configuration()
        configuration.retryDelays[.offline] = [0.1]
        let directory = makeDirectory(fetcher, clock: clock, configuration: configuration)
        directory.updateDocumentReferences(["A"])
        directory.retain("A")
        await settle("failed, waiting") {
            if case .failed(.offline, attempts: 1, nextRetryAt: .some) = directory.state(for: "A") { return true }
            return false
        }
        directory.release("A")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(fetcher.fetchCount == 1, "the retry wait died with the last viewer")
    }

    @Test func foregroundRetriesShownFailuresOnce() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .failure(.server), .failure(.server), .failure(.server), .place(Self.place("A")))
        fetcher.script("B", .failure(.server), .failure(.server), .failure(.server), .place(Self.place("B")))
        let directory = makeDirectory(fetcher, clock: clock)
        directory.updateDocumentReferences(["A", "B"])
        directory.retain("A")
        directory.retain("B")
        await settle("exhausted") {
            directory.state(for: "A") == .failed(.server, attempts: 3, nextRetryAt: nil)
                && directory.state(for: "B") == .failed(.server, attempts: 3, nextRetryAt: nil)
        }
        directory.release("B") // B is no longer on screen
        directory.handleForeground()
        await settle("A retried once") { isResolved(directory.state(for: "A")) }
        #expect(fetcher.calls.filter { $0 == "A" }.count == 4)
        #expect(fetcher.calls.filter { $0 == "B" }.count == 3, "not shown, not retried")
        directory.release("A")
    }

    // MARK: Freshness and retention

    @Test func staleValuesStayVisibleWhileRefetchingAndExpireAtTheRetentionLimit() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        let old = Self.place("A", name: "Old")
        let new = Self.place("A", name: "New")
        fetcher.script("A", .place(old), .failure(.offline), .failure(.offline), .failure(.offline), .failure(.offline), .failure(.offline), .place(new))
        let directory = makeDirectory(fetcher, clock: clock, configuration: Self.configuration(freshness: 60, retention: 600))
        directory.updateDocumentReferences(["A"])
        directory.retain("A")
        await settle("resolved") { directory.place(for: "A") == old }
        directory.release("A")

        // Past freshness: shown again, the old value stays visible while the refetch fails.
        clock.advance(61)
        directory.retain("A")
        await settle("stale, refetch exhausted") {
            if case .resolved(let place, _, stale: true) = directory.state(for: "A"), place == old, fetcher.fetchCount == 6 { return true }
            return false
        }
        #expect(directory.place(for: "A") == old)

        // Past retention: discarded, and refetched because it is still shown.
        clock.advance(600)
        directory.sweep()
        await settle("replaced after expiry") { directory.place(for: "A") == new }
        if case .resolved(_, _, stale: false) = directory.state(for: "A") {} else { Issue.record("fresh after refetch") }
        directory.release("A")

        // Past retention with nobody showing it: gone, not refetched.
        clock.advance(601)
        directory.sweep()
        #expect(directory.state(for: "A") == .idle)
        #expect(fetcher.fetchCount == 7)
    }

    @Test func theSweepTimerAppliesFreshnessByItself() async {
        let fetcher = FakeFetcher()
        let old = Self.place("A", name: "Old")
        let new = Self.place("A", name: "New")
        fetcher.script("A", .place(old), .place(new))
        let directory = PlaceDirectory(fetcher: fetcher, configuration: Self.configuration(freshness: 0.05, retention: 10))
        directory.updateDocumentReferences(["A"])
        directory.retain("A")
        await settle("resolved") { directory.place(for: "A") == old }
        await settle("refreshed by the timer") { directory.place(for: "A") == new }
        directory.release("A")
    }

    // MARK: Clearing

    @Test func clearCancelsEverythingAndForgetsEverything() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .hang)
        fetcher.script("B", .place(Self.place("B")))
        let directory = makeDirectory(fetcher, clock: clock)
        directory.updateDocumentReferences(["A", "B"])
        directory.retain("A")
        directory.retain("B")
        await settle("B resolved") { isResolved(directory.state(for: "B")) }
        directory.clear()
        await settle("A cancelled") { fetcher.cancelled.contains("A") }
        #expect(directory.state(for: "A") == .idle && directory.state(for: "B") == .idle)
        #expect(directory.interest(in: "A") == 0 && directory.isIdle)
    }

    @Test func memoryPressureDropsOnlyWhatIsNotShown() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .place(Self.place("A")))
        fetcher.script("B", .place(Self.place("B")))
        let directory = makeDirectory(fetcher, clock: clock)
        directory.updateDocumentReferences(["A", "B"])
        directory.retain("A")
        directory.retain("B")
        await settle("both resolved") { isResolved(directory.state(for: "A")) && isResolved(directory.state(for: "B")) }
        directory.release("B")
        directory.discardUndisplayed()
        #expect(isResolved(directory.state(for: "A")) && directory.state(for: "B") == .idle)
        directory.release("A")
    }

    /// The display type has no persistence path: it cannot be encoded, so it can never be
    /// written to Firestore, the cache, UserDefaults or a file by accident.
    @Test func resolvedPlacesAreNeverEncodable() {
        #expect(!(ResolvedPlace.self is any Encodable.Type))
        #expect(!(ResolvedPlace.self is any Decodable.Type))
        #expect(!(PlaceDirectory.State.self is any Encodable.Type))
    }
}
