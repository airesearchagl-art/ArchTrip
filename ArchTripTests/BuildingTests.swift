import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

struct BuildingTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeBuilding() -> Building {
        Building(
            id: "b1",
            name: "札幌市民交流プラザ",
            architect: "Example Architects",
            completedYear: 2018,
            address: "札幌市中央区北1条西1丁目",
            latitude: 43.0617,
            longitude: 141.3561,
            visitMinutes: 90,
            priority: 3,
            visited: false,
            note: "Theatre foyer",
            createdAt: date
        )
    }

    private static let requiredKeys: Set<String> = [
        "id", "name", "architect", "address", "visitMinutes", "priority", "visited", "note", "createdAt", "updatedAt",
    ]

    @Test func validBuilding() {
        #expect(makeBuilding().isValid)
        let minimal = Building(id: "b2", name: "Minimal", createdAt: date)
        #expect(minimal.isValid)
        #expect(minimal.visitMinutes == 60)
        #expect(minimal.priority == 2)
        #expect(!minimal.visited)
        #expect(minimal.updatedAt == minimal.createdAt)
    }

    @Test func emptyNameIsInvalid() {
        var building = makeBuilding()
        building.name = ""
        #expect(!building.isValid)
    }

    @Test func excessiveFieldLengthsAreInvalid() {
        var name = makeBuilding(); name.name = String(repeating: "a", count: 201)
        var architect = makeBuilding(); architect.architect = String(repeating: "a", count: 201)
        var address = makeBuilding(); address.address = String(repeating: "a", count: 301)
        var note = makeBuilding(); note.note = String(repeating: "a", count: 2001)
        for building in [name, architect, address, note] {
            #expect(!building.isValid)
        }
        var atLimit = makeBuilding(); atLimit.address = String(repeating: "a", count: 300)
        #expect(atLimit.isValid)
    }

    @Test(arguments: [0, 4, 481, -10])
    func invalidVisitMinutes(_ minutes: Int) {
        var building = makeBuilding()
        building.visitMinutes = minutes
        #expect(!building.isValid)
    }

    @Test(arguments: [0, 4, -1])
    func invalidPriority(_ priority: Int) {
        var building = makeBuilding()
        building.priority = priority
        #expect(!building.isValid)
    }

    @Test func completedYearIsOptionalButRanged() {
        var building = makeBuilding()
        building.completedYear = nil
        #expect(building.isValid)
        building.completedYear = 0
        #expect(!building.isValid)
        building.completedYear = 2101
        #expect(!building.isValid)
        building.completedYear = 607
        #expect(building.isValid)
    }

    @Test func coordinatesBothNilIsValid() {
        var building = makeBuilding()
        building.latitude = nil
        building.longitude = nil
        #expect(building.isValid)
        #expect(!building.hasCoordinate)
    }

    @Test func onlyOneCoordinateIsInvalid() {
        var latitudeOnly = makeBuilding(); latitudeOnly.longitude = nil
        var longitudeOnly = makeBuilding(); longitudeOnly.latitude = nil
        #expect(latitudeOnly.invalidReason == "latitude and longitude must be set together")
        #expect(longitudeOnly.invalidReason == "latitude and longitude must be set together")
    }

    @Test func coordinateRanges() {
        var building = makeBuilding()
        building.latitude = 90.0001
        #expect(!building.isValid)
        building.latitude = -90
        building.longitude = 180
        #expect(building.isValid)
        building.longitude = -180.5
        #expect(!building.isValid)
    }

    @Test func updatedBeforeCreatedIsInvalid() {
        var building = makeBuilding()
        building.updatedAt = building.createdAt.addingTimeInterval(-1)
        #expect(!building.isValid)
    }

    @Test func firestoreRoundTrip() throws {
        let building = makeBuilding()
        let fields = try Firestore.Encoder().encode(building)
        #expect(try Firestore.Decoder().decode(Building.self, from: fields) == building)
    }

    /// The Security Rules rely on this shape: nil Optionals are omitted, not written as null.
    @Test func nilOptionalsAreOmittedFromFirestoreFields() throws {
        let building = Building(id: "b3", name: "No location", createdAt: date)
        let fields = try Firestore.Encoder().encode(building)
        #expect(Set(fields.keys) == Self.requiredKeys)
        #expect(fields["completedYear"] == nil)
        #expect(fields["latitude"] == nil)
        #expect(fields["longitude"] == nil)
    }

    @Test func presentOptionalsAndFieldTypes() throws {
        let fields = try Firestore.Encoder().encode(makeBuilding())
        #expect(Set(fields.keys) == Self.requiredKeys.union(["completedYear", "latitude", "longitude"]))
        // Integers must arrive as Firestore integers (rules use `is int`).
        for key in ["completedYear", "visitMinutes", "priority"] {
            let number = try #require(fields[key] as? NSNumber, "\(key)")
            #expect(CFNumberIsFloatType(number) == false, "\(key) should be an integer")
        }
        for key in ["latitude", "longitude"] {
            #expect(fields[key] is NSNumber, "\(key)")
        }
        #expect(fields["visited"] as? Bool == false)
        for key in ["createdAt", "updatedAt"] {
            #expect(fields[key] is Timestamp, "\(key)")
        }
    }

    @Test func decodingWithoutOptionalFields() throws {
        var fields = try Firestore.Encoder().encode(makeBuilding())
        fields.removeValue(forKey: "completedYear")
        fields.removeValue(forKey: "latitude")
        fields.removeValue(forKey: "longitude")
        let building = try Firestore.Decoder().decode(Building.self, from: fields)
        #expect(building.completedYear == nil)
        #expect(!building.hasCoordinate)
    }

    @Test func paths() {
        #expect(BuildingPath.collection(uid: "u1") == "users/u1/buildings")
        #expect(BuildingPath.document(uid: "u1", buildingID: "b1") == "users/u1/buildings/b1")
    }

    // MARK: Apple Maps Place ID (v0.2)

    /// Apple's sample Place ID (WWDC24), 17 characters.
    private static let samplePlaceID = "I63802885C8189B2B"

    @Test func applePlaceIdIsOmittedWhenNilAndKeptVerbatim() throws {
        let unlinked = try Firestore.Encoder().encode(makeBuilding())
        #expect(unlinked["applePlaceId"] == nil)
        #expect(!makeBuilding().hasPlace)

        var linked = makeBuilding()
        linked.applePlaceId = Self.samplePlaceID
        let fields = try Firestore.Encoder().encode(linked)
        #expect(fields["applePlaceId"] as? String == Self.samplePlaceID)
        #expect(Set(fields.keys) == Self.requiredKeys.union(["completedYear", "latitude", "longitude", "applePlaceId"]))
        #expect(try Firestore.Decoder().decode(Building.self, from: fields) == linked)
        #expect(linked.hasPlace && linked.isValid && linked.isWritable)

        // Stored exactly as MapKit gave it: no trimming, re-casing or other normalization.
        let unusual = " i63802885c8189b2b/x "
        var raw = linked
        raw.applePlaceId = unusual
        let rawFields = try Firestore.Encoder().encode(raw)
        #expect(rawFields["applePlaceId"] as? String == unusual)
        #expect(try Firestore.Decoder().decode(Building.self, from: rawFields).applePlaceId == unusual)
    }

    /// The length bound is this project's, enforced when writing only: a longer stored ID
    /// still decodes and lists, and only saving is refused. An empty ID is corrupt.
    @Test func applePlaceIdLengthIsAWriteTimeBoundOnly() throws {
        #expect(Building.applePlaceIdMaxLength == 128)
        var building = makeBuilding()
        building.applePlaceId = String(repeating: "A", count: Building.applePlaceIdMaxLength)
        #expect(building.isValid && building.isWritable && !building.applePlaceIdExceedsLimit)

        building.applePlaceId = String(repeating: "A", count: Building.applePlaceIdMaxLength + 1)
        #expect(building.isValid, "a longer stored ID is still read and listed")
        #expect(!building.isWritable && building.applePlaceIdExceedsLimit, "but this version refuses to write it")

        building.applePlaceId = String(repeating: "A", count: 300)
        let fields = try Firestore.Encoder().encode(building)
        let decoded = try Firestore.Decoder().decode(Building.self, from: fields)
        #expect(decoded.isValid && decoded.applePlaceId?.count == 300)
        #expect(DocumentDecoding.decode([(id: decoded.id, data: fields)], as: Building.self, validate: \.invalidReason).failures.isEmpty)

        building.applePlaceId = ""
        #expect(building.invalidReason == "empty applePlaceId")
        building.applePlaceId = nil
        #expect(building.isValid && building.isWritable && !building.hasPlace)
    }

    /// A place may sit beside legacy coordinates (a relinked old Building): both are valid
    /// document shapes. Which one is displayed is decided by `BuildingLocation`, not here.
    @Test func placeMayCoexistWithLegacyCoordinates() {
        var relinked = makeBuilding()
        relinked.applePlaceId = Self.samplePlaceID
        #expect(relinked.isValid && relinked.hasPlace && relinked.hasCoordinate)

        let idOnly = Building(id: "b4", name: "ID only", createdAt: date, applePlaceId: Self.samplePlaceID)
        #expect(idOnly.isValid && idOnly.hasPlace && !idOnly.hasCoordinate)

        var halfPair = idOnly
        halfPair.latitude = 43
        #expect(halfPair.invalidReason == "latitude and longitude must be set together")
    }

    /// Rollback compatibility: a document carrying `applePlaceId` decodes under the pre-v0.2
    /// model shape, which has no such key, because Firestore.Decoder ignores unknown keys.
    /// This documents the decoder; the previous build itself is checked in acceptance.
    @Test func documentsWithAPlaceIdDecodeUnderThePreviousModelShape() throws {
        var linked = makeBuilding()
        linked.applePlaceId = Self.samplePlaceID
        let fields = try Firestore.Encoder().encode(linked)
        let legacy = try Firestore.Decoder().decode(PreviousBuildingShape.self, from: fields)
        #expect(legacy.id == linked.id && legacy.name == linked.name)
        #expect(legacy.latitude == linked.latitude && legacy.longitude == linked.longitude)
        // Re-encoding that shape sends no applePlaceId, so an old update leaves the key alone.
        #expect(try Firestore.Encoder().encode(legacy)["applePlaceId"] == nil)
    }

    /// The Building's document keys before v0.2, as the previous build decodes them.
    private struct PreviousBuildingShape: Codable {
        var id: String
        var name: String
        var architect: String
        var completedYear: Int?
        var address: String
        var latitude: Double?
        var longitude: Double?
        var visitMinutes: Int
        var priority: Int
        var visited: Bool
        var note: String
        var createdAt: Date
        var updatedAt: Date
    }

    @Test func ordering() {
        let visited = Building(id: "v", name: "A visited", priority: 3, visited: true, createdAt: date)
        let high = Building(id: "h", name: "Z high", priority: 3, createdAt: date)
        let normalB = Building(id: "nb", name: "B normal", createdAt: date)
        let normalA = Building(id: "na", name: "A normal", createdAt: date)
        let low = Building(id: "l", name: "A low", priority: 1, createdAt: date)
        #expect(BuildingOrdering.sorted([visited, low, normalB, high, normalA]).map(\.id) == ["h", "na", "nb", "l", "v"])
    }
}
