import Foundation

/// Writes note content to disk.
///
/// Uses `String.write(to:atomically:encoding:)` with atomically=true, which
/// stages to a sibling temp file and renames — so partial writes are
/// impossible if the app crashes mid-save.
///
/// Note: we previously wrapped this in `NSFileCoordinator` to coordinate with
/// file presenters (Obsidian, iA Writer). In practice the coordinator's
/// interaction with user-selected security-scoped bookmarks has been flaky
/// on recent macOS releases — it could translate the URL to one the sandbox
/// then refused to write to, producing NSCocoaErrorDomain 513 (EPERM). Direct
/// atomic write preserves crash-safety without that failure mode, and our
/// VaultWatcher already refreshes on external edits.
public final class NoteWriter {

    public init() {}

    public func write(_ body: String, to url: URL) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    public func createNew(in vault: Vault, title: String, folder: String = "", body: String = "") throws -> Note {
        let fm = FileManager.default
        let safeTitle = Self.safeFilename(from: title)
        let parentURL: URL
        if folder.isEmpty {
            parentURL = vault.root
        } else {
            parentURL = vault.root.appendingPathComponent(folder)
            if !fm.fileExists(atPath: parentURL.path) {
                try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
            }
        }
        var candidateURL = parentURL.appendingPathComponent("\(safeTitle).md")
        var suffix = 1
        while fm.fileExists(atPath: candidateURL.path) {
            suffix += 1
            candidateURL = parentURL.appendingPathComponent("\(safeTitle) \(suffix).md")
        }

        try write(body, to: candidateURL)
        let id = try vault.noteID(for: candidateURL)
        let now = Date()
        return Note(
            id: id, url: candidateURL, title: title, body: body,
            modifiedAt: now, createdAt: now
        )
    }

    public func append(_ text: String, to url: URL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let separator = existing.isEmpty || existing.hasSuffix("\n\n") ? "" :
                        existing.hasSuffix("\n") ? "\n" : "\n\n"
        try write(existing + separator + text + "\n", to: url)
    }

    // MARK: - Filename hygiene

    public static func safeFilename(from title: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = title.components(separatedBy: disallowed).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
