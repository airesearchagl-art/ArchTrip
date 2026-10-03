import SwiftUI

@main struct ArchTripApp: App {
    @State private var session: AppSession
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.default

    init() {
        let session = AppSession()
        session.start(firebaseConfigured: FirebaseBootstrap.configureIfAvailable())
        _session = State(initialValue: session)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(\.locale, language.locale)
        }
    }
}
