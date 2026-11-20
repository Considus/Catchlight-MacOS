import WebKit
import XCTest

/// The splash's "© 2026 Considus" plate fills the first run's column, as the iPhone's
/// SplashFooterPill fills its row (`maxWidth: .infinity`), its words centred.
final class SplashFootTests: XCTestCase {
    func testTheFooterFillsTheColumn() throws {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        harness.load("index.html", in: self, injecting: [WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        let text = try XCTUnwrap(try harness.run("""
            show('splash');   // read at once: a Reduce Motion Mac leaves the splash straight away
            const layer = document.querySelector('.first-run'), col = layer.querySelector('.fr-column'), foot = layer.querySelector('.fr-foot');
            const c = col.getBoundingClientRect(), f = foot.getBoundingClientRect(), r = document.createRange(); r.selectNodeContents(foot);
            const words = r.getBoundingClientRect();
            return JSON.stringify({ step: layer.dataset.step, col: [c.left, c.width], foot: [f.left, f.width], centre: (words.left + words.right) / 2 - (f.left + f.right) / 2 });
            """, in: self) as? String)
        let r = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
        XCTAssertEqual(r["step"] as? String, "splash")
        let col = try XCTUnwrap(r["col"] as? [Double]), foot = try XCTUnwrap(r["foot"] as? [Double])
        XCTAssertEqual(foot[0], col[0], accuracy: 0.5, "from the column's left edge: \(r)")
        XCTAssertEqual(foot[1], col[1], accuracy: 0.5, "across its width: \(r)")
        XCTAssertEqual(r["centre"] as! Double, 0, accuracy: 0.5, "the words centred: \(r)")
    }
}
