import SwiftUI
import MacStorageCore

/// Single “Allow All Access” flow — no per-app or per-folder prompts.
struct AccessPermissionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Storage Access", systemImage: "lock.shield")
                .font(.title2.bold())

            Text("MacStorage Studio needs access to scan applications and their data. Instead of asking for each app or folder, grant access once.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                bullet("All apps in /Applications and ~/Applications")
                bullet("App support files, caches, and containers")
                bullet("Home folder, Library, and attached volumes")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Allow All") {
                        Text(model.allowAllAccess ? "On" : "Off")
                            .foregroundStyle(model.allowAllAccess ? .primary : .secondary)
                    }
                    LabeledContent("Full Disk Access") {
                        Text(model.hasFullDiskAccess ? "Granted" : "Not granted")
                            .foregroundStyle(model.hasFullDiskAccess ? Color.green : Color.orange)
                    }
                    if model.allowAllAccess && !model.hasFullDiskAccess {
                        Text("In System Settings → Privacy & Security → Full Disk Access, enable MacStorage Studio. If the scanner still cannot read app data, also enable ScannerWorker from the app package (Contents/MacOS). Then click Recheck.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button {
                    model.enableAllowAllAccess()
                } label: {
                    Text("Allow All Access")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                if model.allowAllAccess {
                    Button("Recheck Full Disk Access") {
                        model.refreshAccessState()
                        if model.hasFullDiskAccess {
                            model.statusMessage = "Full Disk Access confirmed"
                            model.showAccessSheet = false
                            dismiss()
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Button("Open Full Disk Access Settings…") {
                        model.openFullDiskAccessSettings()
                    }
                    .frame(maxWidth: .infinity)
                }

                Button("Not Now") {
                    AccessController.shared.hasSeenOnboarding = true
                    model.showAccessSheet = false
                    dismiss()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(24)
        .frame(width: 440, height: 420)
        .onAppear {
            model.refreshAccessState()
        }
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .foregroundStyle(.primary)
    }
}
