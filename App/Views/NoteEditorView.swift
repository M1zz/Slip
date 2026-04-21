import SwiftUI
import Combine
import SlipCore

struct NoteEditorView: View {
    @EnvironmentObject var appState: AppState
    @State private var autosave: AnyCancellable?

    var body: some View {
        Group {
            if appState.currentNoteID == nil {
                emptyState
            } else {
                MarkdownTextView(
                    text: Binding(
                        get: { appState.currentNoteBody },
                        set: { newValue in
                            appState.currentNoteBody = newValue
                        }
                    ),
                    titles: { Array(appState.titleByID.values) },
                    onWikilinkClick: { target in
                        openTargetByTitle(target)
                    }
                )
                .onChange(of: appState.currentNoteBody) { _, _ in
                    debouncedSave()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(currentTitle)
                    .font(.headline)
            }
        }
    }

    private var currentTitle: String {
        guard let id = appState.currentNoteID else { return "" }
        return appState.titleByID[id] ?? id.relativePath
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.append")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No note selected")
                .foregroundStyle(.secondary)
            Text("Create one with ⌘N, or capture a thought with ⌥⌘Space.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openTargetByTitle(_ title: String) {
        let match = appState.titleByID.first { $0.value.caseInsensitiveCompare(title) == .orderedSame }
        if let match {
            appState.openNote(match.key)
        }
        // If no match, we could offer "Create note titled X" — left for v2.
    }

    private func debouncedSave() {
        autosave?.cancel()
        autosave = Just(())
            .delay(for: .seconds(0.8), scheduler: RunLoop.main)
            .sink { _ in appState.saveCurrentNote() }
    }
}
