import Foundation
import AppKit
import SwiftUI
import SlipCore

@MainActor
final class AppState: ObservableObject {

    // MARK: - Vault

    @Published var vault: Vault?
    @Published var noteList: [NoteID] = []
    @Published var currentNoteID: NoteID?
    /// Title of the currently open note, shown as a dedicated field in the
    /// editor. Split out of the body on open and combined back in on save
    /// as the note's first H1 — so the on-disk `.md` stays a plain markdown
    /// file that Obsidian, iA Writer etc. can read untouched.
    @Published var currentNoteTitle: String = ""
    /// Body WITHOUT the title H1 line. Round-trips as `# <title>\n\n<body>`
    /// when combined for save.
    @Published var currentNoteBody: String = ""
    /// Incremented by the toolbar/⌘K handler to ask the active editor to
    /// insert `[[` at the cursor (which triggers the existing wikilink
    /// autocomplete). MarkdownTextView observes this counter.
    @Published var insertLinkRequest: Int = 0
    @Published var searchQuery: String = "" {
        didSet { runSearch() }
    }
    @Published var searchResults: [NoteID] = []
    @Published var backlinks: [NoteID] = []
    @Published var rediscovery: [RediscoveryEngine.RediscoveryCard] = []
    @Published var titleByID: [NoteID: String] = [:]
    @Published var tags: [NoteIndex.TagCount] = []
    @Published var selectedTag: String? {
        didSet { applyTagFilter() }
    }

    /// Full list from the index; `noteList` reflects the current tag filter.
    private var allNoteIDs: [NoteID] = []

    // MARK: - Services

    private var index: NoteIndex?
    private var indexer: VaultIndexer?
    private let writer = NoteWriter()
    private let rediscoveryEngine = RediscoveryEngine()

    // MARK: - Vault lifecycle

    func openVault(at url: URL) {
        do {
            let bookmark = try VaultBookmark.create(from: url)
            UserDefaults.standard.set(bookmark.data, forKey: "VaultBookmark")
            try activate(bookmark: bookmark)
        } catch {
            NSLog("Failed to open vault: \(error)")
        }
    }

    func restoreVault() {
        guard let data = UserDefaults.standard.data(forKey: "VaultBookmark") else { return }
        do {
            try activate(bookmark: VaultBookmark(data: data))
        } catch {
            NSLog("Failed to restore vault: \(error)")
            UserDefaults.standard.removeObject(forKey: "VaultBookmark")
        }
    }

    private var watcher: VaultWatcher?
    /// Tracks files we saved ourselves within the last second. Lets us ignore
    /// the FSEvent echo that follows an in-app write.
    private var recentInternalWrites: [String: Date] = [:]

    private func activate(bookmark: VaultBookmark) throws {
        // Tear down any previous session cleanly.
        watcher?.stop()
        watcher = nil

        let vault = try Vault(bookmark: bookmark)
        let accessGranted = vault.beginAccess()
        NSLog("[Slip] vault opened at \(vault.root.path), security-scope access=\(accessGranted)")
        let vaultID = Self.stableVaultID(for: vault.root)
        let dbURL = try NoteIndex.defaultURL(for: vaultID)
        let index = try NoteIndex(databaseURL: dbURL)
        let indexer = VaultIndexer(vault: vault, index: index)

        self.vault = vault
        self.index = index
        self.indexer = indexer

        Task.detached { [weak self] in
            do {
                try indexer.fullReindex()
                try indexer.garbageCollect()
                await self?.refreshAfterIndex()
                await self?.startWatching()
            } catch {
                NSLog("Reindex failed: \(error)")
            }
        }
    }

    private func startWatching() {
        guard let vault, watcher == nil else { return }
        let w = VaultWatcher(root: vault.root) { [weak self] urls in
            Task { @MainActor in
                self?.handleExternalChanges(urls: urls)
            }
        }
        do {
            try w.start()
            self.watcher = w
        } catch {
            NSLog("VaultWatcher failed to start: \(error)")
        }
    }

    private func handleExternalChanges(urls: [URL]) {
        guard let indexer else { return }
        // Drop events for files we just wrote ourselves (echo suppression).
        let cutoff = Date().addingTimeInterval(-1.5)
        recentInternalWrites = recentInternalWrites.filter { $0.value > cutoff }

        let filtered = urls.filter { url in
            guard url.pathExtension.lowercased() == "md" else { return false }
            if let when = recentInternalWrites[url.standardizedFileURL.path],
               when > cutoff {
                return false
            }
            return true
        }
        guard !filtered.isEmpty else { return }

        Task.detached { [weak self] in
            try? indexer.reindex(urls: filtered)
            await self?.refreshAfterIndex()
        }
    }

    private func refreshAfterIndex() {
        guard let index else { return }
        do {
            self.allNoteIDs = try index.allNoteIDs()
            self.titleByID = Dictionary(uniqueKeysWithValues:
                try index.allMetrics().map { ($0.id, $0.title) }
            )
            self.tags = (try? index.listTags()) ?? []
            applyTagFilter()
            refreshRediscovery()
        } catch {
            NSLog("Refresh failed: \(error)")
        }
    }

    func graphSnapshot() -> NoteIndex.GraphSnapshot? {
        guard let index else { return nil }
        return try? index.graphSnapshot()
    }

    private func applyTagFilter() {
        guard let index else {
            noteList = allNoteIDs
            return
        }
        if let tag = selectedTag {
            noteList = (try? index.noteIDs(withTag: tag)) ?? []
        } else {
            noteList = allNoteIDs
        }
    }

    // MARK: - Note operations

