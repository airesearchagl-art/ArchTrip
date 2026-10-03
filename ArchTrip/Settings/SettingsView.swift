import SwiftUI

struct SettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.default
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: $language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(verbatim: language.nativeName).tag(language)
                        }
                    }
                }
                Section("Developer") {
                    NavigationLink("Developer Diagnostics") {
                        SyncDiagnosticsView()
                    }
                }
                Section {
                    LabeledContent("Version") {
                        Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
