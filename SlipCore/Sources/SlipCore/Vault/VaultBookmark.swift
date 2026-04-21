import Foundation

/// Persists access to a user-selected folder across app launches using
/// security-scoped bookmark data.
///
/// Usage:
///   // After NSOpenPanel returns a URL:
///   let bookmark = try VaultBookmark.create(from: url)
///   UserDefaults.standard.set(bookmark.data, forKey: "VaultBookmark")
///
///   // On next launch:
///   let data = UserDefaults.standard.data(forKey: "VaultBookmark")!
///   let bookmark = VaultBookmark(data: data)
///   let vault = try Vault(bookmark: bookmark)
public struct VaultBookmark: Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public static func create(from url: URL) throws -> VaultBookmark {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return VaultBookmark(data: data)
    }

    /// Resolve the bookmark back to a URL. Throws if the bookmark is stale
    /// (folder moved/deleted), in which case the caller should re-prompt the user.
    public func resolve() throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale { throw Vault.VaultError.staleBookmark }
        return url
    }
}
