import WebKit
import XCTest

/// M4: a click on a reminder's notification or a Spotlight result opens that Take. The page's
/// `catchlightOpenTake` is the real `ui/` in a WKWebView; `TakeOpener` is the shell's side.
final class OpenTakeTests: XCTestCase {
    /// The main window (an account exists) with sixty Takes, one a month for five years, oldest first (the default order), so the newest is far below the fold.
    private func page() -> WebViewHarness {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        harness.load("index.html", in: self, injecting: [WKUserScript(source: "localStorage.clear(); localStorage.setItem('cl.account', JSON.stringify({ made: true }));", injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        _ = try? harness.run("""
            takes = Array.from({ length: 60 }, (_, i) => ({
              id: `000000${String(i).padStart(2, '0')}-0000-4000-8000-000000000000`.toUpperCase(),
              at: new Date(Date.UTC(2022 + Math.floor(i / 12), i % 12, 10, 9)).toISOString(),
              isNote: true, blocks: [{ k: 'text', text: `Take number ${i}` }]
            }));
            renderTakes();
            """, in: self)
        return harness
    }

    private let idBelowTheFold = "00000059-0000-4000-8000-000000000000"
    private let idOther = "00000030-0000-4000-8000-000000000000"

    /// What the page says after opening `id`: whether the call found it, which card has focus, and
    /// whether that card is inside `#takes`'s visible area.
    private func open(_ harness: WebViewHarness, _ id: String, before: String = "") throws -> [String: Any] {
        let reply = try harness.run("""
            \(before)
            if (typeof window.catchlightOpenTake !== 'function') return JSON.stringify({ missing: true });
            const found = window.catchlightOpenTake(\(id.debugDescription));
            const card = document.activeElement?.closest?.('[data-take]');
            const list = document.querySelector('#takes').getBoundingClientRect();
            const r = card?.getBoundingClientRect();
            return JSON.stringify({ found, focused: card?.dataset.take ?? null,
              inside: !!r && r.top >= list.top && r.bottom <= list.bottom,
              dock, storyboard, month: filterMonth, search: searchText });
            """, in: self) as? String
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(reply).utf8)) as? [String: Any])
        XCTAssertNil(parsed["missing"], "the page has no catchlightOpenTake")
        return parsed
    }

    func testATakeBelowTheFoldGetsFocusAndScrollsIntoView() throws {
        let harness = page()
        let before = try harness.run("return document.querySelector(`#takes [data-take=\"\(idBelowTheFold.uppercased())\"]`).getBoundingClientRect().top > document.querySelector('#takes').getBoundingClientRect().bottom;", in: self) as? Bool
        XCTAssertEqual(before, true, "the Take starts below the fold, or the test proves nothing")
        let after = try open(harness, idBelowTheFold.lowercased())
        XCTAssertEqual(after["found"] as? Bool, true)
        XCTAssertEqual(after["focused"] as? String, idBelowTheFold.uppercased())
        XCTAssertEqual(after["inside"] as? Bool, true)
    }

    func testAMonthFilterIsClearedFirst() throws {
        let harness = page()
        let after = try open(harness, idBelowTheFold, before: "filterMonth = '2026-07'; renderTakes();")
        XCTAssertEqual(after["focused"] as? String, idBelowTheFold.uppercased())
        XCTAssertTrue(after["month"] is NSNull)
    }

    func testSearchStoryboardAndSequenceAreLeftFirst() throws {
        let harness = page()
        let searching = try open(harness, idOther, before: "dockTo('search'); searchText = 'number 30'; renderTakes();")
        XCTAssertEqual(searching["focused"] as? String, idOther.uppercased())
        XCTAssertEqual(searching["dock"] as? String, "resting")
        XCTAssertEqual(searching["search"] as? String, "")
        let boarded = try open(harness, idOther, before: "dockTo('storyboard');")
        XCTAssertEqual(boarded["focused"] as? String, idOther.uppercased())
        XCTAssertEqual(boarded["storyboard"] as? Bool, false)
        let sequenced = try open(harness, idOther, before: "dockTo('sequence'); tapFilter('important');")
        XCTAssertEqual(sequenced["focused"] as? String, idOther.uppercased())
        XCTAssertEqual(sequenced["dock"] as? String, "resting")
    }

    func testAnUnknownIdChangesNothing() throws {
        let harness = page()
        let after = try open(harness, "FFFFFFFF-0000-4000-8000-000000000000", before: "filterMonth = '2026-07'; renderTakes();")
        XCTAssertEqual(after["found"] as? Bool, false)
        XCTAssertEqual(after["month"] as? String, "2026-07", "an unknown Take changes nothing")
    }

    // MARK: TakeOpener

    func testTheOpenerCallsThePageWithTheLowercasedId() {
        var calls: [String] = []
        let opener = TakeOpener { calls.append($0) }
        opener.pageDidLoad()
        opener.open(UUID(uuidString: "ABCDEF12-0000-4000-8000-000000000000")!)
        XCTAssertEqual(calls, ["abcdef12-0000-4000-8000-000000000000"])
    }

    func testAClickBeforeThePageHasLoadedWaitsForIt() {
        var calls: [String] = []
        let opener = TakeOpener { calls.append($0) }
        opener.open(UUID(uuidString: "ABCDEF12-0000-4000-8000-000000000000")!)
        XCTAssertEqual(calls, [])
        opener.pageDidLoad()
        XCTAssertEqual(calls, ["abcdef12-0000-4000-8000-000000000000"])
        opener.pageDidLoad()
        XCTAssertEqual(calls.count, 1, "a reload does not open it again")
    }
}
