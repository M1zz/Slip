import Foundation

/// Extracts GitHub-flavored markdown task list items from a note body.
///
/// Recognizes the standard form:
///   - [ ] open item
///   - [x] completed item
///   * [X] also fine
///
/// Each parsed entry carries the 1-indexed line number where the item
/// appears so the index / aggregated views can deep-link back to the
/// exact spot in the note.
public enum TodoParser {

    public struct ParsedTodo: Hashable, Sendable {
        public let lineIndex: Int
        public let completed: Bool
        public let text: String
        public init(lineIndex: Int, completed: Bool, text: String) {
            self.lineIndex = lineIndex
            self.completed = completed
            self.text = text
        }
    }

    private static let regex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^[ \t]*[-*+][ \t]+\[([ xX])\][ \t]+(.+?)[ \t]*$"#,
            options: [.anchorsMatchLines]
        )
    }()

    public static func todos(in text: String) -> [ParsedTodo] {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let lineStarts = computeLineStarts(ns)

        var results: [ParsedTodo] = []
        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 3 else { return }
            let state = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return }
            let line = lineNumber(for: m.range.location, in: lineStarts)
            results.append(ParsedTodo(
                lineIndex: line,
                completed: state.lowercased() == "x",
                text: body
            ))
        }
        return results
    }

    private static func computeLineStarts(_ ns: NSString) -> [Int] {
        var starts: [Int] = [0]
        var i = 0
        while i < ns.length {
            if ns.character(at: i) == 0x0A { starts.append(i + 1) }
            i += 1
        }
        return starts
    }

    private static func lineNumber(for offset: Int, in starts: [Int]) -> Int {
        // Binary search for the largest start whose value is <= offset.
        var lo = 0, hi = starts.count - 1, answer = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= offset {
                answer = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return answer + 1 // 1-indexed
    }
}

/// Vault-scoped todo entry as returned by `NoteIndex.allTodos()`.
public struct TodoItem: Hashable, Sendable {
    public let noteID: NoteID
    public let lineIndex: Int
    public let completed: Bool
    public let text: String
    public init(noteID: NoteID, lineIndex: Int, completed: Bool, text: String) {
        self.noteID = noteID
        self.lineIndex = lineIndex
        self.completed = completed
        self.text = text
    }
}
