import WebKit
import XCTest

/// Labels show their words as written, in sentence case, as the iPhone's do (Mark, 2026-11-20: the
/// brand rule is sentence case): the side label on each conflict card ("Local", "Cloud") and About's
/// "Open source licences" heading.
final class SentenceCaseTests: XCTestCase {
    private func style(_ html: String, _ selector: String) throws -> String {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        harness.load("index.html", in: self, injecting: [WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        return try XCTUnwrap(try harness.run("""
            const d = document.createElement('div'); d.innerHTML = `\(html)`; document.body.append(d);
            const cs = getComputedStyle(d.querySelector('\(selector)'));
            return JSON.stringify([cs.textTransform, cs.letterSpacing]);
            """, in: self) as? String)
    }

    func testTheConflictSideLabelIsNotForcedToCapitals() throws {
        XCTAssertEqual(try style("<span class=\"cf-label\">Local</span>", ".cf-label"), #"["none","normal"]"#)
    }

    func testTheLicencesHeadingIsSentenceCase() throws {
        XCTAssertEqual(try style("<div class=\"scard\"><h4>Open source licences</h4></div>", ".scard h4"), #"["none","normal"]"#)
        let source = try String(contentsOf: WebViewHarness.repoUI.appendingPathComponent("settings.js"), encoding: .utf8)
        XCTAssertTrue(source.contains("t('Open source licences')"), "the heading's words, as the iPhone's")
    }
}
