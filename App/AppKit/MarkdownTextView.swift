import AppKit
import SwiftUI
import SlipCore

/// SwiftUI-facing markdown editor backed by `NSTextView` (TextKit 2).
///
/// Why NSTextView and not `TextEditor`:
/// - SwiftUI's `TextEditor` gives no hook into layout, attributes, or cursor —
///   we need all three for Live Preview semantic highlighting.
/// - TextKit 2 is the modern default on macOS 14+ and is what `NSTextView`
///   uses automatically when created fresh.
///
/// Live Preview strategy (MVP):
/// 1. User types → `textDidChange` fires.
/// 2. We debounce (~120ms) then run `MarkdownStructure(text:)` off the main
///    queue.
/// 3. On main, we translate spans → `NSAttributedString` attributes and apply
///    them inside `textStorage.beginEditing / endEditing`.
/// 4. We never replace the string content — attributes only — so cursor,
///    selection, and undo stack are preserved.
///
/// Future work (v2): hide syntax characters (e.g., `**`) with zero-width
/// attributes when the cursor is not on the current line.
struct MarkdownTextView: NSViewRepresentable {

    @Binding var text: String
    /// Titles of all notes in the vault, for the `[[` autocomplete popover.
    /// Read lazily via `titles()` inside the coordinator to pick up updates
    /// without recreating the text view.
    var titles: () -> [String] = { [] }
    /// Monotonically increasing counter that asks the editor to insert `[[`
    /// at the current cursor position, which kicks off the wikilink
    /// autocomplete popover. Driven by the toolbar "link" button / ⌘K.
    var insertLinkRequest: Int = 0
    /// Save an NSImage to the vault and return the relative markdown path
    /// (e.g. `_attachments/paste-...png`) — invoked when the user pastes an
    /// image. Returning nil falls back to plain-text paste.
    var onImagePaste: ((NSImage) -> String?)? = nil
    var onWikilinkClick: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        // Build the scroll view + text view manually so we can substitute
        // our paste-aware NSTextView subclass.
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = MarkdownAwareTextView()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.font = Theme.body
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true

        textView.onImagePaste = onImagePaste

        scrollView.documentView = textView

        context.coordinator.textView = textView
        textView.string = text
        context.coordinator.reapplyHighlighting()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownAwareTextView else { return }
        // Keep the paste callback in sync — closures captured at make time
        // get stale once SwiftUI re-renders with new dependencies.
        textView.onImagePaste = onImagePaste
        // Only replace if the external binding diverged (e.g., switching notes).
        if textView.string != text {
            textView.string = text
            context.coordinator.reapplyHighlighting()
        }
        if context.coordinator.lastInsertLinkRequest != insertLinkRequest {
            context.coordinator.lastInsertLinkRequest = insertLinkRequest
            context.coordinator.insertAtCursor("[[")
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(
            setText: { self.text = $0 },
            onWikilinkClick: onWikilinkClick
        )
        coordinator.titlesProvider = titles
        return coordinator
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        private let setText: (String) -> Void
        private let onWikilinkClick: (String) -> Void
        private var highlightWorkItem: DispatchWorkItem?
        var lastInsertLinkRequest: Int = 0
        let completer = WikilinkCompleter()
        var titlesProvider: () -> [String] = { [] }

        init(setText: @escaping (String) -> Void, onWikilinkClick: @escaping (String) -> Void) {
            self.setText = setText
            self.onWikilinkClick = onWikilinkClick
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            setText(tv.string)
            // When the user has just pressed Enter, re-highlight immediately
            // instead of after the 120ms debounce. NSTextView inherits the
            // typing attributes from the character before the cursor, so if
            // we wait, text typed on the new line carries over heading /
            // blockquote / code-block styling from the line above until the
            // debounce fires.
            if Self.editEndedWithNewline(tv) {
                reapplyHighlighting()
                resetTypingAttributesToBody(tv)
            } else {
                scheduleHighlighting()
            }
            updateWikilinkCompletion()
        }

        private static func editEndedWithNewline(_ tv: NSTextView) -> Bool {
            let ns = tv.string as NSString
            let loc = tv.selectedRange().location
            guard loc > 0, loc <= ns.length else { return false }
            return ns.character(at: loc - 1) == 0x0A
        }

        /// After a newline, force the typing attributes back to body so the
        /// next keystroke doesn't reuse whatever the previous block inherited.
        private func resetTypingAttributesToBody(_ tv: NSTextView) {
            tv.typingAttributes = [
                .font: Theme.body,
                .foregroundColor: NSColor.labelColor
            ]
        }

        /// Insert a string at the cursor (replacing the selection) and move
        /// the caret to the end of the inserted text. Used by the toolbar
        /// "insert link" button to drop `[[` at the cursor and let the
        /// wikilink popover take over.
        func insertAtCursor(_ s: String) {
            guard let tv = textView else { return }
            tv.window?.makeFirstResponder(tv)
            let range = tv.selectedRange()
            if tv.shouldChangeText(in: range, replacementString: s) {
                tv.textStorage?.replaceCharacters(in: range, with: s)
                tv.didChangeText()
                let newCaret = range.location + (s as NSString).length
                tv.setSelectedRange(NSRange(location: newCaret, length: 0))
            }
            updateWikilinkCompletion()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateWikilinkCompletion()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard completer.isShown else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                completer.moveSelection(by: 1); return true
            case #selector(NSResponder.moveUp(_:)):
                completer.moveSelection(by: -1); return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):
                commitCompletion(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                completer.hide(); return true
            default:
                return false
            }
        }

