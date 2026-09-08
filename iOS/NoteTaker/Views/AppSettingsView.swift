import SwiftUI

struct AppSettingsView: View {
    let model: LibraryAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Settings", selection: $model.settingsSection) {
                    ForEach(AppSettingsSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .accessibilityIdentifier("settings-sections")

                switch model.settingsSection {
                case .ai:
                    AISettingsView(configuration: model.aiConfiguration)
                case .sync:
                    SyncSettingsView(settings: model.settings, sync: model.sync,
                                     library: model.library, embedded: true)
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 600, height: 740)
        #endif
    }
}
