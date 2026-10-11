import Foundation

nonisolated enum TimelineItem: Identifiable, Equatable, Sendable {
    case event(Event)
    /// Derived gap between two adjacent Events. Never persisted. Shown as
    /// "Travel / Free Time": the time available for moving between Events,
    /// not a computed travel time.
    case freeTime(start: Date, end: Date)
    /// The current time, on today's timeline only (G6-UX-06). Display-only: never
    /// persisted and never part of the gap calculation.
    case now(Date)

    var id: String {
        switch self {
        case .event(let event): "event-\(event.id)"
        case .freeTime(let start, _): "free-\(start.timeIntervalSinceReferenceDate)"
        case .now(let date): "now-\(date.timeIntervalSinceReferenceDate)"
        }
    }
}

nonisolated enum TimelineBuilder {
    static let freeTimeThreshold: TimeInterval = 30 * 60

    /// Timed Events that touch `day`, including ones crossing midnight. A zero-length
    /// Event counts for the day its start falls on. All-day Events are left out; see
    /// `allDayEvents(on:from:calendar:)`.
    static func events(on day: Date, from events: [Event], calendar: Calendar) -> [Event] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return events
            .filter { $0.isTimed && $0.startDate < dayEnd && ($0.endDate > dayStart || $0.startDate >= dayStart) }
            .sorted(by: chronological)
    }

    /// All-day Events (stays, rental cars, whole-day notes) that apply to `day`: stays
    /// first, then rental cars, then the rest, each chronologically. They never enter
    /// `items(for:)`, so they neither create nor shorten Travel / Free Time.
    static func allDayEvents(on day: Date, from events: [Event], calendar: Calendar) -> [Event] {
        events
            .filter { !$0.isTimed && AllDaySchedule.applies($0, on: day, calendar: calendar) }
            .sorted { lhs, rhs in
                let ranks = (AllDaySchedule.sectionRank(lhs.type), AllDaySchedule.sectionRank(rhs.type))
                return ranks.0 != ranks.1 ? ranks.0 < ranks.1 : chronological(lhs, rhs)
            }
    }

    /// Chronological timed Events for `day` with Travel / Free Time between adjacent
    /// Events when the gap is at least `threshold`. No gap before the first or after
    /// the last Event; Events overlapping earlier ones never create gaps. When `now`
    /// falls on `day`, a `.now` row is placed at its chronological position (see
    /// `insert`); it is shown even on a day without timed Events.
    static func items(
        for day: Date,
        events: [Event],
        calendar: Calendar,
        threshold: TimeInterval = freeTimeThreshold,
        now: Date? = nil
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
        if let now, calendar.isDate(now, inSameDayAs: day) {
            insert(.now(now), at: now, afterTies: true, into: &items)
        }
        return items
    }

    /// Places a point-in-time item among the Events and gaps without touching the gap
    /// calculation. The point follows every Event that started before `time`; inside a
    /// gap it splits the gap's display into the part before and the part after it (same
    /// total, no zero-length part); at a gap boundary it sits next to the gap. `afterTies`
    /// says whether it follows an Event (or earlier point) at exactly the same instant:
    /// the current time does, because that Event has begun.
    static func insert(_ item: TimelineItem, at time: Date, afterTies: Bool, into items: inout [TimelineItem]) {
        var index = 0
        while index < items.count {
            switch items[index] {
            case .event(let event):
                guard event.startDate < time || (afterTies && event.startDate == time) else {
                    items.insert(item, at: index)
                    return
                }
            case .now(let other):
                guard other < time || (afterTies && other == time) else {
                    items.insert(item, at: index)
                    return
                }
            case .freeTime(let start, let end):
                if time <= start {
                    items.insert(item, at: index)
                    return
                }
                if time < end {
                    items[index] = .freeTime(start: start, end: time)
                    items.insert(contentsOf: [item, .freeTime(start: time, end: end)], at: index + 1)
                    return
                }
            }
            index += 1
        }
        items.append(item)
    }

    /// Whether a timed Event is over at `now` (G6-UX-06 subdued styling). An Event that
    /// spans `now`, or ends exactly at it, is still active; all-day Events are never
    /// "completed" by their midnight boundaries.
    static func isCompleted(_ event: Event, at now: Date) -> Bool {
        event.isTimed && event.endDate < now
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
            var day = firstDay(of: event, calendar: calendar)
            let last = lastDay(of: event, calendar: calendar)
            while day <= last, days.count < limit {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return days.sorted()
    }

    /// The day an Event starts on; all-day Events use `AllDaySchedule`.
    static func firstDay(of event: Event, calendar: Calendar) -> Date {
        event.isTimed
            ? calendar.startOfDay(for: event.startDate)
            : AllDaySchedule.firstDay(of: event, calendar: calendar)
    }

    /// The day an Event ends on; a timed end exactly at midnight belongs to the day before.
    static func lastDay(of event: Event, calendar: Calendar) -> Date {
        guard event.isTimed else { return AllDaySchedule.lastDay(of: event, calendar: calendar) }
        let end = event.endDate > event.startDate ? event.endDate.addingTimeInterval(-1) : event.startDate
        return calendar.startOfDay(for: end)
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
                isOutside(firstDay(of: $0, calendar: calendar), trip: trip, calendar: calendar)
                    || isOutside(lastDay(of: $0, calendar: calendar), trip: trip, calendar: calendar)
            }
            .sorted(by: chronological)
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
