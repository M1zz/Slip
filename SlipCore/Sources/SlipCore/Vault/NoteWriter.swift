import Foundation

/// Writes note content to disk using `NSFileCoordinator` so external editors
/// (Obsidian, iA Writer, vim) and iCloud Drive sync see consistent state.
///
/// Writes are atomic: we use `.atomic` so partial writes are impossible if the
/// app crashes mid-save.
public final class NoteWriter {

    public init() {}

    public func write(_ body: String, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var innerError: Error?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try body.write(to: coordinatedURL, atomically: true, encoding: .utf8)
            } catch {
                innerError = error
            }
        }

        if let e = coordinationError { throw e }
        if let e = innerError { throw e }
    }

    public func createNew(in vault: Vault, title: String, body: String = "") throws -> Note {
        let fm = FileManager.default
        let safeTitle = Self.safeFilename(from: title)
        var candidateURL = vault.root.appendingPathComponent("\(safeTitle).md")
        var suffix = 1
        while fm.fileExists(atPath: candidateURL.path) {
            suffix += 1
            candidateURL = vault.root.appendingPathComponent("\(safeTitle) \(suffix).md")
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

    private static func safeFilename(from title: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = title.components(separatedBy: disallowed).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
