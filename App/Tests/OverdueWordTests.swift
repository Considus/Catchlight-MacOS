import XCTest

/// An overdue Take's state word, as the iPhone's TakeStateWordStrip: the translated "Overdue" in
/// capitals by the language's own rules, at the time line's 11, sideways in the strip left of
/// the Iris when it fits at 80% or more, else at the start of the time line at full size (owner
/// 2026-11-12: OVERDUE in capitals; Art Director 2026-11-20: the Mac drew English at 9).
final class OverdueWordTests: XCTestCase {
    private let overdue = #"[{"id":"7D4C4A4E-0000-4000-8000-0000000000AA","at":"2026-11-01T09:00:00.000Z","blocks":[{"k":"text","text":"Call"}],"reminder":{"kind":"time","when":"2020-01-01T09:00:00Z","notify":true,"done":false}}]"#

    /// What the overdue card shows, in `lang`: the strip's word (or nil), its size as drawn, and
    /// the time line's first word.
    private func shown(_ lang: String) throws -> [String: Any] {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil, privateStorage: true)
        harness.load("index.html?lang=\(lang)", in: self)
        let json = try harness.run("""
            takes = \(overdue); renderTakes();
            await new Promise(r => setTimeout(r, 60));
            const card = document.querySelector('.card.overdue');
            const before = getComputedStyle(card, '::before').content;
            const word = [...card.querySelectorAll('.state-word')].find(w => getComputedStyle(w).display !== 'none' && w.getBoundingClientRect().width > 0);
            const drawn = word ? word.getBoundingClientRect() : null;
            const inline = [...card.querySelectorAll('.meta .state-inline')].find(w => getComputedStyle(w).display !== 'none');
            return JSON.stringify({
              before: before === 'none' || before === 'normal' ? null : before,
              strip: word ? word.textContent : null,
              size: word ? parseFloat(getComputedStyle(word).fontSize) * (parseFloat(getComputedStyle(word).getPropertyValue('--word-scale')) || 1) : null,
              upright: drawn ? drawn.height > drawn.width : null,
              line: inline ? inline.textContent : null,
              hidden: word ? word.getAttribute('aria-hidden') : null,
            });
            """, in: self) as? String
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(json).utf8)) as? [String: Any])
    }

    func testEnglishShowsOverdueSidewaysAtElevenInTheStrip() throws {
        let r = try shown("en")
        XCTAssertNil(r["before"] as? String, "no word drawn by the stylesheet")
        XCTAssertEqual(r["strip"] as? String, "OVERDUE")
        XCTAssertEqual(try XCTUnwrap(r["size"] as? Double), 11, accuracy: 0.01)
        XCTAssertEqual(r["upright"] as? Bool, true, "it reads sideways")
        XCTAssertEqual(r["hidden"] as? String, "true", "the card's label speaks the state")
        XCTAssertNil(r["line"] as? String)
    }

    func testGermanShowsTheTranslatedWordInCapitals() throws {
        let r = try shown("de")
        XCTAssertEqual(r["strip"] as? String, "ÜBERFÄLLIG")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(r["size"] as? Double), 11 * 0.8 - 0.01, "never under 80%")
        XCTAssertNil(r["line"] as? String)
    }

    /// Turkish "SÜRESİ GEÇTİ" doesn't fit the strip at 80%, so it starts the time line instead.
    func testAWordThatDoesntFitStartsTheTimeLine() throws {
        let r = try shown("tr")
        XCTAssertNil(r["strip"] as? String, "too long for the strip")
        XCTAssertEqual(r["line"] as? String, "Süresi geçti")
    }
}
