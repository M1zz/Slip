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
            self.allFolders = listFoldersOnDisk()
            self.allTodos = (try? index.allTodos()) ?? []
            self.graphRevision &+= 1
            applyTagFilter()
            refreshRediscovery()
        } catch {
            NSLog("Refresh failed: \(error)")
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
        guard let vault else {
            NSLog("[Slip] saveCurrentNote skipped: no vault")
            return
        }
        guard let id = currentNoteID else {
            NSLog("[Slip] saveCurrentNote skipped: no currentNoteID")
            return
        }
        // If the title has diverged from the on-disk filename, rename
        // the file before writing so the .md file always matches the
        // human title. The rename updates currentNoteID + allNoteIDs in
        // place so the sidebar refreshes immediately, then we write to
        // the new URL.
        let (writeURL, writeID) = renameToMatchTitleIfNeeded(id: id, vault: vault)

        let url = writeURL
        let fullContent = Self.renderNote(
            title: currentNoteTitle,
            body: currentNoteBody,
            tags: currentNoteTags,
            extraFrontmatter: currentNoteExtraFrontmatter
        )
        do {
            try writer.write(fullContent, to: url)
            NSLog("[Slip] saved \(fullContent.count) chars to \(url.path)")
            markInternalWrite(url: url)
            reindexIncrementally([url])
        } catch {
            NSLog("[Slip] Save failed for \(url.path): \(error)")
        }
        _ = writeID
    }

    /// If the editor's title differs from the current filename, rename
    /// the file (handling collisions with " 2" suffixes) and patch the
    /// in-memory state so subsequent saves write to the new path.
    /// Returns the URL/ID to write to (new or unchanged).
    private func renameToMatchTitleIfNeeded(id: NoteID, vault: Vault) -> (URL, NoteID) {
        let originalURL = vault.url(for: id)
        let trimmedTitle = currentNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return (originalURL, id) }

        let safeStem = NoteWriter.safeFilename(from: trimmedTitle)
        let currentStem = originalURL.deletingPathExtension().lastPathComponent
        guard currentStem != safeStem else { return (originalURL, id) }

        let parentURL = originalURL.deletingLastPathComponent()
        var targetURL = parentURL.appendingPathComponent("\(safeStem).md")
        var n = 1
        while FileManager.default.fileExists(atPath: targetURL.path),
              targetURL.standardizedFileURL != originalURL.standardizedFileURL {
            n += 1
            targetURL = parentURL.appendingPathComponent("\(safeStem) \(n).md")
        }
        guard targetURL.standardizedFileURL != originalURL.standardizedFileURL else {
            return (originalURL, id)
        }
        do {
            try FileManager.default.moveItem(at: originalURL, to: targetURL)
            NSLog("[Slip] renamed \(originalURL.lastPathComponent) → \(targetURL.lastPathComponent)")
            markInternalWrite(url: originalURL)
            markInternalWrite(url: targetURL)
            guard let newID = try? vault.noteID(for: targetURL) else {
                return (targetURL, id)
            }
            if let idx = allNoteIDs.firstIndex(of: id) {
                allNoteIDs[idx] = newID
            }
            if let title = titleByID.removeValue(forKey: id) {
                titleByID[newID] = title
            }
            currentNoteID = newID
            applyTagFilter()
            return (targetURL, newID)
        } catch {
            NSLog("[Slip] Rename on save failed: \(error)")
            return (originalURL, id)
        }
    }

    func createNewNote(in folder: String = "") {
        guard let vault else {
            NSLog("[Slip] createNewNote skipped: no vault")
            return
        }
        // Flush pending edits on the current note before creating a new one.
        if currentNoteID != nil {
            saveCurrentNote()
        }
        do {
            let note = try writer.createNew(in: vault, title: "Untitled", folder: folder, body: "")
            NSLog("[Slip] created note at \(note.url.path)")
            currentNoteID = note.id
            currentNoteTitle = ""
            currentNoteBody = ""
            currentNoteTags = []
            currentNoteExtraFrontmatter = ""
            markInternalWrite(url: note.url)
            reindexIncrementally([note.url])
        } catch {
            NSLog("[Slip] Create failed in \(vault.root.path): \(error)")
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

    /// Move a note to another folder. `destinationFolder` is the relative
    /// path inside the vault ("" for vault root). Filenames keep the same
    /// basename; if a collision exists we suffix " 2", " 3", etc.
    func moveNote(_ id: NoteID, toFolder destinationFolder: String) {
        guard let vault else { return }
        let oldURL = vault.url(for: id)
        let filename = oldURL.lastPathComponent
        let parentURL = destinationFolder.isEmpty
            ? vault.root
            : vault.root.appendingPathComponent(destinationFolder)
        // Skip no-op moves (already in that folder).
        if parentURL.standardizedFileURL == oldURL.deletingLastPathComponent().standardizedFileURL {
            return
        }
        do {
            if !FileManager.default.fileExists(atPath: parentURL.path) {
                try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
            }
            // Resolve filename collision.
            let stem = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            var candidate = parentURL.appendingPathComponent(filename)
            var n = 1
            while FileManager.default.fileExists(atPath: candidate.path) {
                n += 1
                candidate = parentURL.appendingPathComponent("\(stem) \(n).\(ext)")
            }
            try FileManager.default.moveItem(at: oldURL, to: candidate)
            NSLog("[Slip] moved \(oldURL.path) → \(candidate.path)")
            markInternalWrite(url: oldURL)
            markInternalWrite(url: candidate)

            // Optimistic UI update: rewrite the in-memory note list with
            // the new path so the sidebar tree flips immediately. Without
            // this, the user would see the note in the old folder until
            // the background reindex (Task.detached → DB write →
            // refreshAfterIndex) finished, which is what gave the
            // appearance of "two places at once".
            if let newID = try? vault.noteID(for: candidate) {
                if let idx = allNoteIDs.firstIndex(of: id) {
                    allNoteIDs[idx] = newID
                }
                if let title = titleByID.removeValue(forKey: id) {
                    titleByID[newID] = title
                }
                if currentNoteID == id {
                    self.currentNoteID = newID
                }
                applyTagFilter()
            }

            reindexIncrementally([oldURL, candidate])
        } catch {
            NSLog("[Slip] Move failed (\(oldURL.path) → \(parentURL.path)): \(error)")
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
