import FirebaseFirestore
import Foundation

/// A model stored as one Firestore document: written whole on create, field by field on update.
nonisolated protocol FirestoreDocument: Encodable {
    /// Fields omitted from the document when nil (`Firestore.Encoder` skips nil). An update
    /// deletes them when they were stored and are nil now, so the stored document keeps
    /// matching the model.
    static var optionalFields: [String] { get }
}

/// Fields for updating an existing document with `updateData`.
///
/// `createdAt` is never resent. The rules require it unchanged, and the client cannot
/// resend it faithfully: Firestore keeps microsecond precision, `Date` is a `Double` that
/// is only accurate to about ±119 ns here, and `Timestamp(date:)` truncates. A decoded
/// `createdAt` therefore re-encodes into the previous microsecond about half the time,
/// and the server rejects the update as a `createdAt` change (RF-01; see
/// TimestampPrecisionTests). Left out, the server keeps the value it already has.
///
/// An optional field is deleted only when `previous` (the stored document as loaded) has
/// it and `document` does not. Deleting a field the document never had is harmless on the
/// server, but in the Firestore SDK's local view (12.19.2) a `FieldValue.delete()` of an
/// absent key that sorts before the delete of a present key makes the pending snapshot
/// skip the later delete and drop the document's last fields (`updatedAt`, …), so the
/// model fails to decode until the write is acknowledged. Reproduced offline for clearing
/// a stay's clock time and for converting an all-day Event back to timed; the server
/// applied every write correctly (G6-UX05 offline investigation, 2026-10-11).
nonisolated enum DocumentUpdate {
    static let immutableField = "createdAt"

    static func fields<Document: FirestoreDocument>(
        for document: Document, replacing previous: Document
    ) throws -> [String: Any] {
        var fields = try Firestore.Encoder().encode(document)
        fields.removeValue(forKey: immutableField)
        let stored = try Firestore.Encoder().encode(previous)
        for field in Document.optionalFields where fields[field] == nil && stored[field] != nil {
            fields[field] = FieldValue.delete()
        }
        return fields
    }
}
