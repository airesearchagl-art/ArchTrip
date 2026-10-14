import FirebaseFirestore
import Foundation

nonisolated enum TravelPointUpdateError: Error, Equatable {
    /// The setting is over this version's bound, empty or unreadable: nothing is sent.
    case notWritable
}

/// The fields of a travel point update: `travelPoint` (its map, or a deletion) and
/// `updatedAt`, nothing else. The rest of the Event (title, dates, location, note,
/// Building link, all-day and clock fields, `createdAt`) is not sent, so whatever
/// another screen or device wrote to it is left as it is. The server merges the two
/// fields into the stored document and validates the result as a whole (the rules).
///
/// `updatedAt` changes so that an open travel screen's `TravelRequestKey` no longer
/// matches and its old result is shown as stale; no result is ever stored.
nonisolated enum TravelPointUpdate {
    static let fieldName = "travelPoint"
    static let updatedAtField = "updatedAt"

    static func fields(setting: TravelPointSetting?, createdAt: Date, now: Date = Date()) throws -> [String: Any] {
        var fields: [String: Any] = [updatedAtField: Timestamp(date: max(now, createdAt))]
        if let setting {
            guard setting.isWritable, let value = setting.documentValue else { throw TravelPointUpdateError.notWritable }
            fields[fieldName] = value
        } else {
            fields[fieldName] = FieldValue.delete()
        }
        return fields
    }
}
