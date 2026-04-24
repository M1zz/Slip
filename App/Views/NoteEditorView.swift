import SwiftUI
import Combine
import SlipCore

struct NoteEditorView: View {
    @EnvironmentObject var appState: AppState
    @State private var autosave: AnyCancellable?
    @FocusState private var titleFocused: Bool

    var body: some View {
        Group {
            if appState.currentNoteID == nil {
                emptyState
            } else {
                VStack(spacing: 0) {
                    TextField("Title", text: Binding(
                        get: { appState.currentNoteTitle },
                        set: { appState.currentNoteTitle = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .semibold))
                    .focused($titleFocused)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                    .onChange(of: appState.currentNoteTitle) { _, _ in
                        debouncedSave()
                    }
                    Divider()
                    MarkdownTextView(
                        text: Binding(
                            get: { appState.currentNoteBody },
                            set: { newValue in
                                appState.currentNoteBody = newValue
                            }
                        ),
                        titles: { Array(appState.titleByID.values) },
                        insertLinkRequest: appState.insertLinkRequest,
                        onWikilinkClick: { target in
                            openTargetByTitle(target)
                        }
                    )
                    .onChange(of: appState.currentNoteBody) { _, _ in
                        debouncedSave()
                    }
                }
            }
        }
        .onChange(of: appState.currentNoteID) { _, _ in
            // When the editor swaps to a different note, focus the title
            // field if the new note has no title yet (empty new notes) so
            // the user can type straight away.
            if appState.currentNoteID != nil, appState.currentNoteTitle.isEmpty {
                titleFocused = true
            }
        }
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
            .delay(for: .seconds(0.3), scheduler: RunLoop.main)
            .sink { _ in appState.saveCurrentNote() }
    }
}
