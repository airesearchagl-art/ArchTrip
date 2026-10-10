import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

struct BuildingSchedulingTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Sapporo") ?? TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private let building = Building(
        id: "b-kitara",
        name: "札幌コンサートホール Kitara",
        address: "札幌市中央区中島公園1-15",
        latitude: 43.0479,
        longitude: 141.3556,
        visitMinutes: 90,
        note: "Do not copy me"
    )

    @Test func startCombinesDayAndTime() {
        let start = BuildingScheduling.startDate(day: at(16, 0), time: at(3, 14, 30), calendar: calendar)
        #expect(start == at(16, 14, 30))
    }

    @Test func makesArchitectureEventSnapshot() {
        let now = at(1, 8)
        let event = BuildingScheduling.makeEvent(visiting: building, tripID: "trip-1", start: at(16, 14), durationMinutes: building.visitMinutes, now: now)
        #expect(event.type == .architecture)
        #expect(event.buildingId == "b-kitara")
        #expect(event.tripId == "trip-1")
        #expect(event.title == building.name)
        #expect(event.locationName.isEmpty)
        #expect(event.startDate == at(16, 14))
        #expect(event.endDate == at(16, 15, 30))
        #expect(event.note.isEmpty)
        #expect(event.createdAt == now && event.updatedAt == now)
        #expect(event.isValid)
    }

    @Test func customDurationIsApplied() {
        let event = BuildingScheduling.makeEvent(visiting: building, tripID: "t", start: at(16, 9), durationMinutes: 30)
        #expect(event.endDate == at(16, 9, 30))
    }

    /// Option A: the Building's address and coordinates never enter a new Event; the
    /// Event is linked by id and titled with the name only.
    @Test func addressIsNotCopiedIntoTheEvent() {
        let event = BuildingScheduling.makeEvent(visiting: building, tripID: "t", start: at(16, 9), durationMinutes: 60)
        #expect(event.locationName.isEmpty)
        #expect(event.note.isEmpty)
        #expect(event.buildingId == building.id)
        #expect(event.isValid)
    }

    @Test func pickingABuildingSetsTheTitleUnlessCustom() {
        let other = Building(id: "b-other", name: "モエレ沼公園 ガラスのピラミッド")
        #expect(BuildingScheduling.title(current: "", previous: nil, selected: building) == building.name)
        #expect(BuildingScheduling.title(current: "  ", previous: nil, selected: building) == building.name)
        // Re-picking replaces the previous Building's name...
        #expect(BuildingScheduling.title(current: building.name, previous: building, selected: other) == other.name)
        // ...but never a title the user typed.
        #expect(BuildingScheduling.title(current: "Kitara backstage tour", previous: building, selected: other) == "Kitara backstage tour")
    }

    @Test func linkResolution() {
        let linked = BuildingScheduling.makeEvent(visiting: building, tripID: "t", start: at(16, 9), durationMinutes: 60)
        #expect(BuildingLink.resolve(linked, in: [building]) == .available(building))
        // Building deleted: the Event stays intact and the link reports unavailable.
        #expect(BuildingLink.resolve(linked, in: []) == .unavailable(buildingID: "b-kitara"))
        #expect(linked.isValid)
        let plain = Event(tripId: "t", type: .food, title: "Lunch", startDate: at(16, 12), endDate: at(16, 13))
        #expect(BuildingLink.resolve(plain, in: [building]) == .none)
        // The editor resolves its picked id the same way.
        #expect(BuildingLink.resolve(buildingID: nil, in: [building]) == .none)
        #expect(BuildingLink.resolve(buildingID: "b-kitara", in: [building]) == .available(building))
        #expect(BuildingLink.resolve(buildingID: "b-kitara", in: []) == .unavailable(buildingID: "b-kitara"))
    }
}
