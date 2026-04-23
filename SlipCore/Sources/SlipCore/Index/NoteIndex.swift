import Foundation
import GRDB

/// SQLite-backed index of all notes in the vault.
///
/// Schema:
///   notes (id PK, title, path, created_at, modified_at, last_viewed_at,
///          view_count, body_hash)
///   notes_fts (virtual FTS5 over title + body, external content = notes)
///   links (source_id, target_id, kind)    -- kind: wikilink, tag, unlinked
///   tags  (note_id, tag)
///
/// The DB lives in Application Support, *not* in the vault folder — we want
/// external sync (iCloud Drive / Dropbox) to carry only the .md files. The
/// index is rebuilt on first open if missing, or incrementally on file change.
public final class NoteIndex {

    private let dbQueue: DatabaseQueue

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.dbQueue = try DatabaseQueue(path: databaseURL.path)
        try migrate()
    }

    /// Convenience: standard Application Support location per vault.
    public static func defaultURL(for vaultID: String) throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Slip/Indexes", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(vaultID).sqlite")
    }

    // MARK: - Schema

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE notes (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    path TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    modified_at REAL NOT NULL,
                    last_viewed_at REAL,
                    view_count INTEGER NOT NULL DEFAULT 0,
                    body_hash TEXT NOT NULL
                );
                CREATE INDEX idx_notes_modified ON notes(modified_at DESC);
                CREATE INDEX idx_notes_viewed ON notes(last_viewed_at);

                CREATE VIRTUAL TABLE notes_fts USING fts5(
                    title, body,
                    content='', tokenize='unicode61 remove_diacritics 2'
                );

                CREATE TABLE links (
                    source_id TEXT NOT NULL,
                    target_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    PRIMARY KEY (source_id, target_id, kind)
                );
                CREATE INDEX idx_links_target ON links(target_id);

                CREATE TABLE tags (
                    note_id TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    PRIMARY KEY (note_id, tag)
                );
                CREATE INDEX idx_tags_tag ON tags(tag);
            """)
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Upsert

    public struct IndexedNote {
        public let id: NoteID
        public let title: String
        public let path: String
        public let body: String
        public let createdAt: Date
        public let modifiedAt: Date
        public let bodyHash: String
        public let outgoingLinks: [OutgoingLink]
        public let tags: [String]

        public init(
            id: NoteID,
            title: String,
            path: String,
            body: String,
            createdAt: Date,
            modifiedAt: Date,
            bodyHash: String,
            outgoingLinks: [OutgoingLink],
            tags: [String]
        ) {
            self.id = id; self.title = title; self.path = path; self.body = body
            self.createdAt = createdAt; self.modifiedAt = modifiedAt
            self.bodyHash = bodyHash; self.outgoingLinks = outgoingLinks; self.tags = tags
        }
    }

    public struct OutgoingLink {
        public let targetID: NoteID
        public let kind: String // "wikilink" | "unlinked"
        public init(targetID: NoteID, kind: String) {
            self.targetID = targetID; self.kind = kind
        }
    }

    public func upsert(_ note: IndexedNote) throws {
        try dbQueue.write { db in
            // 1. Notes row — preserve view tracking on update.
            try db.execute(sql: """
                INSERT INTO notes (id, title, path, created_at, modified_at, body_hash)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    path = excluded.path,
                    modified_at = excluded.modified_at,
                    body_hash = excluded.body_hash
            """, arguments: [
                note.id.relativePath, note.title, note.path,
                note.createdAt.timeIntervalSince1970, note.modifiedAt.timeIntervalSince1970,
                note.bodyHash
            ])

            // 2. FTS: delete by rowid (linked to notes.rowid), then reinsert.
            //    Using content='' means we fully own the FTS rows — no shadow sync.
            try db.execute(sql: """
                DELETE FROM notes_fts
                WHERE rowid = (SELECT rowid FROM notes WHERE id = ?)
            """, arguments: [note.id.relativePath])
            try db.execute(sql: """
                INSERT INTO notes_fts (rowid, title, body)
                VALUES ((SELECT rowid FROM notes WHERE id = ?), ?, ?)
            """, arguments: [note.id.relativePath, note.title, note.body])

            // 3. Links — fully replace for this source.
            try db.execute(sql: "DELETE FROM links WHERE source_id = ?", arguments: [note.id.relativePath])
            for link in note.outgoingLinks {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO links (source_id, target_id, kind)
                    VALUES (?, ?, ?)
                """, arguments: [note.id.relativePath, link.targetID.relativePath, link.kind])
            }

            // 4. Tags — fully replace.
            try db.execute(sql: "DELETE FROM tags WHERE note_id = ?", arguments: [note.id.relativePath])
            for tag in Set(note.tags) {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO tags (note_id, tag) VALUES (?, ?)
                """, arguments: [note.id.relativePath, tag])
            }
        }
    }

    public func delete(id: NoteID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes_fts WHERE rowid = (SELECT rowid FROM notes WHERE id = ?)", arguments: [id.relativePath])
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id.relativePath])
            try db.execute(sql: "DELETE FROM links WHERE source_id = ? OR target_id = ?", arguments: [id.relativePath, id.relativePath])
            try db.execute(sql: "DELETE FROM tags WHERE note_id = ?", arguments: [id.relativePath])
        }
    }

    // MARK: - Reads

    public func recordView(id: NoteID, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE notes
                SET last_viewed_at = ?, view_count = view_count + 1
                WHERE id = ?
            """, arguments: [date.timeIntervalSince1970, id.relativePath])
        }
    }

    public func backlinks(to id: NoteID) throws -> [NoteID] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source_id FROM links
                WHERE target_id = ? AND kind IN ('wikilink', 'unlinked')
                ORDER BY source_id
            """, arguments: [id.relativePath])
            return rows.map { NoteID(relativePath: $0["source_id"]) }
        }
    }

    public func allNoteIDs() throws -> [NoteID] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id FROM notes ORDER BY modified_at DESC")
            return rows.map { NoteID(relativePath: $0["id"]) }
        }
    }

    public struct TagCount: Hashable, Sendable {
        public let tag: String
        public let count: Int
        public init(tag: String, count: Int) {
            self.tag = tag
            self.count = count
        }
    }

    public func listTags() throws -> [TagCount] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT tag, COUNT(*) AS cnt
                FROM tags
                GROUP BY tag
                ORDER BY cnt DESC, tag ASC
            """)
            return rows.map { TagCount(tag: $0["tag"], count: $0["cnt"]) }
        }
    }

    public func noteIDs(withTag tag: String) throws -> [NoteID] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.note_id
                FROM tags t
                JOIN notes n ON n.id = t.note_id
                WHERE t.tag = ?
                ORDER BY n.modified_at DESC
            """, arguments: [tag])
            return rows.map { NoteID(relativePath: $0["note_id"]) }
        }
    }

    public func search(_ query: String, limit: Int = 50) throws -> [NoteID] {
        // FTS5 requires escaping — wrap user input as a phrase query.
        let escaped = query
            .replacingOccurrences(of: "\"", with: "\"\"")
        let ftsQuery = "\"\(escaped)\" OR \(escaped)*"
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.id
                FROM notes_fts f
                JOIN notes n ON n.rowid = f.rowid
                WHERE notes_fts MATCH ?
                ORDER BY rank
                LIMIT ?
            """, arguments: [ftsQuery, limit])
            return rows.map { NoteID(relativePath: $0["id"]) }
        }
    }

    /// Metadata snapshot used by the RediscoveryEngine.
    public struct NoteMetrics {
        public let id: NoteID
        public let title: String
        public let createdAt: Date
        public let modifiedAt: Date
        public let lastViewedAt: Date?
        public let viewCount: Int
        public let incomingLinks: Int
        public let outgoingLinks: Int
        public let tags: [String]
    }

    public func allMetrics() throws -> [NoteMetrics] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    n.id, n.title, n.created_at, n.modified_at,
                    n.last_viewed_at, n.view_count,
                    (SELECT COUNT(*) FROM links WHERE target_id = n.id) AS incoming,
                    (SELECT COUNT(*) FROM links WHERE source_id = n.id) AS outgoing
                FROM notes n
            """)
            return rows.map { row in
                let id = NoteID(relativePath: row["id"])
                let lastViewedRaw: TimeInterval? = row["last_viewed_at"]
                return NoteMetrics(
                    id: id,
                    title: row["title"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    modifiedAt: Date(timeIntervalSince1970: row["modified_at"]),
                    lastViewedAt: lastViewedRaw.map { Date(timeIntervalSince1970: $0) },
                    viewCount: row["view_count"],
                    incomingLinks: row["incoming"],
                    outgoingLinks: row["outgoing"],
                    tags: [] // filled by caller if needed, keeps this query flat
                )
            }
        }
    }
}
