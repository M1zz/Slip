import Foundation
import Markdown

/// A flat, UI-friendly view of a markdown document.
///
/// `MarkdownStructure` walks the `Markdown` document tree once and emits a list
/// of styled spans that the text view can apply as attributes. We keep this in
/// SlipCore (no AppKit/UIKit) so the same logic works on macOS and iOS.
public struct MarkdownStructure {

    public enum Span: Hashable {
        case heading(level: Int, range: Range<Int>)
        case bold(range: Range<Int>)
        case italic(range: Range<Int>)
        case code(range: Range<Int>)          // inline code
        case codeBlock(range: Range<Int>)
        case link(range: Range<Int>, destination: String?)
        case blockquote(range: Range<Int>)
        case listMarker(range: Range<Int>)
        case frontmatter(range: Range<Int>)
    }

    public let spans: [Span]
    public let wikilinks: [NoteReference]
    /// Ranges covering syntax characters (the `**`, `_`, `` ` ``, `# `, etc.)
    /// that should be dimmed when the cursor is off-line for Live Preview.
    public let syntaxMarkers: [Range<Int>]
    /// UTF-16 offset of the first character of each 1-indexed line.
    /// Index 0 is a dummy; use `line(forUTF16Offset:)` to look up a line.
    public let lineStarts: [Int]

    /// Returns the 1-indexed line number containing `offset`. Returns 0 if the
    /// structure is empty.
    public func line(forUTF16Offset offset: Int) -> Int {
        guard lineStarts.count > 1 else { return 0 }
        // Binary search: find the largest line whose start <= offset.
        var lo = 1, hi = lineStarts.count - 1, answer = 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= offset {
                answer = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return answer
    }

    public init(text: String) {
        var spans: [Span] = []

        // 1. Frontmatter (YAML between leading `---` fences). swift-markdown
        //    doesn't parse this, and we want it visually dimmed.
        if let fmRange = Self.frontmatterRange(in: text) {
            spans.append(.frontmatter(range: fmRange))
        }

        // 2. Markdown tree walk.
        let document = Document(parsing: text, options: [.parseBlockDirectives])
        var walker = SpanCollector(source: text)
        walker.visit(document)
        spans.append(contentsOf: walker.spans)
        var syntaxMarkers = walker.syntaxMarkers

        // 3. Inline-link fallback. swift-markdown occasionally fails to
        //    recognize `[text](url)` when the surrounding paragraph has
        //    leading emoji or unusual punctuation. We sweep the source
        //    one more time with a tight regex, skip anything that already
        //    overlaps a span the main walker emitted (links, code, code
        //    blocks, frontmatter), and synthesize the missing link span
        //    + its `[`, `](url)` syntax markers ourselves.
        let (extraLinks, extraMarkers) = Self.detectInlineLinks(in: text, existing: spans)
        spans.append(contentsOf: extraLinks)
        syntaxMarkers.append(contentsOf: extraMarkers)

        // 4. Wikilinks + tags (separate pass, also UTF-16 offsets).
        self.wikilinks = WikilinkParser.references(in: text)
        self.spans = spans
        self.syntaxMarkers = syntaxMarkers
        self.lineStarts = walker.utf16LineStarts
    }

    private static func detectInlineLinks(in text: String, existing: [Span]) -> ([Span], [Range<Int>]) {
        let pattern = #"\[([^\[\]\n]+?)\]\(([^()\s]+?)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ([], [])
        }
        let ns = text as NSString
        // Anything inside an existing link, code span, code block, or
        // frontmatter shouldn't be re-styled as a link.
        var blocked: [Range<Int>] = []
        for span in existing {
            switch span {
            case .link(let r, _): blocked.append(r)
            case .code(let r): blocked.append(r)
            case .codeBlock(let r): blocked.append(r)
            case .frontmatter(let r): blocked.append(r)
            default: break
            }
        }

        var newSpans: [Span] = []
        var newMarkers: [Range<Int>] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 3 else { return }
            let outerNS = m.range
            let outer = outerNS.location..<(outerNS.location + outerNS.length)
            for b in blocked where b.lowerBound < outer.upperBound && outer.lowerBound < b.upperBound {
                return
            }
            let labelNS = m.range(at: 1)
            let urlNS = m.range(at: 2)
            let url = ns.substring(with: urlNS)
            newSpans.append(.link(range: outer, destination: url))
            // `[` is the first char of the match; `](…)` runs from after
            // the label through the closing `)` (= outer.upperBound).
            newMarkers.append(outer.lowerBound..<(outer.lowerBound + 1))
            let middleStart = labelNS.location + labelNS.length
            newMarkers.append(middleStart..<outer.upperBound)
        }
        return (newSpans, newMarkers)
    }

    // MARK: - Frontmatter

    private static func frontmatterRange(in text: String) -> Range<Int>? {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return nil }
        let ns = text as NSString
        // Find the closing `---` on its own line.
        let search = NSRange(location: 3, length: ns.length - 3)
        let closer = ns.range(of: "\n---\n", range: search)
        if closer.location != NSNotFound {
            let end = closer.location + closer.length
            return 0..<end
        }
        let closerR = ns.range(of: "\n---\r\n", range: search)
        if closerR.location != NSNotFound {
            let end = closerR.location + closerR.length
            return 0..<end
        }
        return nil
    }
}

