import SwiftUI

struct EventEditorView: View {
    let tripID: String
    let existing: Event?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var type: EventType
    @State private var title: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var locationName: String
    @State private var note: String
    @State private var confirmingDelete = false

    init(tripID: String, existing: Event?, defaultDay: Date) {
        self.tripID = tripID
        self.existing = existing
        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: defaultDay) ?? defaultDay
        _type = State(initialValue: existing?.type ?? .business)
        _title = State(initialValue: existing?.title ?? "")
        _startDate = State(initialValue: existing?.startDate ?? defaultStart)
        _endDate = State(initialValue: existing?.endDate ?? defaultStart.addingTimeInterval(60 * 60))
        _locationName = State(initialValue: existing?.locationName ?? "")
        _note = State(initialValue: existing?.note ?? "")
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedLocation: String { locationName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var issue: LocalizedStringKey? {
        if trimmedTitle.isEmpty { return "Enter a title." }
        if endDate < startDate { return "The end must be on or after the start." }
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
                    TextField("Title", text: $title, prompt: Text("e.g. Site visit"))
                }
                Section {
                    DatePicker("Start", selection: $startDate)
                    DatePicker("End", selection: $endDate, in: startDate...)
                } footer: {
                    if let issue {
                        Text(issue).foregroundStyle(.red)
                    }
                }
                if existing?.buildingId != nil, type == .architecture {
                    buildingLinkSection
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

    @ViewBuilder
    private var buildingLinkSection: some View {
        Section("Building") {
            switch existing.map({ BuildingLink.resolve($0, in: session.buildings) }) ?? .none {
            case .available(let building):
                NavigationLink {
                    BuildingDetailView(buildingID: building.id)
                } label: {
                    Label {
                        Text(verbatim: building.name)
                    } icon: {
                        Image(systemName: "building.columns.fill")
                    }
                }
            case .unavailable:
                Label("This building is no longer available", systemImage: "building.columns")
                    .foregroundStyle(.secondary)
            case .none:
                EmptyView()
            }
        }
    }

    private func save() {
        let now = Date()
        let createdAt = existing?.createdAt ?? now
        let event = Event(
            id: existing?.id ?? UUID().uuidString,
            tripId: tripID,
            type: type,
            title: trimmedTitle,
            startDate: startDate,
            endDate: endDate,
            locationName: trimmedLocation,
            note: trimmedNote,
            createdAt: createdAt,
            updatedAt: max(now, createdAt),
            // Keep the Building link only while the Event stays an architecture visit.
            buildingId: type == .architecture ? existing?.buildingId : nil
        )
        guard event.isValid else { return }
        session.saveEvent(event)
        dismiss()
    }
}
