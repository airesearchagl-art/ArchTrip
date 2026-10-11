import SwiftUI

struct EventEditorView: View {
    let tripID: String
    let existing: Event?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var type: EventType
    @State private var title: String
    /// Timed dates. Kept while the all-day toggle is on, so switching back restores
    /// what was typed (G6-UX-04).
    @State private var startDate: Date
    @State private var endDate: Date
    /// All-day range: the first day at local midnight and the day after the last day
    /// (exclusive end, see `AllDaySchedule`). Kept while the toggle is off, likewise.
    @State private var isAllDay: Bool
    @State private var firstDay: Date
    @State private var endExclusive: Date
    @State private var locationName: String
    @State private var note: String
    /// Link to an existing Building (architecture Events only, RF-04).
    @State private var buildingId: String?
    @State private var confirmingDelete = false
    @State private var hasSaved = false

    private let calendar = Calendar.current

    init(tripID: String, existing: Event?, defaultDay: Date) {
        self.tripID = tripID
        self.existing = existing
        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: defaultDay) ?? defaultDay
        _type = State(initialValue: existing?.type ?? .business)
        _title = State(initialValue: existing?.title ?? "")
        _startDate = State(initialValue: existing?.startDate ?? defaultStart)
        _endDate = State(initialValue: existing?.endDate ?? defaultStart.addingTimeInterval(60 * 60))
        _isAllDay = State(initialValue: existing?.isAllDay == true)
        // An existing Event's days, whether it is timed or all-day; a new Event starts as one day.
        let first = existing.map { TimelineBuilder.firstDay(of: $0, calendar: calendar) } ?? calendar.startOfDay(for: defaultDay)
        let last = existing.map { TimelineBuilder.lastDay(of: $0, calendar: calendar) } ?? first
        _firstDay = State(initialValue: first)
        _endExclusive = State(initialValue: AllDaySchedule.dayAfter(last, calendar: calendar))
        _locationName = State(initialValue: existing?.locationName ?? "")
        _note = State(initialValue: existing?.note ?? "")
        _buildingId = State(initialValue: existing?.buildingId)
    }

    private var buildingLink: BuildingLink {
        BuildingLink.resolve(buildingID: buildingId, in: session.buildings)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedLocation: String { locationName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var issue: LocalizedStringKey? {
        if trimmedTitle.isEmpty { return "Enter a title." }
        if !isAllDay, endDate < startDate { return "The end must be on or after the start." }
        if trimmedTitle.count > Event.titleMaxLength
            || trimmedLocation.count > Event.locationNameMaxLength
            || trimmedNote.count > Event.noteMaxLength {
            return "Some fields are too long."
        }
        return nil
    }

    var body: some View {
        let navigationTitle: LocalizedStringKey = existing == nil ? "New Event" : "Edit Event"
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(EventType.allCases) { type in
                            Label(type.label, systemImage: type.systemImage).tag(type)
                        }
                    }
                    Toggle("All-day", isOn: $isAllDay)
                    TextField("Title", text: $title, prompt: Text("e.g. Site visit"))
                }
                Section {
                    if isAllDay {
                        allDayPickers
                    } else {
                        DatePicker("Start", selection: $startDate)
                        DatePicker("End", selection: $endDate, in: startDate...)
                    }
                } footer: {
                    if let issue {
                        Text(issue).foregroundStyle(.red)
                    } else if isAllDay {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(allDayText.footer)
                            Text("All-day events don't count toward Travel / Free Time.")
                        }
                    }
                }
                if type == .architecture {
                    buildingSection
                }
                Section {
                    TextField("Location", text: $locationName)
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }
                if existing != nil {
                    Section {
                        Button("Delete Event", role: .destructive) {
                            confirmingDelete = true
                        }
                    }
                }
            }
            .onChange(of: startDate) { oldStart, newStart in
                // Keep the duration when the start moves.
                let duration = max(0, endDate.timeIntervalSince(oldStart))
                endDate = newStart.addingTimeInterval(duration)
            }
            .onChange(of: buildingId) { previous, selected in
                guard let selected, let building = session.building(id: selected) else { return }
                title = BuildingScheduling.title(current: title, previous: previous.flatMap(session.building(id:)), selected: building)
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
            .confirmationDialog("Delete this event?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let existing { session.deleteEvent(existing) }
                    dismiss()
                }
            }
        }
    }

    // MARK: All-day (G6-UX-02/03/04)

    /// A hotel is entered as check-in / check-out (the check-out day is not a night of the
    /// stay); a rental car as pickup / return and anything else as first / last day, both
    /// inclusive. The stored range is the same half-open [first day, end) in every case.
    @ViewBuilder
    private var allDayPickers: some View {
        DatePicker(allDayText.start, selection: firstDayBinding, displayedComponents: .date)
        switch AllDaySchedule.endConvention(for: type) {
        case .checkOut:
            DatePicker(
                allDayText.end, selection: checkOutBinding,
                in: AllDaySchedule.dayAfter(firstDay, calendar: calendar)..., displayedComponents: .date
            )
        case .lastDay:
            DatePicker(allDayText.end, selection: lastDayBinding, in: firstDay..., displayedComponents: .date)
        }
    }

    private var allDayText: (start: LocalizedStringKey, end: LocalizedStringKey, footer: LocalizedStringKey) {
        switch type {
        case .hotel:
            ("Check-in", "Check-out", "Shown on each night from check-in until the day before check-out.")
        case .car:
            ("Pickup day", "Return day", "Shown on each day from pickup through return.")
        default:
            ("First day", "Last day", "Shown on each day in this range.")
        }
    }

    /// Moving the first day keeps the number of days, as moving a timed start keeps the duration.
    private var firstDayBinding: Binding<Date> {
        Binding {
            firstDay
        } set: { newValue in
            let days = AllDaySchedule.dayCount(from: firstDay, to: endExclusive, calendar: calendar)
            firstDay = calendar.startOfDay(for: newValue)
            endExclusive = calendar.date(byAdding: .day, value: days, to: firstDay)
                ?? AllDaySchedule.dayAfter(firstDay, calendar: calendar)
        }
    }

    /// The check-out day is the exclusive end itself; at least one night.
    private var checkOutBinding: Binding<Date> {
        Binding {
            endExclusive
        } set: { newValue in
            endExclusive = AllDaySchedule.dates(firstDay: firstDay, endExclusive: newValue, calendar: calendar).end
        }
    }

    /// The inclusive last day, stored as the day after it.
    private var lastDayBinding: Binding<Date> {
        Binding {
            AllDaySchedule.dayBefore(endExclusive, calendar: calendar)
        } set: { newValue in
            endExclusive = AllDaySchedule.dates(firstDay: firstDay, lastDay: newValue, calendar: calendar).end
        }
    }

    // MARK: Building (RF-04)

    /// Pick an existing Building (no duplicate Buildings, no MapKit search here) or
    /// enter the visit by hand. Only the name is taken from the Building: its address
    /// may come from Apple Maps search and is not copied into the Event (Option A).
    @ViewBuilder
    private var buildingSection: some View {
        Section {
            switch buildingLink {
            case .unavailable:
                Label("This building is no longer available", systemImage: "building.columns")
                    .foregroundStyle(.secondary)
                Button("Unlink building") { buildingId = nil }
            case .available, .none:
                if session.buildings.isEmpty {
                    Text("No buildings yet. Add one in the Architecture tab, or enter the visit manually.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Existing building", selection: $buildingId) {
                        Text("Enter manually").tag(String?.none)
                        ForEach(BuildingOrdering.sorted(session.buildings)) { building in
                            Text(verbatim: building.name).tag(Optional(building.id))
                        }
                    }
                    if case .available(let building) = buildingLink {
                        NavigationLink {
                            BuildingDetailView(buildingID: building.id)
                        } label: {
                            Label("Building details", systemImage: "building.columns.fill")
                        }
                    }
                }
            }
        } header: {
            Text("Building")
        } footer: {
            if buildingId != nil {
                Text("The building's name is used as the title. Enter the location yourself.")
            }
        }
    }

    private func save() {
        let now = Date()
        let createdAt = existing?.createdAt ?? now
        let dates = isAllDay
            ? AllDaySchedule.dates(firstDay: firstDay, endExclusive: endExclusive, calendar: calendar)
            : (start: startDate, end: endDate)
        let event = Event(
            id: existing?.id ?? UUID().uuidString,
            tripId: tripID,
            type: type,
            title: trimmedTitle,
            startDate: dates.start,
            endDate: dates.end,
            locationName: trimmedLocation,
            note: trimmedNote,
            createdAt: createdAt,
            updatedAt: max(now, createdAt),
            // Keep the Building link only while the Event stays an architecture visit.
            buildingId: type == .architecture ? buildingId : nil,
            // Timed Events omit the flag, so their documents stay exactly as before G6.
            isAllDay: isAllDay ? true : nil
        )
        guard event.isValid, !hasSaved else { return }
        hasSaved = true
        if existing == nil {
            session.createEvent(event)
        } else {
            session.updateEvent(event)
        }
        dismiss()
    }
}
