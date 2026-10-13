import SwiftUI

struct TripDashboardView: View {
    let tripID: String

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var events: [Event] = []
    @State private var eventFailures: [DecodeFailure] = []
    @State private var hasLoadedEvents = false
    @State private var eventsLoadFailed = false
    @State private var selectedDay: Date?
    @State private var editorTarget: EventEditorTarget?
    @State private var editingTrip = false
    /// RF-03: the Trip being deleted. Attached outside `dashboard(_:)` so the sheet
    /// survives the Trip vanishing from the list while its batches are acknowledged.
    @State private var deletionTarget: Trip?

    private let calendar = Calendar.current

    var body: some View {
        Group {
            if let trip = session.trip(id: tripID) {
                dashboard(trip)
            } else {
                ContentUnavailableView("Trip not found", systemImage: "suitcase")
            }
        }
        .sheet(item: $deletionTarget) { trip in
            TripDeletionView(trip: trip) {
                deletionTarget = nil
                dismiss()
            }
        }
        .task(id: tripID) {
            guard let uid = session.uid, let store = session.store else { return }
            for await result in store.eventUpdates(uid: uid, tripID: tripID) {
                hasLoadedEvents = true
                switch result {
                case .success(let snapshot):
                    events = snapshot.items
                    eventFailures = snapshot.failures
                    eventsLoadFailed = false
                case .failure:
                    eventsLoadFailed = true
                }
            }
        }
    }

    private var eventLoadState: EventLoadState {
        if eventsLoadFailed { return .failed }
        if !hasLoadedEvents { return .loading }
        return .loaded(events, complete: eventFailures.isEmpty)
    }

    private func dashboard(_ trip: Trip) -> some View {
        let days = TimelineBuilder.days(for: trip, events: events, calendar: calendar)
        let day = currentDay(in: days)
        let isOutside = { (day: Date) in TimelineBuilder.isOutside(day, trip: trip, calendar: calendar) }
        // Re-evaluated at the start of every minute while on screen, and again when the
        // app returns to the foreground, so the current-time row and the completed
        // styling stay right without timers, polling or network (G6-UX-06).
        return TimelineView(.everyMinute) { context in
            timeline(trip, days: days, day: day, isOutside: isOutside, now: context.date)
        }
        .navigationTitle(Text(verbatim: trip.title))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorTarget = .new(day: day)
                } label: {
                    Label("Add Event", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    editingTrip = true
                } label: {
                    Label("Edit Trip", systemImage: "pencil")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(role: .destructive) {
                    deletionTarget = trip
                } label: {
                    Label("Delete Trip", systemImage: "trash")
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            switch target {
            case .new(let day):
                EventEditorView(tripID: trip.id, existing: nil, defaultDay: day)
            case .edit(let event):
                EventEditorView(tripID: trip.id, existing: event, defaultDay: day)
            }
        }
        .sheet(isPresented: $editingTrip) {
            TripEditorView(trip: trip, events: eventLoadState)
        }
    }

    private func timeline(
        _ trip: Trip, days: [Date], day: Date, isOutside: @escaping (Date) -> Bool, now: Date
    ) -> some View {
        let items = TimelineBuilder.items(for: day, events: events, calendar: calendar, now: now)
        let allDay = TimelineBuilder.allDayEvents(on: day, from: events, calendar: calendar)
        let hasTimedEvents = items.contains { item in
            if case .event = item { return true }
            return false
        }
        let emptyText: LocalizedStringKey = allDay.isEmpty ? "No events on this day" : "No timed events on this day"
        return List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    if !trip.destination.isEmpty {
                        Label {
                            Text(verbatim: trip.destination)
                        } icon: {
                            Image(systemName: "mappin.and.ellipse")
                        }
                    }
                    Label {
                        Text(verbatim: DateFormatting.dateRange(trip.startDate, trip.endDate, locale: locale, calendar: calendar))
                    } icon: {
                        Image(systemName: "calendar")
                    }
                }
                .foregroundStyle(.secondary)
                DayStrip(days: days, selectedDay: day, isOutside: isOutside) { selectedDay = $0 }
            }

