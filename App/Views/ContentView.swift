import SwiftUI
import SlipCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var inspectorVisible: Bool = true

    var body: some View {
        Group {
            if appState.vault == nil {
                VaultPickerView()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                } detail: {
                    NoteEditorView()
                        .inspector(isPresented: $inspectorVisible) {
                            InspectorView()
                        }
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                        // Attach these to the detail column's toolbar so
                        // `.primaryAction` lands on the top-right of the
                        // window, not inside the sidebar's toolbar area.
                        .toolbar {
                            ToolbarItemGroup(placement: .primaryAction) {
                                Button {
                                    appState.requestInsertLink()
                                } label: {
                                    Image(systemName: "link")
                                }
                                .keyboardShortcut("k")
                                .disabled(appState.currentNoteID == nil)
                                .help("Insert Link to Another Note (⌘K)")

                                Button {
                                    openWindow(id: "graph")
                                } label: {
                                    Image(systemName: "point.3.connected.trianglepath.dotted")
                                }
                                .help("Show Graph (⇧⌘G)")

                                Button {
                                    inspectorVisible.toggle()
                                } label: {
                                    Image(systemName: "sidebar.right")
                                }
                                .help("Toggle Inspector")
                            }
                        }
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
