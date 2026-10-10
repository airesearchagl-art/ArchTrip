import Foundation

nonisolated enum TimelineItem: Identifiable, Equatable, Sendable {
    case event(Event)
    /// Derived gap between two adjacent Events. Never persisted. Shown as
    /// "Travel / Free Time": the time available for moving between Events,
    /// not a computed travel time.
    case freeTime(start: Date, end: Date)

    var id: String {
        switch self {
        case .event(let event): "event-\(event.id)"
        case .freeTime(let start, _): "free-\(start.timeIntervalSinceReferenceDate)"
        }
    }
}

nonisolated enum TimelineBuilder {
    static let freeTimeThreshold: TimeInterval = 30 * 60

    /// Events that touch `day`, including ones crossing midnight. A zero-length
    /// Event counts for the day its start falls on.
    static func events(on day: Date, from events: [Event], calendar: Calendar) -> [Event] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return events
            .filter { $0.startDate < dayEnd && ($0.endDate > dayStart || $0.startDate >= dayStart) }
            .sorted(by: chronological)
    }

    /// Chronological Events for `day` with Free Time between adjacent Events
    /// when the gap is at least `threshold`. No Free Time before the first or
    /// after the last Event; Events overlapping earlier ones never create gaps.
    static func items(
        for day: Date,
        events: [Event],
        calendar: Calendar,
        threshold: TimeInterval = freeTimeThreshold
    ) -> [TimelineItem] {
        var items: [TimelineItem] = []
        var latestEnd: Date?
        for event in self.events(on: day, from: events, calendar: calendar) {
            if let latestEnd, event.startDate.timeIntervalSince(latestEnd) >= threshold {
                items.append(.freeTime(start: latestEnd, end: event.startDate))
            }
            items.append(.event(event))
            latestEnd = max(latestEnd ?? event.endDate, event.endDate)
        }
        return items
    }

    /// The Trip's days plus any day an Event starts or ends on, so no Event is unreachable.
    static func days(for trip: Trip, events: [Event], calendar: Calendar, limit: Int = 366) -> [Date] {
        var days = Set<Date>()
        var day = calendar.startOfDay(for: trip.startDate)
        let tripLastDay = calendar.startOfDay(for: trip.endDate)
        while day <= tripLastDay, days.count < limit {
            days.insert(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        for event in events {
            days.insert(calendar.startOfDay(for: event.startDate))
            days.insert(lastDay(of: event, calendar: calendar))
        }
        return days.sorted()
    }

    /// Whether `day` lies before the Trip's first day or after its last.
    static func isOutside(_ day: Date, trip: Trip, calendar: Calendar) -> Bool {
        let day = calendar.startOfDay(for: day)
        return day < calendar.startOfDay(for: trip.startDate) || day > calendar.startOfDay(for: trip.endDate)
    }

    /// Events that touch a day outside the Trip's dates, chronologically. Changing the
    /// Trip's dates never moves its Events (each has its own), so these stay visible for
    /// the user to edit or delete one by one.
    static func events(outside trip: Trip, from events: [Event], calendar: Calendar) -> [Event] {
        events
            .filter {
                isOutside($0.startDate, trip: trip, calendar: calendar)
                    || isOutside(lastDay(of: $0, calendar: calendar), trip: trip, calendar: calendar)
            }
            .sorted(by: chronological)
    }

    /// The day an Event ends on; an end exactly at midnight belongs to the day before.
    private static func lastDay(of event: Event, calendar: Calendar) -> Date {
        let end = event.endDate > event.startDate ? event.endDate.addingTimeInterval(-1) : event.startDate
        return calendar.startOfDay(for: end)
    }

    static func chronological(_ lhs: Event, _ rhs: Event) -> Bool {
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.id < rhs.id
    }

    static func hoursAndMinutes(from start: Date, to end: Date) -> (hours: Int, minutes: Int) {
        let totalMinutes = max(0, Int(end.timeIntervalSince(start) / 60))
        return (totalMinutes / 60, totalMinutes % 60)
    }
}
