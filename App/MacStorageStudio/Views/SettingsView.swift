import SwiftUI
import AppKit
import MacStorageCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Text("Scans and metadata stay in a local SQLite database. No telemetry or cloud upload.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.allowAllAccess },
                    set: { on in
                        if on {
                            model.enableAllowAllAccess()
                        } else {
                            model.disableAllowAllAccess()
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow All Access")
                        Text("Scan every app and volume without individual prompts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Full Disk Access") {
                    Text(model.hasFullDiskAccess ? "Granted" : "Required")
                        .foregroundStyle(model.hasFullDiskAccess ? Color.secondary : Color.orange)
                }

                Button("Open Full Disk Access Settings…") {
                    model.openFullDiskAccessSettings()
                }

                Button("Recheck Access") {
                    model.refreshAccessState()
                    model.roots = AccessController.shared.scanRoots()
                }
            } header: {
                Text("Access")
            } footer: {
                Text("macOS only allows Full Disk Access to be granted in System Settings. Allow All turns on full scan scope and opens those settings once. After enabling the app there, return and press Recheck.")
            }

            Section {
                Text("The scanner runs as a separate process. If it crashes, this window stays open and you can resume.")
                    .foregroundStyle(.secondary)
                Button("Run Isolation Test") {
                    Task { await model.testWorkerCrashIsolation() }
                }
            } header: {
                Text("Scanner")
            }

            Section {
                Text(model.store.databaseURL.path)
                    .font(.caption)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Database")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
        .padding()
        .onAppear { model.refreshAccessState() }
    }
}
