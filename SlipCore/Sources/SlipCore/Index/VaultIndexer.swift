import Foundation
import CryptoKit

/// Coordinates the flow: Vault files → parsed content → NoteIndex rows.
///
/// Entry points:
/// - `fullReindex()` walks the entire vault. Use on first launch or vault switch.
/// - `reindex(urls:)` updates a set of files after internal saves or watcher events.
///   Handles creations, modifications, and deletions in one pass.
/// - `garbageCollect()` removes index rows for files that no longer exist on disk.
///
/// Title→ID resolution happens in two passes so wikilink targets can be
/// resolved even when they're introduced in the same batch. For incremental
/// updates, we use a title→ID map from the current DB so cross-note links stay
/// consistent. A full periodic relink (not yet scheduled) would be v0.3 work.
public final class VaultIndexer {

    private let vault: Vault
    private let index: NoteIndex

    public init(vault: Vault, index: NoteIndex) {
        self.vault = vault
        self.index = index
    }

    // MARK: - Full reindex

    public func fullReindex() throws {
        try vault.withAccess { _ in
            let urls = try vault.enumerateMarkdownFiles()

            // Pass 1: collect raw metadata so we can build a title → ID map.
            var raws: [(url: URL, id: NoteID, title: String, body: String,
                        created: Date, modified: Date)] = []
            var titleIndex: [String: NoteID] = [:]

            for url in urls {
                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let created = values.creationDate ?? Date()
                let modified = values.contentModificationDate ?? created
                let id = try vault.noteID(for: url)
                let title = Self.extractTitle(body: body, fallbackFilename: url.deletingPathExtension().lastPathComponent)
                raws.append((url, id, title, body, created, modified))
                // Lowercased key so wikilinks are case-insensitive on match.
                titleIndex[title.lowercased()] = id
            }

            // Pass 2: parse references + upsert into DB.
            for raw in raws {
                let refs = WikilinkParser.references(in: raw.body)

                var outgoing: [NoteIndex.OutgoingLink] = []
                var tags: [String] = Self.extractFrontmatterTags(body: raw.body)
                for ref in refs {
                    switch ref.kind {
                    case .wikilink(let target, _):
                        if let targetID = titleIndex[target.lowercased()] {
                            outgoing.append(.init(targetID: targetID, kind: "wikilink"))
                        }
                        // If no match, we skip — could also store as "pending" link.
                    case .tag(let t):
                        tags.append(t)
                    case .unlinkedMention:
                        break
                    }
                }

                // Unlinked mentions: scan body for other note titles. Cheap on
                // small vaults; for large vaults switch to a trie/Aho-Corasick.
                let lowerBody = raw.body.lowercased()
                for (titleKey, otherID) in titleIndex where otherID != raw.id {
                    // Require word-ish boundaries.
                    if lowerBody.contains(titleKey) {
                        // Skip if already a wikilink target.
                        if outgoing.contains(where: { $0.targetID == otherID }) { continue }
                        outgoing.append(.init(targetID: otherID, kind: "unlinked"))
                    }
                }

                let hash = Self.sha256(raw.body)
                let indexed = NoteIndex.IndexedNote(
                    id: raw.id,
                    title: raw.title,
                    path: raw.url.path,
                    body: raw.body,
                    createdAt: raw.created,
                    modifiedAt: raw.modified,
                    bodyHash: hash,
                    outgoingLinks: outgoing,
                    tags: tags
                )
                try index.upsert(indexed)
            }
        }
    }

    // MARK: - Incremental reindex