    func openNote(_ id: NoteID) {
        guard let vault, let index else { return }
        // Flush any pending edits on the outgoing note before we swap state.
        // Without this, clicking a new note within the editor's debounce
        // window (0.8s) would silently drop the in-progress changes.
        if currentNoteID != nil, currentNoteID != id {
            saveCurrentNote()
        }
        let url = vault.url(for: id)
        let fullContent = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let (title, body) = Self.splitTitleAndBody(fullContent)
        self.currentNoteID = id
        self.currentNoteTitle = title
        self.currentNoteBody = body
        self.backlinks = (try? index.backlinks(to: id)) ?? []
        try? index.recordView(id: id)
    }

    func requestInsertLink() {
        insertLinkRequest &+= 1
    }

    /// Split a note's full `.md` content into an explicit title (from the
    /// first H1 line, if any) and the remaining body. Leading blank lines
    /// are preserved only if there was no H1 to consume.
    static func splitTitleAndBody(_ fullContent: String) -> (title: String, body: String) {
        let lines = fullContent.components(separatedBy: "\n")
        var i = 0
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            i += 1
        }
        guard i < lines.count else { return ("", fullContent) }
        let first = lines[i].trimmingCharacters(in: .whitespaces)
        guard first.hasPrefix("# ") else { return ("", fullContent) }
        let title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)

        // Drop the H1 line and one trailing blank line if present.
        var after = i + 1
        if after < lines.count, lines[after].trimmingCharacters(in: .whitespaces).isEmpty {
            after += 1
        }
        let body = after >= lines.count ? "" : lines[after...].joined(separator: "\n")
        return (title, body)
    }

    /// Rejoin the edited title and body into a full markdown document. Empty
    /// titles result in a bodyless-first file (no H1 at all).
    static func combineTitleAndBody(title: String, body: String) -> String {
        let t = title.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return body }
        if body.isEmpty { return "# \(t)\n" }
        return "# \(t)\n\n\(body)"
    }

    func saveCurrentNote() {
        guard let vault else {
            NSLog("[Slip] saveCurrentNote skipped: no vault")
            return
        }
        guard let id = currentNoteID else {
            NSLog("[Slip] saveCurrentNote skipped: no currentNoteID")
            return
        }
        let url = vault.url(for: id)
        let fullContent = Self.combineTitleAndBody(title: currentNoteTitle, body: currentNoteBody)
        do {
            try writer.write(fullContent, to: url)
            NSLog("[Slip] saved \(fullContent.count) chars to \(url.path)")
            markInternalWrite(url: url)
            reindexIncrementally([url])
        } catch {
            NSLog("[Slip] Save failed for \(url.path): \(error)")
        }
    }

    func createNewNote() {
        guard let vault else {
            NSLog("[Slip] createNewNote skipped: no vault")
            return
        }
        // Flush pending edits on the current note before creating a new one.
        if currentNoteID != nil {
            saveCurrentNote()
        }
        do {
            // Empty body — the title will come from whatever the user types on
            // the first line (see VaultIndexer.extractTitle's first-non-empty
            // fallback). No placeholder avoids the stale "Untitled" H1 sticking
            // around when the user types below it instead of replacing it.
            let note = try writer.createNew(in: vault, title: "Untitled", body: "")
            NSLog("[Slip] created note at \(note.url.path)")
            currentNoteID = note.id
            currentNoteTitle = ""
            currentNoteBody = ""
            markInternalWrite(url: note.url)
            reindexIncrementally([note.url])
        } catch {
            NSLog("[Slip] Create failed in \(vault.root.path): \(error)")
        }
    }

    /// Called by AppDelegate after Quick Capture commits — appends to today's daily note.
    func appendToDailyNote(_ text: String) {
        guard let vault else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = formatter.string(from: Date()) + ".md"
        let url = vault.root.appendingPathComponent(filename)

        var entry = ""
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        entry += "- \(ts) \(text)"
        do {
            try writer.append(entry, to: url)
            markInternalWrite(url: url)
            reindexIncrementally([url])
        } catch {
            NSLog("Quick capture append failed: \(error)")
        }
    }

    private func markInternalWrite(url: URL) {
        recentInternalWrites[url.standardizedFileURL.path] = Date()
    }

    private func reindexIncrementally(_ urls: [URL]) {
        guard let indexer else { return }
        Task.detached { [weak self] in
            try? indexer.reindex(urls: urls)
            await self?.refreshAfterIndex()
        }
    }

    // MARK: - Search

    private func runSearch() {
        guard let index else { searchResults = []; return }
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchResults = []; return }
        searchResults = (try? index.search(q)) ?? []
    }

    // MARK: - Rediscovery

    func refreshRediscovery() {
        guard let index else { return }
        do {
            let metrics = try index.allMetrics()
            let context: RediscoveryEngine.Context
            if let current = currentNoteID {
                let linked = Set(try index.backlinks(to: current)) // proxy for linked set
                context = RediscoveryEngine.Context(
                    currentNoteID: current,
                    linkedTargets: linked
                )
            } else {
                context = .none
            }
            self.rediscovery = rediscoveryEngine.rediscover(from: metrics, context: context)
        } catch {
            NSLog("Rediscovery failed: \(error)")
        }
    }

    // MARK: - Helpers

    private static func stableVaultID(for url: URL) -> String {
        // Hash the canonical path so different vaults get different DBs.
        let path = url.standardizedFileURL.path
        var hasher = Hasher()
        hasher.combine(path)
        let value = UInt64(bitPattern: Int64(hasher.finalize()))
        return String(value, radix: 16)
    }
}
