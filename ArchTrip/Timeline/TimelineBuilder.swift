import Foundation

nonisolated enum TimelineItem: Identifiable, Equatable, Sendable {
    case event(Event)
    /// Derived gap between two adjacent Events. Never persisted.
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
        let lastDay = calendar.startOfDay(for: trip.endDate)
        while day <= lastDay, days.count < limit {
            days.insert(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        for event in events {
            days.insert(calendar.startOfDay(for: event.startDate))
            if event.endDate > event.startDate {
                days.insert(calendar.startOfDay(for: event.endDate.addingTimeInterval(-1)))
            }
        }
        return days.sorted()
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
