import WebKit
import XCTest

/// The last of the iPhone's motion: the edit card and the dimmed Takes (UIState.fanFade, 0.2 s,
/// none with Reduce Motion), the switches (FlatToggleStyle, snappy 0.15, none with Reduce
/// Motion), the repeat options (snappy 0.2), and the first run's step crossfade (0.18), failure
/// card, wrong-guess flash and its fade into the app (RootView, 0.4).
final class MotionRestTests: XCTestCase {
    private func page(firstRun: Bool = false) -> WebViewHarness {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        harness.load("index.html", in: self, injecting: [WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        if !firstRun { _ = try? harness.run("document.querySelector('.first-run').hidden = true; document.body.classList.remove('first-running');", in: self) }
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
        const finishAll = () => document.getAnimations().forEach(a => a.finish());
        """

    func testTheEditCardAndTheDimmedTakesFadeWithTheFanFade() throws {
        let harness = page()
        let r = try json(harness, recorder + """
            const card = document.querySelector('#take-editor'), list = getComputedStyle(document.querySelector('#takes'));
            beginEdit(takes.find(t => !t.obie));
            const into = calls.find(c => c.el === card);
            finishAll(); calls.length = 0;
            discardEdit();
            const copy = document.querySelector('.take-editor.leaving'), out = calls.find(c => c.el === copy);
            const c = copy ? { hidden: copy.getAttribute('aria-hidden'), ids: copy.querySelectorAll('[id]').length + (copy.id ? 1 : 0), inert: copy.inert } : null;
            finishAll(); await new Promise(f => setTimeout(f, 20));
            return { still: still.matches, media: matchMedia('(prefers-reduced-motion: reduce)').matches, into: into ? [opacities(into), into.options.duration, into.options.easing] : null, out: out ? [opacities(out), out.options.duration] : null,
              copy: c, cardHidden: card.hidden, gone: !document.querySelector('.take-editor.leaving'), dim: [list.transitionProperty, list.transitionDuration, list.transitionTimingFunction] };
            """)
        XCTAssertEqual(r["cardHidden"] as? Bool, true, "the card itself goes at once")
        XCTAssertEqual(r["gone"] as? Bool, true)
        let dim = try XCTUnwrap(r["dim"] as? [String])
        if r["still"] as? Bool == true {
            XCTAssertNil(r["into"] as? [Any], "Reduce Motion: no fade: \(r)"); XCTAssertNil(r["out"] as? [Any])
        } else {
            let into = try XCTUnwrap(r["into"] as? [Any], "\(r)")
            XCTAssertEqual(into[0] as? [Double], [0, 1]); XCTAssertEqual(into[1] as? Double, 200); XCTAssertEqual(into[2] as? String, "ease-in-out")
            let out = try XCTUnwrap(r["out"] as? [Any], "\(r)")
            XCTAssertEqual(out[0] as? [Double], [1, 0]); XCTAssertEqual(out[1] as? Double, 200)
            let copy = try XCTUnwrap(r["copy"] as? [String: Any])
            XCTAssertEqual(copy["hidden"] as? String, "true"); XCTAssertEqual(copy["ids"] as? Int, 0); XCTAssertEqual(copy["inert"] as? Bool, true)
        }
        // The dimming is the stylesheet's, so it follows the system setting itself.
        if r["media"] as? Bool == true { XCTAssertEqual(dim[1], "0s", "Reduce Motion: the Takes dim at once: \(r)") }
        else { XCTAssertEqual(dim, ["opacity", "0.2s", "ease-in-out"], "the Takes dim and come back over 0.2 s: \(r)") }
    }

    func testASwitchTurnsWithTheSnappySpring() throws {
        let harness = page()
        let r = try json(harness, recorder + """
            openSettings(); await new Promise(f => setTimeout(f, 300));
            const before = document.querySelector('[data-set="confirmDelete"]'), wasOn = before.checked;
            calls.length = 0;
            before.checked = !wasOn; before.dispatchEvent(new Event('change', { bubbles: true }));
            const now = document.querySelector('[data-set="confirmDelete"]');
            const track = calls.find(c => c.el === now && !c.options.pseudoElement), knob = calls.find(c => c.el === now && c.options.pseudoElement === '::after');
            finishAll();
            const rest = getComputedStyle(now, '::after').transform, fill = getComputedStyle(now).backgroundColor;
            return { still: still.matches, replaced: now !== before, wasOn, on: now.checked,
              track: track ? [track.frames.map(f => f.backgroundColor), track.options.duration, track.options.easing.slice(0, 7)] : null,
              knob: knob ? [knob.frames.map(f => f.transform), knob.options.duration] : null, rest, fill };
            """)
        XCTAssertEqual(r["replaced"] as? Bool, true, "the sheet repaints, so only an animation can show the turn")
        XCTAssertNotEqual(r["wasOn"] as? Bool, r["on"] as? Bool)
        if r["still"] as? Bool == true {
            XCTAssertNil(r["track"] as? [Any], "Reduce Motion: no turn: \(r)"); XCTAssertNil(r["knob"] as? [Any])
        } else {
            let track = try XCTUnwrap(r["track"] as? [Any], "\(r)"), knob = try XCTUnwrap(r["knob"] as? [Any], "\(r)")
            let fills = try XCTUnwrap(track[0] as? [String])
            XCTAssertNotEqual(fills[0], fills[1]); XCTAssertEqual(fills[1], r["fill"] as? String, "to the new fill")
            XCTAssertEqual(track[2] as? String, "linear(", "a spring, as a linear() easing")
            XCTAssertEqual(track[1] as! Double, 194, accuracy: 3, "snappy 0.15: response 0.15, damping 0.85, settled in about 0.19 s")
            let moves = try XCTUnwrap(knob[0] as? [String])
            XCTAssertNotEqual(moves[0], moves[1]); XCTAssertEqual(moves[1], r["rest"] as? String, "the knob ends where it rests: \(r)")
        }
    }

    func testTheRepeatOptionsOpenAndCloseWithASpring() throws {
        let harness = page()
        let r = try json(harness, recorder + """
            const rsheet = document.querySelector('.reminder-sheet');
            openReminder(takes.find(t => !t.obie), null); await new Promise(f => setTimeout(f, 100));
            const flip = on => { const s = rsheet.querySelector('[data-r="repeat"]'); s.checked = on; s.dispatchEvent(new Event('change', { bubbles: true })); };
            calls.length = 0; flip(true);
            const row = rsheet.querySelector('[data-r="interval"]')?.closest('.srow'), open = calls.find(c => c.el === row);
            finishAll(); const full = row && getComputedStyle(row).height;
            calls.length = 0; flip(false);
            const copy = rsheet.querySelector('[aria-hidden="true"] [data-r="interval"]')?.closest('.srow'), shut = calls.find(c => c.el === copy);
            const during = { live: rsheet.querySelectorAll('[data-r="interval"]:not([inert] *)').length, hidden: copy?.getAttribute('aria-hidden') };
            finishAll(); await new Promise(f => setTimeout(f, 20));
            return { still: still.matches, full, open: open ? [open.frames.map(f => f.height ?? null), opacities(open), open.options.duration, (open.options.easing ?? '').slice(0, 7)] : null,
              shut: shut ? [shut.frames.map(f => f.height ?? null), opacities(shut)] : null, during, gone: rsheet.querySelectorAll('[data-r="interval"]').length };
            """)
        let open = try XCTUnwrap(r["open"] as? [Any], "the Interval row animates in: \(r)")
        let shut = try XCTUnwrap(r["shut"] as? [Any], "and a copy of it out: \(r)")
        let during = try XCTUnwrap(r["during"] as? [String: Any])
        XCTAssertEqual(during["live"] as? Int, 0, "the setting is already off while the copy goes: \(r)")
        XCTAssertEqual(r["gone"] as? Int, 0)
        if r["still"] as? Bool == true {
            XCTAssertEqual(open[1] as? [Double], [0, 1], "Reduce Motion: a fade alone: \(r)"); XCTAssertEqual(open[2] as? Double, 120)
            XCTAssertEqual((open[0] as? [Any])?.compactMap { $0 as? String }, [], "nothing moves")
        } else {
            XCTAssertEqual(open[0] as? [String], ["0px", r["full"] as! String], "it opens to its height: \(r)")
            XCTAssertEqual(open[1] as? [Double], [0, 1])
            XCTAssertEqual(open[2] as! Double, 259, accuracy: 3, "snappy 0.2: response 0.2, damping 0.85")
            XCTAssertEqual(open[3] as? String, "linear(")
            XCTAssertEqual(shut[0] as? [String], [r["full"] as! String, "0px"]); XCTAssertEqual(shut[1] as? [Double], [1, 0])
        }
    }

    func testFirstRunStepsCrossfadeAndTheBrandMarkStays() throws {
        let harness = page(firstRun: true)
        let r = try json(harness, recorder + """
            const layer = document.querySelector('.first-run');
            const go = (from, to) => {
              show(from); finishAll(); calls.length = 0;
              const before = layer.querySelector('.fr-column').getBoundingClientRect();
              show(to);
              const copy = layer.querySelector('.fr-leaving'), out = calls.find(c => c.el === copy);
              const body = layer.querySelector('.fr-body'), column = layer.querySelector('.fr-column');
              const into = calls.find(c => c.el === body || c.el === column);
              const at = copy?.getBoundingClientRect();
              const res = { out: out ? [opacities(out), out.options.duration] : null, into: into ? [into.el === body ? 'body' : 'column', opacities(into), into.options.duration] : null,
                brandShown: copy ? getComputedStyle(copy.querySelector('.fr-brand') ?? copy).visibility : null, hidden: copy?.getAttribute('aria-hidden'),
                shift: at ? [at.left - before.left, at.top - before.top] : null, step: layer.dataset.step };
              finishAll(); return res;
            };
            const a = go('storage', 'folder'), b = go('folder', 'complete'), c = go('splash', 'welcome');
            await new Promise(f => setTimeout(f, 20));
            return { a, b, c, left: layer.querySelectorAll('.fr-leaving').length };
            """)
        let a = try XCTUnwrap(r["a"] as? [String: Any]), b = try XCTUnwrap(r["b"] as? [String: Any]), c = try XCTUnwrap(r["c"] as? [String: Any])
        XCTAssertEqual(a["step"] as? String, "folder")
        XCTAssertEqual((a["out"] as? [Any])?.first as? [Double], [1, 0], "\(a)"); XCTAssertEqual((a["out"] as? [Any])?.last as? Double, 180)
        XCTAssertEqual((a["into"] as? [Any])?.first as? String, "body", "the same mark stays; only the words fade: \(a)")
        XCTAssertEqual(a["brandShown"] as? String, "hidden", "the leaving copy carries no second mark")
        XCTAssertEqual(a["hidden"] as? String, "true")
        let shift = try XCTUnwrap(a["shift"] as? [Double])
        XCTAssertEqual(shift[0], 0, accuracy: 0.5, "the copy sits where the step was: \(a)"); XCTAssertEqual(shift[1], 0, accuracy: 0.5)
        XCTAssertEqual((b["into"] as? [Any])?.first as? String, "column", "onto the colour field the mark changes, so it fades too: \(b)")
        XCTAssertEqual((c["out"] as? [Any])?.last as? Double, 400, "leaving the splash takes RootView's 0.4: \(c)")
        XCTAssertEqual(r["left"] as? Int, 0, "no copies left behind")
    }

    func testAWrongGuessFlashesAndFadesBack() throws {
        let harness = page(firstRun: true)
        let r = try json(harness, recorder + """
            const layer = document.querySelector('.first-run');
            fr.words = ['amber','birch','cedar','delta','ember','fjord','grove','haven','inlet','juniper','kestrel','lumen'];
            newConfirm(); show('confirm'); finishAll();
            const wrong = fr.bank.map((w, i) => i).filter(i => !fr.positions.some(p => fr.bank[i] === fr.words[p]));
            calls.length = 0;
            fr.picked = wrong.slice(0, 3); checkConfirm();
            const error = layer.querySelector('#fr-error'), card = calls.find(c => c.el === error);
            const flash = calls.filter(c => c.el.classList?.contains('fr-slot'));
            await new Promise(f => setTimeout(f, 700));
            const back = calls.filter(c => c.el.classList?.contains('fr-slot') && c.el.isConnected);
            return { card: card ? [opacities(card), card.options.duration] : null, flash: flash.length, flashTo: flash[0]?.frames[1].backgroundColor, flashFrom: flash[0]?.frames[0].backgroundColor,
              back: back.length, backFrom: back[0]?.frames[0].backgroundColor, backTo: back[0]?.frames[1].backgroundColor, duration: flash[0]?.options.duration };
            """)
        XCTAssertEqual((r["card"] as? [Any])?.first as? [Double], [0, 1], "the failure card fades in: \(r)")
        XCTAssertEqual((r["card"] as? [Any])?.last as? Double, 180)
        XCTAssertEqual(r["flash"] as? Int, 3, "each slot flashes: \(r)"); XCTAssertEqual(r["duration"] as? Double, 180)
        XCTAssertNotEqual(r["flashFrom"] as? String, r["flashTo"] as? String)
        XCTAssertEqual(r["back"] as? Int, 3, "and fades back once cleared: \(r)")
        XCTAssertEqual(r["backFrom"] as? String, r["flashTo"] as? String, "from the flash")
        XCTAssertEqual(r["backTo"] as? String, r["flashFrom"] as? String, "to the plain slot")
    }

    func testTheFirstRunFadesIntoTheApp() throws {
        let harness = page(firstRun: true)
        let r = try json(harness, recorder + """
            const layer = document.querySelector('.first-run');
            show('complete'); finishAll(); calls.length = 0;
            await finish();
            const copy = document.querySelector('.fr-leaving'), out = calls.find(c => c.el === copy);
            const res = { hidden: layer.hidden, running: document.body.classList.contains('first-running'), out: out ? [opacities(out), out.options.duration, out.options.easing] : null,
              copyHidden: copy?.getAttribute('aria-hidden'), events: copy && getComputedStyle(copy).pointerEvents, first: document.querySelector('.first-run') === layer };
            finishAll(); await new Promise(f => setTimeout(f, 20));
            res.gone = !document.querySelector('.fr-leaving');
            return res;
            """)
        XCTAssertEqual(r["hidden"] as? Bool, true, "the first run itself is gone at once"); XCTAssertEqual(r["running"] as? Bool, false)
        let out = try XCTUnwrap(r["out"] as? [Any], "a copy fades over the app: \(r)")
        XCTAssertEqual(out[0] as? [Double], [1, 0]); XCTAssertEqual(out[1] as? Double, 400); XCTAssertEqual(out[2] as? String, "ease-in-out")
        XCTAssertEqual(r["copyHidden"] as? String, "true"); XCTAssertEqual(r["events"] as? String, "none")
        XCTAssertEqual(r["first"] as? Bool, true, "the real layer is still the one the page finds")
        XCTAssertEqual(r["gone"] as? Bool, true)
    }
}
