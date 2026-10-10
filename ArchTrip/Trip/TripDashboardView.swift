import SwiftUI

struct TripDashboardView: View {
    let tripID: String

    @Environment(AppSession.self) private var session
    @Environment(\.locale) private var locale
    @State private var events: [Event] = []
    @State private var eventFailures: [DecodeFailure] = []
    @State private var hasLoadedEvents = false
    @State private var eventsLoadFailed = false
    @State private var selectedDay: Date?
    @State private var editorTarget: EventEditorTarget?
    @State private var editingTrip = false

    private let calendar = Calendar.current

    var body: some View {
        Group {
            if let trip = session.trip(id: tripID) {
                dashboard(trip)
            } else {
                ContentUnavailableView("Trip not found", systemImage: "suitcase")
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
        let items = TimelineBuilder.items(for: day, events: events, calendar: calendar)
        let isOutside = { (day: Date) in TimelineBuilder.isOutside(day, trip: trip, calendar: calendar) }
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
                if items.isEmpty {
                    Text("No events on this day")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        switch item {
                        case .event(let event):
                            Button {
                                editorTarget = .edit(event)
                            } label: {
                                EventRow(event: event, day: day)
                            }
                            .tint(.primary)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    session.deleteEvent(event)
                                }
                            }
                        case .freeTime(let start, let end):
                            FreeTimeRow(start: start, end: end)
                        }
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
    }
}

struct FreeTimeRow: View {
    let start: Date
    let end: Date

    var body: some View {
        let duration = TimelineBuilder.hoursAndMinutes(from: start, to: end)
        HStack(spacing: 8) {
            line
            HStack(spacing: 4) {
                Image(systemName: "cup.and.saucer.fill")
                Text("Free time")
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
