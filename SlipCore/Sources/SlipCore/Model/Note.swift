import Foundation

/// A single markdown note on disk.
///
/// `Note` is the canonical in-memory representation of a `.md` file within a `Vault`.
/// The file on disk is the source of truth; this struct is a read-through view plus
/// derived metadata stored in the index (`NoteIndex`).
public struct Note: Identifiable, Hashable, Sendable {
    /// Stable identifier derived from the path relative to the vault root.
    /// Survives file moves only if the caller updates the ID via rename.
    public let id: NoteID

    /// Absolute URL on disk. Always inside the vault root.
    public let url: URL

    /// Title as displayed in UI. Derived from (in order):
    /// 1. `title:` frontmatter key, 2. first H1, 3. filename without extension.
    public let title: String

    /// Full markdown body including frontmatter.
    public let body: String

    /// File system modification date.
    public let modifiedAt: Date

    /// File system creation date.
    public let createdAt: Date

    /// Last time the user opened this note in Slip (tracked separately from mtime
    /// so external edits don't count as "viewed").
    public let lastViewedAt: Date?

    public init(
        id: NoteID,
        url: URL,
        title: String,
        body: String,
        modifiedAt: Date,
        createdAt: Date,
        lastViewedAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.body = body
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.lastViewedAt = lastViewedAt
    }
}

/// Path-based note identifier, relative to the vault root, with forward slashes.
/// Example: `projects/devkoan/launch-plan.md`
public struct NoteID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let relativePath: String

    public init(relativePath: String) {
        // Normalize separators — we store POSIX-style for cross-platform
        // stability. Also force NFC composition so paths derived from URLs
        // (often NFC on APFS) match paths read from FileManager
        // enumerators (sometimes NFD on HFS+/network), which would
        // otherwise cause SQLite WHERE id = ? lookups to silently miss
        // and leave stale rows behind after rename/move.
        self.relativePath = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .precomposedStringWithCanonicalMapping
    }

    public var description: String { relativePath }
}
