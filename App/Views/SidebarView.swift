import SwiftUI
import SlipCore

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var notesExpanded: Bool = true
    @State private var tagsExpanded: Bool = true

    private var displayed: [NoteID] {
        appState.searchQuery.isEmpty ? appState.noteList : appState.searchResults
    }

    /// Folder-aware tree of the currently displayed notes. Folders only
    /// appear if they contain at least one note in the visible set, so a
    /// tag filter or search hides empty branches automatically.
    private var noteTree: [FileTreeNode] {
        Self.buildTree(noteIDs: displayed, titleByID: appState.titleByID)
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
                set: { newValue in
                    guard let id = newValue else { return }
                    Task { @MainActor in appState.openNote(id) }
                }
            )) {
                Section(isExpanded: $notesExpanded) {
                    OutlineGroup(noteTree, id: \.id, children: \.children) { node in
                        switch node.kind {
                        case .folder(let name):
                            FolderRow(name: name)
                        case .note(let id, let title):
                            NoteRow(id: id, title: title).tag(id)
                        }
                    }
                } header: {
                    Text(notesSectionTitle)
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

    /// Build a folder/file tree from the flat list of note IDs. The
    /// algorithm walks each note's relative path component-by-component,
    /// lazily creating intermediate folder branches in a temporary tree
    /// and then renders that into a sorted, recursive `FileTreeNode` list.
    static func buildTree(noteIDs: [NoteID], titleByID: [NoteID: String]) -> [FileTreeNode] {
        final class Branch {
            var subFolders: [String: Branch] = [:]
            var notes: [(id: NoteID, title: String)] = []
        }

        let root = Branch()
        for id in noteIDs {
            let parts = id.relativePath.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var current = root
            for folder in parts.dropLast() {
                if let next = current.subFolders[folder] {
                    current = next
                } else {
                    let next = Branch()
                    current.subFolders[folder] = next
                    current = next
                }
            }
            let title = titleByID[id] ?? id.relativePath
            current.notes.append((id, title))
        }

        func render(_ branch: Branch, parentPath: String) -> [FileTreeNode] {
            var nodes: [FileTreeNode] = []
            // Folders first, alphabetically.
            for (name, sub) in branch.subFolders.sorted(by: {
                $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }) {
                let fullPath = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
                let children = render(sub, parentPath: fullPath)
                nodes.append(.folder(name: name, path: fullPath, children: children))
            }
            // Notes after, by title.
            for (id, title) in branch.notes.sorted(by: {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }) {
                nodes.append(.note(id: id, title: title))
            }
            return nodes
        }

        return render(root, parentPath: "")
    }
}

// MARK: - Tree model

struct FileTreeNode: Identifiable {
    let id: String
    let kind: Kind
    /// `nil` for notes (so OutlineGroup doesn't render a disclosure
    /// triangle), an array (possibly empty) for folders.
    let children: [FileTreeNode]?

    enum Kind {
        case folder(name: String)
        case note(id: NoteID, title: String)
    }

    static func folder(name: String, path: String, children: [FileTreeNode]) -> FileTreeNode {
        FileTreeNode(id: "f:\(path)", kind: .folder(name: name), children: children)
    }

    static func note(id: NoteID, title: String) -> FileTreeNode {
        FileTreeNode(id: "n:\(id.relativePath)", kind: .note(id: id, title: title), children: nil)
    }
}

// MARK: - Rows

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

private struct FolderRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(name)
                .fontWeight(.medium)
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
