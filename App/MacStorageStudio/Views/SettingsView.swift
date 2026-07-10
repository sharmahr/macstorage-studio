import SwiftUI
import AppKit
import MacStorageCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: Binding(
                    get: { model.appearanceMode },
                    set: { model.setAppearance($0) }
                )) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows macOS light/dark. Light and Dark lock the app appearance.")
            }

            Section {
                Text("Scans and metadata stay in a local SQLite database. No telemetry or cloud upload.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }

            Section {
                LabeledContent("Full Disk Access") {
                    Text(model.hasFullDiskAccess ? "Granted" : "Not granted")
                        .foregroundStyle(model.hasFullDiskAccess ? Color.secondary : Color.orange)
                }

                Button("Install to Applications & Open Settings") {
                    model.allowAllAccess = true
                    AccessController.shared.allowAllAccess = true
                    do {
                        let url = try AccessController.shared.installToApplications()
                        note = "Installed to \(url.path). In Full Disk Access click + and choose MacStorage Studio."
                        AccessController.shared.registerWithTCC()
                        model.refreshAccessState()
                        AccessController.shared.openFullDiskAccessSettings()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    } catch {
                        note = error.localizedDescription
                    }
                }

                Button("Recheck Access") {
                    model.probeFullDiskAccess()
                    note = model.hasFullDiskAccess ? "Granted." : "Still not granted — use + in Full Disk Access."
                }

                Button("Show App in Finder") {
                    AccessController.shared.revealAppInFinder()
                }

                Button("Open Full Disk Access Settings…") {
                    model.openFullDiskAccessSettings()
                }

                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Access")
            } footer: {
                Text("The app does not appear in the Full Disk Access list until you add it with +. Install to Applications first, then use + and select MacStorage Studio.")
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
        .frame(width: 520, height: 480)
        .padding()
        .onAppear { model.refreshAccessState() }
    }
}