/// Walks a `Markdown.Document` and collects styled spans with UTF-16 ranges.
///
/// swift-markdown's `SourceRange` gives us line:column, which we convert into
/// UTF-16 offsets that match what `NSTextStorage` expects.
///
/// Also emits `syntaxMarkers` — the sub-ranges covering the delimiter characters
/// (`**`, `_`, `` ` ``, `# `, etc.). The editor uses these to fade the markers
/// out when the cursor isn't on the same line.
private struct SpanCollector: MarkupWalker {
    let source: String
    let utf16LineStarts: [Int]
    var spans: [MarkdownStructure.Span] = []
    var syntaxMarkers: [Range<Int>] = []

    init(source: String) {
        self.source = source
        self.utf16LineStarts = Self.computeLineStarts(source)
    }

    private static func computeLineStarts(_ s: String) -> [Int] {
        // UTF-16 offsets of the first code unit of each 1-indexed line.
        var offsets: [Int] = [0, 0] // dummy 0 index so line 1 -> index 1
        let ns = s as NSString
        var i = 0
        while i < ns.length {
            let ch = ns.character(at: i)
            if ch == 0x0A { // \n
                offsets.append(i + 1)
            }
            i += 1
        }
        return offsets
    }

    private func utf16Offset(for position: SourceLocation) -> Int {
        // swift-markdown's columns are 1-indexed *character* columns. For robust
        // UTF-16 mapping we scan from line start.
        let line = position.line
        let col = position.column
        guard line >= 1, line < utf16LineStarts.count else { return 0 }
        let lineStart = utf16LineStarts[line]
        let ns = source as NSString
        // Advance (col - 1) characters in UTF-16.
        var offset = lineStart
        var remaining = max(col - 1, 0)
        while remaining > 0, offset < ns.length {
            let ch = ns.character(at: offset)
            if UTF16.isLeadSurrogate(ch), offset + 1 < ns.length {
                offset += 2
            } else {
                offset += 1
            }
            remaining -= 1
        }
        return min(offset, ns.length)
    }

    private func range(for markup: Markup) -> Range<Int>? {
        guard let sr = markup.range else { return nil }
        let start = utf16Offset(for: sr.lowerBound)
        var end = utf16Offset(for: sr.upperBound)
        // Trim trailing newline / CR so block-level spans (heading, blockquote,
        // code block, list item) don't style the line terminator. If the
        // newline is styled as heading, NSTextView inherits that font as the
        // typing attribute for the next line and new text starts in heading
        // style until highlighting runs again.
        let ns = source as NSString
        while end > start, end <= ns.length {
            let prev = ns.character(at: end - 1)
            if prev == 0x0A || prev == 0x0D {
                end -= 1
            } else {
                break
            }
        }
        guard end > start else { return nil }
        return start..<end
    }

    // MARK: - Visitors

