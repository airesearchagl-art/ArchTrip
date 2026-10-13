import Foundation
import Observation

/// A Trip deletion that stopped after something was sent, kept on this device so it can
/// be checked again and finished from the Trip list, even after the screen closed or
/// the app restarted. Holds the Trip ID, counts and states only: no title, no Event.
nonisolated struct PendingTripDeletion: Codable, Equatable, Identifiable, Sendable {
    let tripID: String
    let startedAt: Date
    var updatedAt: Date
    var acknowledgedEvents: Int
    var tripStatus: TripDeletion.TripStatus
    /// `TripDeletion.Stop.Reason` as a short code, for the list row.
    var reason: String

    var id: String { tripID }
}

/// Local, per-account ledger of stopped deletions (RF-03). Backed by `UserDefaults`:
/// nothing here goes to Firestore, so no Rules or model change is involved.
@Observable
final class TripDeletionLedger {
    static let key = "archtrip.pendingTripDeletions"

    private let defaults: UserDefaults
    private(set) var recordsByUser: [String: [PendingTripDeletion]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func records(for uid: String) -> [PendingTripDeletion] {
        (recordsByUser[uid] ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    func record(_ record: PendingTripDeletion, uid: String) {
        var records = recordsByUser[uid] ?? []
        if let index = records.firstIndex(where: { $0.tripID == record.tripID }) {
            records[index] = record
        } else {
            records.append(record)
        }
        recordsByUser[uid] = records
        save()
    }

    func remove(tripID: String, uid: String) {
        guard var records = recordsByUser[uid] else { return }
        records.removeAll { $0.tripID == tripID }
        recordsByUser[uid] = records.isEmpty ? nil : records
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.key) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        recordsByUser = (try? decoder.decode([String: [PendingTripDeletion]].self, from: data)) ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if recordsByUser.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? encoder.encode(recordsByUser) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
