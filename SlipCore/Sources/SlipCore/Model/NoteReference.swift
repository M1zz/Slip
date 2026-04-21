import Foundation

/// A structured reference discovered inside a note's body.
///
/// Three kinds:
/// - `.wikilink`: `[[Target Note]]` or `[[Target|alias]]`. Resolved lazily against
///    the vault's title→ID map.
/// - `.tag`: `#tag` or `#nested/tag`, using the hierarchical tag convention.
/// - `.unlinkedMention`: plain-text appearance of another note's title with no
///    surrounding brackets. Populated by the indexer, not the parser.
public struct NoteReference: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case wikilink(target: String, alias: String?)
        case tag(String)
        case unlinkedMention(targetID: NoteID)
    }

    public let kind: Kind
    /// UTF-16 offset into the note body, suitable for direct use with
    /// `NSAttributedString` / `NSTextView`.
    public let range: Range<Int>

    public init(kind: Kind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }
}