    mutating func visitHeading(_ heading: Heading) {
        if let r = range(for: heading) {
            spans.append(.heading(level: heading.level, range: r))
            // Marker: `# ` (or `## `, `### `, …). ATX headings only — setext
            // headings (underline style) are rarer and not handled here.
            let ns = source as NSString
            let prefixLen = min(heading.level + 1, r.upperBound - r.lowerBound)
            if prefixLen > 0, r.lowerBound + prefixLen <= ns.length {
                syntaxMarkers.append(r.lowerBound..<(r.lowerBound + prefixLen))
            }
        }
        descendInto(heading)
    }

    mutating func visitStrong(_ strong: Strong) {
        if let r = range(for: strong) {
            spans.append(.bold(range: r))
            addPairedMarkers(in: r, length: 2)
        }
        descendInto(strong)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        if let r = range(for: emphasis) {
            spans.append(.italic(range: r))
            addPairedMarkers(in: r, length: 1)
        }
        descendInto(emphasis)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        if let r = range(for: inlineCode) {
            spans.append(.code(range: r))
            addPairedMarkers(in: r, length: 1)
        }
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        if let r = range(for: codeBlock) {
            spans.append(.codeBlock(range: r))
            // The opening/closing ``` fences. We approximate as the first and
            // last lines of the block.
            let ns = source as NSString
            let lo = r.lowerBound
            let hi = r.upperBound
            if hi - lo >= 6, hi <= ns.length {
                // Opener: from lo to first newline after lo.
                let rest = NSRange(location: lo, length: hi - lo)
                let nlOpen = ns.range(of: "\n", range: rest)
                if nlOpen.location != NSNotFound {
                    syntaxMarkers.append(lo..<nlOpen.location)
                }
                // Closer: from the last newline before hi to hi.
                var i = hi - 1
                while i > lo && ns.character(at: i) != 0x0A { i -= 1 }
                if i > lo { syntaxMarkers.append(i..<hi) }
            }
        }
    }

    mutating func visitLink(_ link: Link) {
        if let r = range(for: link) {
            spans.append(.link(range: r, destination: link.destination))
            // Link syntax: `[text](url)`. Hide the leading `[` and the
            // entire `](url)` tail so only the visible label remains. The
            // previous behavior left the URL itself uncovered, so users
            // saw `text https://example.com` smushed together.
            let ns = source as NSString
            if r.lowerBound < ns.length, ns.character(at: r.lowerBound) == 0x5B { // '['
                syntaxMarkers.append(r.lowerBound..<(r.lowerBound + 1))
            }
            let search = NSRange(location: r.lowerBound, length: r.upperBound - r.lowerBound)
            let middle = ns.range(of: "](", range: search)
            if middle.location != NSNotFound {
                syntaxMarkers.append(middle.location..<r.upperBound)
            }
        }
        descendInto(link)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        if let r = range(for: blockQuote) {
            spans.append(.blockquote(range: r))
            // `> ` at the start of each line in the quote.
            let ns = source as NSString
            var i = r.lowerBound
            while i < r.upperBound {
                // Find line start: i is at start of a line within blockquote.
                if i < ns.length, ns.character(at: i) == 0x3E { // '>'
                    let end = min(i + 2, r.upperBound)
                    syntaxMarkers.append(i..<end)
                }
                // Skip to next line.
                while i < r.upperBound, i < ns.length, ns.character(at: i) != 0x0A { i += 1 }
                i += 1
            }
        }
        descendInto(blockQuote)
    }

    mutating func visitListItem(_ listItem: ListItem) {
        // Approximate the marker: first 2-4 chars of the line (`- `, `* `, `1. `).
        if let r = range(for: listItem) {
            let markerEnd = min(r.lowerBound + 4, r.upperBound)
            spans.append(.listMarker(range: r.lowerBound..<markerEnd))
            syntaxMarkers.append(r.lowerBound..<markerEnd)
        }
        descendInto(listItem)
    }

    // MARK: - Marker helpers

    /// For symmetrical inline delimiters like `**…**` (length=2) or `_…_` (length=1),
    /// add marker ranges at both ends of the span range.
    private mutating func addPairedMarkers(in range: Range<Int>, length: Int) {
        let len = range.upperBound - range.lowerBound
        guard len >= length * 2 else { return }
        syntaxMarkers.append(range.lowerBound..<(range.lowerBound + length))
        syntaxMarkers.append((range.upperBound - length)..<range.upperBound)
    }
}
