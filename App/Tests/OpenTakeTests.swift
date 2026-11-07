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

    /// What the page says after opening `id`: what the call answered, which card has focus, and
    /// whether that card is inside `#takes`'s visible area.
    private func open(_ harness: WebViewHarness, _ id: String, before: String = "") throws -> [String: Any] {
        let reply = try harness.run("""
            \(before)
            if (typeof window.catchlightOpenTake !== 'function') return JSON.stringify({ missing: true });
            const result = window.catchlightOpenTake(\(id.debugDescription));
            const card = document.activeElement?.closest?.('[data-take]');
            const list = document.querySelector('#takes').getBoundingClientRect();
            const r = card?.getBoundingClientRect();
            return JSON.stringify({ result, focused: card?.dataset.take ?? null,
              inside: !!r && r.top >= list.top && r.bottom <= list.bottom,
              dock, storyboard, month: filterMonth, search: searchText,
              editing: !!draft, ring: !!focusRing, picker: !!reminderFor, settingsOpen: !sheet.hidden,
              text: takes.find(t => t.id === '\(idBelowTheFold.uppercased())')?.blocks[0].text });
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
        XCTAssertEqual(after["result"] as? String, "opened")
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
        XCTAssertEqual(after["result"] as? String, "missing")
        XCTAssertEqual(after["month"] as? String, "2026-07", "an unknown Take changes nothing")
    }

    func testAnOpenEditorIsSavedAndTheCardFocused() throws {
        let harness = page()
        let after = try open(harness, idBelowTheFold, before: """
            beginEdit(takes.find(t => t.id === '\(idBelowTheFold.uppercased())'));
            document.querySelector('#take-rows .etext').textContent = 'Edited before the click';
            """)
        XCTAssertEqual(after["result"] as? String, "opened")
        XCTAssertEqual(after["text"] as? String, "Edited before the click", "the unsaved edit is kept")
        XCTAssertEqual(after["editing"] as? Bool, false)
        XCTAssertEqual(after["focused"] as? String, idBelowTheFold.uppercased())
    }

    /// Each overlay owns the keyboard, so a click changes nothing while one is open and says so.
    func testAnOpenOverlayIsLeftAloneAndTheCallSaysBusy() throws {
        let overlays = [
            ("the Focus-ring", "openFocusRing(takes[30], document.querySelector(`#takes [data-iris=\"${takes[30].id}\"]`), false);", "ring"),
            ("the reminder picker", "openReminder(takes[30], null, null);", "picker"),
            ("Settings", "openSettings();", "settingsOpen"),
        ]
        for (name, open, flag) in overlays {
            let harness = page()
            let after = try self.open(harness, idBelowTheFold, before: "\(open) filterMonth = '2026-07'; renderTakes();")
            XCTAssertEqual(after["result"] as? String, "busy", name)
            XCTAssertEqual(after[flag] as? Bool, true, "\(name) is still open")
            XCTAssertEqual(after["month"] as? String, "2026-07", "\(name): the filter is untouched")
            XCTAssertNotEqual(after["focused"] as? String, idBelowTheFold.uppercased(), name)
        }
    }

    // MARK: TakeOpener

    private let someID = UUID(uuidString: "ABCDEF12-0000-4000-8000-000000000000")!
    private let lowercased = "abcdef12-0000-4000-8000-000000000000"

    /// An opener whose page answers from `answers` (one per call, then "opened"), and whose
    /// retries are held in `scheduled` until the test runs them.
    private final class Rig {
        var calls: [String] = []
        var answers: [String] = []
        var scheduled: [() -> Void] = []
        lazy var opener = TakeOpener(callPage: { [unowned self] id, reply in
            calls.append(id)
            reply(answers.isEmpty ? "opened" : answers.removeFirst())
        }, schedule: { [unowned self] _, work in scheduled.append(work) })
        func runRetry() { let work = scheduled.removeFirst(); work() }
    }

    func testTheOpenerCallsThePageWithTheLowercasedId() {
        let rig = Rig()
        rig.opener.pageDidLoad()
        rig.opener.open(someID)
        XCTAssertEqual(rig.calls, [lowercased])
    }

    func testAClickBeforeThePageHasLoadedWaitsForIt() {
        let rig = Rig()
        rig.opener.open(someID)
        XCTAssertEqual(rig.calls, [])
        rig.opener.pageDidLoad()
        XCTAssertEqual(rig.calls, [lowercased])
        rig.opener.pageDidLoad()
        XCTAssertEqual(rig.calls.count, 1, "a reload does not open it again")
    }

    func testAClickThatFindsThePageBusyIsRetriedUntilItOpens() {
        let rig = Rig()
        rig.answers = ["busy", "busy"]
        rig.opener.pageDidLoad()
        rig.opener.open(someID)
        XCTAssertEqual(rig.calls.count, 1)
        rig.runRetry()
        XCTAssertEqual(rig.calls.count, 2)
        rig.runRetry()
        XCTAssertEqual(rig.calls.count, 3)
        XCTAssertTrue(rig.scheduled.isEmpty, "it opened, so nothing more is scheduled")
    }

    func testANewerClickReplacesAnOlderOneStillRetrying() {
        let rig = Rig()
        rig.answers = ["busy"]
        rig.opener.pageDidLoad()
        rig.opener.open(someID)
        let newer = UUID(uuidString: "11111111-0000-4000-8000-000000000000")!
        rig.opener.open(newer)
        rig.runRetry()
        XCTAssertEqual(rig.calls, [lowercased, "11111111-0000-4000-8000-000000000000"], "the old retry does nothing")
    }

    func testARetryStopsAfterItsLimit() {
        let rig = Rig()
        rig.answers = Array(repeating: "busy", count: 1000)
        rig.opener.pageDidLoad()
        rig.opener.open(someID)
        while !rig.scheduled.isEmpty { rig.runRetry() }
        XCTAssertEqual(rig.calls.count, 1 + TakeOpener.retryLimit)
    }

    func testAPageThatIsGoneStopsOpeningUntilItLoadsAgain() {
        let rig = Rig()
        rig.opener.pageDidLoad()
        rig.opener.pageDidUnload()
        rig.opener.open(someID)
        XCTAssertEqual(rig.calls, [])
        rig.opener.pageDidLoad()
        XCTAssertEqual(rig.calls, [lowercased])
    }
}
