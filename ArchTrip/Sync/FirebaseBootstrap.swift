import FirebaseCore
import FirebaseFirestore
import Foundation

enum FirebaseBootstrap {
    /// Configures Firebase only when GoogleService-Info.plist is bundled,
    /// so the app still launches (showing "not configured") without it.
    static func configureIfAvailable() -> Bool {
        if FirebaseApp.app() != nil { return true }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            return false
        }
        FirebaseApp.configure()

        // Must be set before any other Firestore call.
        let settings = Firestore.firestore().settings
        settings.cacheSettings = PersistentCacheSettings()
        Firestore.firestore().settings = settings
        return true
    }
}
