import Foundation
import Testing
@testable import ArchTrip

/// Linking rules and the no-fallback display rule (v0.2).
struct PlaceLinkTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let sampleID = "I63802885C8189B2B"

    @Test func candidatesWithoutAUsableIdentifierCannotBeLinked() {
        #expect(PlaceLink.issue(forIdentifier: nil) == .noIdentifier)
        #expect(PlaceLink.issue(forIdentifier: "") == .noIdentifier)
        #expect(PlaceLink.issue(forIdentifier: sampleID) == nil)
        #expect(PlaceLink.issue(forIdentifier: String(repeating: "A", count: Building.applePlaceIdMaxLength)) == nil)
        #expect(PlaceLink.issue(forIdentifier: String(repeating: "A", count: Building.applePlaceIdMaxLength + 1)) == .identifierTooLong)
        // Not normalized: whitespace counts and is kept.
        #expect(PlaceLink.issue(forIdentifier: " ") == nil)
    }

    @Test func duplicatesAreFoundByTheIdOrAnyAlternate() {
        let linked = Building(id: "b1", name: "Linked", createdAt: date, applePlaceId: sampleID)
        let viaAlternate = Building(id: "b2", name: "Alternate", createdAt: date, applePlaceId: "IOLD0000000000001")
        let other = Building(id: "b3", name: "Other", createdAt: date, applePlaceId: "IOTHER00000000001")
        let unlinked = Building(id: "b4", name: "Unlinked", latitude: 43, longitude: 141, createdAt: date)
        let buildings = [other, unlinked, viaAlternate, linked]

        let candidate: Set<String> = [sampleID, "IOLD0000000000001"]
        #expect(PlaceLink.duplicates(of: candidate, in: buildings).map(\.id) == ["b2", "b1"])
        #expect(PlaceLink.duplicates(of: candidate, in: buildings, excluding: "b1").map(\.id) == ["b2"], "editing b1 itself is not a duplicate")
        #expect(PlaceLink.duplicates(of: ["INEW0000000000001"], in: buildings).isEmpty)
        #expect(PlaceLink.duplicates(of: [], in: buildings).isEmpty)
    }

    /// A linked Building never falls back to stored coordinates: without a fetched place it
    /// has no location, even when legacy coordinates sit beside the link. An unlinked
    /// Building keeps showing its stored coordinates as before.
    @Test func linkedBuildingsUseOnlyTheFetchedPlace() {
        let place = ResolvedPlace(identifier: sampleID, name: "Fixture", address: nil, latitude: 43.05, longitude: 141.35)
        let unlinkedNoCoordinates = Building(id: "a", name: "A", createdAt: date)
        let unlinkedStored = Building(id: "b", name: "B", latitude: 43.0, longitude: 141.3, createdAt: date)
        let linkedIdOnly = Building(id: "c", name: "C", createdAt: date, applePlaceId: sampleID)
        let linkedWithLegacy = Building(id: "d", name: "D", latitude: 43.0, longitude: 141.3, createdAt: date, applePlaceId: sampleID)

        #expect(BuildingLocation.resolve(unlinkedNoCoordinates, place: nil) == .none)
        #expect(BuildingLocation.resolve(unlinkedStored, place: nil) == .stored(latitude: 43.0, longitude: 141.3))
        #expect(BuildingLocation.resolve(unlinkedStored, place: place) == .stored(latitude: 43.0, longitude: 141.3), "an unlinked Building ignores any place")

        #expect(BuildingLocation.resolve(linkedIdOnly, place: nil) == .none)
        #expect(BuildingLocation.resolve(linkedIdOnly, place: place) == .place(latitude: 43.05, longitude: 141.35))
        #expect(BuildingLocation.resolve(linkedWithLegacy, place: nil) == .none, "no fallback to the stored coordinates")
        #expect(BuildingLocation.resolve(linkedWithLegacy, place: place) == .place(latitude: 43.05, longitude: 141.35))

        // Unlinking a Building that kept legacy coordinates shows them again.
        var unlinkedAgain = linkedWithLegacy
        unlinkedAgain.applePlaceId = nil
        #expect(BuildingLocation.resolve(unlinkedAgain, place: nil) == .stored(latitude: 43.0, longitude: 141.3))
        #expect(BuildingLocation.resolve(linkedWithLegacy, place: place).coordinates?.latitude == 43.05)
        #expect(BuildingLocation.none.coordinates == nil)
    }
}
