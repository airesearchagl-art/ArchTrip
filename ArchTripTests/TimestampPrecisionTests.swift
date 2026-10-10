import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// RF-01 root cause, client side. Firestore stores timestamps at microsecond precision.
/// `Timestamp.dateValue()` turns that into a `Double`, which at today's magnitudes is only
/// accurate to about ±119 ns, and `Timestamp(date:)` truncates the fraction. A stored
/// `createdAt` decoded to a `Date` therefore re-encodes a few nanoseconds off; when that
/// lands in the previous microsecond (about half of all values) the server, which
/// compares at microsecond precision, sees a changed `createdAt` and rejects the update.
/// Updates must not resend it (see `DocumentUpdate`).
struct TimestampPrecisionTests {
    private let seconds: Int64 = 1_790_000_000

    private func microseconds(of timestamp: Timestamp) -> Int64 {
        timestamp.seconds * 1_000_000 + Int64(timestamp.nanoseconds / 1_000)
    }

    @Test func wholeSecondsSurviveTheDateRoundTrip() {
        let whole = Timestamp(seconds: seconds, nanoseconds: 0)
        #expect(Timestamp(date: whole.dateValue()) == whole)
    }

    @Test func microsecondTimestampsMostlyDoNotSurviveTheDateRoundTrip() {
        var count = 0
        var changed = 0
        var previousMicrosecond = 0
        var maxDrift: Int32 = 0
        for micros in stride(from: 1, to: 1_000_000, by: 997) {
            count += 1
            let timestamp = Timestamp(seconds: seconds, nanoseconds: Int32(micros * 1_000))
            let resent = Timestamp(date: timestamp.dateValue())
            if resent != timestamp { changed += 1 }
            if microseconds(of: resent) < microseconds(of: timestamp) { previousMicrosecond += 1 }
            maxDrift = max(maxDrift, abs(resent.nanoseconds - timestamp.nanoseconds))
        }
        print("RF01-EVIDENCE Timestamp→Date→Timestamp changed \(changed)/\(count) microsecond values, \(previousMicrosecond)/\(count) land in the previous microsecond, max drift \(maxDrift) ns")
        #expect(changed > count * 9 / 10)
        #expect(previousMicrosecond > count / 4 && previousMicrosecond < count * 3 / 4)
        #expect(maxDrift < 1_000)
    }

    /// The app writes `createdAt = Date()`: sub-microsecond, which the server truncates.
    @Test func dateHasMorePrecisionThanFirestoreKeeps() {
        let sent = Timestamp(date: Date(timeIntervalSince1970: 1_790_000_000.123_456_7))
        #expect(sent.nanoseconds % 1_000 != 0)
    }
}
