import Foundation

/// A derived point on the timed timeline for a hotel stay's optional clock times
/// (G6-UX-05): check-in on the stay's first day and check-out on its check-out day (the
/// day after the last night), each at the minutes stored on the stay. Markers are never
/// stored and never documents of their own: one exists exactly while the stay carries
/// that time, and tapping it opens the stay's editor.
nonisolated struct HotelMarker: Identifiable, Equatable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case checkIn
        case checkOut
    }

    let kind: Kind
    /// The stay the marker is derived from.
    let event: Event
    let time: Date

    /// Stable per stay and kind, so rows keep their identity across refreshes.
    var id: String { "marker-\(event.id)-\(kind.rawValue)" }

    /// The markers of `event`, in time order: none unless it is an all-day hotel stay
    /// with a clock time set.
    static func markers(for event: Event, calendar: Calendar) -> [HotelMarker] {
        guard event.type == .hotel, !event.isTimed else { return [] }
        var markers: [HotelMarker] = []
        if let minutes = event.checkInMinutes,
           let time = AllDaySchedule.clock(
               minutes: minutes, on: AllDaySchedule.firstDay(of: event, calendar: calendar), calendar: calendar
           ) {
            markers.append(HotelMarker(kind: .checkIn, event: event, time: time))
        }
        if let minutes = event.checkOutMinutes,
           let time = AllDaySchedule.clock(
               minutes: minutes, on: AllDaySchedule.endExclusive(of: event, calendar: calendar), calendar: calendar
           ) {
            markers.append(HotelMarker(kind: .checkOut, event: event, time: time))
        }
        return markers.sorted(by: before)
    }

    /// Markers of every stay in `events` that fall on `day`, in time order; at the same
    /// instant a check-out precedes a check-in.
    static func markers(on day: Date, from events: [Event], calendar: Calendar) -> [HotelMarker] {
        events
            .flatMap { markers(for: $0, calendar: calendar) }
            .filter { calendar.isDate($0.time, inSameDayAs: day) }
            .sorted(by: before)
    }

    private static func before(_ lhs: HotelMarker, _ rhs: HotelMarker) -> Bool {
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        if lhs.kind != rhs.kind { return lhs.kind == .checkOut }
        return lhs.event.id < rhs.event.id
    }
}
