import Foundation

/// What a screen knows about a Trip's Events, from the Events listener.
nonisolated enum EventLoadState: Equatable, Sendable {
    case loading
    case failed
    /// `complete` is false when some documents failed to decode.
    case loaded([Event], complete: Bool)
}

/// The warning shown while editing a Trip's dates. Events are never moved with the
/// Trip (RF-02): the user sees how many fall outside the new dates and edits them
/// individually from the timeline.
nonisolated enum TripDatesWarning: Equatable, Sendable {
    /// The Events could not be counted: not loaded yet, or the listener failed.
    case unknown
    /// `count` decoded Events lie outside the new dates. `complete` is false when some
    /// documents failed to decode, so the count is only a lower bound.
    case outside(count: Int, complete: Bool)

    /// nil when nothing needs saying: the dates are unchanged, or every decoded Event
    /// still fits and all of them decoded.
    static func forDates(start: Date, end: Date, of trip: Trip, events: EventLoadState, calendar: Calendar) -> TripDatesWarning? {
        if calendar.isDate(start, inSameDayAs: trip.startDate), calendar.isDate(end, inSameDayAs: trip.endDate) {
            return nil
        }
        switch events {
        case .loading, .failed:
            return .unknown
        case .loaded(let events, let complete):
            var moved = trip
            moved.startDate = start
            moved.endDate = end
            let outside = TimelineBuilder.events(outside: moved, from: events, calendar: calendar)
            if outside.isEmpty, complete { return nil }
            return .outside(count: outside.count, complete: complete)
        }
    }
}
