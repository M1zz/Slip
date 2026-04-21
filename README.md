# Slip

A markdown thought tool for macOS (iOS to follow). File-based vault, semantic markdown highlighting with Live Preview, global Quick Capture, and a rediscovery engine grounded in cognitive-science memory research.

The name is a nod to the [slip-box](https://en.wikipedia.org/wiki/Zettelkasten) tradition — Luhmann's Zettelkasten that kept 90,000 thoughts connected and findable over decades. Slip is shorter and less precious: a slip of paper, jotted, filed, and eventually rediscovered.

## Project layout

```
Slip/
├── project.yml              XcodeGen spec — generates Slip.xcodeproj
├── App/                     macOS app target (SwiftUI + AppKit)
│   ├── SlipApp.swift        @main entry point
│   ├── AppDelegate.swift    Hotkey, menu bar, quick capture coordination
│   ├── AppState.swift       Observable root state + VaultWatcher wiring
│   ├── Views/               SwiftUI views
│   ├── AppKit/              NSTextView + NSPanel wrappers
│   │   ├── MarkdownTextView.swift    Live Preview editor
│   │   ├── QuickCapturePanel.swift   Floating HUD panel
│   │   └── WikilinkCompleter.swift   [[…]] autocomplete popover
│   └── System/              GlobalHotkey, MenuBarController
└── SlipCore/                Swift Package — all business logic (macOS + iOS)
    └── Sources/SlipCore/
        ├── Vault/           File-system access + FSEventStream watcher
        ├── Model/           Note, NoteID, NoteReference
        ├── Parser/          swift-markdown tree walker + wikilink regex
        ├── Index/           GRDB SQLite + FTS5, incremental reindex
        ├── Search/
        └── Rediscovery/     Ebbinghaus + Bjork scoring
```

## First-time setup

Install XcodeGen (once):

```bash
brew install xcodegen
```

Generate the Xcode project and open it:

```bash
cd Slip
xcodegen generate
open Slip.xcodeproj
```

Xcode will resolve the Swift packages (`swift-markdown`, `GRDB.swift`) on first open.

Signing: in the `Slip` target, set your Team under **Signing & Capabilities**. The entitlements file allows user-selected file access (for the vault) and already enables the App Sandbox.

Run: ⌘R. On first launch you'll be asked to pick a vault folder.

## Keyboard shortcuts

| Action                  | Shortcut            |
| ----------------------- | ------------------- |
| Quick Capture (global)  | ⌥⌘Space             |
| New Note                | ⌘N                  |
| Quick Capture (in-app)  | ⇧⌘N                 |
| Refresh Rediscovery     | ⇧⌘R                 |
| Find in note            | ⌘F                  |
| Wikilink autocomplete   | Type `[[`           |
| Accept completion       | ⏎ or Tab            |
| Dismiss completion      | Esc                 |

## What's new vs the v0.1 scaffold

This build upgrades the three biggest rough edges called out in the initial plan:

### Incremental reindex via FSEventStream

The v0.1 code ran `fullReindex()` on every save — fine for a handful of notes, painful above a thousand. Now:

- `VaultWatcher` (CoreServices FSEventStream wrapper) reports changed URLs across the whole vault tree with 500ms coalescing
- `VaultIndexer.reindex(urls:)` handles creations, modifications, and deletions in one pass and uses the current DB's title map for wikilink resolution
- `VaultIndexer.garbageCollect()` removes index rows for files deleted externally
- `AppState` tracks recent in-app writes for ~1.5s to suppress FSEvent echoes from its own saves

Net effect: instant save, and external edits from Obsidian/iA Writer/vim/iCloud Drive show up automatically in the sidebar without a restart.

### Live Preview with cursor awareness

`MarkdownStructure` now emits a `syntaxMarkers` list — the specific sub-ranges covering `**`, `_`, `` ` ``, `# `, `> `, list bullets, and link delimiters. `MarkdownTextView` tracks the cursor line and:

- On the cursor line: markers stay full-color so you can edit them directly
- Off the cursor line: markers fade to ~35% so your eye lands on content, not punctuation

Re-highlighting only fires when the cursor crosses a line boundary, so horizontal typing stays at native speed. Parsing happens on-main for MVP — when notes get very long, move the parse to a background queue and keep only the attribute application on main.

### `[[…]]` autocomplete popover

`WikilinkCompleter` is an `NSPopover` + SwiftUI list that appears when the cursor is inside an unclosed `[[`. It:

- Filters vault titles by prefix → contains → subsequence fuzzy match
- Anchors to the cursor rect via `firstRect(forCharacterRange:)`
- Handles ↑/↓/⏎/⇥/Esc through `textView(_:doCommandBy:)` — the text view keeps focus while the popover is open
- Inserts `[[Title]]` and advances the caret past the closing brackets

If no matches exist, the popover stays hidden rather than showing an empty list.

## Architecture decisions

**Why XcodeGen.** `.xcodeproj` is a merge-conflict magnet. `project.yml` is human-editable and git-diffable. Regenerate with `xcodegen generate` whenever you add or move files.

**Why file-based.** The user owns `.md` files directly. Obsidian, iA Writer, vim, anything else can read and write them in parallel. Sync is whatever the user already uses (iCloud Drive, Dropbox, Git). Slip never requires a proprietary format.

**Why a separate index DB.** The index is a rebuildable cache. Storing it in Application Support (not in the vault) keeps iCloud Drive sync fast — only `.md` files cross the wire.

**Why SlipCore as a Swift Package.** Every line of business logic (parsing, indexing, rediscovery, linking, search) lives in a package with zero dependency on AppKit or UIKit. When the iOS target lands, this package compiles against iOS with no changes.

**Why FSEventStream, not DispatchSource or NSFilePresenter.** FSEventStream is recursive by default, kernel-mediated, coalesces rapid events, and handles APFS/HFS+/iCloud Drive uniformly. `DispatchSource.makeFileSystemObjectSource` requires one file descriptor per watched directory. `NSFilePresenter` is per-file. For whole-vault watching, FSEventStream wins.

**Why Carbon for the global hotkey.** It's still the only supported API on macOS, and the wrapper is 80 lines. `HotKey` (the Soffes package) is a fine alternative if you prefer a dependency.

## Rediscovery: what it actually does

Every note gets a score combining:

- **Forgetting curve (Ebbinghaus)**: `r = exp(-Δt / stability)` where stability grows with view count.
- **Desirable difficulty (Bjork)**: peak reward at `r ≈ 0.5` — the "almost forgotten" zone where retrieval benefits most.
- **Orphan rescue**: boost notes with zero incoming links and low view count — they have no other way to resurface.
- **Weak-tie boost**: 2-hop graph neighbors that aren't directly linked.
- **Shared-tag boost**: notes that share tags with the current one.

Each card in the Rediscover panel shows its reasons as pills (`forgotten`, `orphan`, `weak tie`, `shared tag`, `untouched`). That metacognitive transparency is part of the product — the user learns how their own knowledge structure works.

Tune in `RediscoveryEngine.Config`. The default is `dailyCount: 5`, which is deliberate — more than 5 and users ignore the list.

## Roadmap

**v0.1 (initial scaffold)**
- Vault + file-based notes
- Semantic highlighting via NSTextView + swift-markdown
- Wikilinks with click-to-open
- Global hotkey Quick Capture → daily note
- Full-text search (FTS5)
- Backlinks
- Rediscovery engine with reasons

**v0.2 (this build)**
- FSEventStream-based incremental reindex
- Echo suppression for in-app writes
- Live Preview with off-line marker dimming
- `[[…]]` autocomplete popover with fuzzy filter
- Garbage collection for deleted files

**v0.3**
- Off-main markdown parsing for long documents
- Unlinked mentions in sidebar ("mentioned in 3 other notes")
- Periodic relink pass (when renamed notes' titles change incoming references)
- Customizable hotkey in Settings
- Graph view (SwiftUI Canvas)
- Create-on-commit for wikilinks to nonexistent titles

**v0.4 (iOS)**
- iOS target sharing SlipCore
- iCloud Drive ubiquity container for vault sync
- Share Extension for Quick Capture from any app
- Widget: today's Rediscovery

**v0.5 (AI-assisted rediscovery)**
- Semantic embeddings (local, via CoreML) for "this is related but you haven't linked it"
- Connection prompts ("these three notes share a theme you haven't named")

## Known rough edges

- The unlinked-mention scan in `fullReindex` is O(notes × titles) per file. For vaults > ~2k notes, switch to Aho-Corasick or a trie.
- Markdown parsing runs on main. Fine for notes under ~10k characters; move to a background queue for longer documents.
- Incremental reindex skips unlinked-mention discovery for speed — unlinked mentions are only refreshed on full reindex.
- `insertCompletion` updates text storage directly rather than through the text view's input system; this skips input method composition. Should be safe for simple title completions but worth revisiting if Korean/Japanese IME users hit issues.

## License

TBD. SlipCore uses `swift-markdown` (Apache 2.0) and `GRDB.swift` (MIT).