            if !eventFailures.isEmpty {
                DecodeFailureSection(failures: eventFailures)
            }
            if eventsLoadFailed {
                Label("Couldn't load data", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            Section {
                if !hasTimedEvents {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    switch item {
                    case .event(let event):
                        Button {
                            editorTarget = .edit(event)
                        } label: {
                            EventRow(event: event, day: day, isCompleted: TimelineBuilder.isCompleted(event, at: now))
                        }
                        .tint(.primary)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                session.deleteEvent(event)
                            }
                        }
                    case .freeTime(let start, let end):
                        FreeTimeRow(start: start, end: end)
                    case .now(let date):
                        NowRow(date: date)
                    case .marker(let marker):
                        // Derived from its all-day Event: opens that Event's editor and has no
                        // delete of its own.
                        Button {
                            editorTarget = .edit(marker.event)
                        } label: {
                            EventMarkerRow(marker: marker, isCompleted: marker.time < now)
                        }
                        .tint(.primary)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: DateFormatting.day(day, locale: locale))
                    if isOutside(day) {
                        // Kept visible on purpose: Events never move with the Trip's dates.
                        Label("Outside the trip dates", systemImage: "calendar.badge.exclamationmark")
                            .foregroundStyle(.orange)
                            .textCase(nil)
                    }
                }
            }

            // G6: stays, rental cars and other all-day Events sit below the timed
            // timeline and never take part in Travel / Free Time.
            if !allDay.isEmpty {
                Section {
                    ForEach(allDay) { event in
                        Button {
                            editorTarget = .edit(event)
                        } label: {
                            AllDayEventRow(event: event)
                        }
                        .tint(.primary)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                session.deleteEvent(event)
                            }
                        }
                    }
                } header: {
                    Text("All-day & stays")
                }
            }
        }
    }

    /// The chosen day, else today if it is in the Trip, else the first day.
    private func currentDay(in days: [Date]) -> Date {
        if let selectedDay, days.contains(selectedDay) { return selectedDay }
        let today = calendar.startOfDay(for: Date())
        if days.contains(today) { return today }
        return days.first ?? today
    }
}

enum EventEditorTarget: Identifiable {
    case new(day: Date)
    case edit(Event)

    var id: String {
        switch self {
        case .new(let day): "new-\(day.timeIntervalSinceReferenceDate)"
        case .edit(let event): event.id
        }
    }
}

private struct DayStrip: View {
    let days: [Date]
    let selectedDay: Date
    /// Days outside the Trip's dates, shown because an Event touches them.
    let isOutside: (Date) -> Bool
    let select: (Date) -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { day in
                    let isSelected = day == selectedDay
                    let outside = isOutside(day)
                    Button {
                        select(day)
                    } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: day.formatted(.dateTime.weekday(.abbreviated).locale(locale)))
                                .font(.caption2)
                            Text(verbatim: day.formatted(.dateTime.day().locale(locale)))
                                .font(.headline)
                        }
                        .frame(minWidth: 52, minHeight: 48)
                        .background(background(isSelected: isSelected, outside: outside), in: .rect(cornerRadius: 10))
                        .foregroundStyle(isSelected ? Color.white : outside ? Color.orange : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityLabel(accessibilityLabel(for: day, outside: outside))
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func background(isSelected: Bool, outside: Bool) -> Color {
        if isSelected { return .accentColor }
        return outside ? Color.orange.opacity(0.15) : Color(.secondarySystemBackground)
    }

    private func accessibilityLabel(for day: Date, outside: Bool) -> Text {
        let label = DateFormatting.day(day, locale: locale)
        return outside ? Text("\(label), outside the trip dates") : Text(verbatim: label)
    }
}

