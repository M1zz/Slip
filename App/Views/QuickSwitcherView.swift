import SwiftUI
import SlipCore

/// ⌘P modal for jumping to a note by title. Fuzzy filter — every
/// query character must appear in the title in order, ignoring case
/// and intervening characters — same model as VS Code / Obsidian /
/// Sublime, so the matching feels familiar. Returning `Enter` opens
/// the highlighted note, `Esc` dismisses.
struct QuickSwitcherView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var queryFocused: Bool

    private var matches: [Match] {
        Self.rank(query: query, titles: appState.titleByID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find note by title", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($queryFocused)
                    .onSubmit { openSelected() }
                    .onChange(of: query) { _, _ in selectedIndex = 0 }
                    .onKeyPress(.upArrow) {
                        selectedIndex = max(0, selectedIndex - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        selectedIndex = min(matches.count - 1, selectedIndex + 1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            if matches.isEmpty {
                VStack {
                    Text(query.isEmpty ? "Start typing to find a note" : "No matches")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
                .padding(.vertical, 16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { idx, match in
                                MatchRow(
                                    title: match.title,
                                    folder: Self.folder(of: match.id),
                                    isSelected: idx == selectedIndex
                                )
                                .id(idx)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedIndex = idx
                                    openSelected()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selectedIndex) { _, new in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(new, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 520)
        .onAppear { queryFocused = true }
    }

    private func openSelected() {
        guard !matches.isEmpty,
              selectedIndex >= 0,
              selectedIndex < matches.count
        else { return }
        let id = matches[selectedIndex].id
        dismiss()
        appState.openNote(id)
    }

    private static func folder(of id: NoteID) -> String? {
        let parts = id.relativePath.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    // MARK: - Fuzzy matching

    fileprivate struct Match: Identifiable {
        let id: NoteID
        let title: String
        let score: Int
    }

    /// Subsequence match with a simple score: contiguous runs add
    /// more, prefix matches add more, shorter titles win ties. Good
    /// enough that "abc" finds "Architecture: building blocks of
    /// concurrency" without hand-tuning weights.
    fileprivate static func rank(
        query: String,
        titles: [NoteID: String]
    ) -> [Match] {
        let q = query.lowercased()
        var results: [Match] = []
        for (id, title) in titles {
            let lowerTitle = title.lowercased()
            if q.isEmpty {
                results.append(Match(id: id, title: title, score: -lowerTitle.count))
                continue
            }
            guard let score = subsequenceScore(query: q, in: lowerTitle) else { continue }
            results.append(Match(id: id, title: title, score: score))
        }
        return results
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(50)
            .map { $0 }
    }

    private static func subsequenceScore(query q: String, in title: String) -> Int? {
        var qIdx = q.startIndex
        var score = 0
        var run = 0
        var matchedAtStart = false
        var firstMatch = true
        for (i, ch) in title.enumerated() {
            if qIdx == q.endIndex { break }
            if ch == q[qIdx] {
                if firstMatch {
                    matchedAtStart = (i == 0)
                    firstMatch = false
                }
                run += 1
                score += 5 + run        // contiguous runs compound
                qIdx = q.index(after: qIdx)
            } else {
                run = 0
            }
        }
        guard qIdx == q.endIndex else { return nil }
        if matchedAtStart { score += 30 }
        score -= title.count / 4         // shorter title is a tiebreak boost
        return score
    }
}

private struct MatchRow: View {
    let title: String
    let folder: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(isSelected ? Color.white : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.white : .primary)
                if let folder, !folder.isEmpty {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
    }
}
