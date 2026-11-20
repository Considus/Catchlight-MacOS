import WebKit
import XCTest

/// Settings rows with a second line, as the iPhone builds them (SettingsView): a picker with a
/// description is one row, the setting's line laid out like any row with the description 6 below
/// it across the full width; a switch with a sub-line stacks it 2 under the title. As on the
/// iPhone's list (measured on iOS 27), the description row has 15 above its line and 15 under the
/// description, and the switch row's text is centred in its 82 row (Mark, 2026-11-20).
final class SettingsSublineTests: XCTestCase {
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

    private let probe = """
        openSettings(); await new Promise(f => setTimeout(f, 300));
        const lines = node => { const r = document.createRange(); r.selectNodeContents(node); return [...r.getClientRects()].filter(x => x.width > 0); };
        const rowOf = sel => document.querySelector(sel).closest('.srow');
        const title = row => lines(row.querySelector('.srow-label').firstChild);
        const ordinary = rowOf('[data-set="mode"]'), o = ordinary.getBoundingClientRect();
        const titleTop = title(ordinary)[0].top - o.top;
        """

    func testAPickerWithADescriptionIsTheRowThenTheDescriptionBelow() throws {
        let harness = page()
        let r = try json(harness, probe + """
            const muted = (() => { const d = document.createElement('div'); d.style.color = getComputedStyle(document.documentElement).getPropertyValue('--muted'); document.body.append(d); const v = getComputedStyle(d).color; d.remove(); return v; })();
            const row = rowOf('[data-set="spotlight"]'), b = row.getBoundingClientRect(), cs = getComputedStyle(row);
            const note = row.querySelector('small'), n = note.getBoundingClientRect(), ns = getComputedStyle(note), noteLines = lines(note);
            const t = title(row), icon = row.querySelector('.srow-icon').getBoundingClientRect(), value = row.querySelector('.srow-value').getBoundingClientRect();
            const line = row.querySelector('.srow-line').getBoundingClientRect();
            return { titleTop, rowTitleTop: t[0].top - b.top, titleLines: t.length, lineTop: line.top - b.top,
              gap: noteLines[0].top - line.bottom, noteLeft: n.left - icon.left, noteWidth: n.width, content: b.width - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight),
              valueMid: (value.top + value.bottom) / 2 - (t[0].top + t[0].bottom) / 2,
              below: b.bottom - noteLines[noteLines.length - 1].bottom,
              size: ns.fontSize, weight: ns.fontWeight, colour: ns.color, muted };
            """)
        XCTAssertEqual(r["rowTitleTop"] as! Double, r["titleTop"] as! Double, accuracy: 0.6, "the setting's line sits as in an ordinary row: \(r)")
        XCTAssertEqual(r["lineTop"] as! Double, 15, accuracy: 0.6, "15 above the setting's line, as on the iPhone: \(r)")
        XCTAssertEqual(r["gap"] as! Double, 6, accuracy: 0.6, "6 under the setting's line: \(r)")
        XCTAssertEqual(r["noteLeft"] as! Double, 0, accuracy: 0.6, "the description starts under the icon: \(r)")
        XCTAssertEqual(r["noteWidth"] as! Double, r["content"] as! Double, accuracy: 0.6, "full width: \(r)")
        XCTAssertEqual(r["valueMid"] as! Double, 0, accuracy: 1, "the value stays on the setting's line: \(r)")
        XCTAssertEqual(r["below"] as! Double, 15, accuracy: 0.6, "15 under the description, as on the iPhone: \(r)")
        XCTAssertEqual(r["size"] as? String, "13px")
        XCTAssertEqual(r["weight"] as? String, "400")
        XCTAssertEqual(r["colour"] as? String, r["muted"] as? String)
    }

    func testASwitchWithASubLineStacksItTwoUnderTheTitle() throws {
        let harness = page()
        let r = try json(harness, probe + """
            const row = rowOf('[data-set="followUp"]'), b = row.getBoundingClientRect();
            const t = title(row), sub = lines(row.querySelector('small'));
            return { height: b.height, rowTitleTop: t[0].top - b.top, gap: sub[0].top - t[t.length - 1].bottom, below: b.bottom - sub[sub.length - 1].bottom };
            """)
        XCTAssertEqual(r["gap"] as! Double, 2, accuracy: 0.6, "\(r)")
        XCTAssertEqual(r["height"] as! Double, 82, accuracy: 0.6, "the iPhone's 82 switch row: \(r)")
        XCTAssertEqual(r["rowTitleTop"] as! Double, r["below"] as! Double, accuracy: 1, "the text is centred in it: \(r)")
    }
}
