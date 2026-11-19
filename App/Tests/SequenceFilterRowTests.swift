import WebKit
import XCTest

/// Sequence as the iPhone does it (DailiesToolbar, Mark 2026-11-19: "iPhone way"): the toolbar
/// keeps its four columns, Sequence turns to a cross in the accent's text colour, and the four
/// filters appear in a row just above the toolbar. Sequence again, a click on empty space or
/// Escape closes them.
final class SequenceFilterRowTests: XCTestCase {
    private func page() -> WebViewHarness {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        harness.load("index.html", in: self, injecting: [WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        _ = try? harness.run("document.querySelector('.first-run').hidden = true; document.body.classList.remove('first-running');", in: self)
        return harness
    }

    private func json(_ harness: WebViewHarness, _ body: String) throws -> [String: Any] {
        let text = try XCTUnwrap(try harness.run("return JSON.stringify(await (async () => {\n\(body)\n})());", in: self) as? String)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    /// Opening Sequence keeps the four toolbar columns and adds the four filters, 44 tall, 6
    /// apart, 8 above the panel, in the panel's colours until one is on.
    func testSequenceShowsTheFiltersAboveTheToolbar() throws {
        let harness = page()
        let r = try json(harness, """
            const root = getComputedStyle(document.documentElement);
            const colour = c => { const d = document.createElement('div'); d.style.color = c; document.body.append(d); const v = getComputedStyle(d).color; d.remove(); return v; };
            const role = n => colour(root.getPropertyValue('--' + n));
            const dock = document.querySelector('#takes-dock');
            dock.querySelector('[data-act="sequence"]').click();
            tapFilter('important');
            const cols = [...dock.querySelectorAll('.dock-btn:not(.chip)')].map(b => b.querySelector('.lbl')?.textContent);
            const seqBtn = dock.querySelector('[data-act="sequence"]');
            const chips = [...dock.querySelectorAll('.chip')].map(c => { const b = c.getBoundingClientRect(), cs = getComputedStyle(c);
              return { act: c.dataset.act, top: b.top, bottom: b.bottom, left: b.left, right: b.right, h: b.height, fill: cs.backgroundColor, edge: cs.borderTopColor, glyph: cs.color, pressed: c.getAttribute('aria-pressed'), radius: cs.borderTopLeftRadius }; });
            const panel = dock.getBoundingClientRect();
            return { cols, open: seqBtn.getAttribute('aria-expanded'), seqColour: getComputedStyle(seqBtn).color, chips, panelTop: panel.top, panelLeft: panel.left, panelRight: panel.right,
              roles: { accentText: role('accent-text'), surface: role('surface'), line: role('line'), text: role('text'), accent: role('accent'), onAccent: role('on-accent') } };
            """)
        let roles = try XCTUnwrap(r["roles"] as? [String: String])
        XCTAssertEqual(r["cols"] as? [String], ["Add", "Storyboard", "Sequence", "Search"], "the toolbar keeps its four columns")
        XCTAssertEqual(r["open"] as? String, "true")
        XCTAssertEqual(r["seqColour"] as? String, roles["accentText"])
        let chips = try XCTUnwrap(r["chips"] as? [[String: Any]])
        XCTAssertEqual(chips.map { $0["act"] as? String }, ["important", "notes", "tasks", "reminders"])
        let panelTop = try XCTUnwrap(r["panelTop"] as? Double)
        XCTAssertEqual(chips[0]["left"] as! Double, r["panelLeft"] as! Double, accuracy: 0.6)
        XCTAssertEqual(chips[3]["right"] as! Double, r["panelRight"] as! Double, accuracy: 0.6)
        for (i, c) in chips.enumerated() {
            XCTAssertEqual(c["h"] as! Double, 44, accuracy: 0.6)
            XCTAssertEqual(panelTop - (c["bottom"] as! Double), 8, accuracy: 0.6, "8 above the panel")
            XCTAssertEqual(c["radius"] as? String, "14px")
            if i > 0 { XCTAssertEqual((c["left"] as! Double) - (chips[i - 1]["right"] as! Double), 6, accuracy: 0.6) }
            if c["pressed"] as? String == "true" {
                XCTAssertEqual(c["fill"] as? String, roles["accent"]); XCTAssertEqual(c["glyph"] as? String, roles["onAccent"])
            } else {
                XCTAssertEqual(c["fill"] as? String, roles["surface"]); XCTAssertEqual(c["edge"] as? String, roles["line"])
                XCTAssertEqual(c["glyph"] as? String, roles["text"])
            }
        }
        XCTAssertEqual(chips[0]["pressed"] as? String, "true")
    }

    /// Sequence again closes the filters and clears them, as Escape does.
    func testSequenceAgainOrEscapeClosesTheFilters() throws {
        let harness = page()
        let r = try json(harness, """
            const dock = document.querySelector('#takes-dock');
            dock.querySelector('[data-act="sequence"]').click(); tapFilter('notes');
            dock.querySelector('[data-act="sequence"]').click();
            const again = { chips: dock.querySelectorAll('.chip').length, notes: seq.notes, mode: dock.dataset.mode, open: dock.querySelector('[data-act="sequence"]').getAttribute('aria-expanded') };
            dock.querySelector('[data-act="sequence"]').click();
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
            return { again, escape: { chips: dock.querySelectorAll('.chip').length, mode: dock.dataset.mode } };
            """)
        let again = try XCTUnwrap(r["again"] as? [String: Any]), escape = try XCTUnwrap(r["escape"] as? [String: Any])
        XCTAssertEqual(again["chips"] as? Int, 0); XCTAssertEqual(again["notes"] as? Bool, false)
        XCTAssertEqual(again["mode"] as? String, "resting"); XCTAssertEqual(again["open"] as? String, "false")
        XCTAssertEqual(escape["chips"] as? Int, 0); XCTAssertEqual(escape["mode"] as? String, "resting")
    }
}
