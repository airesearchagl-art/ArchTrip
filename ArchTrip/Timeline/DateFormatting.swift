import Foundation

/// Locale-explicit formatting so the in-app language choice applies,
/// independent of the device language.
nonisolated enum DateFormatting {
    static func day(_ date: Date, locale: Locale) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated).locale(locale))
    }

    static func shortDate(_ date: Date, locale: Locale) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }

    static func dateRange(_ start: Date, _ end: Date, locale: Locale, calendar: Calendar) -> String {
        if calendar.isDate(start, inSameDayAs: end) {
            return shortDate(start, locale: locale)
        }
        return "\(shortDate(start, locale: locale)) – \(shortDate(end, locale: locale))"
    }

    static func time(_ date: Date, locale: Locale) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    /// Times for an Event row; endpoints on other days carry their date.
    static func eventTimeRange(_ event: Event, on day: Date, locale: Locale, calendar: Calendar) -> String {
        func label(_ date: Date) -> String {
            calendar.isDate(date, inSameDayAs: day)
                ? time(date, locale: locale)
                : "\(shortDate(date, locale: locale)) \(time(date, locale: locale))"
        }
        if event.startDate == event.endDate {
            return label(event.startDate)
        }
        return "\(label(event.startDate)) – \(label(event.endDate))"
    }
}