        // Handle ⌘-click on wikilink spans.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let target = link as? String, target.hasPrefix("slip://wikilink/") {
                let name = String(target.dropFirst("slip://wikilink/".count))
                    .removingPercentEncoding ?? ""
                onWikilinkClick(name)
                return true
            }
            return false
        }

        // MARK: - Highlighting pipeline

        private func scheduleHighlighting() {
            highlightWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.reapplyHighlighting()
            }
            highlightWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
        }

        func reapplyHighlighting(precomputed: MarkdownStructure? = nil) {
            guard let textView, let storage = textView.textStorage else { return }
            let text = textView.string
            let structure = precomputed ?? MarkdownStructure(text: text)

            storage.beginEditing()
            let full = NSRange(location: 0, length: (text as NSString).length)

            // Reset to plain baseline.
            storage.setAttributes([
                .font: Theme.body,
                .foregroundColor: NSColor.labelColor
            ], range: full)

            // Semantic styling (fonts, colors for bold/italic/headings/etc.).
            for span in structure.spans {
                MarkdownTextView.apply(span: span, on: storage, in: text)
            }
            for ref in structure.wikilinks {
                MarkdownTextView.apply(reference: ref, on: storage, in: text)
            }

            // WYSIWYG: hide all syntax markers (#, **, _, `, > …) unconditionally.
            // The characters are still in the text storage — the `.md` file, undo
            // stack, and copy/paste see the raw markdown — but the glyphs collapse
            // to zero width + transparent so the user only sees the rendered form.
            // This matches Notion/Bear: the moment `# ` becomes a valid heading,
            // the marker is gone and typing continues in heading style.
            for marker in structure.syntaxMarkers {
                let length = (text as NSString).length
                let lo = max(0, min(length, marker.lowerBound))
                let hi = max(lo, min(length, marker.upperBound))
                guard hi > lo else { continue }
                let range = NSRange(location: lo, length: hi - lo)
                storage.addAttributes([
                    .foregroundColor: NSColor.clear,
                    .font: Theme.hidden
                ], range: range)
            }

            storage.endEditing()
        }

        // MARK: - Wikilink completion

        /// Detects whether the cursor sits inside an open `[[…` span and, if so,
        /// shows/updates the popover with matching titles. Hides otherwise.
        private func updateWikilinkCompletion() {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let cursor = tv.selectedRange().location
            guard cursor <= ns.length else { completer.hide(); return }

            // Scan backwards up to 64 chars for `[[`, bailing on `]` or newline.
            let scanStop = max(0, cursor - 64)
            var i = cursor - 1
            var openAt: Int? = nil
            while i > scanStop {
                let ch = ns.character(at: i)
                if ch == 0x5D || ch == 0x0A { break }                        // ']' or '\n'
                if ch == 0x5B, i > 0, ns.character(at: i - 1) == 0x5B {      // `[[`
                    openAt = i + 1
                    break
                }
                i -= 1
            }

            guard let queryStart = openAt, queryStart <= cursor else {
                completer.hide(); return
            }
            let query = ns.substring(with: NSRange(location: queryStart, length: cursor - queryStart))
            if query.contains("\n") || query.contains("]") { completer.hide(); return }

            completer.show(
                query: query,
                titles: titlesProvider(),
                anchorView: tv,
                anchorRange: NSRange(location: cursor, length: 0),
                onSelect: { [weak self] selected in
                    self?.insertCompletion(selected, replacingFrom: queryStart - 2, to: cursor)
                }
            )
        }

        private func commitCompletion() {
            guard let tv = textView else { completer.hide(); return }
            let ns = tv.string as NSString
            let cursor = tv.selectedRange().location
            let scanStop = max(0, cursor - 64)
            var i = cursor - 1
            var openAt: Int? = nil
            while i > scanStop {
                let ch = ns.character(at: i)
                if ch == 0x5D || ch == 0x0A { break }
                if ch == 0x5B, i > 0, ns.character(at: i - 1) == 0x5B {
                    openAt = i + 1; break
                }
                i -= 1
            }
            guard let queryStart = openAt,
                  let selected = completer.currentSelection else {
                completer.hide(); return
            }
            insertCompletion(selected, replacingFrom: queryStart - 2, to: cursor)
        }

        private func insertCompletion(_ title: String, replacingFrom start: Int, to end: Int) {
            guard let tv = textView, start >= 0, end >= start else { return }
            let replacement = "[[\(title)]]"
            let range = NSRange(location: start, length: end - start)
            if tv.shouldChangeText(in: range, replacementString: replacement) {
                tv.textStorage?.replaceCharacters(in: range, with: replacement)
                tv.didChangeText()
                let newCaret = start + (replacement as NSString).length
                tv.setSelectedRange(NSRange(location: newCaret, length: 0))
            }
            completer.hide()
            scheduleHighlighting()
        }
    }

    // MARK: - Styling

    private static func apply(span: MarkdownStructure.Span, on storage: NSTextStorage, in text: String) {
        let length = (text as NSString).length
        func nsRange(_ r: Range<Int>) -> NSRange? {
            let lo = max(0, min(length, r.lowerBound))
            let hi = max(lo, min(length, r.upperBound))
            return hi > lo ? NSRange(location: lo, length: hi - lo) : nil
        }

        switch span {
        case .heading(let level, let r):
            guard let range = nsRange(r) else { return }
            storage.addAttributes([
                .font: Theme.heading(level: level),
                .foregroundColor: NSColor.labelColor
            ], range: range)

        case .bold(let r):
            guard let range = nsRange(r) else { return }
            storage.addAttributes([.font: Theme.bold], range: range)

        case .italic(let r):
            guard let range = nsRange(r) else { return }
            storage.addAttributes([.font: Theme.italic], range: range)

        case .code(let r), .codeBlock(let r):
            guard let range = nsRange(r) else { return }
            storage.addAttributes([
                .font: Theme.mono,
                .backgroundColor: NSColor.textBackgroundColor.blended(withFraction: 0.06, of: .labelColor) ?? .clear
            ], range: range)

        case .link(let r, let destination):
            guard let range = nsRange(r) else { return }
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.linkColor
            ]
            if let dest = destination, !dest.isEmpty {
                // Attach the destination so the text view's
                // clickedOnLink: delegate routes the click to NSWorkspace
                // (which opens it in the default browser).
                attrs[.link] = dest
                attrs[.cursor] = NSCursor.pointingHand
            }
            storage.addAttributes(attrs, range: range)

        case .blockquote(let r):
            guard let range = nsRange(r) else { return }
            storage.addAttributes([
                .foregroundColor: NSColor.secondaryLabelColor
            ], range: range)

        case .listMarker(let r):
            guard let range = nsRange(r) else { return }
            storage.addAttributes([
                .foregroundColor: NSColor.tertiaryLabelColor
            ], range: range)

        case .frontmatter(let r):
            guard let range = nsRange(r) else { return }
            storage.addAttributes([
                .font: Theme.mono,
                .foregroundColor: NSColor.tertiaryLabelColor
            ], range: range)
        }
    }

    private static func apply(reference: NoteReference, on storage: NSTextStorage, in text: String) {
        let length = (text as NSString).length
        let lo = max(0, min(length, reference.range.lowerBound))
        let hi = max(lo, min(length, reference.range.upperBound))
        guard hi > lo else { return }
        let range = NSRange(location: lo, length: hi - lo)

        switch reference.kind {
        case .wikilink(let target, _):
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
            storage.addAttributes([
                .foregroundColor: NSColor.systemPurple,
                .link: "slip://wikilink/\(encoded)",
                .cursor: NSCursor.pointingHand
            ], range: range)
        case .tag:
            storage.addAttributes([
                .foregroundColor: NSColor.systemTeal
            ], range: range)
        case .unlinkedMention:
            break
        }
    }
}

