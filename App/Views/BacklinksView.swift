import SwiftUI
import SlipCore

struct BacklinksView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.uturn.left")
                    .foregroundStyle(.secondary)
                Text("Backlinks")
                    .font(.headline)
                Spacer()
                Text("\(appState.backlinks.count)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if appState.backlinks.isEmpty {
                Text(appState.currentNoteID == nil ?
                     "Open a note to see what links to it." :
                     "No notes link here yet.")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                List {
                    ForEach(appState.backlinks, id: \.self) { id in
                        Button {
                            appState.openNote(id)
                        } label: {
                            HStack {
                                Image(systemName: "link")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(appState.titleByID[id] ?? id.relativePath)
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