struct EventRow: View {
    let event: Event
    let day: Date
    /// G6-UX-06: a timed Event that has ended is subdued, still legible and editable.
    var isCompleted = false

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.type.systemImage)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(event.type.tint, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: DateFormatting.eventTimeRange(event, on: day, locale: locale, calendar: .current))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(verbatim: event.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isCompleted ? .secondary : .primary)
                HStack(spacing: 4) {
                    Text(event.type.label)
                    if !event.locationName.isEmpty {
                        Text(verbatim: "· \(event.locationName)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(isCompleted ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCompleted ? Text("Completed") : Text(verbatim: ""))
    }
}

/// An all-day Event's derived clock-time point on the timed timeline: a stay's check-in /
/// check-out (G6-UX-05) or a rental car's pickup / return (G6-UX-07). An instant, not a
/// busy period; it names the Event it comes from and shows that Event's location and a
/// note preview, read from it each time (G6-UX-05-RF-Display-01).
struct EventMarkerRow: View {
    let marker: EventMarker
    var isCompleted = false

    @Environment(\.locale) private var locale

    private var title: LocalizedStringKey {
        switch marker.kind {
        case .checkIn: "Hotel check-in"
        case .checkOut: "Hotel check-out"
        case .pickup: "Rental car pickup"
        case .return: "Rental car return"
        }
    }

    /// Names the source Event, by what it is.
    private var source: Text {
        switch marker.kind {
        case .checkIn, .checkOut: Text("Stay: \(marker.event.title)")
        case .pickup, .return: Text("Rental car: \(marker.event.title)")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: marker.event.type.systemImage)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(marker.event.type.tint, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: DateFormatting.time(marker.time, locale: locale))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isCompleted ? .secondary : .primary)
                Group {
                    Label {
                        source
                    } icon: {
                        Image(systemName: "link")
                    }
                    // Blank fields have no line at all; a long address wraps.
                    if let location = marker.locationName {
                        Label {
                            Text(verbatim: location)
                                .lineLimit(3)
                        } icon: {
                            Image(systemName: "mappin.and.ellipse")
                        }
                        .accessibilityLabel(Text("Location: \(location)"))
                    }
                    if let note = marker.notePreview {
                        Label {
                            Text(verbatim: note)
                                .lineLimit(EventMarker.notePreviewMaxLines)
                        } icon: {
                            Image(systemName: "note.text")
                        }
                        .accessibilityLabel(Text("Note: \(note)"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 2)
        .opacity(isCompleted ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCompleted ? Text("Completed") : Text(verbatim: ""))
    }
}

/// The current time on today's timeline (G6-UX-06): a red rule with a text label and the
/// time, so colour is never the only cue. It marks an instant, not a busy period.
struct NowRow: View {
    let date: Date

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            line
            HStack(spacing: 4) {
                Image(systemName: "clock.fill")
                Text("Now")
                Text(verbatim: DateFormatting.time(date, locale: locale))
                    .monospacedDigit()
            }
            .lineLimit(1)
            .layoutPriority(1)
            line
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.red)
        .listRowBackground(Color.red.opacity(0.06))
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle()
            .fill(.red)
            .frame(maxWidth: .infinity, maxHeight: 2)
    }
}

/// A stay, rental car or other all-day Event in the "All-day & stays" section (G6).
/// Shows the stay as check-in / check-out and other ranges as first – last day.
struct AllDayEventRow: View {
    let event: Event

    @Environment(\.locale) private var locale
    private let calendar = Calendar.current

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.type.systemImage)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(event.type.tint, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.type.allDayLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: event.title)
                    .font(.body.weight(.semibold))
                Group {
                    range
                    if !event.locationName.isEmpty {
                        Text(verbatim: event.locationName)
                    }
                    if !event.note.isEmpty {
                        Text(verbatim: event.note)
                            .lineLimit(3)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var range: some View {
        let first = AllDaySchedule.firstDay(of: event, calendar: calendar)
        let last = AllDaySchedule.lastDay(of: event, calendar: calendar)
        switch AllDaySchedule.endConvention(for: event.type) {
        case .checkOut:
            let checkOut = AllDaySchedule.dayAfter(last, calendar: calendar)
            Text("Check-in \(DateFormatting.shortDate(first, locale: locale)) · Check-out \(DateFormatting.shortDate(checkOut, locale: locale))")
        case .lastDay:
            if first != last {
                Text(verbatim: DateFormatting.dateRange(first, last, locale: locale, calendar: calendar))
            }
        }
    }
}

/// The gap between two timed Events (G6-UX-01: "Travel / Free Time"). The duration is
/// the whole gap, usable for moving between Events; it is not an estimated travel time.
struct FreeTimeRow: View {
    let start: Date
    let end: Date

    var body: some View {
        let duration = TimelineBuilder.hoursAndMinutes(from: start, to: end)
        HStack(spacing: 8) {
            line
            HStack(spacing: 4) {
                Image(systemName: "cup.and.saucer.fill")
                Text("Travel / Free Time")
                durationText(duration)
            }
            .lineLimit(1)
            .layoutPriority(1)
            line
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.green)
        .listRowBackground(Color.green.opacity(0.08))
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle()
            .fill(.green.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: 1)
    }

    private func durationText(_ duration: (hours: Int, minutes: Int)) -> Text {
        switch (duration.hours, duration.minutes) {
        case (0, let minutes): Text("\(minutes) min")
        case (let hours, 0): Text("\(hours) hr")
        case (let hours, let minutes): Text("\(hours) hr \(minutes) min")
        }
    }
}
