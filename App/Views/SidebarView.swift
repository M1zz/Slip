import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SlipCore

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var notesExpanded: Bool = true
    @State private var tagsExpanded: Bool = true
    @State private var newFolderPrompt: NewFolderPrompt? = nil

    private var displayed: [NoteID] {
        appState.searchQuery.isEmpty ? appState.noteList : appState.searchResults
    }

    private var noteTree: [FileTreeNode] {
        Self.buildTree(
            noteIDs: displayed,
            titleByID: appState.titleByID,
            folders: appState.allFolders
        )
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
                        rowView(for: node)
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
            ToolbarItemGroup {
                Button(action: { appState.createNewNote() }) {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Note (⌘N)")

                Button {
                    newFolderPrompt = NewFolderPrompt(parent: "")
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("New Folder")
            }
        }
        .sheet(item: $newFolderPrompt) { prompt in
            NewFolderSheet(parent: prompt.parent) { name in
                appState.createFolder(name: name, in: prompt.parent)
            }
        }
    }


    @ViewBuilder
    private func rowView(for node: FileTreeNode) -> some View {
        switch node.kind {
        case .folder(let name, let path):
            FolderDropZone(name: name) { providers in
                handleDrop(providers: providers, into: path)
            }
            .contextMenu {
                Button("New Note Here") {
                    Task { @MainActor in appState.createNewNote(in: path) }
                }
                Button("New Subfolder…") {
                    newFolderPrompt = NewFolderPrompt(parent: path)
                }
            }
        case .note(let id, let title):
            Button {
                Task { @MainActor in appState.openNote(id) }
            } label: {
                NoteRow(id: id, title: title)
            }
            .buttonStyle(.plain)
            .tag(id)
            .contextMenu {
                Menu("Move to") {
                    Button("Vault Root") {
                        Task { @MainActor in appState.moveNote(id, toFolder: "") }
                    }
                    if !appState.allFolders.isEmpty {
                        Divider()
                        ForEach(appState.allFolders, id: \.self) { folder in
                            Button(folder) {
                                Task { @MainActor in
                                    appState.moveNote(id, toFolder: folder)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button {
                    NSLog("[Slip] context menu: deleting '\(title)' (id=\(id.relativePath))")
                    let target = id
                    // Defer the actual delete one runloop tick so SwiftUI
                    // can fully dismiss the context menu first; otherwise
                    // the file-system mutation can race with the still-
                    // animating menu and the row appears not to update.
                    DispatchQueue.main.async {
                        appState.deleteNote(target)
                    }
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
            .onDrag {
                NSItemProvider(object: id.relativePath as NSString)
            } preview: {
                NoteDragPreview(title: title)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider], into folderPath: String) -> Bool {
        var handled = false
        for provider in providers {
            guard provider.canLoadObject(ofClass: NSString.self) else { continue }
            handled = true
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let s = object as? NSString else { return }
                let id = NoteID(relativePath: s as String)
                Task { @MainActor in
                    appState.moveNote(id, toFolder: folderPath)
                }
            }
        }
        return handled
    }

    private var notesSectionTitle: String {
        if let tag = appState.selectedTag {
            return "Notes · #\(tag)"
        }
        return "Notes"
    }

    /// Build a folder/file tree from the flat list of note IDs and folder
    /// paths. Folders are pre-seeded from `folders` so that newly created
    /// empty folders show up before any note has been added to them.
    static func buildTree(
        noteIDs: [NoteID],
        titleByID: [NoteID: String],
        folders: [String]
    ) -> [FileTreeNode] {
        final class Branch {
            var subFolders: [String: Branch] = [:]
            var notes: [(id: NoteID, title: String)] = []
        }

        let root = Branch()

        // Pre-create empty folders.
        for path in folders {
            let parts = path.split(separator: "/").map(String.init)
            var current = root
            for folder in parts {
                if let next = current.subFolders[folder] {
                    current = next
                } else {
                    let next = Branch()
                    current.subFolders[folder] = next
                    current = next
                }
            }
        }

        // Place every note in its folder.
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
            for (name, sub) in branch.subFolders.sorted(by: {
                $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }) {
                let fullPath = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
                let children = render(sub, parentPath: fullPath)
                nodes.append(.folder(name: name, path: fullPath, children: children))
            }
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
    let children: [FileTreeNode]?

    enum Kind {
        case folder(name: String, path: String)
        case note(id: NoteID, title: String)
    }

    static func folder(name: String, path: String, children: [FileTreeNode]) -> FileTreeNode {
        FileTreeNode(id: "f:\(path)", kind: .folder(name: name, path: path), children: children)
    }

    static func note(id: NoteID, title: String) -> FileTreeNode {
        FileTreeNode(id: "n:\(id.relativePath)", kind: .note(id: id, title: title), children: nil)
    }
}

// MARK: - New folder prompt

private struct NewFolderPrompt: Identifiable {
    let id = UUID()
    let parent: String
}

private struct NewFolderSheet: View {
    let parent: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(parent.isEmpty ? "New Folder" : "New Folder in \(parent)")
                .font(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { create() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { nameFocused = true }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
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
                // Disable text selection so the Text doesn't intercept
                // clicks (macOS 14+ Text is selectable by default and
                // swallows the row's tap target).
                .textSelection(.disabled)
            Spacer(minLength: 0)
        }
        // Stretch the row to the full sidebar width and make the entire
        // rectangle hit-testable, so clicking the empty area next to the
        // title still selects the note.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// FolderRow that highlights itself when a note is being dragged over it,
/// so the drop target is unambiguous before the user releases the mouse.
private struct FolderDropZone: View {
    let name: String
    let onDrop: ([NSItemProvider]) -> Bool
    @State private var isTargeted: Bool = false

    var body: some View {
        FolderRow(name: name)
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isTargeted ? Color.accentColor.opacity(0.20) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(isTargeted ? Color.accentColor : .clear, lineWidth: 1)
                    )
            )
            .animation(.easeOut(duration: 0.12), value: isTargeted)
            .onDrop(of: [.utf8PlainText], isTargeted: $isTargeted) { providers in
                onDrop(providers)
            }
    }
}

/// Floating preview the user sees attached to the cursor during a note
/// drag. Mirrors the sidebar row chrome but with a card background so it
/// reads as detached from the list.
private struct NoteDragPreview: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(title)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
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
