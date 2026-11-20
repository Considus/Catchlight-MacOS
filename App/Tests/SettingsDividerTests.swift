import WebKit
import XCTest

/// Rows in a Settings group are divided by a hairline, as on the iPhone: in the line colour, from
/// the title's left edge to the row's right edge, between rows only (none above the first or under
/// the last). Read from the drawn pixels, because the old divider was set in the CSS yet painted
/// over by its own card-coloured cut-out and never showed (Art Director, 2026-11-20).
final class SettingsDividerTests: XCTestCase {
    /// The colours down one column, in device pixels, across the given points.
    private func colours(at xs: [Double], ys: ClosedRange<Double>) throws -> [Double: [String]] {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        harness.load("index.html", in: self, injecting: [WKUserScript(source: "localStorage.clear(); localStorage.setItem('cl.scene', JSON.stringify('daylight'));", injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        // Two rows built as settings.js builds them, in normal flow at (20, 20), so a snapshot sees them.
        _ = try harness.run("""
            document.body.innerHTML = '<section id="settings" style="position:static;display:block;padding:20px;background:var(--ground)"><div class="sgroup">'
              + '<label class="srow"><svg class="srow-icon" viewBox="0 0 24 24"></svg><span class="srow-label">Mode</span><span class="srow-value">Light</span><select><option>x</option></select></label>'
              + '<button class="srow" type="button"><svg class="srow-icon" viewBox="0 0 24 24"></svg><span class="srow-label">Scene</span></button></div></section>';
            await new Promise(f => setTimeout(f, 200)); return 1;
            """, in: self)
        let done = expectation(description: "snapshot")
        var image: NSImage?
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: 400, height: 220)
        harness.webView.takeSnapshot(with: config) { img, _ in image = img; done.fulfill() }
        wait(for: [done], timeout: 20)
        let rep = try XCTUnwrap(image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let scale = Double(rep.pixelsWide) / 400
        var out: [Double: [String]] = [:]
        for x in xs {
            out[x] = (Int(ys.lowerBound * scale)...Int(ys.upperBound * scale)).map { y in
                let c = rep.colorAt(x: Int(x * scale), y: y)!.usingColorSpace(.sRGB)!
                return String(format: "%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
            }
        }
        return out
    }

    func testAHairlineDividesTheRowsFromTheTitleToTheRightEdge() throws {
        // The rows start at x 20; the title at 20 + 16 + 22 + 14 = 72. The boundary is at y 20 + 74 = 94.
        let c = try colours(at: [60, 80, 300], ys: 90...98)
        let card = "FFFFFF"
        XCTAssertTrue(c[60]!.allSatisfy { $0 == card }, "no line left of the title: \(c[60]!)")
        for x in [80.0, 300.0] {
            let marked = c[x]!.filter { $0 != card }
            XCTAssertEqual(marked.count, 1, "one device pixel of line at x \(x): \(c[x]!)")
        }
    }

    func testNoLineAboveTheFirstRowOrUnderTheLast() throws {
        let c = try colours(at: [300], ys: 20...24)
        XCTAssertTrue(c[300]!.allSatisfy { $0 == "FFFFFF" }, "\(c[300]!)")
        let d = try colours(at: [300], ys: 163...167)
        XCTAssertTrue(d[300]!.allSatisfy { $0 == "FFFFFF" }, "\(d[300]!)")
    }
}
