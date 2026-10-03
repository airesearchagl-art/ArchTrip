import FirebaseFirestore
import Foundation

/// A Firestore document that exists but could not be turned into a model.
/// Surfaced to the UI instead of being silently dropped.
nonisolated struct DecodeFailure: Identifiable, Equatable, Sendable {
    let documentID: String
    let reason: String

    var id: String { documentID }
}

nonisolated struct QueryResult<Item: Sendable>: Sendable {
    var items: [Item]
    var failures: [DecodeFailure]
    var isFromCache: Bool
    var hasPendingWrites: Bool
}

nonisolated enum DocumentDecoding {
    /// Decodes each document independently so one malformed document is reported
    /// as a failure without hiding the others. `validate` returns a reason to reject.
    static func decode<Item: Decodable & Identifiable>(
        _ documents: [(id: String, data: [String: Any])],
        as type: Item.Type,
        validate: (Item) -> String? = { _ in nil }
    ) -> (items: [Item], failures: [DecodeFailure]) where Item.ID == String {
        let decoder = Firestore.Decoder()
        var items: [Item] = []
        var failures: [DecodeFailure] = []
        for document in documents {
            do {
                let item = try decoder.decode(Item.self, from: document.data)
                if item.id != document.id {
                    failures.append(DecodeFailure(documentID: document.id, reason: "id field does not match document ID"))
                } else if let reason = validate(item) {
                    failures.append(DecodeFailure(documentID: document.id, reason: reason))
                } else {
                    items.append(item)
                }
            } catch {
                failures.append(DecodeFailure(documentID: document.id, reason: String(describing: error)))
            }
        }
        return (items, failures)
    }
}
