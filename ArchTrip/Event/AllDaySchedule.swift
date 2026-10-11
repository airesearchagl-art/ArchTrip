import Foundation

/// Calendar-day arithmetic for all-day Events (G6-UX-02/03/04).
///
/// An all-day Event keeps the same `startDate`/`endDate` timestamps as a timed one, placed
/// at local midnight, and applies to every day in [startDate, endDate). A hotel stay checked
/// in on the 15th and out on the 17th is stored 15 00:00 – 17 00:00 and appears on the
/// nights of the 15th and 16th; a rental car picked up on the 15th and returned on the 17th
/// is stored 15 00:00 – 18 00:00 and appears on all three days.
///
/// Day boundaries always come from the caller's `Calendar`, never from 86 400-second
/// arithmetic, so month and year ends and daylight-saving days work. Days are read back
/// from the timestamps at noon rather than at the boundary itself, so a clock offset of
/// less than 12 hours (another time zone, a daylight-saving shift) still yields the days
/// that were entered.
nonisolated enum AllDaySchedule {
    /// How the editor shows the end of an all-day Event of a given type.
    enum EndConvention: Equatable, Sendable {
        /// Hotel: the check-out day is shown and is not a night of the stay.
        case checkOut
        /// Everything else: the last day is shown and included.
        case lastDay
    }

    static func endConvention(for type: EventType) -> EndConvention {
        type == .hotel ? .checkOut : .lastDay
    }

    private static let halfDay: TimeInterval = 12 * 60 * 60

    /// First day the all-day Event applies to.
    static func firstDay(of event: Event, calendar: Calendar) -> Date {
        calendar.startOfDay(for: event.startDate.addingTimeInterval(halfDay))
    }

    /// Last day the all-day Event applies to (inclusive). Never before the first day, so
    /// a degenerate range still shows on one day.
    static func lastDay(of event: Event, calendar: Calendar) -> Date {
        let first = firstDay(of: event, calendar: calendar)
        return max(first, calendar.startOfDay(for: event.endDate.addingTimeInterval(-halfDay)))
    }

    /// The day after the last day: the stored `endDate` of a well-formed all-day Event.
    static func endExclusive(of event: Event, calendar: Calendar) -> Date {
        dayAfter(lastDay(of: event, calendar: calendar), calendar: calendar)
    }

    static func applies(_ event: Event, on day: Date, calendar: Calendar) -> Bool {
        let day = calendar.startOfDay(for: day)
        return firstDay(of: event, calendar: calendar) <= day && day <= lastDay(of: event, calendar: calendar)
    }

    /// Stored dates covering `firstDay` up to, not including, `endExclusive`: at least one day.
    static func dates(firstDay: Date, endExclusive: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: firstDay)
        let end = max(dayAfter(start, calendar: calendar), calendar.startOfDay(for: endExclusive))
        return (start, end)
    }

    /// Stored dates covering `firstDay` through `lastDay` inclusive (rental car, other).
    static func dates(firstDay: Date, lastDay: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let last = max(calendar.startOfDay(for: firstDay), calendar.startOfDay(for: lastDay))
        return dates(firstDay: firstDay, endExclusive: dayAfter(last, calendar: calendar), calendar: calendar)
    }

    /// Stored dates for a stay from `checkIn` to `checkOut` (exclusive): at least one night.
    static func dates(checkIn: Date, checkOut: Date, calendar: Calendar) -> (start: Date, end: Date) {
        dates(firstDay: checkIn, endExclusive: checkOut, calendar: calendar)
    }

    /// `minutes` after local midnight on `day` (17:00 is 1020), or nil when out of range.
    /// Used for a stay's check-in / check-out markers (G6-UX-05); a clock time that does
    /// not exist on a daylight-saving day is moved forward by the calendar.
    static func clock(minutes: Int, on day: Date, calendar: Calendar) -> Date? {
        guard Event.clockMinutesRange.contains(minutes) else { return nil }
        return calendar.date(
            bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: calendar.startOfDay(for: day)
        )
    }

    /// The clock time of `date` as minutes after midnight, for storing a picked time.
    static func minutes(of date: Date, calendar: Calendar) -> Int {
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        return (clock.hour ?? 0) * 60 + (clock.minute ?? 0)
    }

    static func dayAfter(_ day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    static func dayBefore(_ day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .day, value: -1, to: start) ?? start.addingTimeInterval(-86_400)
    }

    /// Whole days from `firstDay` to `endExclusive`, at least one; used to keep the length
    /// when the first day moves.
    static func dayCount(from firstDay: Date, to endExclusive: Date, calendar: Calendar) -> Int {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: firstDay), to: calendar.startOfDay(for: endExclusive)
        ).day ?? 1
        return max(1, days)
    }

    /// Order in the all-day section: stays, then rental cars, then everything else.
    static func sectionRank(_ type: EventType) -> Int {
        switch type {
        case .hotel: 0
        case .car: 1
        default: 2
        }
    }
}
