import WebKit
import XCTest

/// The rest of the iPhone's motion: the Dailies heading crossfades on a mode change (0.18 s);
/// a Take opened from outside pulses in the accent (UIKitTimeline.attemptReveal); the conflict
/// banner fades in and out while the list makes room (0.2 s); a shot list item's tick changes
/// over 0.15 s (none with Reduce Motion) and a dropped item settles into its slot (0.18 s).
final class MotionMoreTests: XCTestCase {
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

    private let recorder = """
        const calls = [], animate = Element.prototype.animate;
        Element.prototype.animate = function (frames, options) {
          calls.push({ el: this, frames: JSON.parse(JSON.stringify(frames)), options: JSON.parse(JSON.stringify(options ?? {})) });
          return animate.call(this, frames, options);
        };
        const opacities = c => c.frames.map(f => f.opacity ?? null);
        """

    func testTheHeadingCrossfadesOnAModeChange() throws {
        let harness = page()
        let r = try json(harness, recorder + """
            const heading = document.querySelector('#dailies-heading');
            document.querySelector('#takes-dock [data-act="sequence"]').click();
            const into = calls.find(c => c.el === heading), ghost = document.querySelector('.text-leaving');
            const out = calls.find(c => c.el === ghost);
            const g = ghost ? { text: ghost.textContent, hidden: ghost.getAttribute('aria-hidden'), id: ghost.id, left: ghost.getBoundingClientRect().left - heading.getBoundingClientRect().left, top: ghost.getBoundingClientRect().top - heading.getBoundingClientRect().top } : null;
            ghost?.getAnimations().forEach(a => a.finish());
            await new Promise(f => setTimeout(f, 20));
            return { into: into ? [opacities(into), into.options.duration, into.options.easing] : null, out: out ? [opacities(out), out.options.duration] : null,
              ghost: g, text: heading.textContent, headings: document.querySelectorAll('#dailies-heading').length, gone: !document.querySelector('.text-leaving') };
            """)
        let into = try XCTUnwrap(r["into"] as? [Any], "the new title fades in: \(r)")
        XCTAssertEqual(into[0] as? [Double], [0, 1]); XCTAssertEqual(into[1] as? Double, 180); XCTAssertEqual(into[2] as? String, "ease-in-out")
        let out = try XCTUnwrap(r["out"] as? [Any], "the old one fades out over it: \(r)")
        XCTAssertEqual(out[0] as? [Double], [1, 0]); XCTAssertEqual(out[1] as? Double, 180)
        let ghost = try XCTUnwrap(r["ghost"] as? [String: Any])
        XCTAssertEqual(ghost["text"] as? String, "Dailies"); XCTAssertEqual(ghost["hidden"] as? String, "true"); XCTAssertEqual(ghost["id"] as? String, "")
        XCTAssertEqual(ghost["left"] as! Double, 0, accuracy: 0.5, "in the same place: \(r)"); XCTAssertEqual(ghost["top"] as! Double, 0, accuracy: 0.5)
        XCTAssertEqual(r["text"] as? String, "Sequence"); XCTAssertEqual(r["headings"] as? Int, 1)
        XCTAssertEqual(r["gone"] as? Bool, true, "the copy goes once faded")
    }

    func testATakeOpenedFromOutsidePulsesInTheAccent() throws {
        let harness = page()
        let r = try json(harness, recorder + """
            const take = takes.find(t => !t.obie);
            const said = catchlightOpenTake(take.id);
            const card = document.querySelector(`#takes [data-take="${take.id}"]`), flash = card?.querySelector('.reveal-flash');
            const call = calls.find(c => c.el === flash), cs = flash && getComputedStyle(flash);
            const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim();
            const probe = document.createElement('div'); probe.style.color = accent; document.body.append(probe); const want = getComputedStyle(probe).color; probe.remove();
            const box = flash && [flash.getBoundingClientRect().width - card.getBoundingClientRect().width, flash.getBoundingClientRect().height - card.getBoundingClientRect().height];
            return { said, found: !!call, frames: call ? opacities(call) : [], offsets: call ? call.frames.map(f => f.offset ?? null) : [], delay: call?.options.delay, duration: call?.options.duration,
              fill: cs?.backgroundColor, want, hidden: flash?.getAttribute('aria-hidden'), events: cs?.pointerEvents, box };
            """)
        XCTAssertEqual(r["said"] as? String, "opened")
        XCTAssertEqual(r["found"] as? Bool, true, "\(r)")
        XCTAssertEqual(r["frames"] as? [Double], [0, 0.18, 0.18, 0], "up to 18% and back: \(r)")
        let offsets = try XCTUnwrap(r["offsets"] as? [Any])
        XCTAssertEqual(offsets[1] as! Double, 0.4 / 1.4, accuracy: 0.001, "0.4 s up"); XCTAssertEqual(offsets[2] as! Double, 1 / 1.4, accuracy: 0.001, "held until 1 s")
        XCTAssertEqual(r["delay"] as? Double, 350, "once the scroll has settled"); XCTAssertEqual(r["duration"] as? Double, 1400)
        XCTAssertEqual(r["fill"] as? String, r["want"] as? String, "the accent: \(r)")
        XCTAssertEqual(r["hidden"] as? String, "true"); XCTAssertEqual(r["events"] as? String, "none")
        XCTAssertEqual(r["box"] as? [Double], [0, 0], "over the whole card, its edge too: \(r)")
    }