    /// Reindex only the given URLs. Missing files are treated as deletions.
    ///
    /// Behavior:
    /// - Filters to `.md` files within the vault (non-md and out-of-vault events
    ///   are ignored).
    /// - Uses the current DB's title→ID map for wikilink resolution. Cross-note
    ///   link drift (when a renamed note's title changes incoming references)
    ///   is acceptable between runs; a periodic relink pass handles it.
    /// - Skips the expensive unlinked-mention scan. Unlinked mentions are
    ///   resolved during `fullReindex()` only. This is a conscious tradeoff:
    ///   incremental stays O(edited files), unlinked-mentions stay fresh on
    ///   vault-wide events like opening a different vault.
    public func reindex(urls: [URL]) throws {
        try vault.withAccess { _ in
            // Build title map once from the current DB state.
            var titleIndex: [String: NoteID] = [:]
            for m in try index.allMetrics() {
                titleIndex[m.title.lowercased()] = m.id
            }

            let fm = FileManager.default

            for url in urls {
                // Filter out non-md and out-of-vault.
                guard url.pathExtension.lowercased() == "md" else { continue }
                let id: NoteID
                do {
                    id = try vault.noteID(for: url)
                } catch {
                    continue // outside vault
                }

                // Deleted file → remove from index.
                guard fm.fileExists(atPath: url.path) else {
                    try? index.delete(id: id)
                    continue
                }

                // Directory or bundle masquerading as .md — skip.
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue { continue }

                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let created = values.creationDate ?? Date()
                let modified = values.contentModificationDate ?? created
                let title = Self.extractTitle(
                    body: body,
                    fallbackFilename: url.deletingPathExtension().lastPathComponent
                )

                // Keep the title map fresh in case this batch includes multiple
                // new notes that reference each other.
                titleIndex[title.lowercased()] = id

                let refs = WikilinkParser.references(in: body)
                var outgoing: [NoteIndex.OutgoingLink] = []
                var tags: [String] = Self.extractFrontmatterTags(body: body)
                for ref in refs {
                    switch ref.kind {
                    case .wikilink(let target, _):
                        if let targetID = titleIndex[target.lowercased()] {
                            outgoing.append(.init(targetID: targetID, kind: "wikilink"))
                        }
                    case .tag(let t):
                        tags.append(t)
                    case .unlinkedMention:
                        break
                    }
                }

                // Unlinked-mention scan on the saved note too, so the graph
                // picks up bare title mentions immediately instead of only
                // on the next full reindex.
                let lowerBody = body.lowercased()
                for (titleKey, otherID) in titleIndex where otherID != id {
                    guard !titleKey.isEmpty else { continue }
                    if lowerBody.contains(titleKey),
                       !outgoing.contains(where: { $0.targetID == otherID }) {
                        outgoing.append(.init(targetID: otherID, kind: "unlinked"))
                    }
                }

                let hash = Self.sha256(body)
                let indexed = NoteIndex.IndexedNote(
                    id: id,
                    title: title,
                    path: url.path,
                    body: body,
                    createdAt: created,
                    modifiedAt: modified,
                    bodyHash: hash,
                    outgoingLinks: outgoing,
                    tags: tags
                )
                try index.upsert(indexed)
            }
        }
    }

    /// Remove index rows for `.md` files that no longer exist on disk.
    /// Run periodically (e.g., on app launch) to clean up after external deletes.
    public func garbageCollect() throws {
        try vault.withAccess { _ in
            let existing = Set(try vault.enumerateMarkdownFiles().compactMap {
                try? vault.noteID(for: $0)
            })
            let indexed = Set(try index.allNoteIDs())
            for stale in indexed.subtracting(existing) {
                try index.delete(id: stale)
            }
        }
    }

    // MARK: - Helpers

    /// Tags declared in YAML frontmatter (`tags: [foo, bar]` or block form).
    /// Combined with inline `#tags` from the body to make up the full tag set
    /// for a note.
    static func extractFrontmatterTags(body: String) -> [String] {
        guard body.hasPrefix("---\n") else { return [] }
        guard let close = body.range(of: "\n---\n",
                                     range: body.index(body.startIndex, offsetBy: 4)..<body.endIndex)
            ?? body.range(of: "\n---\r\n",
                          range: body.index(body.startIndex, offsetBy: 4)..<body.endIndex)
        else { return [] }
        let fmText = String(body[body.index(body.startIndex, offsetBy: 4)..<close.lowerBound])

        let lines = fmText.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("tags:") else { continue }
            let value = trimmed.dropFirst("tags:".count).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("[") && value.hasSuffix("]") {
                return value.dropFirst().dropLast()
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                    .filter { !$0.isEmpty }
            }
            var collected: [String] = []
            for sub in lines.dropFirst(i + 1) {
                let s = sub.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("- ") {
                    let item = String(s.dropFirst(2))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !item.isEmpty { collected.append(item) }
                } else if !s.isEmpty {
                    break
                }
            }
            return collected
        }
        return []
    }

    private static func extractTitle(body: String, fallbackFilename: String) -> String {
        // 1. frontmatter `title:` key.
        if body.hasPrefix("---\n"),
           let end = body.range(of: "\n---\n") {
            let fm = body[body.index(body.startIndex, offsetBy: 4)..<end.lowerBound]
            for line in fm.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("title:") {
                    let value = trimmed.dropFirst("title:".count)
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !value.isEmpty { return String(value) }
                }
            }
        }
        // 2. first H1.
        for line in body.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") {
                let title = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return Self.truncate(title) }
            }
        }
        // 3. first non-empty line. Users may type without an explicit H1 —
        //    with marker hiding, the `#` is invisible anyway, so requiring it
        //    would leave every note titled "Untitled". Strip leading block
        //    markers so they don't show up in the sidebar title.
        for line in body.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let cleaned = Self.stripLeadingMarkdownSyntax(t)
            if !cleaned.isEmpty { return Self.truncate(cleaned) }
        }
        // 4. filename.
        return fallbackFilename
    }

    private static func stripLeadingMarkdownSyntax(_ line: String) -> String {
        var s = line
        // Heading hashes of any level.
        while s.hasPrefix("#") { s = String(s.dropFirst()) }
        // Blockquote / list markers.
        while let first = s.first, "><-*".contains(first) { s = String(s.dropFirst()) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func truncate(_ s: String, limit: Int = 80) -> String {
        if s.count <= limit { return s }
        return String(s.prefix(limit)) + "…"
    }

    private static func sha256(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
