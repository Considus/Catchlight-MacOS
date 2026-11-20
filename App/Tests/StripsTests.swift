import XCTest
import WebKit

/// The strips at the top of Dailies, as the iPhone's DailiesView `topStrips`: conflicts, reminders
/// silenced, a sync error and Takes skipped by sync, in that order, each a full-width band with
/// the conflict strip's geometry. Driven through the page's real bridge.js over a stand-in shell
/// that answers each command with a canned reply, so the sync wiring is the one the app runs.
final class StripsTests: XCTestCase {
    /// The shell's message handler, answering from `replies` (a queue per command, then a fixed
    /// answer) and recording each command the page sent.
    final class FakeShell: NSObject, WKScriptMessageHandlerWithReply {
        var queued: [String: [Any]] = [:]
        var fixed: [String: Any] = ["notificationStatus": "enabled", "conflicts": [Any]()]
        private(set) var sent: [String] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
            let cmd = (message.body as? [String: Any])?["cmd"] as? String ?? ""
            sent.append(cmd)
            if var q = queued[cmd], !q.isEmpty { replyHandler(q.removeFirst(), nil); queued[cmd] = q; return }
            replyHandler(fixed[cmd] ?? NSNull(), nil)
        }
    }

    private var shell: FakeShell!

    /// The page as the app loads it: a shell, an account, a sync folder, and `takes` as given.
    private func page(takes: String = "[]", notifications: String = "enabled", conflicts: [Any] = [], library extra: String = "") -> WebViewHarness {
        shell = FakeShell()
        shell.fixed["notificationStatus"] = notifications
        shell.fixed["conflicts"] = conflicts
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil, privateStorage: true)
        harness.webView.configuration.userContentController.addScriptMessageHandler(shell, contentWorld: .page, name: "catchlight")
        let start = WKUserScript(source: """
            // The page's storage outlives a test: start each with no saved settings or strip state.
            ['cl.remindersSilencedDismissed', 'cl.settings'].forEach(k => localStorage.removeItem(k));
            window.catchlightShell = Object.freeze({ language: 'en' });
            localStorage.removeItem('cl.onset.phraseMissing'); localStorage.removeItem('cl.onset.remindersSilenced');
            window.catchlightLibrary = { account: true, takes: \(takes), scripts: []\(extra) };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        harness.load("index.html", in: self, injecting: [start])
        _ = try? harness.run("store.set('account', { ...store.get('account', {}), folder: 'Sync' }); return 0;", in: self)
        return harness
    }

    /// Each strip showing, with its words as they show (the hint is only for VoiceOver).
    private func strips(_ harness: WebViewHarness) throws -> String? {
        try harness.run("""
            return JSON.stringify([...document.querySelectorAll('#strips > .strip:not([hidden])')].map(s => { const c = s.cloneNode(true); c.querySelectorAll('.sr-only').forEach(h => h.remove()); return [s.dataset.strip, c.textContent.trim()]; }));
            """, in: self) as? String
    }

    private let waitFor = "for (let i = 0; i < 100 && !(%@); i++) await new Promise(r => setTimeout(r, 50));"

    // MARK: Sync error

    func testASyncErrorShowsAStripWithDismiss() throws {
        let harness = page()
        shell.queued["sync"] = [["error": "Sync encountered a problem and will retry."]]
        _ = try harness.run("await catchlightBridge.sync('manual'); return 0;", in: self)
        XCTAssertEqual(try strips(harness), #"[["sync","Sync encountered a problem and will retry.Dismiss"]]"#)
        let after = try harness.run("""
            const was = settings.notices[0]?.message;
            document.querySelector('[data-strip="sync"] [data-strip-act="dismiss"]').click();
            \(String(format: waitFor, "!document.querySelector('[data-strip=\"sync\"]:not([hidden])')"))
            return JSON.stringify([was, !!document.querySelector('[data-strip="sync"]:not([hidden])')]);
            """, in: self) as? String
        XCTAssertEqual(after, #"["Sync encountered a problem and will retry.",false]"#, "still in Notice History; Dismiss takes the strip away")
    }

    func testTheSyncStripGoesByItselfAfterEightSeconds() throws {
        let harness = page()
        XCTAssertEqual(try harness.run("return STRIP_TIMEOUT.sync;", in: self) as? Int, 8000, "the iPhone's 8 s")
        shell.queued["sync"] = [["error": "Sync encountered a problem and will retry."]]
        let gone = try harness.run("""
            STRIP_TIMEOUT.sync = 150;
            await catchlightBridge.sync('manual');
            const shown = !!document.querySelector('[data-strip="sync"]:not([hidden])');
            await new Promise(r => setTimeout(r, 600));
            return JSON.stringify([shown, !!document.querySelector('[data-strip="sync"]:not([hidden])')]);
            """, in: self) as? String
        XCTAssertEqual(gone, "[true,false]")
    }

    func testASyncWithoutAnErrorShowsNoStrip() throws {
        let harness = page()
        shell.queued["sync"] = [["applied": 0, "conflicts": 0]]
        _ = try harness.run("await catchlightBridge.sync('manual'); return 0;", in: self)
        XCTAssertEqual(try strips(harness), "[]")
    }

    // MARK: Skipped Takes

    func testSkippedTakesAreCountedOnceEachUntilDismissed() throws {
        let a = UUID().uuidString, b = UUID().uuidString, c = UUID().uuidString
        let harness = page()
        shell.queued["sync"] = [["quarantined": 2, "quarantinedIDs": [a, b]], ["quarantined": 2, "quarantinedIDs": [b, c]], ["quarantined": 1, "quarantinedIDs": [a]]]
        _ = try harness.run("await catchlightBridge.sync('manual'); await catchlightBridge.sync('manual'); return 0;", in: self)
        XCTAssertEqual(try strips(harness), #"[["quarantine","3 Takes couldn't be verified and were skipped.Dismiss"]]"#, "a Take every pass re-reports is counted once (AppModel.reportQuarantined)")
        _ = try harness.run("""
            document.querySelector('[data-strip="quarantine"] [data-strip-act="dismiss"]').click();
            await catchlightBridge.sync('manual'); return 0;
            """, in: self)
        XCTAssertEqual(try strips(harness), #"[["quarantine","1 Take couldn't be verified and were skipped.Dismiss"]]"#.replacingOccurrences(of: "1 Take couldn't be verified and were skipped.", with: try harness.run("return t(\"%lld Takes couldn't be verified and were skipped.\", 1);", in: self) as! String), "Dismiss starts the count again")
    }

    func testTheSkippedStripDoesNotGoByItself() throws {
        let harness = page()
        shell.queued["sync"] = [["quarantined": 1, "quarantinedIDs": [UUID().uuidString]]]
        let still = try harness.run("""
            STRIP_TIMEOUT.sync = 50;
            await catchlightBridge.sync('manual');
            await new Promise(r => setTimeout(r, 300));
            return !!document.querySelector('[data-strip="quarantine"]:not([hidden])');
            """, in: self) as? Bool
        XCTAssertEqual(still, true, "on the iPhone it stays until Dismiss")
    }

    // MARK: Reminders silenced

    private let alerting = #"[{"id":"7D4C4A4E-0000-4000-8000-000000000001","at":"2026-11-01T09:00:00.000Z","blocks":[{"k":"text","text":"Call"}],"reminder":{"kind":"time","when":"2099-01-01T09:00:00Z","notify":true,"done":false}}]"#
    private let silent = #"[{"id":"7D4C4A4E-0000-4000-8000-000000000002","at":"2026-11-01T09:00:00.000Z","blocks":[{"k":"text","text":"Call"}],"reminder":{"kind":"time","when":"2099-01-01T09:00:00Z","notify":false,"done":false}}]"#

    private func settle(_ harness: WebViewHarness) throws {
        _ = try harness.run("for (let i = 0; i < 20; i++) await new Promise(r => setTimeout(r, 25)); return 0;", in: self)
    }

    func testNotificationsOffWithAnAlertingReminderShowsTheStrip() throws {
        let harness = page(takes: alerting, notifications: "denied")
        try settle(harness)
        XCTAssertEqual(try strips(harness), #"[["silenced","Enable NotificationsTurn on"]]"#)
        let a11y = try harness.run("""
            const s = document.querySelector('[data-strip="silenced"]');
            const on = s.querySelector('[data-strip-act="turn-on"]'), x = s.querySelector('[data-strip-act="close"]');
            return JSON.stringify([on.getAttribute('aria-label'), document.getElementById(on.getAttribute('aria-describedby'))?.textContent, x.getAttribute('aria-label')]);
            """, in: self) as? String
        XCTAssertEqual(a11y, #"["Turn on notifications","Opens System Settings.","Dismiss"]"#)
    }

    func testTurnOnAsksTheShell() throws {
        let harness = page(takes: alerting, notifications: "denied")
        try settle(harness)
        _ = try harness.run("document.querySelector('[data-strip=\"silenced\"] [data-strip-act=\"turn-on\"]').click(); await new Promise(r => setTimeout(r, 100)); return 0;", in: self)
        XCTAssertTrue(shell.sent.contains("enableNotifications"), "the shell opens System Settings for a denied permission: \(shell.sent)")
    }

    func testNoStripWithoutAnAlertingReminderOrWhenAllowed() throws {
        let quiet = page(takes: silent, notifications: "denied")
        try settle(quiet)
        XCTAssertEqual(try strips(quiet), "[]", "a reminder with Notify off can't be silenced")
        let allowed = page(takes: alerting, notifications: "enabled")
        try settle(allowed)
        XCTAssertEqual(try strips(allowed), "[]")
        let notAsked = page(takes: alerting, notifications: "ask")
        try settle(notAsked)
        XCTAssertEqual(try strips(notAsked), "[]", "only denied counts (ReminderScheduler.remindersSilenced)")
    }

    func testClosingTheSilencedStripIsForGood() throws {
        let harness = page(takes: alerting, notifications: "denied")
        try settle(harness)
        _ = try harness.run("document.querySelector('[data-strip=\"silenced\"] [data-strip-act=\"close\"]').click(); return 0;", in: self)
        try settle(harness)
        XCTAssertEqual(try strips(harness), "[]")
        let again = try harness.run("paintStrips(); dispatchEvent(new Event('focus')); for (let i = 0; i < 10; i++) await new Promise(r => setTimeout(r, 25)); return JSON.stringify([document.querySelectorAll('#strips > .strip:not([hidden])').length, store.get('remindersSilencedDismissed', false)]);", in: self) as? String
        XCTAssertEqual(again, "[0,true]", "stored, so it never comes back")
    }

    func testTheSilencedStripFollowsThePermission() throws {
        let harness = page(takes: alerting, notifications: "denied")
        try settle(harness)
        XCTAssertEqual(try strips(harness), #"[["silenced","Enable NotificationsTurn on"]]"#)
        shell.fixed["notificationStatus"] = "enabled"
        _ = try harness.run("dispatchEvent(new Event('focus')); return 0;", in: self)
        try settle(harness)
        XCTAssertEqual(try strips(harness), "[]", "turned on in System Settings, gone when the window comes back")
    }

    // MARK: Conflicts, order and look

    func testConflictsWithAnUnverifiedCopySayADecisionIsWaiting() throws {
        let take: [String: Any] = ["kind": "take", "blocks": [["k": "text", "text": "Mine"]]]
        let harness = page(conflicts: [["id": UUID().uuidString, "unverified": true, "local": take, "cloud": take]])
        _ = try harness.run(String(format: waitFor, "!conflictBanner.hidden") + " return 0;", in: self)
        XCTAssertEqual(try strips(harness), #"[["conflict","1 Take needs a decision.Review"]]"#.replacingOccurrences(of: "1 Take needs a decision.", with: try harness.run("return t('%lld Takes need a decision.', 1);", in: self) as! String))
    }

    func testTheStripsComeInTheIPhonesOrder() throws {
        let take: [String: Any] = ["kind": "take", "blocks": [["k": "text", "text": "Mine"]]]
        let harness = page(takes: alerting, notifications: "denied", conflicts: [["id": UUID().uuidString, "local": take, "remote": take]])
        shell.queued["sync"] = [["error": "Sync encountered a problem and will retry.", "quarantined": 1, "quarantinedIDs": [UUID().uuidString], "conflicts": 1]]
        let order = try harness.run("""
            \(String(format: waitFor, "!conflictBanner.hidden"))
            await catchlightBridge.sync('manual');
            \(String(format: waitFor, "document.querySelector('[data-strip=\"silenced\"]:not([hidden])')"))
            return JSON.stringify([...document.querySelectorAll('#strips > .strip:not([hidden])')].map(s => s.dataset.strip));
            """, in: self) as? String
        XCTAssertEqual(order, #"["conflict","silenced","sync","quarantine"]"#)
    }

    func testEveryStripHasTheIPhonesGeometry() throws {
        let take: [String: Any] = ["kind": "take", "blocks": [["k": "text", "text": "Mine"]]]
        let harness = page(takes: alerting, notifications: "denied", conflicts: [["id": UUID().uuidString, "local": take, "remote": take]])
        shell.queued["sync"] = [["error": "Sync encountered a problem and will retry.", "quarantined": 1, "quarantinedIDs": [UUID().uuidString], "conflicts": 1]]
        let looks = try harness.run("""
            \(String(format: waitFor, "!conflictBanner.hidden"))
            await catchlightBridge.sync('manual');
            \(String(format: waitFor, "document.querySelector('[data-strip=\"silenced\"]:not([hidden])')"))
            document.getAnimations().forEach(a => a.finish());
            const col = document.querySelector('#sidebar').getBoundingClientRect();
            return JSON.stringify([...document.querySelectorAll('#strips > .strip:not([hidden])')].map(s => {
              const cs = getComputedStyle(s), r = s.getBoundingClientRect(), text = getComputedStyle(s.querySelector('.strip-text'));
              const icon = s.querySelector('.strip-icon').getBoundingClientRect(), act = getComputedStyle(s.querySelector('button'));
              return [s.dataset.strip, Math.round(r.left - col.left), Math.round(col.right - r.right), r.height >= 44, cs.paddingLeft, cs.borderTopWidth, cs.borderRadius,
                text.fontSize, text.fontWeight, Math.round(icon.width), act.fontSize, act.fontWeight, cs.columnGap];
            }));
            """, in: self) as? String
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(looks).utf8)) as? [[Any]])
        XCTAssertEqual(rows.count, 4, looks ?? "")
        for row in rows {
            let name = row[0] as! String
            XCTAssertEqual(row[1] as? Int, 0, "\(name): the band starts at the column's edge")
            XCTAssertEqual(row[2] as? Int, 0, "\(name): and runs to its other edge")
            XCTAssertEqual(row[3] as? Bool, true, "\(name): at least 44 tall")
            XCTAssertEqual(row[4] as? String, "16px", "\(name): 16 at the sides")
            XCTAssertEqual(row[5] as? String, "0px", "\(name): no border")
            XCTAssertEqual(row[6] as? String, "0px", "\(name): square, a band")
            XCTAssertEqual(row[7] as? String, "14px", "\(name): 14 pt text")
            XCTAssertEqual(row[8] as? String, "400", "\(name): regular")
            XCTAssertEqual(row[9] as? Int, 16, "\(name): 16 pt icon")
            XCTAssertEqual(row[10] as? String, "14px", "\(name): 14 pt action")
            XCTAssertEqual(row[11] as? String, "500", "\(name): medium action")
            XCTAssertEqual(row[12] as? String, "10px", "\(name): 10 between")
        }
    }

    /// The tint behind each band, read as colour: the accent at 15% for conflicts and silenced
    /// reminders, ruby at 12% for errors (`ckAdd.opacity(0.15)`, `ckRuby.opacity(0.12)`).
    func testTheBandsAreTintedAsOnTheIPhone() throws {
        let take: [String: Any] = ["kind": "take", "blocks": [["k": "text", "text": "Mine"]]]
        let harness = page(takes: alerting, notifications: "denied", conflicts: [["id": UUID().uuidString, "local": take, "remote": take]])
        shell.queued["sync"] = [["error": "Sync encountered a problem and will retry.", "quarantined": 1, "quarantinedIDs": [UUID().uuidString], "conflicts": 1]]
        let tints = try harness.run("""
            \(String(format: waitFor, "!conflictBanner.hidden"))
            await catchlightBridge.sync('manual');
            \(String(format: waitFor, "document.querySelector('[data-strip=\"silenced\"]:not([hidden])')"))
            const probe = c => { const d = document.createElement('i'); d.style.color = c; document.body.append(d); const v = getComputedStyle(d).color; d.remove(); return v; };
            const root = getComputedStyle(document.documentElement);
            const want = (v, a) => probe(`color-mix(in srgb, ${root.getPropertyValue(v).trim()} ${a}%, transparent)`);
            return JSON.stringify([...document.querySelectorAll('#strips > .strip:not([hidden])')].map(s => [s.dataset.strip, getComputedStyle(s).backgroundColor,
              s.dataset.strip === 'conflict' || s.dataset.strip === 'silenced' ? want('--accent', 15) : want('--ruby', 12)]));
            """, in: self) as? String
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(tints).utf8)) as? [[String]])
        XCTAssertEqual(rows.count, 4, tints ?? "")
        for row in rows { XCTAssertEqual(row[1], row[2], "\(row[0])") }
    }

    // MARK: No Privacy phrase

    private let phrase = "No Privacy phrase on this device. Export now, then Settings > Start over."

    func testAMissingPhraseShowsTheStripSecondAfterConflicts() throws {
        let take: [String: Any] = ["kind": "take", "blocks": [["k": "text", "text": "Mine"]]]
        let harness = page(takes: alerting, notifications: "denied", conflicts: [["id": UUID().uuidString, "local": take, "remote": take]], library: ", phraseMissing: true")
        let order = try harness.run("""
            \(String(format: waitFor, "!conflictBanner.hidden && document.querySelector('[data-strip=\"silenced\"]:not([hidden])')"))
            return JSON.stringify([...document.querySelectorAll('#strips > .strip:not([hidden])')].map(s => s.dataset.strip));
            """, in: self) as? String
        XCTAssertEqual(order, #"["conflict","phrase","silenced"]"#)
        XCTAssertEqual(try strips(harness).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String]] }?[1], ["phrase", phrase + "Export now"])
        let a11y = try harness.run("""
            document.getAnimations().forEach(a => a.finish());   // measured at rest, not mid-fold
            const b = document.querySelector('[data-strip="phrase"] [data-strip-act="export"]'), s = getComputedStyle(b.closest('.strip'));
            return JSON.stringify([b.getAttribute('aria-label'), document.getElementById(b.getAttribute('aria-describedby'))?.textContent, s.paddingTop, s.paddingBottom]);
            """, in: self) as? String
        XCTAssertEqual(a11y, #"["Export your Takes","Saves a readable copy. Not a Privacy phrase.","8px","8px"]"#)
    }

    func testNoPhraseStripWhenThePhraseIsThere() throws {
        let harness = page()
        try settle(harness)
        XCTAssertEqual(try strips(harness), "[]")
    }

    func testExportNowAsksFirstThenExportsEveryTake() throws {
        let harness = page(takes: alerting, library: ", phraseMissing: true")
        try settle(harness)
        let dialog = try harness.run("""
            document.querySelector('[data-strip="phrase"] [data-strip-act="export"]').click();
            return JSON.stringify([alertBox.open, alertBox.querySelector('h2, h1, .alert-title')?.textContent, alertBox.querySelector('p')?.textContent, [...alertBox.querySelectorAll('button')].map(b => b.textContent)]);
            """, in: self) as? String
        XCTAssertEqual(dialog, #"[true,"Export a readable copy?","The file is readable text and it does not contain a Privacy phrase. Use Start over and Import from a file to re-import your Takes. Delete the export once your Takes are back.",["Export anyway","Cancel"]]"#)
        XCTAssertFalse(shell.sent.contains("exportFile"), "nothing leaves before the choice")
        _ = try harness.run("[...alertBox.querySelectorAll('button')].find(b => b.textContent === 'Export anyway').click(); await new Promise(r => setTimeout(r, 200)); return 0;", in: self)
        XCTAssertTrue(shell.sent.contains("exportFile"), "\(shell.sent)")
    }

    func testCancelExportsNothing() throws {
        let harness = page(takes: alerting, library: ", phraseMissing: true")
        try settle(harness)
        _ = try harness.run("""
            document.querySelector('[data-strip="phrase"] [data-strip-act="export"]').click();
            [...alertBox.querySelectorAll('button')].find(b => b.textContent === 'Cancel').click();
            await new Promise(r => setTimeout(r, 200)); return 0;
            """, in: self)
        XCTAssertFalse(shell.sent.contains("exportFile"))
    }

    /// As NoticeOnset: a lasting condition goes into Notice History once when it begins, not at
    /// each launch, and again only after it has ended and come back.
    func testEachLastingStripIsRecordedOnceWhenItBegins() throws {
        let harness = page(takes: alerting, notifications: "denied", library: ", phraseMissing: true")
        try settle(harness)
        let first = try harness.run("return JSON.stringify(settings.notices.filter(n => n.category === 'storage').map(n => n.message).sort());", in: self) as? String
        XCTAssertEqual(first, "[\"Enable Notifications\",\"\(phrase)\"]")
        let again = try harness.run("paintStrips(); dispatchEvent(new Event('focus')); for (let i = 0; i < 10; i++) await new Promise(r => setTimeout(r, 25)); renderTakes(); return settings.notices.filter(n => n.category === 'storage').length;", in: self) as? Int
        XCTAssertEqual(again, 2, "not again while it lasts")
    }
}
