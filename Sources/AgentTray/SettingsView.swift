import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: StatsStore
    @ObservedObject var settings: AppSettings
    @State private var providerID = ""
    @State private var providerName = ""

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Refresh interval", value: "Every minute")

                Toggle("Launch Agent Tray at login", isOn: Binding(
                    get: { settings.launchAtLoginEnabled },
                    set: { settings.setLaunchAtLogin($0) }
                ))

                if let error = settings.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Profiles") {
                ForEach(Array(store.allProfiles.enumerated()), id: \.element.id) { index, profile in
                    profileRow(profile, at: index)
                }
            }

            Section("Add Codex provider") {
                TextField("Provider ID", text: $providerID, prompt: Text("azure"))
                TextField("Display name", text: $providerName, prompt: Text("Codex Azure"))
                Button("Add provider") {
                    settings.addManualProvider(id: providerID, displayName: providerName)
                    providerID = ""
                    providerName = ""
                    store.reloadProfiles()
                }
                .disabled(providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section {
                Text("Agent Tray reads usage metadata from local agent files and the Codex app server. It does not store prompts, responses, or credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 520)
        .padding()
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
            store.reloadProfiles()
        }
    }

    private func profileRow(_ profile: AgentProfile, at index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: profile.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            TextField("Profile name", text: Binding(
                get: { settings.preference(for: profile).displayName },
                set: {
                    settings.updateProfile(id: profile.id, displayName: $0)
                    store.reloadProfiles()
                }
            ))

            Button {
                settings.movePreference(id: profile.id, offset: -1, profiles: store.allProfiles)
                store.reloadProfiles()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move profile up")

            Button {
                settings.movePreference(id: profile.id, offset: 1, profiles: store.allProfiles)
                store.reloadProfiles()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == store.allProfiles.count - 1)
            .help("Move profile down")

            Toggle("Show \(profile.displayName)", isOn: Binding(
                get: { settings.preference(for: profile).isEnabled },
                set: {
                    settings.updateProfile(id: profile.id, isEnabled: $0)
                    store.reloadProfiles()
                }
            ))
            .labelsHidden()
        }
    }
}
