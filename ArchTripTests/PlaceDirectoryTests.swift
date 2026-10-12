import Foundation
import Testing
@testable import ArchTrip

/// `PlaceDirectory` without MapKit: a scripted fetcher, a settable clock and short real
/// waits. Screen interest drives network work; document references drive retention; hold
/// and work tokens are never reused, so late completions and stale releases do nothing.
@MainActor
struct PlaceDirectoryTests {
    /// Scripted lookups. `.hang` suspends until the task is cancelled; `.deferred` suspends
    /// and ignores cancellation until the test completes it (a late, un-cancellable reply).
    final class FakeFetcher: PlaceFetching {
        enum Outcome { case place(ResolvedPlace), failure(PlaceFetchFailure), hang, deferred }
        var outcomes: [String: [Outcome]] = [:]
        private(set) var calls: [String] = []
        private(set) var cancelled: [String] = []
        private var deferred: [String: [CheckedContinuation<ResolvedPlace, Error>]] = [:]
        var fetchCount: Int { calls.count }

        func script(_ identifier: String, _ outcomes: Outcome...) {
            self.outcomes[identifier] = outcomes
        }

        func fetch(_ identifier: String) async throws -> ResolvedPlace {
            calls.append(identifier)
            var queue = outcomes[identifier] ?? []
            let outcome = queue.isEmpty ? Outcome.failure(.server) : queue.removeFirst()
            outcomes[identifier] = queue
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
            case .deferred:
                return try await withCheckedThrowingContinuation { continuation in
                    deferred[identifier, default: []].append(continuation)
                }
            }
        }

        var pendingDeferred: Int { deferred.values.reduce(0) { $0 + $1.count } }

        /// Completes the oldest deferred request for `identifier`, long after anyone cared.
        func complete(_ identifier: String, with result: Result<ResolvedPlace, PlaceFetchFailure>) {
            guard var queue = deferred[identifier], !queue.isEmpty else { return }
            let continuation = queue.removeFirst()
            deferred[identifier] = queue
            continuation.resume(with: result)
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
        configuration.retryDelays = [
            .offline: [0.01, 0.01, 0.01, 0.01], .timeout: [0.01, 0.01, 0.01], .transport: [0.01, 0.01],
            .throttled: [0.01, 0.01], .server: [0.01, 0.01], .notFound: [],
        ]
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

        let token = directory.retain("A")
        #expect(directory.state(for: "A") == .loading)
        await settle("resolved") { isResolved(directory.state(for: "A")) }
        #expect(directory.place(for: "A") == Self.place("A"))
        #expect(fetcher.fetchCount == 1)

        directory.release(token)
        #expect(directory.interest(in: "A") == 0)
        #expect(directory.place(for: "A") == Self.place("A"), "kept: a document still refers to it")
        let again = directory.retain("A")
        await Task.yield()
        #expect(fetcher.fetchCount == 1, "a fresh value is not refetched")
        directory.release(again)
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

        let a = directory.retain("A")
        let b = directory.retain("B")
        let c = directory.retain("C")
        await settle("two running") { fetcher.fetchCount == 2 }
        #expect(directory.state(for: "C") == .loading, "queued behind the concurrency limit")

        directory.release(c)
        #expect(directory.state(for: "C") == .idle, "left the queue without ever fetching")
        directory.release(a)
        await settle("A cancelled") { fetcher.cancelled.contains("A") }
        #expect(directory.state(for: "A") == .idle)
        #expect(fetcher.fetchCount == 2, "freed slot is not used by C: C has no interest")

        // Re-shown: a new request is made.
        let a2 = directory.retain("A")
        await settle("A resolved after re-retain") { isResolved(directory.state(for: "A")) }
        #expect(fetcher.fetchCount == 3)
        directory.release(a2)
        directory.release(b)
        await settle("B cancelled") { fetcher.cancelled.contains("B") }
    }

