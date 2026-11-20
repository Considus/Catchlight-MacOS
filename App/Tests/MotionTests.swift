import WebKit
import XCTest

/// The iPhone's motion (CatchlightMotion, EditorKeyboardBar, DailiesToolbar): the editor bar's
/// plus turns into Cancel's cross with the turn spring; Sequence's three lines fold into a cross
/// over the shape curve; the filter chips rise from behind the toolbar and sink back in 0.2 s.
/// With Reduce Motion on (as on the CI Mac) the plus and the lines fade in place instead.
final class MotionTests: XCTestCase {
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

    /// Records each animation as it starts: the element, its keyframes and its timing.
    private let recorder = """
        const calls = [], animate = Element.prototype.animate;
        Element.prototype.animate = function (frames, options) {
          calls.push({ el: this, frames: JSON.parse(JSON.stringify(frames)), duration: options?.duration, easing: options?.easing ?? 'linear' });
          return animate.call(this, frames, options);
        };
        """

    func testTheCancelPlusTurnsWithTheTurnSpring() throws {
        let harness = page()
        let r = try json(harness, recorder + """
            beginEdit(takes.find(t => !t.obie));
            const plus = document.querySelector('#eb-discard .icon svg');
            const call = calls.find(c => c.el === plus);
            const turns = call ? call.frames.map(f => f.transform ? parseFloat(f.transform.replace('rotate(', '')) : null) : [];
            return { still: still.matches, found: !!call, duration: call?.duration ?? 0, opacity: call ? call.frames.map(f => f.opacity ?? null) : [],
              first: turns[0] ?? null, last: turns[turns.length - 1] ?? null, peak: turns.length ? Math.max(...turns) : null, rest: getComputedStyle(plus).transform };
            """)
        print("MotionTests: Reduce Motion is \(r["still"] as? Bool == true ? "on" : "off")")
        XCTAssertEqual(r["found"] as? Bool, true, "the plus animates as the bar appears: \(r)")
        XCTAssertTrue((r["rest"] as? String ?? "").hasPrefix("matrix(0.707"), "it rests turned 45 degrees: \(r)")
        if r["still"] as? Bool == true {
            XCTAssertEqual(r["opacity"] as? [Double], [0, 1], "Reduce Motion: no turn, a fade: \(r)")
            XCTAssertEqual(r["duration"] as? Double, 120)
        } else {
            XCTAssertEqual(r["first"] as? Double, 0); XCTAssertEqual(r["last"] as? Double, 45)
            XCTAssertGreaterThan(r["peak"] as? Double ?? 0, 45.5, "the turn spring overshoots a little: \(r)")
            XCTAssertEqual(r["duration"] as! Double, 620, accuracy: 60, "spring(response 0.35, damping 0.62) settles in about 0.62 s: \(r)")
        }
    }

    /// The frames are driven by hand, so a slow machine can't skip the middle of the fold.
    func testSequenceLinesFoldIntoACross() throws {
        let harness = page()
        let r = try json(harness, recorder + """
            const queue = []; window.requestAnimationFrame = cb => { queue.push(cb); return queue.length; };
            const run = ts => { const q = queue.splice(0); q.forEach(cb => cb(ts)); };
            const d = () => document.querySelector('#takes-dock [data-act="sequence"] .icon path')?.getAttribute('d');
            const closed = d();
            document.querySelector('#takes-dock [data-act="sequence"]').click();
            const atOnce = d();
            run(1000); const start = d();
            run(1160); const middle = d();
            run(1330); const end = d();
            document.querySelector('#takes-dock [data-act="sequence"]').click();
            run(2000); run(2400); const back = d();
            return { still: still.matches, closed, atOnce, start, middle, end, back,
              fade: calls.filter(c => c.el.closest?.('[data-act="sequence"]')).map(c => [c.frames.map(f => f.opacity ?? null), c.duration]) };
            """)
        let closed = "M5 7L19 7M5 12L19 12M5 17L14 17", open = "M6.5 6.5L17.5 17.5M6.5 17.5L17.5 6.5"
        XCTAssertEqual(r["closed"] as? String, closed, "\(r)")
        if r["still"] as? Bool == true {
            XCTAssertEqual(r["atOnce"] as? String, open, "Reduce Motion: the cross at once: \(r)")
            XCTAssertEqual((r["fade"] as? [[Any]])?.first?.last as? Double, 120, "and a 0.12 s fade: \(r)")
        } else {
            XCTAssertEqual(r["start"] as? String, closed, "\(r)")
            let middle = try XCTUnwrap(r["middle"] as? String)
            XCTAssertNotEqual(middle, closed); XCTAssertNotEqual(middle, open, "half way the lines are moving, not swapped: \(r)")
            XCTAssertEqual(r["end"] as? String, open, "after 0.32 s, the cross: \(r)")
        }
        XCTAssertEqual(r["back"] as? String, closed, "and back to three lines: \(r)")
    }

    func testTheChipsRiseFromBehindTheToolbarAndSinkBack() throws {
        let harness = page()
        let r = try json(harness, recorder + """
            const bar = document.querySelector('#takes-dock');
            document.querySelector('#takes-dock [data-act="sequence"]').click();
            const chips = bar.querySelector('.chips');
            const rise = calls.find(c => c.el === chips);
            const drop = chips.offsetHeight + 8 + bar.offsetHeight;
            calls.length = 0;
            document.querySelector('#takes-dock [data-act="sequence"]').click();
            const sink = calls.find(c => c.el.classList?.contains('chips'));
            const leaving = bar.querySelectorAll('.chips').length;
            sink?.el.getAnimations().forEach(a => a.finish());
            await new Promise(f => setTimeout(f, 20));
            return { drop, rise: rise ? [rise.frames, rise.duration, rise.easing] : null, sink: sink ? [sink.frames, sink.duration, sink.easing] : null,
              leaving, gone: bar.querySelectorAll('.chips').length };
            """)
        let drop = try XCTUnwrap(r["drop"] as? Double)
        let rise = try XCTUnwrap(r["rise"] as? [Any], "the chips animate in: \(r)")
        XCTAssertEqual(rise[1] as? Double, 200); XCTAssertEqual(rise[2] as? String, "ease-in-out")
        let up = try XCTUnwrap(rise[0] as? [[String: Any]])
        XCTAssertEqual(up.first?["opacity"] as? Double, 0); XCTAssertEqual(up.first?["transform"] as? String, "translateY(\(Int(drop))px)")
        XCTAssertEqual(up.last?["opacity"] as? Double, 1); XCTAssertEqual(up.last?["transform"] as? String, "none")
        let sink = try XCTUnwrap(r["sink"] as? [Any], "the chips animate out: \(r)")
        XCTAssertEqual(sink[1] as? Double, 200)
        let down = try XCTUnwrap(sink[0] as? [[String: Any]])
        XCTAssertEqual(down.last?["opacity"] as? Double, 0); XCTAssertEqual(down.last?["transform"] as? String, "translateY(\(Int(drop))px)")
        XCTAssertEqual(r["leaving"] as? Int, 1, "the old row stays while it sinks")
        XCTAssertEqual(r["gone"] as? Int, 0, "and goes once it has")
    }
}
