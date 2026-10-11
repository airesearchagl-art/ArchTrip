import Foundation

/// A derived point on the timed timeline for an all-day Event's optional clock times: a
/// hotel stay's check-in on its first day and check-out on its check-out day, the day
/// after the last night (G6-UX-05); a rental car's pickup on its first day and return on
/// its last day, which is a day of the rental (G6-UX-07). Each sits at the minutes stored
/// on the Event. Markers are never stored and never documents of their own: one exists
/// exactly while the Event carries that time, and tapping it opens the Event's editor.
nonisolated struct EventMarker: Identifiable, Equatable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case checkIn
        case checkOut
        case pickup
        case `return`

        /// Whether the marker ends its Event's use (check-out, return) rather than begins it.
        var isEnd: Bool { self == .checkOut || self == .return }
    }

    let kind: Kind
    /// The all-day Event the marker is derived from.
    let event: Event
    let time: Date

    /// Stable per Event and kind, so rows keep their identity across refreshes.
    var id: String { "marker-\(event.id)-\(kind.rawValue)" }

    /// The markers of `event`, in time order: none unless it is an all-day hotel stay or
    /// rental car with a clock time set.
    static func markers(for event: Event, calendar: Calendar) -> [EventMarker] {
        guard !event.isTimed else { return [] }
        let firstDay = AllDaySchedule.firstDay(of: event, calendar: calendar)
        let clockTimes: [(kind: Kind, minutes: Int?, day: Date)]
        switch event.type {
        case .hotel:
            clockTimes = [
                (.checkIn, event.checkInMinutes, firstDay),
                (.checkOut, event.checkOutMinutes, AllDaySchedule.endExclusive(of: event, calendar: calendar)),
            ]
        case .car:
            clockTimes = [
                (.pickup, event.pickupMinutes, firstDay),
                (.return, event.returnMinutes, AllDaySchedule.lastDay(of: event, calendar: calendar)),
            ]
        default:
            return []
        }
        return clockTimes
            .compactMap { entry -> EventMarker? in
                guard let minutes = entry.minutes,
                      let time = AllDaySchedule.clock(minutes: minutes, on: entry.day, calendar: calendar)
                else { return nil }
                return EventMarker(kind: entry.kind, event: event, time: time)
            }
            .sorted(by: before)
    }

    /// Markers of every Event in `events` that fall on `day`, in time order; at the same
    /// instant an end (check-out, return) precedes a start (check-in, pickup).
    static func markers(on day: Date, from events: [Event], calendar: Calendar) -> [EventMarker] {
        events
            .flatMap { markers(for: $0, calendar: calendar) }
            .filter { calendar.isDate($0.time, inSameDayAs: day) }
            .sorted(by: before)
    }

    /// Deterministic: time, then ends before starts, then the Event's id (one Event has at
    /// most one end and one start, so nothing is left to compare).
    private static func before(_ lhs: EventMarker, _ rhs: EventMarker) -> Bool {
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        if lhs.kind.isEnd != rhs.kind.isEnd { return lhs.kind.isEnd }
        return lhs.event.id < rhs.event.id
    }
}
