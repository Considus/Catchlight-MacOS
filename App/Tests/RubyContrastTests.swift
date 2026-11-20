import XCTest

/// Words on ruby and on the strips' bands reach 4.5:1 in every Scene, Dark and Light, measured on
/// the real `ui/` page (owner, 2026-11-20: "Nudge the colours", as the iPhone's
/// StripActionContrastTests and DeleteSwipeLabelTests).
///
/// Closed list of what is measured, kept in step with `fills` below:
/// - the strips' action words: an error strip, the No Privacy phrase strip, an accent strip;
/// - the overdue line on its card;
/// - every rule that fills with solid ruby and puts words on it (the stylesheet is read, so a
///   new one is caught), with the colour those words take.
final class RubyContrastTests: XCTestCase {
    private var harness: WebViewHarness!

    override func setUp() {
        harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil, privateStorage: true)
        harness.load("index.html", in: self)
    }

    override func tearDown() { harness = nil }

    /// The page's measure: sRGB contrast of an element's words over what is behind them, every
    /// translucent background composited down to the first opaque one (or the page's ground).
    private let measure = """
        const parse = s => {
          let m = s.match(/rgba?\\(([^)]+)\\)/);
          if (m) { const p = m[1].split(/[ ,\\/]+/).filter(Boolean).map(Number); return [p[0]/255, p[1]/255, p[2]/255, p.length > 3 ? p[3] : 1]; }
          m = s.match(/color\\(srgb ([^)]+)\\)/);
          if (m) { const p = m[1].split(/[ \\/]+/).filter(Boolean).map(Number); return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1]; }
          throw new Error('colour not read: ' + s);
        };
        const over = (top, bottom) => [0, 1, 2].map(i => top[3] * top[i] + (1 - top[3]) * bottom[i]).concat(1);
        const lum = c => { const ch = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2]); };
        const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
        const ground = () => parse(getComputedStyle(document.documentElement).getPropertyValue('--ground').trim().replace(/^#(..)(..)(..)$/, (_, r, g, b) => `rgb(${parseInt(r, 16)}, ${parseInt(g, 16)}, ${parseInt(b, 16)})`));
        const behind = el => {
          const layers = [];
          for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
            const c = parse(getComputedStyle(n).backgroundColor);
            if (c[3] > 0) layers.push(c);
            if (c[3] >= 1) break;
          }
          let base = layers.length && layers[layers.length - 1][3] >= 1 ? layers.pop() : ground();
          while (layers.length) base = over(layers.pop(), base);
          return base;
        };
        const contrast = el => ratio(parse(getComputedStyle(el).color), behind(el));
        """

    private let scenes = ["cobalt", "graphite", "onyx", "jade", "tanzanite"]

    func testWordsOnRubyAndOnTheStripsReach4_5To1InEveryScene() throws {
        let result = try harness.run(measure + """
            const box = document.createElement('div'); document.getElementById('strips').append(box);
            box.innerHTML = `
              <div class="strip strip-ruby"><span class="strip-text">x</span><button class="strip-act" data-w="Dismiss on an error strip">Dismiss</button></div>
              <div class="strip strip-ruby strip-phrase"><span class="strip-text">x</span><button class="strip-act" data-w="Export now on the No Privacy phrase strip">Export now</button></div>
              <div class="strip strip-add"><span class="strip-text">x</span><button class="strip-act" data-w="Review on an accent strip">Review</button></div>
              <div class="card overdue"><div class="meta" data-w="the overdue line">Today</div></div>`;
            const low = [], seen = [];
            for (const scene of \(scenes)) for (const mode of ['dark', 'light']) {
              document.documentElement.dataset.scene = scene;
              if (mode === 'light') document.documentElement.dataset.mode = 'light'; else delete document.documentElement.dataset.mode;
              for (const el of box.querySelectorAll('[data-w]')) {
                const r = contrast(el); seen.push(1);
                if (r < 4.5) low.push(`${el.dataset.w}, ${scene} ${mode}: ${r.toFixed(2)}:1`);
              }
            }
            box.remove();
            return JSON.stringify({ count: seen.length, low });
            """, in: self) as? String
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(result).utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 40, "four words, five Scenes, Dark and Light")
        XCTAssertEqual(parsed["low"] as? [String], [])
    }

    /// Every solid ruby fill in the stylesheet that carries words gives them `--on-ruby`, and
    /// `--on-ruby` on ruby reaches 4.5:1 everywhere (white on the Dark ruby doesn't: the iPhone
    /// draws on-accent there).
    func testEveryRubyFillUsesOnRubyAndItReaches4_5To1() throws {
        let result = try harness.run(measure + """
            const fills = [];
            for (const sheet of document.styleSheets) for (const rule of sheet.cssRules) {
              const s = rule.style; if (!s) continue;
              const bg = s.getPropertyValue('background') || s.getPropertyValue('background-color');
              if (/^var\\(--ruby\\)$/.test(bg.trim()) && s.getPropertyValue('color')) fills.push([rule.selectorText, s.getPropertyValue('color').trim()]);
            }
            const probe = document.createElement('div'); document.body.append(probe);
            probe.style.background = 'var(--ruby)'; probe.style.color = 'var(--on-ruby)';
            const low = [];
            for (const scene of \(scenes)) for (const mode of ['dark', 'light']) {
              document.documentElement.dataset.scene = scene;
              if (mode === 'light') document.documentElement.dataset.mode = 'light'; else delete document.documentElement.dataset.mode;
              const r = contrast(probe);
              if (r < 4.5) low.push(`${scene} ${mode}: ${r.toFixed(2)}:1`);
            }
            probe.remove();
            return JSON.stringify({ fills, low });
            """, in: self) as? String
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(result).utf8)) as? [String: Any])
        let fills = try XCTUnwrap(parsed["fills"] as? [[String]])
        XCTAssertEqual(Set(fills.map { $0[0] }), [".ctx button.danger:hover", ".alert-actions .danger", ".swipe-fill.trailing"],
                       "the ruby fills with words on them")
        for fill in fills { XCTAssertEqual(fill[1], "var(--on-ruby)", fill[0]) }
        XCTAssertEqual(parsed["low"] as? [String], [])
    }

    /// The measure can fail: black on white is 21:1, and ruby words on a solid ruby fill are 1:1.
    func testTheMeasureCanFail() throws {
        let result = try harness.run(measure + """
            const a = document.createElement('div'); a.style.cssText = 'background:#fff;color:#000'; document.body.append(a);
            const b = document.createElement('div'); b.style.cssText = 'background:var(--ruby);color:var(--ruby)'; document.body.append(b);
            const out = [contrast(a), contrast(b)].map(r => r.toFixed(2)); a.remove(); b.remove();
            return JSON.stringify(out);
            """, in: self) as? String
        XCTAssertEqual(result, #"["21.00","1.00"]"#)
    }
}
