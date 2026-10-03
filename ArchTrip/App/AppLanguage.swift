import Foundation

/// In-app language choice, persisted in UserDefaults. Japanese by default,
/// independent of the device language.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case japanese = "ja"
    case english = "en"

    static let storageKey = "appLanguage"
    static let `default`: AppLanguage = .japanese

    var id: String { rawValue }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Shown in its own language so it is recognizable whatever is selected.
    var nativeName: String {
        switch self {
        case .japanese: "日本語"
        case .english: "English"
        }
    }
}
