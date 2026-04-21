import SwiftUI
import SlipCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.vault == nil {
                VaultPickerView()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                } content: {
                    NoteEditorView()
                        .navigationSplitViewColumnWidth(min: 400, ideal: 640)
                } detail: {
                    InspectorView()
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
                }
            }
        }
        .onAppear {
            if appState.vault == nil {
                appState.restoreVault()
            }
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RediscoveryView()
                .frame(maxHeight: .infinity)
            Divider()
            BacklinksView()
                .frame(maxHeight: .infinity)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Notes Folder") {
                if let vault = appState.vault {
                    LabeledContent("Location", value: vault.root.path)
                        .textSelection(.enabled)
                }
                Button("Choose different folder…") {
                    VaultPickerView.chooseVault { url in
                        appState.openVault(at: url)
                    }
                }
            }
            Section("Quick Capture") {
                LabeledContent("Hotkey", value: "⌥⌘Space")
                Text("Customizable hotkey coming in v0.2.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 280)
    }
}
