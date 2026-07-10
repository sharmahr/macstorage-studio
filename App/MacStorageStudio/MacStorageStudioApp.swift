import SwiftUI

@main
struct MacStorageStudioApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Start Scan") {
                    Task { await appModel.startScan() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                Button("Cancel Scan") {
                    Task { await appModel.cancelScan() }
                }
                .keyboardShortcut(".", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}
