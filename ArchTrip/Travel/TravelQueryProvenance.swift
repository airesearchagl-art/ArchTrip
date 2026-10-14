import Foundation

/// Where the travel picker's search field got its initial text. The search field is for
/// searching only; what may be saved as a travel point's `query` is decided from this
/// provenance, never from the field's content alone (text being in the field does not
/// make it the user's).
nonisolated enum TravelQuerySource: Hashable, Sendable {
    /// Empty field.
    case empty
    /// Text the user typed into the app elsewhere: the Event's location or its Building's
    /// name. The user's own words, so an edit of it stays theirs.
    case appText(String)
    /// The name or address of an Apple Maps result picked for this search only. Apple's
    /// text, not the user's: it is never saved, edited or not.
    case candidate(String)
    /// The Event's stored `travelPoint.query`, restored for a new search.
    case saved(String)

    var text: String {
        switch self {
        case .empty: ""
        case .appText(let text), .candidate(let text), .saved(let text): text
        }
    }
}

/// Why a picked result is used for this search only and not saved.
nonisolated enum TravelPickReason: Hashable, Sendable {
    /// No ID and no search text to save (auto-filled only, or the user chose not to save).
    case notSaved
    /// The result's ID is longer than this version's bound (R4): routable, not stored.
    case identifierTooLong
}

/// What the picker hands back with the chosen result: the only three things that can
/// happen to the Event's travel point. There is no case carrying the result's name,
/// address or coordinates.
nonisolated enum TravelPickOutcome: Hashable, Sendable {
    case savePlace(id: String)
    case saveQuery(String)
    case thisSearchOnly(TravelPickReason)
}

/// Pure rules of the travel picker: which results save their ID, and what the separate
/// "search text to save" field starts with when a result without an ID is picked.
nonisolated enum TravelQueryProvenance {
    enum Issue: Equatable, Sendable {
        case empty
        case tooLong
    }

    /// The outcome decided by the result's ID alone, or nil when the result has no ID and
    /// the user must say what search text, if any, to save.
    static func outcome(for result: PlaceResult) -> TravelPickOutcome? {
        guard let identifier = result.identifier, !identifier.isEmpty else { return nil }
        return identifier.count <= TravelPointSetting.placeIdMaxLength
            ? .savePlace(id: identifier)
            : .thisSearchOnly(.identifierTooLong)
    }

    /// The initial content of the "search text to save" field: the user's own text only.
    /// An app text left as it was, and an Apple result's text however much it was edited,
    /// give an empty field; the user types there to save anything.
    static func prefill(source: TravelQuerySource, searchText: String) -> String {
        let typed = trimmed(searchText)
        switch source {
        case .empty, .saved:
            return typed
        case .appText(let hint):
            return typed == trimmed(hint) ? "" : typed
        case .candidate:
            return ""
        }
    }

    /// Why the field's content cannot be saved, or nil when it can.
    static func issue(_ text: String) -> Issue? {
        let value = trimmed(text)
        if value.isEmpty { return .empty }
        return value.count > TravelPointSetting.queryMaxLength ? .tooLong : nil
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