// MARK: - Theme

enum Theme {
    static let body: NSFont = {
        NSFont(name: "SF Pro Text", size: 15) ?? NSFont.systemFont(ofSize: 15)
    }()
    static let bold: NSFont = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
    static let italic: NSFont = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
    static let mono: NSFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    /// Used to collapse marker glyphs (`#`, `**`, etc.) to zero width when the
    /// cursor isn't on that line. TextKit still keeps the characters in the
    /// layout, but they occupy effectively no space.
    static let hidden: NSFont = NSFont.systemFont(ofSize: 0.01)

    static func heading(level: Int) -> NSFont {
        let sizes: [CGFloat] = [28, 24, 20, 18, 16, 15]
        let size = sizes[min(max(level, 1), 6) - 1]
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }
}

// MARK: - Paste-aware NSTextView

/// NSTextView subclass that intercepts paste so we can:
/// 1. Convert HTML/RTF rich text (Notion, web pages, Substack, …) to
///    inline markdown so links, bold and italic survive instead of
///    being stripped to plain text by the default `isRichText = false`
///    behavior.
/// 2. Detect a pure-image paste (screenshot, "Copy Image" from a web
///    page) and route it through `onImagePaste`, which is expected to
///    save the image into the vault and return a relative path for an
///    `![](_attachments/…)` markdown reference.
final class MarkdownAwareTextView: NSTextView {

