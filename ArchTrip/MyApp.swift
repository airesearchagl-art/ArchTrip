import SwiftUI

@main struct MyApp: App {
    @State private var model: SyncSpikeModel

    init() {
        let model = SyncSpikeModel()
        model.start(firebaseConfigured: FirebaseBootstrap.configureIfAvailable())
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
