import FirebaseFirestore
import Foundation

/// A model stored as one Firestore document: written whole on create, field by field on update.
nonisolated protocol FirestoreDocument: Encodable {
    /// Fields omitted from the document when nil (`Firestore.Encoder` skips nil). An update
    /// deletes them when absent so the stored document keeps matching the model.
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
nonisolated enum DocumentUpdate {
    static let immutableField = "createdAt"

    static func fields<Document: FirestoreDocument>(for document: Document) throws -> [String: Any] {
        var fields = try Firestore.Encoder().encode(document)
        fields.removeValue(forKey: immutableField)
        for field in Document.optionalFields where fields[field] == nil {
            fields[field] = FieldValue.delete()
        }
        return fields
    }
}
