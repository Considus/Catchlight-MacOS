import WebKit
import XCTest

/// The lock screen, as the iPhone's LockView draws it: the first-run mark and heading in the same
/// place, a message and one button, three states (locked, unlocking, failed), a 0.4 s crossfade in
/// and out of the app and a 0.2 s one between its words. The page reads the shell's answer from
/// `window.catchlightLibrary` (`locked`, `lockFailure`, `unlocked`) and asks the shell to open the
/// library through `catchlightBridge.shell.unlock()`. The harness has no shell, so each page is
/// given a stand-in bridge before any script runs.
final class LockScreenTests: XCTestCase {
    /// `library` is the rest of the object literal the shell would set; `unlock` is the stand-in's
    /// answer (a function returning a promise); `account` says whether an account record exists.
    private func page(_ library: String = "locked: true", unlock: String = "() => new Promise(() => {})", account: Bool = false,
                      hold: Bool = false) -> WebViewHarness {
        let setup = """
            localStorage.clear();
            \(account ? "localStorage.setItem('cl.account', JSON.stringify({ storage: 'local' }));" : "")
            window.catchlightLibrary = { account: true, takes: [], scripts: [], \(library) };
            window.lockAfterCalls = [];
            window.catchlightBridge = { shell: {
              setSpotlight() {}, setWritingTools() {},
              setLockAfter: seconds => { window.lockAfterCalls.push(seconds); return Promise.resolve(); },
              unlock: (\(unlock)),
            } };
            window.holdAnimations = \(hold);
            window.animations = [];
            (() => {
              const animate = Element.prototype.animate;
              Element.prototype.animate = function (frames, options) {
                const a = animate.call(this, frames, options);
                window.animations.push({ el: this, frames: JSON.parse(JSON.stringify(frames)), options: JSON.parse(JSON.stringify(options ?? {})) });
                if (window.holdAnimations) a.pause();
                return a;
              };
            })();
            """
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        harness.load("index.html", in: self, injecting: [WKUserScript(source: setup, injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        return harness
    }

    private func json(_ harness: WebViewHarness, _ body: String) throws -> [String: Any] {
        let text = try XCTUnwrap(try harness.run("return JSON.stringify(await (async () => {\n\(body)\n})());", in: self) as? String)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    private let probe = """
        const tick = () => new Promise(f => setTimeout(f, 30));
        const finishAll = () => document.getAnimations().forEach(a => a.finish());
        const read = (root = '#lock') => ({
          message: document.querySelector(root + ' .lock-message')?.textContent,
          button: document.querySelector(root + ' .lock-button')?.textContent,
          disabled: document.querySelector(root + ' .lock-button')?.disabled,
          live: document.querySelector(root + ' [aria-live="assertive"]')?.textContent,
        });
        """

    private let cancelledText = "Couldn't unlock. Authenticate to open your Takes."
    private let restartText = "Your encrypted library couldn't be opened. Please restart Catchlight."

    func testALockedLibraryShowsTheLockScreenNotFirstRun() throws {
        let harness = page()
        let r = try json(harness, probe + """
            const lock = document.querySelector('#lock'), box = lock?.getBoundingClientRect(), firstRun = document.querySelector('.first-run');
            const heading = lock?.querySelector('h2');
            return { exists: !!lock, section: lock?.tagName, hidden: lock?.hidden, covers: box ? [box.width, box.height] : null, window: [innerWidth, innerHeight],
              firstRunHidden: getComputedStyle(firstRun).display === 'none', firstRunning: document.body.classList.contains('first-running'),
              heading: heading?.textContent, headingTag: heading?.tagName, ...read(),
              focused: document.activeElement === lock?.querySelector('.lock-button'),
              pill: lock?.querySelector('.lock-button')?.className };
            """)
        XCTAssertEqual(r["exists"] as? Bool, true, "\(r)")
        XCTAssertEqual(r["section"] as? String, "SECTION")
        XCTAssertNotEqual(r["hidden"] as? Bool, true)
        XCTAssertEqual(r["covers"] as? [Double], r["window"] as? [Double], "the lock fills the window: \(r)")
        XCTAssertEqual(r["firstRunHidden"] as? Bool, true, "first run never shows while locked: \(r)")
        XCTAssertEqual(r["firstRunning"] as? Bool, false)
        XCTAssertEqual(r["heading"] as? String, "Catchlight is locked")
        XCTAssertEqual(r["headingTag"] as? String, "H2")
        XCTAssertEqual(r["message"] as? String, "Authenticate to open your Takes.")
        XCTAssertEqual(r["button"] as? String, "Unlock")
        XCTAssertEqual(r["disabled"] as? Bool, false)
        XCTAssertEqual(r["focused"] as? Bool, true, "the Unlock button has focus")
        XCTAssertEqual(r["pill"] as? String, "fr-pill primary lock-button")
    }

    func testUnlockingThenCancelledShowsTryAgain() throws {
        let harness = page(unlock: "() => new Promise((_, reject) => { window.refuse = reject; })")
        let r = try json(harness, probe + """
            document.querySelector('#lock .lock-button').click();
            await tick();
            const unlocking = read(), calls = window.lockAfterCalls.length;
            window.refuse('cancelled');
            await tick(); finishAll(); await tick();
            return { unlocking, failed: read(), focused: document.activeElement === document.querySelector('#lock .lock-button'), ghosts: document.querySelectorAll('#lock .text-leaving').length };
            """)
        let unlocking = try XCTUnwrap(r["unlocking"] as? [String: Any])
        XCTAssertEqual(unlocking["message"] as? String, "Authenticating…")
        XCTAssertEqual(unlocking["button"] as? String, "Unlocking…")
        XCTAssertEqual(unlocking["disabled"] as? Bool, true, "disabled while unlocking")
        XCTAssertTrue((unlocking["live"] as? String ?? "").isEmpty, "unlocking is not announced, as on the iPhone: \(unlocking)")
        let failed = try XCTUnwrap(r["failed"] as? [String: Any])
        XCTAssertEqual(failed["button"] as? String, "Try Again")
        XCTAssertEqual(failed["message"] as? String, cancelledText)
        XCTAssertEqual(failed["disabled"] as? Bool, false)
        XCTAssertEqual(failed["live"] as? String, cancelledText, "the failure is announced")
        XCTAssertEqual(r["focused"] as? Bool, true)
        XCTAssertEqual(r["ghosts"] as? Int, 0, "the fading copies are gone once they have faded")
    }

    func testUnopenableSaysRestart() throws {
        let harness = page(unlock: "() => Promise.reject('unopenable')")
        let r = try json(harness, probe + """
            document.querySelector('#lock .lock-button').click();
            await tick(); finishAll(); await tick();
            return read();
            """)
        XCTAssertEqual(r["message"] as? String, restartText)
        XCTAssertEqual(r["button"] as? String, "Try Again")
        XCTAssertEqual(r["live"] as? String, restartText)
    }

    func testAFailureAtLaunchOpensOnTryAgain() throws {
        let harness = page("locked: true, lockFailure: 'cancelled'")
        let r = try json(harness, probe + "return read();")
        XCTAssertEqual(r["button"] as? String, "Try Again")
        XCTAssertEqual(r["message"] as? String, cancelledText)
        XCTAssertEqual(r["live"] as? String, cancelledText)
        let unopenable = try json(page("locked: true, lockFailure: 'unopenable'"), probe + "return read();")
        XCTAssertEqual(unopenable["message"] as? String, restartText)
        XCTAssertEqual(unopenable["button"] as? String, "Try Again")
    }

    func testTheTextCrossfadesOverPointTwoSeconds() throws {
        let harness = page(hold: true)
        let r = try json(harness, probe + """
            window.animations.length = 0;
            document.querySelector('#lock .lock-button').click();
            await tick();
            const of = cls => window.animations.filter(a => a.el.classList.contains(cls));
            const leaving = of('text-leaving').map(a => [a.el.classList.contains('lock-message') ? 'message' : 'button', a.frames.map(f => f.opacity), a.options.duration, a.options.easing]);
            const entering = window.animations.filter(a => !a.el.classList.contains('text-leaving') && (a.el.classList.contains('lock-message') || a.el.classList.contains('lock-button')))
              .map(a => [a.el.classList.contains('lock-message') ? 'message' : 'button', a.frames.map(f => f.opacity), a.options.duration, a.options.easing]);
            const ghost = document.querySelector('#lock .lock-message.text-leaving');
            return { leaving, entering, ghost: ghost ? { text: ghost.textContent, hidden: ghost.getAttribute('aria-hidden'), inert: ghost.inert } : null };
            """)
        func expect(_ key: String, _ from: [Double], line: String) throws {
            let rows = try XCTUnwrap(r[key] as? [[Any]], "\(r)")
            for part in ["message", "button"] {
                let row = try XCTUnwrap(rows.first { $0[0] as? String == part }, "\(part) \(line): \(r)")
                XCTAssertEqual(row[1] as? [Double], from)
                XCTAssertEqual(row[2] as? Double, 200)
                XCTAssertEqual(row[3] as? String, "ease-in-out")
            }
        }
        try expect("leaving", [1, 0], line: "has a leaving copy fading out")
        try expect("entering", [0, 1], line: "fades in")
        let ghost = try XCTUnwrap(r["ghost"] as? [String: Any])
        XCTAssertEqual(ghost["text"] as? String, "Authenticate to open your Takes.", "the leaving copy holds the old words")
        XCTAssertEqual(ghost["hidden"] as? String, "true"); XCTAssertEqual(ghost["inert"] as? Bool, true)
    }

    func testALockedPageFadesInOverPointFourSeconds() throws {
        let harness = page(hold: true)
        let r = try json(harness, """
            const lock = document.querySelector('#lock');
            const fade = window.animations.find(a => a.el === lock);
            return { fade: fade ? [fade.frames.map(f => f.opacity), fade.options.duration, fade.options.easing] : null, behind: getComputedStyle(document.querySelector('#app')).visibility };
            """)
        let fade = try XCTUnwrap(r["fade"] as? [Any], "\(r)")
        XCTAssertEqual(fade[0] as? [Double], [0, 1])
        XCTAssertEqual(fade[1] as? Double, 400)
        XCTAssertEqual(fade[2] as? String, "ease-in-out")
        XCTAssertEqual(r["behind"] as? String, "hidden", "it fades in from the plain ground, not over the app")
    }

    func testAfterUnlockTheLockFadesOutOverPointFourSeconds() throws {
        let harness = page("unlocked: true", account: true, hold: true)
        let r = try json(harness, probe + """
            const copy = document.querySelector('.lock-screen');
            const fade = window.animations.find(a => a.el === copy);
            const before = copy ? { ...read('.lock-screen'), hidden: copy.getAttribute('aria-hidden'), inert: copy.inert, heading: copy.querySelector('h2')?.textContent } : null;
            const appInert = document.querySelector('#app').inert;
            finishAll(); await tick();
            return { before, fade: fade ? [fade.frames.map(f => f.opacity), fade.options.duration, fade.options.easing] : null, appInert, gone: !document.querySelector('.lock-screen') };
            """)
        let before = try XCTUnwrap(r["before"] as? [String: Any], "a copy of the lock screen starts the page: \(r)")
        XCTAssertEqual(before["heading"] as? String, "Catchlight is locked")
        XCTAssertEqual(before["message"] as? String, "Authenticating…")
        XCTAssertEqual(before["button"] as? String, "Unlocking…")
        XCTAssertEqual(before["hidden"] as? String, "true"); XCTAssertEqual(before["inert"] as? Bool, true)
        let fade = try XCTUnwrap(r["fade"] as? [Any], "\(r)")
        XCTAssertEqual(fade[0] as? [Double], [1, 0])
        XCTAssertEqual(fade[1] as? Double, 400)
        XCTAssertEqual(fade[2] as? String, "ease-in-out")
        XCTAssertEqual(r["appInert"] as? Bool, false, "the app is live behind the fading copy")
        XCTAssertEqual(r["gone"] as? Bool, true, "removed once it has faded")
    }

    func testNothingBehindTheLockIsReachable() throws {
        let harness = page()
        let r = try json(harness, """
            const app = document.querySelector('#app'), lock = document.querySelector('#lock');
            const hit = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
            return { inert: app.inert, hidden: app.getAttribute('aria-hidden'), hit: !!hit && lock.contains(hit), focusInLock: lock.contains(document.activeElement) };
            """)
        XCTAssertEqual(r["inert"] as? Bool, true)
        XCTAssertEqual(r["hidden"] as? String, "true")
        XCTAssertEqual(r["hit"] as? Bool, true)
        XCTAssertEqual(r["focusInLock"] as? Bool, true)
    }

    func testTheMenuOffersNothingWhileLocked() throws {
        let flatten = """
            const flat = entries => entries.flatMap(e => e.items ? flat(e.items) : e.separator ? [] : [e]);
            const items = flat(catchlightMenu.model());
            return { enabled: items.filter(i => i.enabled && !i.role).map(i => i.id), roles: items.filter(i => i.role && i.enabled).map(i => i.id) };
            """
        let locked = try json(page(), flatten)
        XCTAssertEqual(locked["enabled"] as? [String], ["help", "report", "copyInfo"], "no item that touches Takes, Scripts or the layout: \(locked)")
        XCTAssertTrue((locked["roles"] as? [String] ?? []).contains("quit"), "Quit stays: \(locked)")
        XCTAssertTrue((locked["roles"] as? [String] ?? []).contains("hide"), "Hide stays: \(locked)")
        // The instrument can see an enabled item: the same page, not locked, offers New Take.
        let open = try json(page("takes: []", account: true), flatten)
        XCTAssertTrue((open["enabled"] as? [String] ?? []).contains("newTake"), "unlocked offers New Take: \(open)")
        // And a locked page refuses the command itself, not only the menu's greying.
        let refused = try json(page(), "const before = takes.length; const ran = catchlightMenu.run('newTake'); return { ran, same: takes.length === before };")
        XCTAssertEqual(refused["ran"] as? Bool, false)
        XCTAssertEqual(refused["same"] as? Bool, true)
    }

    func testLockAfterIsSentToTheShell() throws {
        let harness = page("takes: []", account: true)
        let r = try json(harness, """
            const atLoad = [...window.lockAfterCalls];
            openSettings(); await new Promise(f => setTimeout(f, 300));
            const select = document.querySelector('[data-set="lockAfter"]');
            select.value = '300'; select.dispatchEvent(new Event('change', { bubbles: true }));
            return { atLoad, after: [...window.lockAfterCalls] };
            """)
        XCTAssertEqual(r["atLoad"] as? [String], ["60"])
        XCTAssertEqual(r["after"] as? [String], ["60", "300"])
    }

    /// The lock screen's mark and heading sit where first run's do (a step on the ground with the
    /// same brand mark), in the same face, and the message and button follow the iPhone's spacing.
    func testTheLockScreenMatchesFirstRunsMarkAndHeading() throws {
        let probeLayer = """
            const box = el => { const b = el.getBoundingClientRect(); return [b.left, b.top, b.width, b.height]; };
            const style = el => { const c = getComputedStyle(el); return { size: c.fontSize, weight: c.fontWeight, family: c.fontFamily, variation: c.fontVariationSettings, leading: c.lineHeight, align: c.textAlign, colour: c.color }; };
            const measure = root => { const h = root.querySelector('h2'), p = root.querySelector('.fr-body p'), mark = root.querySelector('.fr-mark'), pc = getComputedStyle(p);
              return { mark: box(mark), headingTop: box(h)[1], heading: style(h), message: { ...style(p), left: pc.paddingLeft, right: pc.paddingRight }, role: h.tagName,
                headingToMessage: p.getBoundingClientRect().top - h.getBoundingClientRect().bottom }; };
            """
        let lock = try json(page(), probeLayer + "return measure(document.querySelector('#lock'));")
        let first = try json(page("takes: []"), probeLayer + "show('localWarning'); return measure(document.querySelector('.first-run'));")
        XCTAssertEqual(lock["mark"] as? [Double], first["mark"] as? [Double], "the mark is first run's, in the same place and size: \(lock) \(first)")
        XCTAssertEqual((lock["mark"] as? [Double])?[2], 72)
        XCTAssertEqual(lock["headingTop"] as? Double ?? 0, first["headingTop"] as? Double ?? -1, accuracy: 0.6, "the heading starts where first run's does")
        let heading = try XCTUnwrap(lock["heading"] as? [String: String]), firstHeading = try XCTUnwrap(first["heading"] as? [String: String])
        XCTAssertEqual(heading["size"], "28px")
        XCTAssertEqual(heading, firstHeading, "the first-run heading style")
        let message = try XCTUnwrap(lock["message"] as? [String: String]), firstMessage = try XCTUnwrap(first["message"] as? [String: String])
        XCTAssertEqual(message["size"], "16px"); XCTAssertEqual(message["weight"], "300")
        XCTAssertEqual(message["left"], "32px"); XCTAssertEqual(message["right"], "32px")
        XCTAssertEqual(message["colour"], firstMessage["colour"], "muted, as first run's body")
        XCTAssertEqual(message["align"], "center")
        XCTAssertEqual(lock["headingToMessage"] as? Double ?? 0, 14, accuracy: 0.6, "the message is 14 below the heading")
    }
}
