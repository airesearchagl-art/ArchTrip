import Foundation
import MapKit
import Testing
@testable import ArchTrip

/// Travel MVP rules against a fake router: where a point may come from, what makes a
/// result stale, that late replies never show, and that a transit answer is not an Event.
@MainActor
struct TravelSearchTests {
    final class FakeRouter: TravelRouting {
        struct Call: Equatable {
            let from: TravelPoint
            let to: TravelPoint
            let mode: TravelMode
            let anchor: TravelAnchor
        }

        var outcomes: [Result<TravelResult, Error>] = []
        var hang = false
        /// A hung reply that does not react to cancellation at all (a router that never
        /// returns): only a release ends it.
        var ignoresCancellation = false
        private(set) var calls: [Call] = []
        private var hung: [Hang] = []

        /// A reply that waits until released, or until its task is cancelled (as MapKit
        /// does when `MKDirections.cancel()` is called).
        nonisolated final class Hang: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Never>?

            func arm(_ continuation: CheckedContinuation<Void, Never>) {
                lock.withLock { self.continuation = continuation }
            }

            func resume() {
                let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    defer { self.continuation = nil }
                    return self.continuation
                }
                continuation?.resume()
            }
        }

        func route(from: TravelPoint, to: TravelPoint, mode: TravelMode, anchor: TravelAnchor) async throws -> TravelResult {
            calls.append(Call(from: from, to: to, mode: mode, anchor: anchor))
            let outcome: Result<TravelResult, Error> = outcomes.isEmpty
                ? .success(TravelSearchTests.result(mode: mode))
                : (outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0])
            if hang {
                let hang = Hang()
                hung.append(hang)
                if ignoresCancellation {
                    await withCheckedContinuation { hang.arm($0) }
                } else {
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { hang.arm($0) }
                    } onCancel: {
                        hang.resume()
                    }
                    try Task.checkCancellation()
                }
            }
            return try outcome.get()
        }

        func release() {
            let waiting = hung
            hung = []
            for hang in waiting { hang.resume() }
        }
    }

    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    static func result(mode: TravelMode) -> TravelResult {
        switch mode {
        case .transit:
            TravelResult(mode: mode, kind: .eta(distance: 1_000), expectedTravelTime: 600, expectedDeparture: nil, expectedArrival: nil)
        default:
            TravelResult(mode: mode, kind: .route(distance: 1_000, steps: ["Fixture step"], path: [TravelCoordinate(latitude: 0, longitude: 0), TravelCoordinate(latitude: 1, longitude: 1)]), expectedTravelTime: 600, expectedDeparture: nil, expectedArrival: nil)
        }
    }

    private let pointA = TravelPoint(name: "Fixture A", latitude: 43.0, longitude: 141.0, placeID: "IFIXTUREA00000000")
    private let pointB = TravelPoint(name: "Fixture B", latitude: 43.1, longitude: 141.1, placeID: nil)

    private func event(_ id: String, buildingId: String? = nil, location: String = "", updatedAt: Date? = nil) -> Event {
        Event(
            id: id, tripId: "trip", type: buildingId == nil ? .business : .architecture, title: "Fixture \(id)",
            startDate: date, endDate: date.addingTimeInterval(3_600), locationName: location, createdAt: date,
            updatedAt: updatedAt, buildingId: buildingId
        )
    }

    private func building(_ id: String, placeID: String? = nil, latitude: Double? = nil, longitude: Double? = nil, updatedAt: Date? = nil) -> Building {
        Building(id: id, name: "Fixture building \(id)", address: "", latitude: latitude, longitude: longitude, createdAt: date, updatedAt: updatedAt, applePlaceId: placeID)
    }

    private func key(_ from: TravelEndpoint, _ to: TravelEndpoint, mode: TravelMode = .car, anchor: TravelAnchor? = nil, fromUpdated: Date? = nil) -> TravelRequestKey {
        TravelRequestKey(
            fromEventID: "a", fromEventUpdatedAt: fromUpdated ?? date, from: from,
            toEventID: "b", toEventUpdatedAt: date, to: to,
            mode: mode, anchor: anchor ?? .departAt(date)
        )
    }

    private var linked: TravelEndpoint { .linkedPlace(placeID: "IFIXTUREA00000000", buildingID: "b1", buildingUpdatedAt: date) }
    private let picked = TravelEndpoint.candidate(PlaceResult(
        kind: .address, name: "", address: "架空県架空市架空町一丁目", latitude: 43.1, longitude: 141.1, identifier: nil,
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    ))

    private func settle(_ what: Comment, _ condition: @escaping () -> Bool) async {
        for _ in 0..<400 where !condition() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition(), what)
    }

    // MARK: Where a point comes from

    @Test func aLinkedBuildingGivesItsPlaceID() {
        let b = building("b1", placeID: "IFIXTUREA00000000", updatedAt: date.addingTimeInterval(5))
        let endpoint = TravelEndpoint.resolve(event: event("a", buildingId: "b1"), buildings: [b])
        #expect(endpoint == .linkedPlace(placeID: "IFIXTUREA00000000", buildingID: "b1", buildingUpdatedAt: date.addingTimeInterval(5)))
        #expect(endpoint.isUsable)
    }

    /// Without a Place ID there is no point, whatever else is stored: legacy coordinates
    /// of unknown provenance are not used (D-022), and nothing is substituted. The hint
    /// is only the suggested query.
    @Test func withoutAPlaceIDTheUserPicksACandidate() {
        let legacy = building("b1", latitude: 43.0, longitude: 141.0)
        #expect(TravelEndpoint.resolve(event: event("a", buildingId: "b1"), buildings: [legacy]) == .unresolved(hint: "Fixture building b1"))
        #expect(TravelEndpoint.resolve(event: event("a", buildingId: "b1", location: "Fixture hall"), buildings: [legacy]) == .unresolved(hint: "Fixture hall"))
        #expect(TravelEndpoint.resolve(event: event("a", buildingId: "missing"), buildings: [legacy]) == .unresolved(hint: ""))
        #expect(TravelEndpoint.resolve(event: event("a", location: "Fixture station"), buildings: []) == .unresolved(hint: "Fixture station"))
        #expect(TravelEndpoint.resolve(event: event("a"), buildings: []) == .unresolved(hint: ""))
        #expect(!TravelEndpoint.unresolved(hint: "x").isUsable)
        #expect(picked.isUsable, "a picked candidate needs no Place ID to route to")
    }

    // MARK: What makes a result stale

    @Test func everyInputIsPartOfTheKey() {
        let base = key(linked, picked)
        #expect(base == key(linked, picked))
        #expect(base != key(linked, picked, mode: .walk), "mode")
        #expect(base != key(linked, picked, mode: .transit), "transit")
        #expect(base != key(linked, picked, anchor: .arriveBy(date)), "anchor kind")
        #expect(base != key(linked, picked, anchor: .departAt(date.addingTimeInterval(60))), "anchor time")
        #expect(base != key(linked, picked, fromUpdated: date.addingTimeInterval(1)), "the Event changed")
        #expect(base != key(.linkedPlace(placeID: "IFIXTUREA00000000", buildingID: "b1", buildingUpdatedAt: date.addingTimeInterval(1)), picked), "the Building changed")
        #expect(base != key(.linkedPlace(placeID: "IOTHER00000000000", buildingID: "b1", buildingUpdatedAt: date), picked), "the Place ID changed")
        let repicked = TravelEndpoint.candidate(PlaceResult(kind: .address, name: "", address: "架空県架空市架空町二丁目", latitude: 43.2, longitude: 141.2, identifier: nil))
        #expect(base != key(linked, repicked), "the point was re-picked")
    }

    @Test func aResultBelongsToTheKeyItWasAskedFor() async {
        let router = FakeRouter()
        let search = TravelSearch(router: router)
        let asked = key(linked, picked)
        search.search(asked, from: pointA, to: pointB)
        await settle("result") { if case .result = search.state { return true } else { return false } }
        #expect(search.isCurrent(asked))
        #expect(!search.isCurrent(key(linked, picked, mode: .walk)), "a changed input makes the shown result stale")
        #expect(router.calls == [FakeRouter.Call(from: pointA, to: pointB, mode: .car, anchor: .departAt(date))])
    }

    @Test func aLateReplyAfterCancelIsDropped() async {
        let router = FakeRouter()
        router.hang = true
        let search = TravelSearch(router: router)
        search.search(key(linked, picked), from: pointA, to: pointB)
        await settle("in flight") { router.calls.count == 1 && search.isSearching }
        search.cancel()
        #expect(search.state == .idle)
        router.release()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(search.state == .idle)
    }

    @Test func aLateReplyAfterANewSearchIsDropped() async {
        let router = FakeRouter()
        router.hang = true
        router.outcomes = [.success(Self.result(mode: .car)), .success(Self.result(mode: .walk))]
        let search = TravelSearch(router: router)
        let first = key(linked, picked)
        let second = key(linked, picked, mode: .walk)
        search.search(first, from: pointA, to: pointB)
        await settle("first in flight") { router.calls.count == 1 }
        search.search(second, from: pointA, to: pointB)
        await settle("second in flight") { router.calls.count == 2 }
        router.release()
        await settle("second result") { search.state == .result(Self.result(mode: .walk), second) }
        #expect(search.isCurrent(second) && !search.isCurrent(first))
    }

    @Test func theSameRequestInFlightIsNotSentAgain() async {
        let router = FakeRouter()
        router.hang = true
        let search = TravelSearch(router: router)
        let asked = key(linked, picked)
        search.search(asked, from: pointA, to: pointB)
        await settle("in flight") { router.calls.count == 1 }
        search.search(asked, from: pointA, to: pointB)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(router.calls.count == 1)
        router.release()
        await settle("result") { search.isCurrent(asked) && !search.isSearching }
    }

    @Test func failuresAreClassifiedAndRetryIsPossible() async {
        let router = FakeRouter()
        router.outcomes = [.failure(MKError(.directionsNotFound)), .failure(URLError(.notConnectedToInternet)), .success(Self.result(mode: .car))]
        let search = TravelSearch(router: router)
        let asked = key(linked, picked)
        search.search(asked, from: pointA, to: pointB)
        await settle("not found") { search.state == .failed(.notFound, asked) }
        search.search(asked, from: pointA, to: pointB)
        await settle("offline") { search.state == .failed(.offline, asked) }
        search.search(asked, from: pointA, to: pointB)
        await settle("result") { search.state == .result(Self.result(mode: .car), asked) }
    }

    @Test func aSearchThatNeverAnswersTimesOut() async {
        let router = FakeRouter()
        router.hang = true
        let search = TravelSearch(router: router, timeout: .milliseconds(30))
        let asked = key(linked, picked)
        search.search(asked, from: pointA, to: pointB)
        await settle("timed out") { search.state == .failed(.timeout, asked) }
        router.release()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(search.state == .failed(.timeout, asked), "the reply that arrives after the timeout is dropped")
    }

    /// The deadline does not depend on the router honouring cancellation: a router that
    /// never returns still leaves "timed out" at the deadline, and its late success or
    /// failure, whenever it comes, does not overwrite that.
    @Test func theDeadlineHoldsEvenWhenTheRouterIgnoresCancellation() async {
        for late in [Result<TravelResult, Error>.success(Self.result(mode: .car)), .failure(MKError(.serverFailure))] {
            let router = FakeRouter()
            router.hang = true
            router.ignoresCancellation = true
            router.outcomes = [late]
            let search = TravelSearch(router: router, timeout: .milliseconds(30))
            let asked = key(linked, picked)
            search.search(asked, from: pointA, to: pointB)
            await settle("timed out without any reply") { search.state == .failed(.timeout, asked) }
            #expect(!search.isSearching)
            router.release()
            try? await Task.sleep(for: .milliseconds(30))
            await Task.yield()
            #expect(search.state == .failed(.timeout, asked), "a late \(late) never replaces the timeout")

            // A new search after the timeout works as usual.
            router.hang = false
            router.outcomes = [.success(Self.result(mode: .walk))]
            let next = key(linked, picked, mode: .walk)
            search.search(next, from: pointA, to: pointB)
            await settle("next result") { search.state == .result(Self.result(mode: .walk), next) }
        }
    }

    // MARK: Transit is not an Event

    /// A transit answer is an estimate for display and an Apple Maps hand-off; the mode
    /// is its own type and no `EventType` (such as `train`) is derived from it.
    @Test func transitIsAnEstimateNotATrainEvent() async {
        #expect(EventType(rawValue: TravelMode.transit.rawValue) == nil)
        #expect(TravelMode.allCases.map(\.rawValue) == ["car", "walk", "transit"])
        #expect(MapKitTravelRouter.transportType(for: .transit) == .transit)
        #expect(MapKitTravelRouter.launchDirectionsMode(for: .transit) == MKLaunchOptionsDirectionsModeTransit)
        let router = FakeRouter()
        let search = TravelSearch(router: router)
        let asked = key(linked, picked, mode: .transit)
        search.search(asked, from: pointA, to: pointB)
        await settle("eta") { search.state == .result(Self.result(mode: .transit), asked) }
        if case .result(let result, _) = search.state, case .eta = result.kind {
            #expect(result.mode == .transit)
        } else {
            Issue.record("a transit answer is an ETA, not a route")
        }
    }

    @Test func routeTimesFollowTheAnchor() {
        let depart = MapKitTravelRouter.times(for: .departAt(date), travelTime: 600)
        #expect(depart.departure == date && depart.arrival == date.addingTimeInterval(600))
        let arrive = MapKitTravelRouter.times(for: .arriveBy(date), travelTime: 600)
        #expect(arrive.arrival == date && arrive.departure == date.addingTimeInterval(-600))
    }
}
