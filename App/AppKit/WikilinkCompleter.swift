import AppKit
import SwiftUI

/// `[[…` autocomplete popover.
///
/// Shown while the text view's cursor is inside an unclosed wikilink. The
/// coordinator detects the trigger, feeds in the current query, and forwards
/// arrow / enter / escape keys to `moveSelection` and `currentSelection`.
///
/// We use `NSPopover` with `.transient` behavior so it dismisses naturally on
/// outside click or text-view resign — but the text view keeps focus, so typing
/// continues to update the query.
final class WikilinkCompleter {

    private let popover = NSPopover()
    private let viewModel = WikilinkCompleterViewModel()
    private weak var anchorView: NSView?

    var isShown: Bool { popover.isShown }

    /// Title that would be inserted if the user presses ⏎ right now.
    var currentSelection: String? { viewModel.selectedTitle }

    init() {
        popover.behavior = .semitransient
        popover.animates = false
        let host = NSHostingController(rootView: WikilinkCompleterView(viewModel: viewModel) { [weak self] title in
            self?.viewModel.onCommit?(title)
        })
        popover.contentViewController = host
    }

    func show(
        query: String,
        titles: [String],
        anchorView: NSView,
        anchorRange: NSRange,
        onSelect: @escaping (String) -> Void
    ) {
        viewModel.query = query
        viewModel.update(titles: titles, query: query)
        viewModel.onCommit = { title in
            onSelect(title)
        }
        self.anchorView = anchorView

        // If nothing matches, hide the popover rather than show an empty list.
        if viewModel.filteredTitles.isEmpty {
            hide()
            return
        }

        if !popover.isShown {
            let rect = Self.cursorRect(in: anchorView, for: anchorRange)
            popover.show(relativeTo: rect, of: anchorView, preferredEdge: .maxY)
        }
    }

    func hide() {
        if popover.isShown { popover.performClose(nil) }
        viewModel.onCommit = nil
    }

    func moveSelection(by delta: Int) {
        viewModel.moveSelection(by: delta)
    }

    // MARK: - Helpers

    /// Converts the cursor's screen rect (from `firstRect(forCharacterRange:)`)
    /// into the anchor view's coordinate space so `NSPopover` can attach.
    private static func cursorRect(in view: NSView, for range: NSRange) -> NSRect {
        guard let textView = view as? NSTextView, let window = textView.window else {
            return NSRect(origin: .zero, size: NSSize(width: 1, height: 1))
        }
        var actual = NSRange()
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: &actual)
        let windowRect = window.convertFromScreen(screenRect)
        let viewRect = textView.convert(windowRect, from: nil)
        // Give the popover something with non-zero width to attach to.
        return NSRect(x: viewRect.minX, y: viewRect.minY, width: max(viewRect.width, 1), height: max(viewRect.height, 1))
    }
}

// MARK: - View model

final class WikilinkCompleterViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var filteredTitles: [String] = []
    @Published var selectedIndex: Int = 0
    var onCommit: ((String) -> Void)?

    var selectedTitle: String? {
        guard selectedIndex >= 0, selectedIndex < filteredTitles.count else { return nil }
        return filteredTitles[selectedIndex]
    }

    func update(titles: [String], query: String) {
        self.query = query
        let filtered = Self.filter(titles: titles, query: query)
        self.filteredTitles = filtered
        self.selectedIndex = filtered.isEmpty ? 0 : min(selectedIndex, filtered.count - 1)
    }

    func moveSelection(by delta: Int) {
        guard !filteredTitles.isEmpty else { return }
        let count = filteredTitles.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    // MARK: - Filtering

    /// Subsequence fuzzy match: query chars must appear in order in the title,
    /// anywhere. Exact prefix matches sort first, then by length.
    private static func filter(titles: [String], query: String) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(titles.prefix(20)) }

        var scored: [(title: String, score: Int)] = []
        for title in titles {
            let lower = title.lowercased()
            if lower.hasPrefix(q) {
                scored.append((title, 0 * 1000 + title.count))
            } else if lower.contains(q) {
                scored.append((title, 1 * 1000 + title.count))
            } else if Self.isSubsequence(q, in: lower) {
                scored.append((title, 2 * 1000 + title.count))
            }
        }
        scored.sort { $0.score < $1.score }
        return Array(scored.prefix(20).map(\.title))
    }

    private static func isSubsequence(_ query: String, in text: String) -> Bool {
        var qIter = query.makeIterator()
        guard var qChar = qIter.next() else { return true }
        for c in text where c == qChar {
            if let next = qIter.next() { qChar = next } else { return true }
        }
        return false
    }
}

// MARK: - View

struct WikilinkCompleterView: View {
    @ObservedObject var viewModel: WikilinkCompleterViewModel
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.filteredTitles.isEmpty {
                Text("No matches")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .padding(10)
            } else {
                ForEach(Array(viewModel.filteredTitles.enumerated()), id: \.offset) { idx, title in
                    row(title: title, isSelected: idx == viewModel.selectedIndex)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectedIndex = idx
                            onSelect(title)
                        }
                }
            }
        }
        .frame(width: 320)
        .padding(.vertical, 4)
    }

    private func row(title: String, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(isSelected ? .white : .secondary)
            Text(title)
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : Color.clear)
    }
}
