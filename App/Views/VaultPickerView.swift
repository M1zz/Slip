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

            VStack(spacing: 10) {
                if Self.iCloudDriveAvailable() {
                    Button {
                        if let url = Self.prepareICloudVault() {
                            appState.openVault(at: url)
                        }
                    } label: {
                        Label("Use iCloud Drive (Sync Across Macs)", systemImage: "icloud")
                            .frame(minWidth: 260)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }

                Button {
                    Self.chooseVault { url in
                        appState.openVault(at: url)
                    }
                } label: {
                    Text("Choose Another Folder…")
                        .frame(minWidth: 260)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
            }

            if Self.iCloudDriveAvailable() {
                Text("iCloud Drive keeps your notes synced on every Mac signed in to the same Apple ID.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
            }
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

    /// Path to the user's iCloud Drive root if it exists locally.
    /// We use the well-known `Mobile Documents/com~apple~CloudDocs` path
    /// rather than `URLForUbiquityContainerIdentifier:` because the
    /// latter requires an iCloud entitlement and a configured container,
    /// while we just want a folder under iCloud Drive that the OS will
    /// sync on its own.
    private static func iCloudDriveRoot() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        return url
    }

    static func iCloudDriveAvailable() -> Bool {
        iCloudDriveRoot() != nil
    }

    /// Ensures `~/Library/Mobile Documents/com~apple~CloudDocs/Slip/`
    /// exists and returns it. Same path on every Mac, so launching the
    /// app on a second machine and clicking the iCloud button lands in
    /// the same vault that's already syncing down.
    static func prepareICloudVault() -> URL? {
        guard let root = iCloudDriveRoot() else { return nil }
        let vault = root.appendingPathComponent("Slip", isDirectory: true)
        if !FileManager.default.fileExists(atPath: vault.path) {
            do {
                try FileManager.default.createDirectory(
                    at: vault,
                    withIntermediateDirectories: true
                )
            } catch {
                NSLog("[Slip] failed to create iCloud vault: \(error)")
                return nil
            }
        }
        return vault
    }
}
