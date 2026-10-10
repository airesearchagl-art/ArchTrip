import SwiftUI

struct TripEditorView: View {
    let existing: Trip?
    /// The Trip's Events, for the dates warning. Irrelevant for a new Trip.
    let events: EventLoadState

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var destination: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var hasSaved = false

    init(trip: Trip?, events: EventLoadState = .loaded([], complete: true)) {
        existing = trip
        self.events = events
        let today = Calendar.current.startOfDay(for: Date())
        _title = State(initialValue: trip?.title ?? "")
        _destination = State(initialValue: trip?.destination ?? "")
        _startDate = State(initialValue: trip?.startDate ?? today)
        _endDate = State(initialValue: trip?.endDate ?? today)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedDestination: String { destination.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var startDay: Date { Calendar.current.startOfDay(for: startDate) }
    private var endDay: Date { Calendar.current.startOfDay(for: endDate) }

    private var issue: LocalizedStringKey? {
        if trimmedTitle.isEmpty { return "Enter a title." }
        if endDay < startDay { return "The end must be on or after the start." }
        if trimmedTitle.count > Trip.titleMaxLength || trimmedDestination.count > Trip.destinationMaxLength {
            return "Some fields are too long."
        }
        return nil
    }

    /// Events are never moved with the Trip; the user is told what the new dates leave out.
    private var datesWarning: TripDatesWarning? {
        guard let existing else { return nil }
        return TripDatesWarning.forDates(start: startDay, end: endDay, of: existing, events: events, calendar: Calendar.current)
    }

    var body: some View {
        let navigationTitle: LocalizedStringKey = existing == nil ? "New Trip" : "Edit Trip"
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, prompt: Text("e.g. Sapporo business trip"))
                    TextField("Destination", text: $destination, prompt: Text("e.g. Sapporo"))
                }
                Section {
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                    DatePicker("End date", selection: $endDate, in: startDate..., displayedComponents: .date)
                } footer: {
                    if let issue {
                        Text(issue).foregroundStyle(.red)
                    }
                }
                if let datesWarning {
                    Section {
                        DatesWarningView(warning: datesWarning, start: startDay, end: endDay)
                    }
                }
            }
            .onChange(of: startDate) {
                if endDate < startDate { endDate = startDate }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(issue != nil)
                }
            }
        }
    }

    private func save() {
        let now = Date()
        let createdAt = existing?.createdAt ?? now
        let trip = Trip(
            id: existing?.id ?? UUID().uuidString,
            title: trimmedTitle,
            destination: trimmedDestination,
            startDate: startDay,
            endDate: endDay,
            createdAt: createdAt,
            updatedAt: max(now, createdAt)
        )
        // One write per editor, even if Save is tapped again while dismissing.
        guard trip.isValid, !hasSaved else { return }
        hasSaved = true
        if existing == nil {
            session.createTrip(trip)
        } else {
            session.updateTrip(trip)
        }
        dismiss()
    }
}

private struct DatesWarningView: View {
    let warning: TripDatesWarning
    let start: Date
    let end: Date

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch warning {
            case .unknown:
                Label("Events couldn't be checked against the new dates. Review them after saving.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .outside(let count, let complete):
                Label("Events outside the trip dates", systemImage: "calendar.badge.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("New trip dates: \(DateFormatting.dateRange(start, end, locale: locale, calendar: .current))")
                Text("\(count) events outside the new dates")
                if !complete {
                    Text("Some events couldn't be loaded and aren't counted.")
                }
                Text("Event dates aren't changed automatically. Edit them individually if needed.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}