    var onImagePaste: ((NSImage) -> String?)?

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        NSLog("[Slip] paste types=\(types.map(\.rawValue))")

        // 1. Rich text source — convert to markdown, preserving links.
        if types.contains(.html), let html = pb.string(forType: .html) {
            NSLog("[Slip] paste: HTML available, len=\(html.count)")
            if insertConvertedHTML(html) {
                NSLog("[Slip] paste: HTML→markdown succeeded")
                return
            }
            NSLog("[Slip] paste: HTML→markdown produced empty result")
        }
        if types.contains(.rtf), let rtfData = pb.data(forType: .rtf) {
            NSLog("[Slip] paste: RTF available, bytes=\(rtfData.count)")
            if insertConvertedRTF(rtfData) {
                NSLog("[Slip] paste: RTF→markdown succeeded")
                return
            }
        }

        // 2. Pure-image paste (no text on pasteboard). NSImage pulls from
        //    PNG/TIFF/PDF/etc. so screenshots and web-page "Copy Image"
        //    both work.
        if !types.contains(.string), !types.contains(.html),
           let image = NSImage(pasteboard: pb) {
            if let onImagePaste, let relPath = onImagePaste(image) {
                NSLog("[Slip] paste: image saved to \(relPath)")
                insertText("![](\(relPath))", replacementRange: selectedRange())
                return
            }
        }

