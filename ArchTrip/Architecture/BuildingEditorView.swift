import SwiftUI

struct BuildingEditorView: View {
    let existing: Building?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var architect: String
    @State private var yearText: String
    @State private var address: String
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var visitMinutes: Int
    @State private var priority: Int
    @State private var visited: Bool
    @State private var note: String

    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var isSearching = false
    @State private var searchFailed = false

    init(building: Building?) {
        existing = building
        _name = State(initialValue: building?.name ?? "")
        _architect = State(initialValue: building?.architect ?? "")
        _yearText = State(initialValue: building?.completedYear.map(String.init) ?? "")
        _address = State(initialValue: building?.address ?? "")
        _latitude = State(initialValue: building?.latitude)
        _longitude = State(initialValue: building?.longitude)
        _visitMinutes = State(initialValue: building?.visitMinutes ?? Building.defaultVisitMinutes)
        _priority = State(initialValue: building?.priority ?? Building.defaultPriority)
        _visited = State(initialValue: building?.visited ?? false)
        _note = State(initialValue: building?.note ?? "")
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var completedYear: Int? { Int(trimmed(yearText)) }

    private var draft: Building {
        let now = Date()
        let createdAt = existing?.createdAt ?? now
        return Building(
            id: existing?.id ?? UUID().uuidString,
            name: trimmed(name),
            architect: trimmed(architect),
            completedYear: trimmed(yearText).isEmpty ? nil : completedYear,
            address: trimmed(address),
            latitude: latitude,
            longitude: longitude,
            visitMinutes: visitMinutes,
            priority: priority,
            visited: visited,
            note: trimmed(note),
            createdAt: createdAt,
            updatedAt: max(now, createdAt)
        )
    }

    private var issue: LocalizedStringKey? {
        if trimmed(name).isEmpty { return "Enter a name." }
        if !trimmed(yearText).isEmpty, completedYear.map(Building.completedYearRange.contains) != true {
            return "Enter a valid year."
        }
        if !draft.isValid { return "Some fields are too long." }
        return nil
    }

    var body: some View {
        let navigationTitle: LocalizedStringKey = existing == nil ? "New Building" : "Edit Building"
        NavigationStack {
            Form {
                searchSection
                Section {
                    LabeledContent("Name") {
                        TextField("Name", text: $name, prompt: Text("e.g. Sapporo Concert Hall Kitara"))
                    }
                    LabeledContent("Architect") {
                        TextField("Architect", text: $architect)
                    }
                    LabeledContent("Completed year") {
                        TextField("Completed year", text: $yearText, prompt: Text("e.g. 1997"))
                            .keyboardType(.numberPad)
                    }
                    LabeledContent("Address") {
                        TextField("Address", text: $address, axis: .vertical)
                    }
                    if latitude != nil, longitude != nil {
                        HStack {
                            Label("Location set", systemImage: "mappin.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Clear", role: .destructive) {
                                latitude = nil
                                longitude = nil
                            }
                            .buttonStyle(.borderless)
                        }
                    } else {
                        Label("No location (search to set one)", systemImage: "mappin.slash")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if let issue {
                        Text(issue).foregroundStyle(.red)
                    }
                }
                Section {
                    Stepper(value: $visitMinutes, in: Building.visitMinutesRange, step: 15) {
                        LabeledContent("Visit duration") {
                            Text("\(visitMinutes) min")
                        }
                    }
                    Picker("Priority", selection: $priority) {
                        Text("High").tag(3)
                        Text("Normal").tag(2)
                        Text("Low").tag(1)
                    }
                    Toggle("Visited", isOn: $visited)
                }
                Section {
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .multilineTextAlignment(.leading)
                }
            }
            .multilineTextAlignment(.trailing)
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

    private var searchSection: some View {
        Section {
            HStack {
                TextField("Search for a place or address", text: $query)
                    .multilineTextAlignment(.leading)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                if isSearching {
                    ProgressView()
                } else {
                    Button("Search") { Task { await search() } }
                        .disabled(trimmed(query).isEmpty)
                        .buttonStyle(.borderless)
                }
            }
            if searchFailed {
                Text("Search needs a network connection. Try again later.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(results) { result in
                Button {
                    apply(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: result.name).foregroundStyle(.primary)
                        Text(verbatim: result.address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Place search")
        }
    }

    private func search() async {
        let text = trimmed(query)
        guard !text.isEmpty else { return }
        isSearching = true
        searchFailed = false
        defer { isSearching = false }
        do {
            results = try await PlaceResult.search(text)
        } catch {
            results = []
            searchFailed = true
        }
    }

    private func apply(_ result: PlaceResult) {
        if trimmed(name).isEmpty { name = result.name }
        if !result.address.isEmpty { address = String(result.address.prefix(Building.addressMaxLength)) }
        latitude = result.latitude
        longitude = result.longitude
        results = []
    }

    private func save() {
        let building = draft
        guard building.isValid else { return }
        session.saveBuilding(building)
        dismiss()
    }
}
