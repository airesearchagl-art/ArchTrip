import Foundation

/// The stored travel point of an Event (travel MVP): what the user chose as the place to
/// route from or to for this Event, reused by every travel search the Event appears in.
/// Read in three forms, written in two. Never a name, an address or coordinates from
/// Apple Maps, never a route, a travel time, a mode or an anchor time.
///
/// It is read with the Event (`Event.travelPoint`) but written only by its own two-field
/// update (`TravelPointUpdate`): the Event's encoding leaves it out, so the editor's
/// whole-model update neither resends nor deletes it.
nonisolated enum TravelPointSetting: Hashable, Sendable {
    /// `{kind: "place", placeId}`: the Apple Maps Place ID of the result the user picked,
    /// kept exactly as MapKit gave it. The place is fetched from it when shown.
    case place(id: String)
    /// `{kind: "query", query}`: the search text the user typed, for a result without an
    /// ID. Restored into the search field next time; the user picks a result again.
    case query(String)
    /// The document holds a `travelPoint` that is neither shape (not a map, unknown or
    /// missing kind, wrong type, empty value, unexpected keys). The Event itself still
    /// reads and shows; the value is never written back, only cleared or replaced.
    case unreadable(reason: String)

    /// This project's write-time bounds, not an Apple format: checked when a result is
    /// picked and by `firebase/firestore.rules`, never when reading, so a stored value
    /// beyond them still reads (it is shown, and refused only when saving).
    static let placeIdMaxLength = 128
    static let queryMaxLength = 200

    static let kindKey = "kind"
    static let placeIdKey = "placeId"
    static let queryKey = "query"

    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }

    /// Longer than this version's bound: read and shown, but not re-saved, and an Event
    /// carrying it cannot be saved by the editor until the setting is cleared.
    var exceedsWriteLimit: Bool {
        switch self {
        case .place(let id): id.count > Self.placeIdMaxLength
        case .query(let text): text.count > Self.queryMaxLength
        case .unreadable: false
        }
    }

    /// Whether this version may write the setting (the rules enforce the same shape).
    var isWritable: Bool {
        switch self {
        case .place(let id): !id.isEmpty && !exceedsWriteLimit
        case .query(let text): !text.isEmpty && !exceedsWriteLimit
        case .unreadable: false
        }
    }

    /// The document map, for `place` and `query` only: `kind` plus exactly one value.
    var documentValue: [String: String]? {
        switch self {
        case .place(let id): [Self.kindKey: "place", Self.placeIdKey: id]
        case .query(let text): [Self.kindKey: "query", Self.queryKey: text]
        case .unreadable: nil
        }
    }
}

extension TravelPointSetting: Codable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ name: String) {
            stringValue = name
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    /// Never throws: whatever the document holds, the Event decodes. A value that is not
    /// one of the two shapes becomes `.unreadable` with a short developer reason (no
    /// stored value is copied into it).
    init(from decoder: Decoder) {
        guard let container = try? decoder.container(keyedBy: Key.self) else {
            self = .unreadable(reason: "not a map")
            return
        }
        let keys = Set(container.allKeys.map(\.stringValue))
        guard let kind = try? container.decode(String.self, forKey: Key(Self.kindKey)) else {
            self = .unreadable(reason: keys.contains(Self.kindKey) ? "kind is not a string" : "missing kind")
            return
        }
        switch kind {
        case "place":
            guard keys.isSubset(of: [Self.kindKey, Self.placeIdKey]) else {
                self = .unreadable(reason: "unexpected keys")
                return
            }
            guard let id = try? container.decode(String.self, forKey: Key(Self.placeIdKey)), !id.isEmpty else {
                self = .unreadable(reason: "invalid placeId")
                return
            }
            self = .place(id: id)
        case "query":
            guard keys.isSubset(of: [Self.kindKey, Self.queryKey]) else {
                self = .unreadable(reason: "unexpected keys")
                return
            }
            guard let text = try? container.decode(String.self, forKey: Key(Self.queryKey)), !text.isEmpty else {
                self = .unreadable(reason: "invalid query")
                return
            }
            self = .query(text)
        default:
            self = .unreadable(reason: "unknown kind")
        }
    }

    /// `place` and `query` encode as their map; `unreadable` refuses, so nothing can
    /// write a value it could not read back to the document.
    func encode(to encoder: Encoder) throws {
        guard let value = documentValue else {
            throw EncodingError.invalidValue(self, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "an unreadable travel point is never written"))
        }
        var container = encoder.container(keyedBy: Key.self)
        for (key, string) in value.sorted(by: { $0.key < $1.key }) {
            try container.encode(string, forKey: Key(key))
        }
    }
}