        NSLog("[Slip] paste: falling through to plain-text default")
        super.paste(sender)
    }

    private func insertConvertedHTML(_ html: String) -> Bool {
        // Regex-based pass first — most reliable for the structural tags we
        // care about (links, headings, bold, italic, lists). Chrome /
        // Substack frequently style bold via `font-weight: 600` instead of
        // `<strong>`, which NSAttributedString doesn't always promote to
        // the `.bold` symbolic trait, so the previous attribute-walk
        // produced unstyled prose.
        let markdown = Self.convertHTMLToMarkdown(html)
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        NSLog("[Slip] paste: HTML→markdown preview: \(String(trimmed.prefix(200)))…")
        insertText(markdown, replacementRange: selectedRange())
        return true
    }

    private func insertConvertedRTF(_ rtf: Data) -> Bool {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attr = try? NSAttributedString(data: rtf, options: options, documentAttributes: nil)
        else { return false }
        let markdown = Self.attributedToMarkdown(attr)
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        insertText(markdown, replacementRange: selectedRange())
        return true
    }

    /// Lightweight HTML → Markdown converter. Intentionally simple (regex,
    /// no DOM parsing), so it can't handle deeply nested malformed markup,
    /// but it gets the common structural cases right where
    /// NSAttributedString's font-trait inference fails on CSS-styled
    /// content from Chrome/Notion/Substack.
    private static func convertHTMLToMarkdown(_ raw: String) -> String {
        var s = raw

        // 0. Drop everything inside <head> / <script> / <style> blocks —
        //    Chrome's HTML pasteboard often includes a full <html><head>…
        //    block of meta/style tags we don't want to text-leak.
        s = removeBlock(in: s, tag: "head")
        s = removeBlock(in: s, tag: "script")
        s = removeBlock(in: s, tag: "style")
        s = removeBlock(in: s, tag: "title")

        // 1. Block-level elements that affect paragraph layout. These get
        //    wrapped in `\n\n` so markdown sees real paragraph breaks.
        for level in (1...6).reversed() {
            let prefix = String(repeating: "#", count: level) + " "
            s = replaceTag(in: s, tag: "h\(level)") { content in
                "\n\n\(prefix)\(content.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
            }
        }
        s = replaceTag(in: s, tag: "blockquote") { content in
            "\n\n> " + content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: "\n> ")
            + "\n\n"
        }
        s = replaceTag(in: s, tag: "li") { content in
            "- \(content.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        s = replaceTag(in: s, tag: "p") { content in "\n\n\(content)\n\n" }
        s = replaceTag(in: s, tag: "div") { content in "\n\(content)\n" }

        // 2. Inline emphasis. Order matters: bold/italic before links so
        //    nested emphasis inside an `<a>` survives.
        s = replaceTag(in: s, tag: "strong") { "**\($0)**" }
        s = replaceTag(in: s, tag: "b") { "**\($0)**" }
        s = replaceTag(in: s, tag: "em") { "*\($0)*" }
        s = replaceTag(in: s, tag: "i") { "*\($0)*" }
        s = replaceTag(in: s, tag: "code") { "`\($0)`" }

        // 3. Links. Custom enumerator instead of a plain regex replace so
        //    we can trim/collapse whitespace inside the link text.
        //    Substack & friends often emit
        //      <a href="…">
        //        <button>Label →</button>
        //      </a>
        //    Naive replacement gave `[\n  Label →\n](url)`, which
        //    CommonMark refuses to parse as a link (newlines inside
        //    `[…]` aren't allowed) — so the brackets stayed visible.
        s = Self.replaceAnchors(in: s)

        // 4. Line breaks and horizontal rules.
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<hr\s*/?>"#, with: "\n\n---\n\n",
                                   options: [.regularExpression, .caseInsensitive])

        // 5. Strip every remaining tag.
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // 6. Decode the most common HTML entities.
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&rsquo;", "’"),
            ("&lsquo;", "‘"),
            ("&rdquo;", "”"),
            ("&ldquo;", "“"),
            ("&hellip;", "…"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&#8217;", "’"),
            ("&#8216;", "‘"),
            ("&#8220;", "“"),
            ("&#8221;", "”"),
        ]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities &#nnn;
        s = s.replacingOccurrences(
            of: #"&#(\d+);"#,
            with: "",
            options: .regularExpression
        )

        // 7. Collapse runs of blank lines down to a single empty line so
        //    we don't end up with a wall of vertical whitespace.
        s = s.replacingOccurrences(
            of: #"\n[ \t]*\n[ \t]*\n+"#,
            with: "\n\n",
            options: .regularExpression
        )

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replace every `<tag …>…</tag>` pair with the result of `transform`
    /// applied to the captured inner text. `[\s\S]*?` is the dotall-safe
    /// equivalent of `.*?` so we match across line breaks.
    private static func replaceTag(in input: String, tag: String,
                                   transform: (String) -> String) -> String {
        let pattern = #"<\#(tag)\b[^>]*>([\s\S]*?)</\#(tag)\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return input }
        let ns = input as NSString
        var result = ""
        var cursor = 0
        regex.enumerateMatches(in: input, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            let outer = m.range
            let inner = m.range(at: 1)
            if outer.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: outer.location - cursor))
            }
            let innerText = ns.substring(with: inner)
            result += transform(innerText)
            cursor = outer.location + outer.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }

    /// Strip `<tag … >…</tag>` blocks entirely.
    private static func removeBlock(in input: String, tag: String) -> String {
        replaceTag(in: input, tag: tag) { _ in "" }
    }

    /// Replace every `<a href="…">…</a>` (or single-quoted href) with a
    /// markdown link, trimming/collapsing whitespace inside the inner
    /// text. CommonMark refuses to parse `[text](url)` if the bracketed
    /// label contains a newline, so a multi-line button HTML wrapper
    /// would otherwise emit `[\n  Label →\n](url)` and the brackets
    /// would stay visible verbatim.
    private static func replaceAnchors(in input: String) -> String {
        let pattern = #"<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>([\s\S]*?)</a\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return input }
        let ns = input as NSString
        var result = ""
        var cursor = 0
        regex.enumerateMatches(in: input, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 4 else { return }
            let outer = m.range
            let dq = m.range(at: 1)
            let sq = m.range(at: 2)
            let inner = m.range(at: 3)
            let urlRange = dq.location != NSNotFound ? dq : sq
            guard urlRange.location != NSNotFound else { return }

            if outer.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: outer.location - cursor))
            }

            let url = ns.substring(with: urlRange)
            let cleaned = cleanInlineText(ns.substring(with: inner))
            if cleaned.isEmpty {
                // Empty label → emit the bare URL so the user still sees
                // something rather than a phantom `[](url)` link.
                result += url
            } else {
                result += "[\(cleaned)](\(url))"
            }
            cursor = outer.location + outer.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }

    /// Strip nested tags and collapse whitespace runs into a single
    /// space, so the output is safe to embed in CommonMark `[…]`.
    private static func cleanInlineText(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Convert an attributed string (from HTML/RTF) into a markdown
    /// approximation. Block level: lines whose first run is in a larger
    /// font become `# ` / `## ` / `### ` headings, paragraphs are
    /// separated by blank lines so the markdown parser keeps them apart.
    /// Inline level: bold/italic via font traits, links via `.link`.
    /// Object-replacement glyphs (`\u{fffc}` from inline images we can't
    /// fetch) are stripped.
    private static func attributedToMarkdown(_ attr: NSAttributedString) -> String {
        let nsString = attr.string as NSString
        let lines = attr.string.components(separatedBy: "\n")
        var blocks: [String] = []
        var lineStart = 0

        for line in lines {
            let lineLength = (line as NSString).length
            defer { lineStart += lineLength + 1 }

            if lineLength == 0 {
                // Blank line — paragraph separator. We'll emit it via
                // joining with "\n\n" below, so just skip here.
                continue
            }

            // Detect heading by font size from the first run on the line.
            var headingPrefix = ""
            let firstAttrs = attr.attributes(at: lineStart, effectiveRange: nil)
            if let font = firstAttrs[.font] as? NSFont {
                let size = font.pointSize
                if size >= 22 { headingPrefix = "# " }
                else if size >= 18 { headingPrefix = "## " }
                else if size >= 15.5 { headingPrefix = "### " }
            }

            let lineRange = NSRange(location: lineStart, length: lineLength)
            var lineMD = ""
            attr.enumerateAttributes(in: lineRange) { attrs, runRange, _ in
                let raw = nsString.substring(with: runRange)
                var text = raw.replacingOccurrences(of: "\u{fffc}", with: "")
                guard !text.isEmpty else { return }

                // Inline emphasis — but skip on heading lines so we don't
                // produce `# **Heading**` (most heading fonts inherit a
                // bold trait).
                let nonWS = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !nonWS.isEmpty, headingPrefix.isEmpty,
                   let font = attrs[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    let bold = traits.contains(.bold)
                    let italic = traits.contains(.italic)
                    if bold && italic {
                        text = "***\(text)***"
                    } else if bold {
                        text = "**\(text)**"
                    } else if italic {
                        text = "*\(text)*"
                    }
                }

                if let link = attrs[.link] {
                    let urlStr: String
                    if let u = link as? URL {
                        urlStr = u.absoluteString
                    } else if let s = link as? String {
                        urlStr = s
                    } else {
                        urlStr = "\(link)"
                    }
                    text = "[\(text)](\(urlStr))"
                }

                lineMD += text
            }

            blocks.append(headingPrefix + lineMD)
        }

        return blocks.joined(separator: "\n\n")
    }
}
