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
    var onWikilinkClick: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

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

        context.coordinator.textView = textView
        textView.string = text
        context.coordinator.reapplyHighlighting()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
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

        case .link(let r, _):
            guard let range = nsRange(r) else { return }
            storage.addAttributes([
                .foregroundColor: NSColor.linkColor
            ], range: range)

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
