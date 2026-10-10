import SwiftUI

/// Schedules a Building visit as an architecture Event on an existing Trip.
struct AddBuildingToTripView: View {
    let building: Building

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var tripID: String?
    @State private var day = Date()
    @State private var time: Date
    @State private var durationMinutes: Int
    @State private var hasSaved = false

    private let calendar = Calendar.current

    init(building: Building) {
        self.building = building
        let defaultTime = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
        _time = State(initialValue: defaultTime)
        _durationMinutes = State(initialValue: building.visitMinutes)
    }

    private var trips: [Trip] {
        let partition = Trip.partition(session.trips, today: Date(), calendar: calendar)
        return partition.upcoming + partition.past
    }

    private var selectedTrip: Trip? {
        tripID.flatMap(session.trip(id:))
    }

    var body: some View {
        NavigationStack {
            Form {
                if trips.isEmpty {
                    ContentUnavailableView("No trips yet", systemImage: "suitcase", description: Text("Create a trip first."))
                } else {
                    Section {
                        LabeledContent("Building") {
                            Text(verbatim: building.name)
                        }
                        Picker("Trip", selection: $tripID) {
                            ForEach(trips) { trip in
                                Text(verbatim: "\(trip.title) (\(DateFormatting.dateRange(trip.startDate, trip.endDate, locale: locale, calendar: calendar)))")
                                    .tag(Optional(trip.id))
                            }
                        }
                    }
                    if let trip = selectedTrip {
                        Section {
                            DatePicker("Date", selection: $day, in: trip.startDate...lastMoment(of: trip), displayedComponents: .date)
                            DatePicker("Start", selection: $time, displayedComponents: .hourAndMinute)
                            Stepper(value: $durationMinutes, in: Building.visitMinutesRange, step: 15) {
                                LabeledContent("Visit duration") {
                                    Text("\(durationMinutes) min")
                                }
                            }
                        } footer: {
                            Text(verbatim: summary)
                        }
                    }
                }
            }
            .navigationTitle("Add to Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(selectedTrip == nil)
                }
            }
            .onAppear {
                if tripID == nil, let first = trips.first {
                    select(first)
                }
            }
            .onChange(of: tripID) {
                if let trip = selectedTrip { clampDay(to: trip) }
            }
        }
    }

    private var start: Date {
        BuildingScheduling.startDate(day: day, time: time, calendar: calendar)
    }

    private var summary: String {
        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        return "\(DateFormatting.day(start, locale: locale)) \(DateFormatting.time(start, locale: locale)) – \(DateFormatting.time(end, locale: locale))"
    }

    private func lastMoment(of trip: Trip) -> Date {
        let lastDay = calendar.startOfDay(for: trip.endDate)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: lastDay) ?? trip.endDate
    }

    private func select(_ trip: Trip) {
        tripID = trip.id
        clampDay(to: trip)
    }

    /// Today when it falls within the Trip, otherwise the Trip's first day.
    private func clampDay(to trip: Trip) {
        let today = calendar.startOfDay(for: Date())
        if today >= calendar.startOfDay(for: trip.startDate), today <= lastMoment(of: trip) {
            day = today
        } else if day < trip.startDate || day > lastMoment(of: trip) {
            day = trip.startDate
        }
    }

    private func add() {
        guard let trip = selectedTrip else { return }
        let event = BuildingScheduling.makeEvent(
            visiting: building,
            tripID: trip.id,
            start: start,
            durationMinutes: durationMinutes
        )
        guard event.isValid, !hasSaved else { return }
        hasSaved = true
        session.createEvent(event)
        dismiss()
    }
}
