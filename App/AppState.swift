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
    /// Tags managed by the editor's tag bar. Persisted as a YAML
    /// frontmatter array (`tags: [foo, bar]`) so the body stays clean
    /// for export and so other markdown editors (Obsidian, iA Writer)
    /// recognize them.
    @Published var currentNoteTags: [String] = []
    /// Frontmatter lines we don't manage (description, canonical_url,
    /// published, cover_image, series, …). Round-tripped verbatim on
    /// save so importing a Dev.to / Hugo / Jekyll post and re-saving
    /// doesn't drop the publish metadata.
    @Published var currentNoteExtraFrontmatter: String = ""
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
    /// Relative paths of all folders inside the vault (empty or not).
    /// Drives both the empty-folder display in the sidebar tree and the
    /// "Move to…" submenu choices.
    @Published var allFolders: [String] = []
    /// Every `- [ ]` / `- [x]` task across the vault, refreshed whenever
    /// the index is rewritten. Drives the inspector's aggregated view.
    @Published var allTodos: [TodoItem] = []
    /// Bumped after every index refresh. The Graph window observes this
    /// counter to re-pull the snapshot when notes/tags/links change in
    /// the main editor — without this, edits made in the main window
    /// leave the open graph stuck on the old layout.
    @Published var graphRevision: Int = 0

    /// Full list from the index; `noteList` reflects the current tag filter.
    private var allNoteIDs: [NoteID] = []

    /// IDs that were just deleted, with the timestamp of deletion. Used
    /// to filter the deleted note out of any subsequent
    /// refreshAfterIndex pass — without this, a vault that lives on
    /// iCloud Drive can resurrect the file after `trashItem` because
    /// the cloud sync brings it back, the watcher reports it, and the
    /// next indexer pass picks it up. Entries expire after 30 seconds.
    private var deletionTombstones: [NoteID: Date] = [:]

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
            // Expire tombstones so they can't block intentional recreation later.
            let cutoff = Date().addingTimeInterval(-30)
            deletionTombstones = deletionTombstones.filter { $0.value > cutoff }
            let blocked = Set(deletionTombstones.keys)

            let dbIDs = try index.allNoteIDs()
            self.allNoteIDs = dbIDs.filter { !blocked.contains($0) }
            self.titleByID = Dictionary(uniqueKeysWithValues:
                try index.allMetrics()
                    .filter { !blocked.contains($0.id) }
                    .map { ($0.id, $0.title) }
            )
            self.tags = (try? index.listTags()) ?? []
            self.allFolders = listFoldersOnDisk()
            self.allTodos = (try? index.allTodos()) ?? []
            self.graphRevision &+= 1
            applyTagFilter()
            refreshRediscovery()
        } catch {
            NSLog("[Slip] refresh failed: \(error)")
        }
    }

    /// Snapshot the vault's directory tree so we can show empty folders
    /// in the sidebar and offer them in "Move to…" submenus.
    private func listFoldersOnDisk() -> [String] {
        guard let vault else { return [] }
        do {
            let urls = try vault.withAccess { _ in try vault.enumerateDirectories() }
            let rootPath = vault.root.standardizedFileURL.path
            var rels: [String] = []
            for url in urls {
                let abs = url.standardizedFileURL.path
                guard abs.hasPrefix(rootPath) else { continue }
                var rel = String(abs.dropFirst(rootPath.count))
                if rel.hasPrefix("/") { rel.removeFirst() }
                if !rel.isEmpty { rels.append(rel) }
            }
            return rels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            NSLog("[Slip] enumerateDirectories failed: \(error)")
            return []
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
            let dbIDs = (try? index.noteIDs(withTag: tag)) ?? []
            // Intersect with allNoteIDs so optimistically-deleted notes
            // disappear immediately even though the DB row hasn't been
            // removed yet by the background reindex.
            let valid = Set(allNoteIDs)
            noteList = dbIDs.filter { valid.contains($0) }
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
        let parsed = Self.parseNote(fullContent)
        self.currentNoteID = id
        self.currentNoteTitle = parsed.title
        self.currentNoteBody = parsed.body
        self.currentNoteTags = parsed.tags
        self.currentNoteExtraFrontmatter = parsed.extraFrontmatter
        self.backlinks = (try? index.backlinks(to: id)) ?? []
        try? index.recordView(id: id)
    }

    func requestInsertLink() {
        insertLinkRequest &+= 1
    }

    /// Save a pasted/dragged image into the vault's `_attachments/` folder
    /// and return the relative markdown path for embedding. Returns nil
    /// if there's no vault, the image can't be encoded, or the write
    /// fails.
    func savePastedImage(_ image: NSImage) -> String? {
        guard let vault else { return nil }
        let attachmentsURL = vault.root.appendingPathComponent("_attachments", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = formatter.string(from: Date())
            // Random-ish suffix so multiple pastes within the same second
            // don't collide.
            let suffix = String(Int.random(in: 1000...9999))
            let filename = "paste-\(stamp)-\(suffix).png"
            let imageURL = attachmentsURL.appendingPathComponent(filename)
            guard let pngData = Self.pngData(from: image) else {
                NSLog("[Slip] savePastedImage: could not encode PNG")
                return nil
            }
            try pngData.write(to: imageURL)
            NSLog("[Slip] saved pasted image to \(imageURL.path)")
            markInternalWrite(url: imageURL)
            return "_attachments/\(filename)"
        } catch {
            NSLog("[Slip] savePastedImage failed: \(error)")
            return nil
        }
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    struct ParsedNote {
        let title: String
        let body: String
        let tags: [String]
        let extraFrontmatter: String
    }

    /// Parse the full `.md` content into editable parts: optional YAML
    /// frontmatter tags, an optional H1 title line, and the remaining body.
    /// Frontmatter is stripped from `body` so the editor only shows the
    /// user's writing — tags are managed separately by the tag bar.
    /// Inline `#tags` left in the body (from notes written before this
    /// scheme) are also extracted into the tag list and removed from the
    /// body — saving the note then writes them back as frontmatter, so
    /// notes get migrated quietly the next time they're opened.
    static func parseNote(_ fullContent: String) -> ParsedNote {
        var content = fullContent
        var fmTags: [String] = []
        var fmTitle = ""
        var extra = ""

        if content.hasPrefix("---\n") {
            let afterOpen = content.index(content.startIndex, offsetBy: 4)
            let closeRange =
                content.range(of: "\n---\n", range: afterOpen..<content.endIndex)
                ?? content.range(of: "\n---\r\n", range: afterOpen..<content.endIndex)
            if let close = closeRange {
                let fmText = String(content[afterOpen..<close.lowerBound])
                let parsed = parseFrontmatter(fmText)
                fmTitle = parsed.title
                fmTags = parsed.tags
                extra = parsed.extra
                content = String(content[close.upperBound...])
            }
        }

        // Title resolution: frontmatter `title:` wins over a body H1.
        // If the body still has a matching `# Title` line at top, strip
        // it so we don't show the title twice.
        let bodyTitle: String
        let bodyAfterTitle: String
        if !fmTitle.isEmpty {
            bodyTitle = fmTitle
            bodyAfterTitle = stripMatchingH1(from: content, matching: fmTitle)
        } else {
            let (extracted, rest) = splitTitleAndBody(content)
            bodyTitle = extracted
            bodyAfterTitle = rest
        }

        let (cleanBody, inlineTags) = extractInlineTagsFromBody(bodyAfterTitle)

        var seen = Set<String>()
        var ordered: [String] = []
        for t in fmTags + inlineTags where !seen.contains(t) {
            seen.insert(t)
            ordered.append(t)
        }
        return ParsedNote(title: bodyTitle, body: cleanBody, tags: ordered, extraFrontmatter: extra)
    }

    /// Walk every line in a frontmatter block, separating the keys we
    /// manage (title, tags) from everything else. The "everything else"
    /// is preserved verbatim so importing a Dev.to/Hugo/Jekyll post and
    /// re-saving doesn't lose canonical_url, description, etc.
    static func parseFrontmatter(_ fm: String) -> (title: String, tags: [String], extra: String) {
        let lines = fm.components(separatedBy: "\n")
        var title = ""
        var tags: [String] = []
        var extraLines: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lowered = trimmed.lowercased()

            if lowered.hasPrefix("title:") {
                title = String(trimmed.dropFirst("title:".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                i += 1
                continue
            }
            if lowered.hasPrefix("tags:") {
                let value = trimmed.dropFirst("tags:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    if value.hasPrefix("[") && value.hasSuffix("]") {
                        tags = parseCSVValue(String(value.dropFirst().dropLast()))
                    } else {
                        // Bare comma-separated form (Dev.to: `tags: a, b, c`)
                        // or a single-tag form (`tags: foo`).
                        tags = parseCSVValue(value)
                    }
                    i += 1
                    continue
                }
                // Block form on subsequent indented `- item` lines.
                i += 1
                while i < lines.count {
                    let sub = lines[i].trimmingCharacters(in: .whitespaces)
                    if sub.hasPrefix("- ") {
                        let item = String(sub.dropFirst(2))
                            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                        if !item.isEmpty { tags.append(item) }
                        i += 1
                    } else {
                        break
                    }
                }
                continue
            }
            extraLines.append(line)
            i += 1
        }

        let extra = extraLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return (title, tags, extra)
    }

    private static func parseCSVValue(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .filter { !$0.isEmpty }
    }

    /// Drop a leading `# Title` line + one blank line if it matches the
    /// expected title (case-insensitive). Otherwise return content
    /// unchanged. Used when the frontmatter already supplied a title and
    /// the body redundantly repeats it as an H1.
    private static func stripMatchingH1(from content: String, matching expectedTitle: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var i = 0
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            i += 1
        }
        guard i < lines.count else { return content }
        let firstTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
        guard firstTrimmed.hasPrefix("# ") else { return content }
        let h1 = String(firstTrimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard h1.lowercased() == expectedTitle.lowercased() else { return content }
        var after = i + 1
        if after < lines.count, lines[after].trimmingCharacters(in: .whitespaces).isEmpty {
            after += 1
        }
        return after >= lines.count ? "" : lines[after...].joined(separator: "\n")
    }

    /// Pull every `#tag` reference out of `body` and return both the
    /// cleaned body and the tag strings (in source order). One leading
    /// space per match is also consumed so we don't leave double spaces
    /// behind.
    static func extractInlineTagsFromBody(_ body: String) -> (cleanBody: String, tags: [String]) {
        let refs = WikilinkParser.references(in: body)
        let tagRefs = refs.compactMap { ref -> (String, Range<Int>)? in
            if case .tag(let t) = ref.kind { return (t, ref.range) }
            return nil
        }
        guard !tagRefs.isEmpty else { return (body, []) }

        var result = body as NSString
        // Apply edits highest-offset first so earlier ranges stay valid.
        let descending = tagRefs.sorted { $0.1.lowerBound > $1.1.lowerBound }
        for (_, range) in descending {
            var nsRange = NSRange(location: range.lowerBound, length: range.upperBound - range.lowerBound)
            if nsRange.location > 0 {
                let prev = result.character(at: nsRange.location - 1)
                if prev == 0x20 { // ASCII space — don't touch newlines
                    nsRange = NSRange(location: nsRange.location - 1, length: nsRange.length + 1)
                }
            }
            result = result.replacingCharacters(in: nsRange, with: "") as NSString
        }
        let tagsInOrder = tagRefs.sorted { $0.1.lowerBound < $1.1.lowerBound }.map { $0.0 }
        return (result as String, tagsInOrder)
    }

    /// Render the editor state back to a markdown file. Emits a YAML
    /// frontmatter block whenever there are tags or preserved extra
    /// frontmatter; otherwise no frontmatter is written. The title is
    /// always emitted as a body H1 (so plain-markdown viewers still
    /// see the heading).
    static func renderNote(title: String, body: String, tags: [String], extraFrontmatter: String = "") -> String {
        let cleanTags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedExtra = extraFrontmatter.trimmingCharacters(in: .newlines)
        let core = combineTitleAndBody(title: title, body: body)

        var fmLines: [String] = []
        if !cleanTags.isEmpty {
            fmLines.append("tags: [\(cleanTags.joined(separator: ", "))]")
        }
        if !trimmedExtra.isEmpty {
            fmLines.append(trimmedExtra)
        }
        guard !fmLines.isEmpty else { return core }
        return "---\n" + fmLines.joined(separator: "\n") + "\n---\n" + core
    }

    /// Split a note's full `.md` content into an explicit title and the
    /// remaining body. The title is taken from (in priority order):
    ///   1. the first H1 line (`# ...`),
    ///   2. otherwise the first non-empty line, with leading block markers
    ///      stripped (`>`, `-`, `*`).
    /// Either way the title line is removed from body so the field and the
    /// editor don't show the same text twice. This keeps the title field
    /// in sync with what the sidebar shows for the same note.
    static func splitTitleAndBody(_ fullContent: String) -> (title: String, body: String) {
        let lines = fullContent.components(separatedBy: "\n")
        var i = 0
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            i += 1
        }
        guard i < lines.count else { return ("", fullContent) }
        let firstTrimmed = lines[i].trimmingCharacters(in: .whitespaces)

        let title: String
        if firstTrimmed.hasPrefix("# ") {
            title = String(firstTrimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        } else {
            // Fallback: first non-empty line, stripped of any leading
            // markdown block syntax (matching VaultIndexer.extractTitle).
            title = stripLeadingMarkdownSyntax(firstTrimmed)
        }
        guard !title.isEmpty else { return ("", fullContent) }

        var after = i + 1
        if after < lines.count, lines[after].trimmingCharacters(in: .whitespaces).isEmpty {
            after += 1
        }
        let body = after >= lines.count ? "" : lines[after...].joined(separator: "\n")
        return (title, body)
    }

    private static func stripLeadingMarkdownSyntax(_ line: String) -> String {
        var s = line
        while s.hasPrefix("#") { s = String(s.dropFirst()) }
        while let first = s.first, "><-*".contains(first) { s = String(s.dropFirst()) }
        return s.trimmingCharacters(in: .whitespaces)
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
        guard let vault else { return }
        guard let id = currentNoteID else { return }

        // Refuse empty writes. They show up two ways and both look like
        // "delete didn't stick": (a) a debounced/lifecycle save firing
        // for a just-trashed note resurrects it as a 0-byte stub;
        // (b) a stale editor state writes empty content over a real
        // note. Either way, we'd rather skip than corrupt — explicit
        // delete is the only way notes go away.
        let fullContent = Self.renderNote(
            title: currentNoteTitle,
            body: currentNoteBody,
            tags: currentNoteTags,
            extraFrontmatter: currentNoteExtraFrontmatter
        )
        guard !fullContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Rename the .md file to match the title if the user changed
        // it. The rename runs through the same renameInState helper as
        // the explicit Move action, so the sidebar reflects the new
        // path right away.
        let writeURL = renameToMatchTitleIfNeeded(id: id, vault: vault)
        do {
            try writer.write(fullContent, to: writeURL)
            markInternalWrite(url: writeURL)
            reindexIncrementally([writeURL])
            NSLog("[Slip] saved \(writeURL.lastPathComponent) (\(fullContent.count) chars)")
        } catch {
            NSLog("[Slip] save failed: \(error)")
        }
    }

    func createNewNote(in folder: String = "") {
        guard let vault else { return }
        flushPendingEdits()
        do {
            let note = try writer.createNew(in: vault, title: "Untitled", folder: folder, body: "")
            markInternalWrite(url: note.url)
            currentNoteID = note.id
            currentNoteTitle = ""
            currentNoteBody = ""
            currentNoteTags = []
            currentNoteExtraFrontmatter = ""
            reindexIncrementally([note.url])
            NSLog("[Slip] created \(note.url.lastPathComponent)")
        } catch {
            NSLog("[Slip] create failed: \(error)")
        }
    }

    func createFolder(name: String, in parent: String = "") {
        guard let vault else { return }
        let cleanName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:"))
            .joined(separator: "-")
        guard !cleanName.isEmpty else { return }

        let parentURL = parent.isEmpty
            ? vault.root
            : vault.root.appendingPathComponent(parent)
        let target = parentURL.appendingPathComponent(cleanName)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            NSLog("[Slip] created folder at \(target.path)")
            self.allFolders = listFoldersOnDisk()
        } catch {
            NSLog("[Slip] Create folder failed: \(error)")
        }
    }

    /// Send the note's file to the system Trash, falling back to a
    /// permanent delete if Trash isn't usable for that path. Drops the
    /// note from every published surface, syncs the SQLite index, and
    /// tombstones the id so iCloud / FSEvent re-creates can't bring
    /// the row back into the sidebar for ~30s.
    func deleteNote(_ id: NoteID) {
        guard let vault else { return }
        let url = vault.url(for: id)
        markInternalWrite(url: url)

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try trashOrRemove(url: url)
            } catch {
                NSLog("[Slip] delete failed: \(error)")
                return
            }
        }
        dropFromState(id)
        deletionTombstones[id] = Date()
        reindexIncrementally([url])
        NSLog("[Slip] deleted \(url.lastPathComponent)")
    }

    /// Move the note's file to a different folder under the vault.
    /// Empty `destinationFolder` means the vault root. Filename clashes
    /// at the destination get a " 2", " 3", … suffix.
    func moveNote(_ id: NoteID, toFolder destinationFolder: String) {
        guard let vault else { return }
        let oldURL = vault.url(for: id)
        let parentURL = destinationFolder.isEmpty
            ? vault.root
            : vault.root.appendingPathComponent(destinationFolder)
        guard parentURL.standardizedFileURL != oldURL.deletingLastPathComponent().standardizedFileURL
        else { return }
        do {
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
            let newURL = uniqueDestination(in: parentURL, named: oldURL.lastPathComponent)
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            markInternalWrite(url: oldURL)
            markInternalWrite(url: newURL)
            if let newID = try? vault.noteID(for: newURL) {
                renameInState(from: id, to: newID)
            }
            reindexIncrementally([oldURL, newURL])
            NSLog("[Slip] moved \(oldURL.lastPathComponent) → \(destinationFolder.isEmpty ? "<root>" : destinationFolder)")
        } catch {
            NSLog("[Slip] move failed: \(error)")
        }
    }

    /// If the editor's title diverged from the current filename, rename
    /// the .md file to match. Returns the URL to write to (the renamed
    /// one, or the original if no rename was needed). Mutates state via
    /// renameInState so this matches the moveNote pipeline.
    private func renameToMatchTitleIfNeeded(id: NoteID, vault: Vault) -> URL {
        let originalURL = vault.url(for: id)
        let trimmedTitle = currentNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return originalURL }

        let safeStem = NoteWriter.safeFilename(from: trimmedTitle)
        let currentStem = originalURL.deletingPathExtension().lastPathComponent
        guard currentStem != safeStem else { return originalURL }

        let parentURL = originalURL.deletingLastPathComponent()
        var targetURL = parentURL.appendingPathComponent("\(safeStem).md")
        var n = 1
        while FileManager.default.fileExists(atPath: targetURL.path),
              targetURL.standardizedFileURL != originalURL.standardizedFileURL {
            n += 1
            targetURL = parentURL.appendingPathComponent("\(safeStem) \(n).md")
        }
        guard targetURL.standardizedFileURL != originalURL.standardizedFileURL
        else { return originalURL }
        do {
            try FileManager.default.moveItem(at: originalURL, to: targetURL)
            markInternalWrite(url: originalURL)
            markInternalWrite(url: targetURL)
            guard let newID = try? vault.noteID(for: targetURL) else { return targetURL }
            renameInState(from: id, to: newID)
            return targetURL
        } catch {
            NSLog("[Slip] rename failed: \(error)")
            return originalURL
        }
    }

    // MARK: - State mutation helpers

    /// Forget every reference the in-memory model holds to the given
    /// note id, plus drop its row from the SQLite index. Used by
    /// deleteNote (and by anything else that needs the note gone now).
    private func dropFromState(_ id: NoteID) {
        allNoteIDs.removeAll { $0 == id }
        titleByID.removeValue(forKey: id)
        searchResults.removeAll { $0 == id }
        backlinks.removeAll { $0 == id }
        allTodos.removeAll { $0.noteID == id }
        if currentNoteID == id { clearCurrentNoteState() }
        try? index?.delete(id: id)
        applyTagFilter()
        graphRevision &+= 1
    }

    /// Replace the old id with the new one across every published
    /// surface and the SQLite index. Called by both moveNote and the
    /// title-driven rename path so they share the same cleanup.
    private func renameInState(from oldID: NoteID, to newID: NoteID) {
        if let idx = allNoteIDs.firstIndex(of: oldID) {
            allNoteIDs[idx] = newID
        }
        if let title = titleByID.removeValue(forKey: oldID) {
            titleByID[newID] = title
        }
        if currentNoteID == oldID { currentNoteID = newID }
        // Old DB row will be replaced when reindex sees the new path; we
        // pre-emptively drop it so a racing refreshAfterIndex can't put
        // the old id back into allNoteIDs.
        try? index?.delete(id: oldID)
        applyTagFilter()
        graphRevision &+= 1
    }

    private func clearCurrentNoteState() {
        currentNoteID = nil
        currentNoteTitle = ""
        currentNoteBody = ""
        currentNoteTags = []
        currentNoteExtraFrontmatter = ""
    }

    private func flushPendingEdits() {
        if currentNoteID != nil { saveCurrentNote() }
    }

    /// Resolve filename collisions inside `parent` by appending "2", "3"…
    /// to the stem. Returns a URL that doesn't currently exist on disk.
    private func uniqueDestination(in parent: URL, named filename: String) -> URL {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = parent.appendingPathComponent(filename)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            n += 1
            candidate = parent.appendingPathComponent("\(stem) \(n).\(ext)")
        }
        return candidate
    }

    /// Trash if possible, fall through to a hard remove if Trash refuses
    /// the volume or silently no-ops (which we've seen on iCloud Drive
    /// for non-ASCII filenames).
    private func trashOrRemove(url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            try FileManager.default.removeItem(at: url)
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
            // Sweep stale DB rows whose files no longer exist (e.g., after
            // a rename/move that the per-URL delete didn't catch due to
            // path-normalization mismatches). Cheap on small vaults and
            // keeps the sidebar from showing duplicate entries.
            try? indexer.garbageCollect()
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
