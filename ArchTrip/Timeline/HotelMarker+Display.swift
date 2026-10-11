import Foundation

/// What a derived marker row shows from its source stay (G6-UX-05-RF-Display-01). Each
/// value is read from the canonical hotel Event when the row is drawn, so an edit of the
/// stay, or a cleared field, shows on the check-in and the check-out marker at once;
/// nothing is copied into another document or stored anywhere.
extension HotelMarker {
    /// A note preview is at most this many lines and characters. The full note stays in
    /// the stay's editor, which the marker opens.
    static let notePreviewMaxLines = 2
    static let notePreviewMaxCharacters = 100

    /// The stay's location, whole, or nil when it is blank: the row then has no location
    /// line rather than a placeholder.
    var locationName: String? {
        let trimmed = event.locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A short preview of the stay's note, or nil when it is blank.
    var notePreview: String? { Self.notePreview(of: event.note) }

    /// The first non-blank lines of `note`, up to `notePreviewMaxLines` and
    /// `notePreviewMaxCharacters`, ending in an ellipsis when anything was left out. Cuts
    /// fall on character boundaries, so Japanese text and emoji are never split. The text
    /// is shown as entered: nothing in it is parsed or interpreted.
    static func notePreview(of note: String) -> String? {
        let lines = note
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let kept = lines.prefix(notePreviewMaxLines).joined(separator: "\n")
        guard lines.count > notePreviewMaxLines || kept.count > notePreviewMaxCharacters else { return kept }
        return kept.prefix(notePreviewMaxCharacters).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
