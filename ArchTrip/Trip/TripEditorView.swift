import SwiftUI

struct TripEditorView: View {
    let existing: Trip?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var destination: String
    @State private var startDate: Date
    @State private var endDate: Date

    init(trip: Trip?) {
        existing = trip
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
        guard trip.isValid else { return }
        session.saveTrip(trip)
        dismiss()
    }
}
