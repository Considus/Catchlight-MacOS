import WebKit
import XCTest

/// Settings rows are as tall as the iPhone's (Mark, 2026-11-20: "Match iPhone (74)"). The iPhone's
/// list puts 15 above and below each row's content, measured on iOS 27 (iPhone 17): an ordinary
/// row's 44 line makes a 74 row, a switch with a sub-line (minimum 52) an 82 row, and a picker
/// with a description sits its 44 line 15 from the top and ends 15 under the description.
final class SettingsRowHeightTests: XCTestCase {
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

    private let open = """
        openSettings(); await new Promise(f => setTimeout(f, 300));
        const rowOf = sel => document.querySelector(sel).closest('.srow');
        const box = el => el.getBoundingClientRect();
        """

    func testEveryOrdinaryRowIs74WithItsLineCentred() throws {
        let harness = page()
        let r = try json(harness, open + """
            const rows = [...document.querySelectorAll('#settings .srow')].filter(e => !e.matches('.sub, .noted, .tall') && e.offsetParent);
            return { count: rows.length, heights: [...new Set(rows.map(e => Math.round(box(e).height * 10) / 10))],
              mode: (() => { const b = box(rowOf('[data-set="mode"]')), l = box(rowOf('[data-set="mode"]').querySelector('.srow-label')); return (l.top + l.bottom) / 2 - b.top; })() };
            """)
        XCTAssertGreaterThan(r["count"] as! Int, 10, "\(r)")
        XCTAssertEqual(r["heights"] as? [Double], [74], "\(r)")
        XCTAssertEqual(r["mode"] as! Double, 37, accuracy: 1, "the line is centred: \(r)")
    }

    func testASwitchWithASubLineIs82() throws {
        let harness = page()
        let r = try json(harness, open + """
            const row = rowOf('[data-set="followUp"]'), b = box(row), l = box(row.querySelector('.srow-label'));
            return { h: b.height, above: l.top - b.top, below: b.bottom - l.bottom };
            """)
        XCTAssertEqual(r["h"] as! Double, 82, accuracy: 0.6, "\(r)")
        XCTAssertEqual(r["above"] as! Double, r["below"] as! Double, accuracy: 1, "centred: \(r)")
    }

    func testAPickerWithADescriptionHas15AboveItsLineAnd15UnderItsDescription() throws {
        let harness = page()
        let r = try json(harness, open + """
            const row = rowOf('[data-set="spotlight"]'), b = box(row), line = box(row.querySelector('.srow-line')), note = box(row.querySelector('.srow-note'));
            return { above: line.top - b.top, line: line.height, gap: note.top - line.bottom, below: b.bottom - note.bottom };
            """)
        XCTAssertEqual(r["above"] as! Double, 15, accuracy: 0.6, "\(r)")
        XCTAssertEqual(r["line"] as! Double, 44, accuracy: 0.6, "\(r)")
        XCTAssertEqual(r["gap"] as! Double, 6, accuracy: 0.6, "\(r)")
        XCTAssertEqual(r["below"] as! Double, 15, accuracy: 0.6, "\(r)")
    }
}
