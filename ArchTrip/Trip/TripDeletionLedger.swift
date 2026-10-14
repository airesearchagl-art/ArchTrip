import Foundation
import Observation

/// A Trip deletion in progress or stopped, kept on this device so it can be checked again
/// and finished from the Trip list, even after the screen closed or the app restarted.
/// Holds the Trip ID, counts and states only: no title, no Event.
nonisolated struct PendingTripDeletion: Codable, Equatable, Identifiable, Sendable {
    let tripID: String
    let startedAt: Date
    var updatedAt: Date
    /// Events in batches the server acknowledged, across runs.
    var acknowledgedEvents: Int
    var tripStatus: TripDeletion.TripStatus
    /// `TripDeletion.Stop.Reason` as a short code once stopped; "started" before the first
    /// batch is sent and "inProgress" while batches are acknowledged.
    var reason: String

    var id: String { tripID }
}

/// Where the ledger keeps its records. A save returns only once the data is on disk.
protocol TripDeletionLedgerStorage {
    func load() throws -> Data?
    func save(_ data: Data?) throws
}

/// A JSON file in Application Support, written atomically (temporary file, then rename)
/// and synchronously: when `save` returns, a force quit cannot lose the record. This is
/// stronger than `UserDefaults.set`, which returns before the defaults system writes the
/// plist. What neither covers is an OS crash or power loss before the kernel flushes the
/// page cache (no `F_FULLFSYNC`), the same bound the rest of the app lives with.
struct FileTripDeletionLedgerStorage: TripDeletionLedgerStorage {
    let url: URL

    static var `default`: FileTripDeletionLedgerStorage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileTripDeletionLedgerStorage(url: base.appendingPathComponent("ArchTrip/pendingTripDeletions.json"))
    }

    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func save(_ data: Data?) throws {
        guard let data else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}

/// Local, per-account ledger of deletions in progress or stopped (RF-03). Nothing here
/// goes to Firestore, so no Rules or model change is involved. Every change is saved
/// before the call returns; a save that fails is thrown to the caller, which must not
/// start a deletion without its record.
@Observable
final class TripDeletionLedger {
    private let storage: any TripDeletionLedgerStorage
    private(set) var recordsByUser: [String: [PendingTripDeletion]] = [:]
    /// Set when the stored file could not be read; the ledger then starts empty and the
    /// next save replaces the file.
    private(set) var loadFailure: String?

    init(storage: any TripDeletionLedgerStorage = FileTripDeletionLedgerStorage.default) {
        self.storage = storage
        load()
    }

    func records(for uid: String) -> [PendingTripDeletion] {
        (recordsByUser[uid] ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    func record(_ record: PendingTripDeletion, uid: String) throws {
        var records = recordsByUser[uid] ?? []
        if let index = records.firstIndex(where: { $0.tripID == record.tripID }) {
            records[index] = record
        } else {
            records.append(record)
        }
        var updated = recordsByUser
        updated[uid] = records
        try save(updated)
        recordsByUser = updated
    }

    func remove(tripID: String, uid: String) throws {
        guard var records = recordsByUser[uid] else { return }
        records.removeAll { $0.tripID == tripID }
        var updated = recordsByUser
        updated[uid] = records.isEmpty ? nil : records
        try save(updated)
        recordsByUser = updated
    }

    private func load() {
        do {
            guard let data = try storage.load() else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            recordsByUser = try decoder.decode([String: [PendingTripDeletion]].self, from: data)
        } catch {
            loadFailure = String(describing: error)
        }
    }

    private func save(_ records: [String: [PendingTripDeletion]]) throws {
        if records.isEmpty {
            try storage.save(nil)
        } else {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try storage.save(try encoder.encode(records))
        }
    }
}