    func testTheConflictBannerFadesInAndFoldsAway() throws {
        let harness = page()
        let r = try json(harness, recorder + """
            const banner = document.querySelector('.conflict-banner');
            conflictList = [{ id: 'a' }, { id: 'b' }]; paintConflicts();
            const come = calls.find(c => c.el === banner);
            banner.getAnimations().forEach(a => a.finish());
            const full = getComputedStyle(banner).height;
            calls.length = 0;
            conflictList = []; paintConflicts();
            const ghost = document.querySelector('.conflict-banner-leaving'), go = calls.find(c => c.el === ghost);
            const during = { hidden: banner.hidden, ghostHidden: ghost?.getAttribute('aria-hidden'), ghostText: ghost?.textContent ?? '', review: document.querySelectorAll('[data-cf="review"]:not([inert] *)').length };
            ghost?.getAnimations().forEach(a => a.finish());
            await new Promise(f => setTimeout(f, 20));
            return { still: still.matches, keys: come ? Object.keys(come.frames[0]).sort() : [], come: come ? [come.frames[0].opacity, come.frames[0].height, come.frames[1].opacity, come.frames[1].height, come.options.duration, come.options.easing] : null, full,
              go: go ? [go.frames[0].opacity, go.frames[1].opacity, go.frames[1].height, go.options.duration] : null, during, gone: !document.querySelector('.conflict-banner-leaving') };
            """)
        let come = try XCTUnwrap(r["come"] as? [Any], "the banner animates in: \(r)")
        if r["still"] as? Bool == true {   // Reduce Motion: a fade alone, nothing moves
            XCTAssertEqual(r["keys"] as? [String], ["opacity"], "\(r)"); XCTAssertEqual(come[4] as? Double, 120)
            let go = try XCTUnwrap(r["go"] as? [Any], "\(r)"); XCTAssertEqual(go[1] as? Double, 0); XCTAssertNil(go[2] as? String)
            XCTAssertEqual(r["gone"] as? Bool, true); return
        }
        XCTAssertEqual(come[0] as? Double, 0); XCTAssertEqual(come[1] as? String, "0px")
        XCTAssertEqual(come[2] as? Double, 1); XCTAssertEqual(come[3] as? String, r["full"] as? String)
        XCTAssertEqual(come[4] as? Double, 200); XCTAssertEqual(come[5] as? String, "ease-in-out")
        let go = try XCTUnwrap(r["go"] as? [Any], "a copy folds away: \(r)")
        XCTAssertEqual(go[0] as? Double, 1); XCTAssertEqual(go[1] as? Double, 0); XCTAssertEqual(go[2] as? String, "0px"); XCTAssertEqual(go[3] as? Double, 200)
        let during = try XCTUnwrap(r["during"] as? [String: Any])
        XCTAssertEqual(during["hidden"] as? Bool, true, "the banner itself is gone at once")
        XCTAssertEqual(during["ghostHidden"] as? String, "true")
        XCTAssertTrue((during["ghostText"] as? String ?? "").contains("2"), "the copy keeps its words while it goes: \(r)")
        XCTAssertEqual(during["review"] as? Int, 0, "and offers nothing to press")
        XCTAssertEqual(r["gone"] as? Bool, true)
    }

