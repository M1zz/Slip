import SwiftUI
import SlipCore

@main
struct SlipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Slip") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { appState.createNewNote() }
                    .keyboardShortcut("n")
                Button("Quick Capture…") { appDelegate.showQuickCapture() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Rediscover") {
                Button("Today's Rediscovery") { appState.refreshRediscovery() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
