import SwiftUI
import AppKit
import MacStorageCore

struct AccessPermissionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var installMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("Full Disk Access is required for a complete scan. macOS will not show this app in the list until you add it with the + button.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Storage Access")
                }

                Section {
                    LabeledContent("Full Disk Access") {
                        Text(model.hasFullDiskAccess ? "Granted" : "Not granted")
                            .foregroundStyle(model.hasFullDiskAccess ? Color.secondary : Color.orange)
                    }
                    LabeledContent("Install location") {
                        Text(AccessController.shared.applicationsInstallURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } header: {
                    Text("Status")
                }

                Section {
                    Text("The Full Disk Access list never auto-fills for this app. You must add it:")
                        .foregroundStyle(.secondary)
                    Text("1. Click “Install to Applications & Open Settings”.\n2. In Full Disk Access, click + (bottom left).\n3. In the file dialog, go to Applications and choose “MacStorage Studio”.\n4. Turn the switch ON.\n5. Click Recheck below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Add with +")
                } footer: {
                    Text("Apps such as Chrome appear because they were added earlier or shipped signed. MacStorage Studio must be added manually with +.")
                }

                Section {
                    Button("Install to Applications & Open Settings") {
                        model.allowAllAccess = true
                        AccessController.shared.allowAllAccess = true
                        AccessController.shared.hasSeenOnboarding = true
                        do {
                            let url = try AccessController.shared.installToApplications()
                            installMessage = "Installed to \(url.path). Use + and select MacStorage Studio."
                            AccessController.shared.registerWithTCC()
                            model.refreshAccessState()
                            AccessController.shared.openFullDiskAccessSettings()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        } catch {
                            installMessage = error.localizedDescription
                            model.enableAllowAllAccess()
                        }
                    }

                    Button("Recheck Full Disk Access") {
                        model.probeFullDiskAccess()
                        if model.hasFullDiskAccess {
                            model.statusMessage = "Full Disk Access granted"
                            AccessController.shared.hasSeenOnboarding = true
                            model.showAccessSheet = false
                            dismiss()
                        } else {
                            installMessage = "Still not granted. Click + in Full Disk Access and select MacStorage Studio from Applications."
                        }
                    }

                    Button("Show App in Finder") {
                        AccessController.shared.revealAppInFinder()
                    }

                    Button("Open Full Disk Access Settings…") {
                        model.openFullDiskAccessSettings()
                    }

                    if let installMessage {
                        Text(installMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Actions")
                }

                Section {
                    Button("Scan Home Folder Only") {
                        Task {
                            await model.startLimitedScan()
                            dismiss()
                        }
                    }
                } header: {
                    Text("Without Full Disk Access")
                } footer: {
                    Text("Limited scan of your home folder. Some protected folders will be skipped.")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Not Now") {
                    AccessController.shared.hasSeenOnboarding = true
                    model.showAccessSheet = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 500, height: 580)
        .onAppear {
            model.refreshAccessState()
            AccessController.shared.registerWithTCC()
            model.refreshAccessState()
        }
    }
}
