import SwiftUI
import SlipCore

/// Aggregates every `- [ ]` / `- [x]` task across the vault into a
/// single inspector section. Open tasks float to the top; checked
/// items stay visible (greyed and struck-through) so you can scan
/// recent progress. Clicking a row jumps to the source note.
struct TodosView: View {
    @EnvironmentObject var appState: AppState
    @State private var showCompleted: Bool = false

    private var visible: [TodoItem] {
        appState.allTodos.filter { showCompleted || !$0.completed }
    }

    private var openCount: Int {
        appState.allTodos.lazy.filter { !$0.completed }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checklist")
                    .foregroundStyle(.green)
                Text("Todos")
                    .font(.headline)
                if openCount > 0 {
                    Text("\(openCount)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                        .foregroundStyle(Color.green)
                }
                Spacer()
                Toggle(isOn: $showCompleted) {
                    Image(systemName: showCompleted ? "eye" : "eye.slash")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.mini)
                .help(showCompleted ? "Hide completed" : "Show completed")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if appState.allTodos.isEmpty {
                Text("No `- [ ]` items in any note yet.")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .padding(.horizontal, 12)
                Spacer()
            } else if visible.isEmpty {
                Text("All done. 🎉")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(visible, id: \.self) { todo in
                            TodoRow(
                                todo: todo,
                                noteTitle: appState.titleByID[todo.noteID] ?? todo.noteID.relativePath
                            ) {
                                appState.openNote(todo.noteID)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

private struct TodoRow: View {
    let todo: TodoItem
    let noteTitle: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: todo.completed ? "checkmark.square.fill" : "square")
                    .foregroundStyle(todo.completed ? Color.green : Color.secondary)
                    .font(.system(size: 13))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.text)
                        .font(.system(size: 12))
                        .foregroundStyle(todo.completed ? Color.secondary : Color.primary)
                        .strikethrough(todo.completed)
                        .multilineTextAlignment(.leading)
                    Text(noteTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