    @Test func documentReferencesDecideRetentionIndependentlyOfInterest() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .place(Self.place("A")), .place(Self.place("A")))
        let directory = makeDirectory(fetcher, clock: clock)

        // No document refers to A yet (e.g. opened before the listener caught up): kept while shown...
        let first = directory.retain("A")
        await settle("resolved") { isResolved(directory.state(for: "A")) }
        // ...and dropped as soon as nobody shows it either.
        directory.release(first)
        #expect(directory.state(for: "A") == .idle)

        // With a document reference, the value survives release and a later reference update.
        directory.updateDocumentReferences(["A"])
        let second = directory.retain("A")
        await settle("resolved again") { isResolved(directory.state(for: "A")) }
        directory.release(second)
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

        let row1 = directory.retain("A") // row of Building 1
        let row2 = directory.retain("A") // row of Building 2
        await settle("resolved") { isResolved(directory.state(for: "A")) }
        #expect(fetcher.fetchCount == 1)
        #expect(directory.interest(in: "A") == 2)

        directory.release(row1) // Building 1's row gone
        #expect(isResolved(directory.state(for: "A")))
        // Building 1 deleted: the other document still refers to A, nothing changes.
        directory.updateDocumentReferences(["A"])
        #expect(isResolved(directory.state(for: "A")))
        // Building 2 deleted while its row is still on screen: kept until the view goes.
        directory.updateDocumentReferences([])
        #expect(isResolved(directory.state(for: "A")))
        directory.release(row2)
        #expect(directory.state(for: "A") == .idle)
    }

    @Test func leastRecentlyUsedValuesAreEvictedPastTheLimit() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        for id in ["A", "B", "C"] { fetcher.script(id, .place(Self.place(id))) }
        let directory = makeDirectory(fetcher, clock: clock, configuration: Self.configuration(maxEntries: 2))
        directory.updateDocumentReferences(["A", "B", "C"])
        for id in ["A", "B", "C"] {
            let token = directory.retain(id)
            await settle("\(id) resolved") { isResolved(directory.state(for: id)) }
            directory.release(token)
            clock.advance(1)
        }
        #expect(directory.state(for: "A") == .idle, "least recently used value evicted past the limit")
        #expect(isResolved(directory.state(for: "B")) && isResolved(directory.state(for: "C")))
    }

    // MARK: Tokens: late completions and stale releases

    /// A reply that arrives after its request was superseded (the fetcher ignored the
    /// cancel) never overwrites the newer result, whether it is a success or a failure.
    @Test func aDelayedOldRequestNeverOverwritesANewerResult() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        let old = Self.place("A", name: "Old")
        let new = Self.place("A", name: "New")
        fetcher.script("A", .deferred, .place(new), .deferred)
        let directory = makeDirectory(fetcher, clock: clock)
        directory.updateDocumentReferences(["A"])

        let first = directory.retain("A")
        await settle("old request in flight") { fetcher.fetchCount == 1 }
        directory.release(first) // cancels; the fake keeps the request alive anyway
        #expect(directory.state(for: "A") == .idle)
        let second = directory.retain("A")
        await settle("new result shown") { directory.place(for: "A") == new }
        #expect(fetcher.fetchCount == 2)

        fetcher.complete("A", with: .success(old))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(directory.place(for: "A") == new, "the late old reply is ignored")
        #expect(fetcher.fetchCount == 2, "and triggers nothing")

        // A late failure is ignored just the same: cancel a refresh, then let it fail.
        clock.advance(Self.configuration().freshness + 1)
        directory.release(second)
        let third = directory.retain("A") // stale: starts a refresh (deferred)
        await settle("refresh in flight") { fetcher.fetchCount == 3 }
        directory.release(third)
        let fourth = directory.retain("A")
        fetcher.complete("A", with: .failure(.offline))
        try? await Task.sleep(for: .milliseconds(20))
        if case .resolved(let place, _, _) = directory.state(for: "A") {
            #expect(place == new, "the value is still shown")
        } else {
            Issue.record("a late failure must not turn the shown value into a failure: \(directory.state(for: "A"))")
        }
        directory.release(fourth)
        #expect(fetcher.pendingDeferred == 0)
    }

    /// After a clear (sign-out / user switch) and the same ID being created again, a reply
    /// to the pre-clear request is ignored; with no re-creation it leaves no entry behind.
    @Test func aDelayedOldRequestIsIgnoredAfterClearAndRecreation() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        let old = Self.place("A", name: "Old")
        let new = Self.place("A", name: "New")
        fetcher.script("A", .deferred, .place(new), .deferred)
        let directory = makeDirectory(fetcher, clock: clock)
        directory.updateDocumentReferences(["A"])

        let before = directory.retain("A")
        await settle("in flight") { fetcher.fetchCount == 1 }
        directory.clear()
        #expect(directory.state(for: "A") == .idle && directory.interest(in: "A") == 0)

        // Same ID, new user: a fresh entry and a fresh request.
        directory.updateDocumentReferences(["A"])
        let after = directory.retain("A")
        await settle("new user's result") { directory.place(for: "A") == new }
        fetcher.complete("A", with: .success(old))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(directory.place(for: "A") == new, "the pre-clear reply is ignored")
        directory.release(before) // the old screen's token: no effect on the new hold
        #expect(directory.interest(in: "A") == 1)
        directory.release(after)

        // Clear with nothing re-created: the late reply must not resurrect an entry.
        clock.advance(Self.configuration().freshness + 1)
        let again = directory.retain("A") // refresh in flight (deferred)
        await settle("refresh in flight") { fetcher.fetchCount == 3 }
        directory.clear()
        fetcher.complete("A", with: .success(old))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(directory.state(for: "A") == .idle && directory.isIdle)
        directory.release(again)
        #expect(directory.state(for: "A") == .idle && directory.interest(in: "A") == 0)
    }

    /// Releases are by token: an old screen's token, after a clear or after the entry was
    /// discarded and re-created, cannot decrement a newer screen's claim. Tokens are never
    /// reused, and releasing twice is harmless.
    @Test func anOldScreensReleaseNeverTouchesANewerHold() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .place(Self.place("A")), .place(Self.place("A")), .place(Self.place("A")))
        let directory = makeDirectory(fetcher, clock: clock)

        // Across a clear.
        let old = directory.retain("A")
        directory.clear()
        let new = directory.retain("A")
        #expect(old != new)
        directory.release(old)
        #expect(directory.interest(in: "A") == 1, "the stale token changed nothing")
        directory.release(old)
        #expect(directory.interest(in: "A") == 1)
        directory.release(new)
        #expect(directory.interest(in: "A") == 0)

        // Across a discard and re-creation of the same ID (no document reference).
        let first = directory.retain("A")
        await settle("resolved") { isResolved(directory.state(for: "A")) }
        directory.release(first)
        #expect(directory.state(for: "A") == .idle, "discarded")
        let second = directory.retain("A")
        directory.release(first)
        #expect(directory.interest(in: "A") == 1, "the token of the discarded entry is dead")
        directory.release(second)
        directory.release(second)
        #expect(directory.interest(in: "A") == 0)
    }

    /// A save the server rejects: the candidate was never cached (the directory has no way
    /// in but a fetch), the Building's row fetched while it existed locally, and once the
    /// document is gone and the row with it, nothing remains and nothing is reused later.
    @Test func aRevertedSaveLeavesNothingBehind() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .place(Self.place("A", name: "First")), .place(Self.place("A", name: "Second")))
        let directory = makeDirectory(fetcher, clock: clock)
        #expect(directory.place(for: "A") == nil && fetcher.fetchCount == 0, "linking in the editor puts nothing here")

        // The local write made the row appear; the listener reported the document.
        directory.updateDocumentReferences(["A"])
        let row = directory.retain("A")
        await settle("fetched while the row exists") { directory.place(for: "A")?.name == "First" }

        // Server rejected: the document is reverted and the row disappears.
        directory.updateDocumentReferences([])
        #expect(isResolved(directory.state(for: "A")), "still shown until the row goes")
        directory.release(row)
        #expect(directory.state(for: "A") == .idle)

        // Saved properly later: a fresh fetch, not the leftover of the failed attempt.
        directory.updateDocumentReferences(["A"])
        let again = directory.retain("A")
        await settle("fetched again") { directory.place(for: "A")?.name == "Second" }
        #expect(fetcher.fetchCount == 2)
        directory.release(again)
    }

    // MARK: Failures and retries

    @Test func offlineFailuresRetryAutomaticallyThenWaitForAManualRetry() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .failure(.offline), .failure(.offline), .failure(.offline), .failure(.offline), .failure(.offline), .place(Self.place("A")))
        let directory = makeDirectory(fetcher, clock: clock)
        directory.updateDocumentReferences(["A"])
        let token = directory.retain("A")

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
        directory.release(token)
    }

    @Test func notFoundIsNeverRetriedAutomatically() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .failure(.notFound), .place(Self.place("A")))
        let directory = makeDirectory(fetcher, clock: clock)
        directory.updateDocumentReferences(["A"])
        let token = directory.retain("A")
        await settle("not found") { directory.state(for: "A") == .failed(.notFound, attempts: 1, nextRetryAt: nil) }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(fetcher.fetchCount == 1)
        directory.handleForeground()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(fetcher.fetchCount == 1, "foreground does not retry a not-found place")
        directory.retry("A")
        await settle("manual retry") { isResolved(directory.state(for: "A")) }
        directory.release(token)
    }

    /// Each failure kind has its own automatic schedule; timeouts and transport failures
    /// are not treated as offline.
    @Test func eachFailureKindHasItsOwnSchedule() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        let expectedAttempts: [(id: String, failure: PlaceFetchFailure, attempts: Int)] = [
            ("O", .offline, 5), ("T", .timeout, 4), ("X", .transport, 3), ("H", .throttled, 3), ("S", .server, 3),
        ]
        for entry in expectedAttempts {
            fetcher.script(entry.id, .failure(entry.failure), .failure(entry.failure), .failure(entry.failure), .failure(entry.failure), .failure(entry.failure), .failure(entry.failure))
        }
        var configuration = Self.configuration()
        configuration.concurrency = 5
        let directory = makeDirectory(fetcher, clock: clock, configuration: configuration)
        directory.updateDocumentReferences(Set(expectedAttempts.map(\.id)))
        let tokens = expectedAttempts.map { directory.retain($0.id) }
        await settle("all exhausted") {
            expectedAttempts.allSatisfy { directory.state(for: $0.id) == .failed($0.failure, attempts: $0.attempts, nextRetryAt: nil) }
        }
        for entry in expectedAttempts {
            #expect(fetcher.calls.filter { $0 == entry.id }.count == entry.attempts, "\(entry.failure)")
        }
        tokens.forEach(directory.release)
    }

    @Test func releaseCancelsAPendingRetryWait() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .failure(.offline), .place(Self.place("A")))
        var configuration = Self.configuration()
        configuration.retryDelays[.offline] = [0.1]
        let directory = makeDirectory(fetcher, clock: clock, configuration: configuration)
        directory.updateDocumentReferences(["A"])
        let token = directory.retain("A")
        await settle("failed, waiting") {
            if case .failed(.offline, attempts: 1, nextRetryAt: .some) = directory.state(for: "A") { return true }
            return false
        }
        directory.release(token)
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
        let a = directory.retain("A")
        let b = directory.retain("B")
        await settle("exhausted") {
            directory.state(for: "A") == .failed(.server, attempts: 3, nextRetryAt: nil)
                && directory.state(for: "B") == .failed(.server, attempts: 3, nextRetryAt: nil)
        }
        directory.release(b) // B is no longer on screen
        directory.handleForeground()
        await settle("A retried once") { isResolved(directory.state(for: "A")) }
        #expect(fetcher.calls.filter { $0 == "A" }.count == 4)
        #expect(fetcher.calls.filter { $0 == "B" }.count == 3, "not shown, not retried")
        directory.release(a)
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
        let first = directory.retain("A")
        await settle("resolved") { directory.place(for: "A") == old }
        directory.release(first)

        // Past freshness: shown again, the old value stays visible while the refetch fails.
        clock.advance(61)
        let second = directory.retain("A")
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
        directory.release(second)

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
        let token = directory.retain("A")
        await settle("resolved") { directory.place(for: "A") == old }
        await settle("refreshed by the timer") { directory.place(for: "A") == new }
        directory.release(token)
    }

    // MARK: Clearing

    @Test func clearCancelsEverythingAndForgetsEverything() async {
        let fetcher = FakeFetcher()
        let clock = Clock()
        fetcher.script("A", .hang)
        fetcher.script("B", .place(Self.place("B")))
        let directory = makeDirectory(fetcher, clock: clock)
        directory.updateDocumentReferences(["A", "B"])
        _ = directory.retain("A")
        _ = directory.retain("B")
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
        let a = directory.retain("A")
        let b = directory.retain("B")
        await settle("both resolved") { isResolved(directory.state(for: "A")) && isResolved(directory.state(for: "B")) }
        directory.release(b)
        directory.discardUndisplayed()
        #expect(isResolved(directory.state(for: "A")) && directory.state(for: "B") == .idle)
        directory.release(a)
    }

    /// The display type has no persistence path: it cannot be encoded, so it can never be
    /// written to Firestore, the cache, UserDefaults or a file by accident.
    @Test func resolvedPlacesAreNeverEncodable() {
        #expect(!(ResolvedPlace.self is any Encodable.Type))
        #expect(!(ResolvedPlace.self is any Decodable.Type))
        #expect(!(PlaceDirectory.State.self is any Encodable.Type))
    }
}
