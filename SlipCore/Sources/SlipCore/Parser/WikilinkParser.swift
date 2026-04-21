import Foundation

/// Scans raw markdown text for `[[wikilinks]]` and `#tags`.
///
/// `swift-markdown` doesn't understand either construct natively, so we
/// discover them with targeted regex passes and return `NoteReference` values
/// with UTF-16 offsets that map directly onto `NSTextView` ranges.
public enum WikilinkParser {

    /// Matches `[[Target]]` or `[[Target|alias]]`. Disallows newlines and `]` inside.
    private static let wikilinkRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\[\[([^\[\]\n|]+)(?:\|([^\[\]\n]+))?\]\]"#)
    }()

    /// Matches `#tag` and `#nested/tag`. Requires the tag to start at line start
    /// or after whitespace so we don't match inside URLs or `#` headers.
    private static let tagRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(?:^|(?<=\s))#([A-Za-z][A-Za-z0-9_\-/]*)"#, options: [.anchorsMatchLines])
    }()

    public static func references(in text: String) -> [NoteReference] {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var results: [NoteReference] = []

        wikilinkRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match else { return }
            let target = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            let aliasRange = match.range(at: 2)
            let alias: String? = aliasRange.location == NSNotFound
                ? nil
                : ns.substring(with: aliasRange).trimmingCharacters(in: .whitespaces)
            let r = match.range
            results.append(.init(
                kind: .wikilink(target: target, alias: alias),
                range: r.location..<(r.location + r.length)
            ))
        }

        tagRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match else { return }
            let tag = ns.substring(with: match.range(at: 1))
            let r = match.range
            results.append(.init(
                kind: .tag(tag),
                range: r.location..<(r.location + r.length)
            ))
        }

        return results
    }
}
