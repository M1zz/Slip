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
                    .padding(.bottom, 6)
                    .onChange(of: appState.currentNoteTitle) { _, _ in
                        debouncedSave()
                    }

                    TagBar(
                        currentTags: currentTags,
                        allTags: allTagSuggestions,
                        onAdd: addTag,
                        onRemove: removeTag
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

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

    // MARK: - Tags

    /// Unique tags found inline in the current note body, in first-occurrence order.
    private var currentTags: [String] {
        let refs = WikilinkParser.references(in: appState.currentNoteBody)
        var seen = Set<String>()
        var ordered: [String] = []
        for ref in refs {
            if case .tag(let t) = ref.kind, !seen.contains(t) {
                seen.insert(t)
                ordered.append(t)
            }
        }
        return ordered
    }

    /// Tags that exist anywhere in the vault, for the add-tag autocomplete.
    private var allTagSuggestions: [String] {
        appState.tags.map(\.tag)
    }

    private func addTag(_ tag: String) {
        let clean = tag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !clean.isEmpty else { return }

        // Already present anywhere in the body? Don't duplicate.
        let escaped = NSRegularExpression.escapedPattern(for: clean)
        let existsPattern = #"(?<![\p{L}\p{N}_/\-])#"# + escaped + #"(?![\p{L}\p{N}_/\-])"#
        if let regex = try? NSRegularExpression(pattern: existsPattern) {
            let fullRange = NSRange(appState.currentNoteBody.startIndex...,
                                    in: appState.currentNoteBody)
            if regex.firstMatch(in: appState.currentNoteBody, range: fullRange) != nil {
                return
            }
        }

        var body = appState.currentNoteBody
        if !body.isEmpty, !body.hasSuffix(" "), !body.hasSuffix("\n") {
            body.append(" ")
        }
        body.append("#\(clean)")
        appState.currentNoteBody = body
    }

    private func removeTag(_ tag: String) {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        // Match optional leading space + #tag at word boundary, so we
        // consume the separator and don't leave `foo  bar` double spaces.
        let pattern = #" ?(?<![\p{L}\p{N}_/\-])#"# + escaped + #"(?![\p{L}\p{N}_/\-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let body = appState.currentNoteBody
        let fullRange = NSRange(body.startIndex..., in: body)
        let newBody = regex.stringByReplacingMatches(in: body, range: fullRange, withTemplate: "")
        appState.currentNoteBody = newBody
    }

    // MARK: - Misc

    private func openTargetByTitle(_ title: String) {
        let match = appState.titleByID.first { $0.value.caseInsensitiveCompare(title) == .orderedSame }
        if let match {
            appState.openNote(match.key)
        }
    }

    private func debouncedSave() {
        autosave?.cancel()
        autosave = Just(())
            .delay(for: .seconds(0.3), scheduler: RunLoop.main)
            .sink { _ in appState.saveCurrentNote() }
    }
}

// MARK: - TagBar

private struct TagBar: View {
    let currentTags: [String]
    let allTags: [String]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void

    @State private var editing: Bool = false
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(currentTags, id: \.self) { tag in
                    TagChip(tag: tag, onRemove: { onRemove(tag) })
                }

                if editing {
                    HStack(spacing: 4) {
                        Image(systemName: "number")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        TextField("tag", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .frame(minWidth: 60, maxWidth: 140)
                            .focused($inputFocused)
                            .onSubmit { commit() }
                            .onExitCommand { cancel() }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().stroke(Color.secondary.opacity(0.4)))

                    if !suggestions.isEmpty {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button { accept(suggestion) } label: {
                                Text("#\(suggestion)")
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Button {
                        editing = true
                        draft = ""
                        DispatchQueue.main.async { inputFocused = true }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Add tag")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var suggestions: [String] {
        let q = draft
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
        guard !q.isEmpty else { return [] }
        let existing = Set(currentTags)
        return allTags
            .filter { !existing.contains($0) && $0.lowercased().contains(q) && $0.lowercased() != q }
            .prefix(4)
            .map { $0 }
    }

    private func accept(_ tag: String) {
        onAdd(tag)
        draft = ""
        editing = false
    }

    private func commit() {
        let cleaned = draft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if !cleaned.isEmpty { onAdd(cleaned) }
        draft = ""
        editing = false
    }

    private func cancel() {
        draft = ""
        editing = false
    }
}

// MARK: - TagChip

private struct TagChip: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
                .font(.system(size: 11, weight: .medium))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(0.7)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .foregroundStyle(Color.accentColor)
    }
}
