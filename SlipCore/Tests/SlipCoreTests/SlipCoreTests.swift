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
}
