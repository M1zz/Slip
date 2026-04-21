import Foundation

/// A user-selected folder containing markdown notes.
///
/// The `Vault` holds a security-scoped URL (granted by `NSOpenPanel` and persisted
/// via `VaultBookmark`), and provides scoped access to read/write operations.
///
/// Lifecycle:
///   let vault = try Vault(bookmarkData: stored)
///   try vault.withAccess { root in
///       // do file IO
///   }
public final class Vault: @unchecked Sendable {

    public enum VaultError: Error {
        case accessDenied
        case outsideVault
        case staleBookmark
    }

    public let root: URL
    private let bookmark: VaultBookmark
    private var accessing = false

    public init(bookmark: VaultBookmark) throws {
        self.bookmark = bookmark
        self.root = try bookmark.resolve()
    }

    /// Start security-scoped access. Call `endAccess()` when done, or use
    /// `withAccess { … }`.
    @discardableResult
    public func beginAccess() -> Bool {
        guard !accessing else { return true }
        accessing = root.startAccessingSecurityScopedResource()
        return accessing
    }

    public func endAccess() {
        guard accessing else { return }
        root.stopAccessingSecurityScopedResource()
        accessing = false
    }

    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard beginAccess() else { throw VaultError.accessDenied }
        defer { endAccess() }
        return try body(root)
    }

    // MARK: - Path utilities

    /// Convert an absolute URL inside the vault to a `NoteID`.
    public func noteID(for url: URL) throws -> NoteID {
        let rootPath = root.standardizedFileURL.path
        let absPath = url.standardizedFileURL.path
        guard absPath.hasPrefix(rootPath) else {
            throw VaultError.outsideVault
        }
        var rel = String(absPath.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return NoteID(relativePath: rel)
    }

    public func url(for id: NoteID) -> URL {
        root.appendingPathComponent(id.relativePath)
    }

    // MARK: - Enumeration

    /// Walk the vault and yield every `.md` file URL. The caller must have
    /// an active security scope (via `withAccess`) or the vault must already
    /// be accessing.
    public func enumerateMarkdownFiles() throws -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles,
            .skipsPackageDescendants
        ]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            guard url.pathExtension.lowercased() == "md" else { continue }
            urls.append(url)
        }
        return urls
    }
}
