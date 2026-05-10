import XCTest
@testable import SlipCore

final class SlipCoreTests: XCTestCase {

    func testWikilinkParserExtractsTargetAndAlias() {
        let text = "See [[Project Alpha]] and [[Notes|my notes]] for details."
        let refs = WikilinkParser.references(in: text)
        XCTAssertEqual(refs.count, 2)

        if case .wikilink(let target, let alias) = refs[0].kind {
            XCTAssertEqual(target, "Project Alpha")
            XCTAssertNil(alias)
        } else {
            XCTFail("Expected wikilink")
        }

        if case .wikilink(let target, let alias) = refs[1].kind {
            XCTAssertEqual(target, "Notes")
            XCTAssertEqual(alias, "my notes")
        } else {
            XCTFail("Expected wikilink with alias")
        }
    }

    func testWikilinkParserExtractsTags() {
        let text = "Tagged with #idea and #project/devkoan but not ### heading."
        let refs = WikilinkParser.references(in: text)
        let tags = refs.compactMap { r -> String? in
            if case .tag(let t) = r.kind { return t } else { return nil }
        }
        XCTAssertTrue(tags.contains("idea"))
        XCTAssertTrue(tags.contains("project/devkoan"))
    }

    func testRetrievabilityDecays() {
        let now = Date()
        let fresh = SpacingAlgorithm.retrievability(
            lastViewedAt: now.addingTimeInterval(-86_400),
            viewCount: 1, createdAt: now.addingTimeInterval(-86_400), now: now
        )
        let stale = SpacingAlgorithm.retrievability(
            lastViewedAt: now.addingTimeInterval(-30 * 86_400),
            viewCount: 1, createdAt: now.addingTimeInterval(-30 * 86_400), now: now
        )
        XCTAssertGreaterThan(fresh, stale)
    }

    func testDesirableDifficultyPeaksNearHalf() {
        let peak = SpacingAlgorithm.desirableDifficulty(retrievability: 0.5)
        let fresh = SpacingAlgorithm.desirableDifficulty(retrievability: 0.95)
        let gone  = SpacingAlgorithm.desirableDifficulty(retrievability: 0.05)
        XCTAssertGreaterThan(peak, fresh)
        XCTAssertGreaterThan(peak, gone)
    }

    func testMarkdownStructureFindsHeadingAndBold() {
        let text = "# Title\n\nSome **bold** text."
        let s = MarkdownStructure(text: text)
        XCTAssertTrue(s.spans.contains { if case .heading(let lvl, _) = $0 { return lvl == 1 } else { return false } })
        XCTAssertTrue(s.spans.contains { if case .bold = $0 { return true } else { return false } })
    }

    func testMarkdownStructureEmitsSyntaxMarkers() {
        let text = "# Heading\n\nThis is **bold** and *italic*."
        let s = MarkdownStructure(text: text)
        // Expect: `# `, `**` opener, `**` closer, `*` opener, `*` closer — at minimum 5.
        XCTAssertGreaterThanOrEqual(s.syntaxMarkers.count, 5)
    }

    func testMarkdownStructureLineLookup() {
        let text = "line one\nline two\nline three"
        let s = MarkdownStructure(text: text)
        XCTAssertEqual(s.line(forUTF16Offset: 0), 1)
        XCTAssertEqual(s.line(forUTF16Offset: 9), 2)   // start of "line two"
        XCTAssertEqual(s.line(forUTF16Offset: 18), 3)  // start of "line three"
    }

    // MARK: - Frontmatter parsing
    //
    // These cover the "paste a Substack / Dev.to article verbatim and
    // have it land cleanly in the editor" path: title surfaces, all
    // four bare-CSV tags get indexed, and the closing `---` is found
    // even when the user copied a bare frontmatter block with no
    // trailing newline.

    private static let substackArticleBody: String = """
    ---
    title: Senior Developers Collect Mistakes. Junior Developers Erase Them.
    subtitle: The habit that keeps most developers stuck at junior level longer than they should be
    published: true
    canonical_url: https://devkoan.substack.com/p/senior-developers-collect-mistakes?r=84w2xe
    tags: career, beginners, productivity, programming
    cover_image: https://dev-to-uploads.s3.amazonaws.com/uploads/articles/qqlzrogp26jarbxwdshw.png
    ---

    There's a moment every junior developer knows.

    You open a pull request. You see a comment. Your stomach drops.

    ---

    ## The reflex that looks like professionalism

    The body has its own `---` horizontal rules — they shouldn't fool
    the close-range lookup into stopping at the wrong one.
    """

    func testFrontmatterExtractsBareCSVTags() {
        let tags = VaultIndexer.extractFrontmatterTags(body: Self.substackArticleBody)
        XCTAssertEqual(
            Set(tags),
            Set(["career", "beginners", "productivity", "programming"]),
            "Bare comma-separated `tags: a, b, c` form should yield all four tags"
        )
    }

    func testFrontmatterExtractsTitle() {
        let title = VaultIndexer.extractTitle(
            body: Self.substackArticleBody,
            fallbackFilename: "fallback"
        )
        XCTAssertEqual(
            title,
            "Senior Developers Collect Mistakes. Junior Developers Erase Them."
        )
    }

    func testFrontmatterCloseDoesntStopAtBodyHorizontalRule() {
        // The article body itself contains `---` lines as section
        // dividers; the parser must find the *first* `\n---\n` after
        // the opening `---\n` and treat that as the close, not get
        // confused by horizontal rules deeper in the body.
        let tags = VaultIndexer.extractFrontmatterTags(body: Self.substackArticleBody)
        XCTAssertFalse(
            tags.isEmpty,
            "If the close-range lookup latched onto a body-side `---`, fmText would be huge and tag extraction would fail"
        )
    }

    func testFrontmatterWithoutTrailingNewlineStillParses() {
        // Bare frontmatter block with no trailing newline — what you
        // get when you copy just the YAML block from another app and
        // the source didn't include a trailing \n. Should still
        // promote tags and title.
        let body = """
        ---
        title: Test Title
        tags: one, two, three
        ---
        """  // multiline string literal does NOT add a trailing newline
        let tags = VaultIndexer.extractFrontmatterTags(body: body)
        XCTAssertEqual(Set(tags), Set(["one", "two", "three"]))
        let title = VaultIndexer.extractTitle(body: body, fallbackFilename: "fb")
        XCTAssertEqual(title, "Test Title")
    }

    func testFrontmatterBracketedTagsStillWork() {
        // Regression guard: the bare-CSV fix should not break the
        // bracketed `tags: [a, b]` flow form that we ship.
        let body = """
        ---
        title: Bracketed
        tags: [alpha, beta, gamma]
        ---

        Body.
        """
        let tags = VaultIndexer.extractFrontmatterTags(body: body)
        XCTAssertEqual(Set(tags), Set(["alpha", "beta", "gamma"]))
    }

    func testFrontmatterBlockFormTagsStillWork() {
        // Regression guard: block form (each tag on its own `- ` line)
        // should also still work after the bare-CSV fix.
        let body = """
        ---
        title: Block
        tags:
          - one
          - two
        ---

        Body.
        """
        let tags = VaultIndexer.extractFrontmatterTags(body: body)
        XCTAssertEqual(Set(tags), Set(["one", "two"]))
    }
}
