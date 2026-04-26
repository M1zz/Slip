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

        // 3. Inline-link detection. Run a regex pass directly on the
        //    UTF-16 source so the link span ranges line up with the
        //    text-view offsets that NSTextStorage uses. Skipped inside
        //    code spans, code blocks, and frontmatter so we don't
        //    accidentally re-style content there.
        let protectedRanges: [Range<Int>] = spans.compactMap { span in
            switch span {
            case .code(let r): return r
            case .codeBlock(let r): return r
            case .frontmatter(let r): return r
            default: return nil
            }
        }
        let (linkSpans, linkMarkers) = Self.detectInlineLinks(in: text, protected: protectedRanges)
        spans.append(contentsOf: linkSpans)
        syntaxMarkers.append(contentsOf: linkMarkers)

        // 4. Wikilinks + tags (separate pass, also UTF-16 offsets).
        self.wikilinks = WikilinkParser.references(in: text)
        self.spans = spans
        self.syntaxMarkers = syntaxMarkers
        self.lineStarts = walker.utf16LineStarts
    }

    /// Find every inline `[text](url)` link in the source via regex. We
    /// use NSRegularExpression here (not swift-markdown's column data)
    /// because cmark/swift-markdown report column positions in UTF-8
    /// bytes, while NSTextStorage and our marker hider operate in
    /// UTF-16 — converting between them goes wrong on any line with
    /// emoji or non-ASCII text. The regex returns NSRange values
    /// directly, which are UTF-16 offsets, so the spans always line up.
    /// Skips matches that fall inside code spans, code blocks, or
    /// frontmatter so we don't accidentally style content there.
    private static func detectInlineLinks(in text: String, protected: [Range<Int>]) -> ([Span], [Range<Int>]) {
        let pattern = #"\[([^\[\]\n]+?)\]\(([^()\s]+?)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ([], [])
        }
        let ns = text as NSString
        var newSpans: [Span] = []
        var newMarkers: [Range<Int>] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 3 else { return }
            let outerNS = m.range
            let outer = outerNS.location..<(outerNS.location + outerNS.length)
            for b in protected where b.lowerBound < outer.upperBound && outer.lowerBound < b.upperBound {
                return
            }
            let labelNS = m.range(at: 1)
            let urlNS = m.range(at: 2)
            let url = ns.substring(with: urlNS)
            newSpans.append(.link(range: outer, destination: url))
            // `[` is the first char of the match; `](url)` runs from
            // after the label through the closing `)`.
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
        // Inline `[text](url)` links and autolinks are emitted by
        // MarkdownStructure's regex pass, which operates directly on
        // UTF-16 offsets. swift-markdown's source columns are UTF-8
        // byte positions, and converting them to UTF-16 offsets gets
        // off-by-N for any line containing emoji or other multi-byte
        // characters — which manifested as link colour and marker
        // hiding landing on the wrong characters. Just descend so
        // children (Text/Strong/Emphasis nested inside the link) still
        // get walked for their own styling.
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
