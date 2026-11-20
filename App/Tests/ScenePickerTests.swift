import WebKit
import XCTest

/// The Scene picker as the iPhone's SettingsView has it: in Appearance, straight under Mode, a menu
/// row named Scene listing the five Scenes by name, Cobalt until the person picks, applied the
/// moment one is chosen and kept for next time.
final class ScenePickerTests: XCTestCase {
    private func page(keeping: Bool = false) -> WebViewHarness {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        harness.load("index.html", in: self, injecting: keeping ? [] : [WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        _ = try? harness.run("document.querySelector('.first-run').hidden = true; document.body.classList.remove('first-running');", in: self)
        return harness
    }

    private func json(_ harness: WebViewHarness, _ body: String) throws -> [String: Any] {
        let text = try XCTUnwrap(try harness.run("return JSON.stringify(await (async () => {\n\(body)\n})());", in: self) as? String)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    func testSceneSitsUnderModeWithTheFiveNames() throws {
        let harness = page()
        let r = try json(harness, """
            openSettings(); await new Promise(f => setTimeout(f, 300));
            const group = document.querySelector('[data-set="mode"]').closest('.sgroup');
            const rows = [...group.querySelectorAll('.srow')].map(x => x.querySelector('.srow-label')?.firstChild?.textContent.trim());
            const select = group.querySelector('[data-set="colourScene"]');
            return { rows, options: select ? [...select.options].map(o => o.textContent) : null, value: select?.value ?? null,
              shown: select?.closest('.srow').querySelector('.srow-value').textContent ?? null, comingSoon: group.textContent.includes('Coming soon'),
              scene: document.documentElement.dataset.scene ?? null };
            """)
        XCTAssertEqual((r["rows"] as? [String])?.prefix(2).map { $0 }, ["Mode", "Scene"])
        XCTAssertEqual(r["options"] as? [String], ["Cobalt", "Graphite", "Onyx", "Jade", "Tanzanite"])
        XCTAssertEqual(r["value"] as? String, "cobalt")
        XCTAssertEqual(r["shown"] as? String, "Cobalt")
        XCTAssertEqual(r["comingSoon"] as? Bool, false)
        XCTAssertEqual(r["scene"] as? String, "cobalt")
    }

    func testChoosingASceneAppliesAtOnceAndIsKept() throws {
        let harness = page()
        let r = try json(harness, """
            openSettings(); await new Promise(f => setTimeout(f, 300));
            const select = document.querySelector('[data-set="colourScene"]');
            select.value = 'jade'; select.dispatchEvent(new Event('change', { bubbles: true }));
            return { scene: document.documentElement.dataset.scene, mode: document.documentElement.dataset.mode, ground: getComputedStyle(document.documentElement).getPropertyValue('--ground').trim() };
            """)
        XCTAssertEqual(r["scene"] as? String, "jade")
        // Jade's ground in the mode the Mac is in (the CI Mac runs Light).
        XCTAssertEqual(r["ground"] as? String, r["mode"] as? String == "light" ? "#F6F8F5" : "#0C1511", "Jade's ground, applied at once: \(r)")
        let again = page(keeping: true)
        let kept = try json(again, "return { scene: document.documentElement.dataset.scene };")
        XCTAssertEqual(kept["scene"] as? String, "jade", "kept for next time")
    }
}
