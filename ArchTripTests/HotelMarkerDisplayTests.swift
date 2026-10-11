import Foundation
import Testing
@testable import ArchTrip

/// G6-UX-05-RF-Display-01: a derived marker row shows its source stay's location and a
/// note preview, read from the canonical hotel Event; nothing is copied or stored.
/// Fixture text only: no real hotel, address or reservation details.
struct HotelMarkerDisplayTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func at(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day))!
    }

    /// A two-night stay with both clock times, so it has a check-in and a check-out marker.
    private func stay(location: String = "Fixture address 1-2-3", note: String = "Fixture note") -> Event {
        let dates = AllDaySchedule.dates(checkIn: at(15), checkOut: at(17), calendar: calendar)
        return Event(
            id: "stay", tripId: "trip", type: .hotel, title: "Fixture Hotel", startDate: dates.start, endDate: dates.end,
            locationName: location, note: note, createdAt: at(1), isAllDay: true, checkInMinutes: 17 * 60, checkOutMinutes: 9 * 60
        )
    }

    private func markers(_ event: Event) -> [HotelMarker] {
        HotelMarker.markers(for: event, calendar: calendar)
    }

    @Test func bothMarkersShowTheStaysLocationAndNotePreview() {
        let event = stay()
        let result = markers(event)
        #expect(result.map(\.kind) == [.checkIn, .checkOut])
        for marker in result {
            #expect(marker.locationName == "Fixture address 1-2-3")
            #expect(marker.notePreview == "Fixture note")
            #expect(marker.event == event, "both markers come from, and open, the one canonical stay")
        }
    }

    @Test func blankLocationAndNoteAreOmitted() {
        for blank in ["", " ", "\n", " \n\t "] {
            for marker in markers(stay(location: blank, note: blank)) {
                #expect(marker.locationName == nil, "blank location \(blank.debugDescription)")
                #expect(marker.notePreview == nil, "blank note \(blank.debugDescription)")
            }
        }
        #expect(markers(stay(location: " 北区 ", note: "")).first?.locationName == "北区")
    }

    /// The address is never shortened by the model; the row wraps it.
    @Test func longJapaneseLocationIsKeptWhole() {
        let address = String(repeating: "架空県架空市架空区架空町一丁目二番三号", count: 10)
        #expect(address.count <= Event.locationNameMaxLength)
        for marker in markers(stay(location: address)) {
            #expect(marker.locationName == address)
        }
    }

    @Test func notePreviewKeepsTheFirstTwoNonBlankLines() {
        #expect(HotelMarker.notePreview(of: "一行目") == "一行目")
        #expect(HotelMarker.notePreview(of: "一行目\n二行目") == "一行目\n二行目")
        #expect(HotelMarker.notePreview(of: "一行目\n\n二行目\n三行目") == "一行目\n二行目…")
        #expect(HotelMarker.notePreview(of: "  a  \r\n  b  \u{2028}c") == "a\nb…")
        #expect(HotelMarker.notePreview(of: "\n\n") == nil)
    }

    /// The cap counts characters, not bytes, and never splits a Japanese character or an
    /// emoji cluster.
    @Test func notePreviewCapsLongTextOnCharacterBoundaries() throws {
        let max = HotelMarker.notePreviewMaxCharacters
        let exact = String(repeating: "あ", count: max)
        #expect(HotelMarker.notePreview(of: exact) == exact)
        let over = exact + "い"
        #expect(HotelMarker.notePreview(of: over) == exact + "…")
        let family = "👨‍👩‍👧"
        let clustered = String(repeating: "か", count: max - 1) + family + "x"
        let preview = try #require(HotelMarker.notePreview(of: clustered))
        #expect(preview.hasSuffix(family + "…"))
        #expect(preview.count == max + 1)
        // A cut right after a space does not leave the space before the ellipsis.
        let spaced = String(repeating: "b", count: max - 1) + " c d"
        #expect(HotelMarker.notePreview(of: spaced) == String(repeating: "b", count: max - 1) + "…")
        #expect(HotelMarker.notePreview(of: String(repeating: "x", count: Event.noteMaxLength))?.count == max + 1)
    }

    /// Editing the stay changes what both markers show; clearing a field removes its line.
    @Test func editingTheSourceStayUpdatesBothMarkers() {
        var event = stay()
        let before = markers(event)
        event.locationName = "Fixture address 4-5-6"
        event.note = "Changed"
        event.updatedAt = at(2)
        let after = markers(event)
        #expect(after.map(\.id) == before.map(\.id), "identity is stable across edits")
        #expect(after.map(\.locationName) == ["Fixture address 4-5-6", "Fixture address 4-5-6"])
        #expect(after.map(\.notePreview) == ["Changed", "Changed"])

        event.locationName = ""
        event.note = ""
        #expect(markers(event).allSatisfy { $0.locationName == nil && $0.notePreview == nil })
    }

    /// Markers stay derived: the type is not encodable, so nothing could write one.
    @Test func markersAreNeverEncodedOrStored() {
        let type: Any.Type = HotelMarker.self
        #expect(!(type is any Encodable.Type))
        #expect(!(type is any Decodable.Type))
        #expect(!(type is any FirestoreDocument.Type))
    }

    /// A legacy timed hotel Event with the same text has no marker and is not touched.
    @Test func timedHotelEventsAreUnchanged() {
        let legacy = Event(
            id: "old", tripId: "trip", type: .hotel, title: "Check-in", startDate: at(15).addingTimeInterval(15 * 3_600),
            endDate: at(15).addingTimeInterval(15 * 3_600 + 1_800), locationName: "Fixture address", note: "Fixture note", createdAt: at(1)
        )
        #expect(markers(legacy).isEmpty)
        #expect(legacy.isValid)
    }
}
