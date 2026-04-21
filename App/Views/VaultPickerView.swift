import SwiftUI
import AppKit

struct VaultPickerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Welcome to Slip")
                .font(.largeTitle)
                .fontWeight(.semibold)
            Text("Pick a folder to keep your notes in.\nSlip reads and writes plain Markdown files — your data stays yours.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                Self.chooseVault { url in
                    appState.openVault(at: url)
                }
            } label: {
                Text("Choose Notes Folder")
                    .frame(minWidth: 180)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func chooseVault(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder containing your markdown notes."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }
}
