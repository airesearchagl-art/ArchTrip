import Foundation
import Observation

/// The save state of travel point writes, per Event, decided by the server's reply and
/// never by the local cache: a write is "syncing" from the moment it is sent, "saved"
/// on the server's acknowledgement and "failed" on its rejection. Each write carries a
/// token from a never-reused sequence and only the latest write of an Event can change
/// its state, so a late reply to an earlier write never overwrites what a newer
/// operation shows. The setting itself is always what the listener delivers.
@Observable
final class TravelPointWriteTracker {
    enum Status: Equatable, Sendable {
        case syncing
        case saved
        case failed
    }

    struct Entry: Equatable, Sendable {
        let token: Int
        var status: Status
    }

    private(set) var entries: [String: Entry] = [:]
    private var sequence = 0

    /// Registers a write that is being sent and returns its token.
    func begin(eventID: String) -> Int {
        sequence += 1
        entries[eventID] = Entry(token: sequence, status: .syncing)
        return sequence
    }

    /// Applies the server's reply to the write with `token`, if it is still the Event's
    /// latest write; otherwise nothing changes.
    func finish(eventID: String, token: Int, error: Error?) {
        guard entries[eventID]?.token == token else { return }
        entries[eventID]?.status = error == nil ? .saved : .failed
    }

    func status(for eventID: String) -> Status? {
        entries[eventID]?.status
    }
}