    func testAShotListTickChangesOverAFifteenthOfASecond() throws {
        let harness = page()
        let r = try json(harness, recorder + """
            const take = takes.find(t => isTask(t) && t.blocks.some(b => b.k === 'check' && !b.done));
            beginEdit(take); openShotList();
            const i = draft.blocks.findIndex(b => b.k === 'check' && !b.done);
            calls.length = 0;
            document.querySelector(`.sl-item[data-i="${i}"] .sl-box`).click();
            const row = document.querySelector(`.sl-item[data-i="${i}"]`);
            const text = calls.find(c => c.el === row.querySelector('.sl-text')), box = calls.find(c => c.el === row.querySelector('.sl-box'));
            row.querySelectorAll('*').forEach(el => el.getAnimations({ subtree: false }).forEach(a => a.finish()));
            row.querySelector('.sl-box').getAnimations({ subtree: true }).forEach(a => a.finish());
            return { still: still.matches, ticked: row.querySelector('.sl-row').classList.contains('ticked'),
              text: text ? [text.frames.map(f => f.color), text.options.duration, text.options.easing] : null,
              box: box ? [opacities(box), box.options.duration, box.options.pseudoElement] : null,
              faint: getComputedStyle(row.querySelector('.sl-text')).color };
            """)
        XCTAssertEqual(r["ticked"] as? Bool, true)
        if r["still"] as? Bool == true {
            XCTAssertNil(r["text"] as? [Any], "Reduce Motion: no animation: \(r)"); XCTAssertNil(r["box"] as? [Any])
        } else {
            let text = try XCTUnwrap(r["text"] as? [Any], "\(r)")
            let colours = try XCTUnwrap(text[0] as? [String])
            XCTAssertNotEqual(colours[0], colours[1], "from the old colour"); XCTAssertEqual(colours[1], r["faint"] as? String, "to the ticked one")
            XCTAssertEqual(text[1] as? Double, 150); XCTAssertEqual(text[2] as? String, "ease-in-out")
            let box = try XCTUnwrap(r["box"] as? [Any], "\(r)")
            XCTAssertEqual(box[0] as? [Double], [0, 1]); XCTAssertEqual(box[1] as? Double, 150); XCTAssertEqual(box[2] as? String, "::before")
        }
    }

    func testADroppedShotListItemSettlesIntoItsSlot() throws {
        let harness = page()
        let r = try json(harness, recorder + """
            const take = takes.find(t => isTask(t) && t.blocks.filter(b => b.k === 'check').length >= 2);
            beginEdit(take); openShotList();
            const first = document.querySelector('.sl-item'), handle = first.querySelector('.sl-handle'), h = handle.getBoundingClientRect();
            const x = h.left + h.width / 2, y = h.top + h.height / 2, step = first.offsetHeight;
            const fire = (type, dy) => handle.dispatchEvent(new PointerEvent(type, { bubbles: true, pointerId: 7, button: 0, clientX: x, clientY: y + dy }));
            fire('pointerdown', 0); fire('pointermove', 5); fire('pointermove', step + 10);
            const before = first.getBoundingClientRect().top;
            calls.length = 0;
            fire('pointerup', step + 10);
            const settle = calls.find(c => c.frames.some(f => (f.transform ?? '').startsWith('translateY')));
            const landed = settle?.el, after = landed?.getBoundingClientRect().top;
            landed?.getAnimations().forEach(a => a.finish());
            return { still: still.matches, found: !!settle, frames: settle ? settle.frames.map(f => f.transform) : [], duration: settle?.options.duration, easing: settle?.options.easing,
              dy: before - (landed ? landed.getBoundingClientRect().top : 0), moved: landed?.dataset.i };
            """)
        if r["still"] as? Bool == true {
            XCTAssertEqual(r["found"] as? Bool, false, "Reduce Motion: it is placed at once: \(r)")
        } else {
            XCTAssertEqual(r["found"] as? Bool, true, "\(r)")
            let frames = try XCTUnwrap(r["frames"] as? [String])
            XCTAssertEqual(frames.last, "none")
            let from = Double(frames[0].replacingOccurrences(of: "translateY(", with: "").replacingOccurrences(of: "px)", with: "")) ?? .nan
            XCTAssertEqual(from, r["dy"] as! Double, accuracy: 0.5, "from where it was let go: \(r)")
            XCTAssertNotEqual(from, 0, accuracy: 0.5)
            XCTAssertEqual(r["duration"] as? Double, 180); XCTAssertEqual(r["easing"] as? String, "ease-in-out")
        }
    }
}
