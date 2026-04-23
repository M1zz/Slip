import SwiftUI
import SlipCore

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var tagsExpanded: Bool = true

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
                Section(notesSectionTitle) {
                    ForEach(displayed, id: \.self) { id in
                        NoteRow(id: id, title: appState.titleByID[id] ?? id.relativePath)
                            .tag(id)
                    }
                }

                if !appState.tags.isEmpty {
                    Section(isExpanded: $tagsExpanded) {
                        TagRow(
                            label: "All Notes",
                            count: nil,
                            isSelected: appState.selectedTag == nil,
                            systemImage: "tray.full"
                        ) {
                            appState.selectedTag = nil
                        }
                        ForEach(appState.tags, id: \.tag) { tc in
                            TagRow(
                                label: "#\(tc.tag)",
                                count: tc.count,
                                isSelected: appState.selectedTag == tc.tag,
                                systemImage: "tag"
                            ) {
                                appState.selectedTag = tc.tag
                            }
                        }
                    } header: {
                        Text("Tags")
                    }
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

    private var notesSectionTitle: String {
        if let tag = appState.selectedTag {
            return "Notes · #\(tag)"
        }
        return "Notes"
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

private struct TagRow: View {
    let label: String
    let count: Int?
    let isSelected: Bool
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.caption)
                Text(label)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Spacer()
                if let count {
                    Text("\(count)")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
