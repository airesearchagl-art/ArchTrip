import MapKit
import Testing
@testable import ArchTrip

/// Real MapKit lookups, separate from every Firestore suite. Opt-in:
/// `TEST_RUNNER_ARCHTRIP_MAPKIT_LIVE=1 xcodebuild test ...` (needs a network).
/// Prints shapes only (lengths, counts), never a place's name or address.
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ARCHTRIP_MAPKIT_LIVE"] == "1"),
    .timeLimit(.minutes(1))
)
struct MapKitPlaceLiveTests {
    /// Apple's sample Place ID (WWDC24).
    private let sampleID = "I63802885C8189B2B"

    @Test func appleSamplePlaceIdResolves() async throws {
        let place = try await MapKitPlaceFetcher().fetch(sampleID)
        #expect(!place.identifier.isEmpty)
        #expect((-90...90).contains(place.latitude) && (-180...180).contains(place.longitude))
        #expect(place.mapItem != nil)
        #expect(PlaceLink.issue(forIdentifier: place.identifier) == nil)
        print("MAPKIT-EVIDENCE sample id resolved: identifier length \(place.identifier.count), alternates \(place.alternateIdentifiers.count), hasName \(place.name != nil), hasAddress \(place.address != nil)")
    }

    /// The point-of-interest search returns results with identifiers; the address search
    /// is reported only, since whether its results carry identifiers is not assumed.
    @Test func searchResultsCarryIdentifiers() async throws {
        let searcher = MapKitPlaceSearcher()
        let pois = try await searcher.search("Apple Park Visitor Center", kind: .pointOfInterest)
        #expect(!pois.isEmpty)
        #expect(pois.allSatisfy { $0.kind == .pointOfInterest })
        let withID = pois.filter { $0.identifier != nil }
        #expect(!withID.isEmpty)
        #expect(withID.allSatisfy { $0.linkIssue == nil })
        print("MAPKIT-EVIDENCE POI search: \(pois.count) results, \(withID.count) with identifiers, longest \(pois.compactMap { $0.identifier?.count }.max() ?? 0)")

        let addresses = try await searcher.search("1 Apple Park Way, Cupertino", kind: .address)
        #expect(addresses.allSatisfy { $0.kind == .address })
        print("MAPKIT-EVIDENCE address search: \(addresses.count) results, \(addresses.filter { $0.identifier != nil }.count) with identifiers")
    }

    @Test func unknownIdentifierFails() async {
        do {
            _ = try await MapKitPlaceFetcher().fetch("INOTAPLACE000000")
            Issue.record("expected a failure for an unknown identifier")
        } catch let failure as PlaceFetchFailure {
            print("MAPKIT-EVIDENCE unknown id -> \(failure)")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// A cancelled lookup ends with `CancellationError`, not a classified failure.
    @Test func cancellationIsReportedAsCancellation() async {
        let task = Task { try await MapKitPlaceFetcher().fetch(sampleID) }
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
            print("MAPKIT-EVIDENCE cancelled lookup -> CancellationError")
        } catch {
            // Already finished before the cancel: acceptable, but note it.
            print("MAPKIT-EVIDENCE cancelled lookup -> \(error)")
        }
    }
}
