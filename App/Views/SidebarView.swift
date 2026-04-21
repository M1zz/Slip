import SwiftUI
import SlipCore

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    private var displayed: [NoteID] {
        appState.searchQuery.isEmpty ? appState.noteList : appState.searchResults
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $appState.searchQuery)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5))
            .cornerRadius(8)
            .padding(12)

            List(selection: Binding(
                get: { appState.currentNoteID },
                set: { if let id = $0 { appState.openNote(id) } }
            )) {
                ForEach(displayed, id: \.self) { id in
                    NoteRow(id: id, title: appState.titleByID[id] ?? id.relativePath)
                        .tag(id)
                }
            }
            .listStyle(.sidebar)
        }
        .toolbar {
            ToolbarItem {
                Button(action: { appState.createNewNote() }) {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Note (⌘N)")
            }
        }
    }
}

private struct NoteRow: View {
    let id: NoteID
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(title)
                .lineLimit(1)
        }
    }
}
