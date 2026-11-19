import WebKit
import XCTest

/// The first run as the iPhone's OnboardingView draws it after the redesign, in the Mac's centred
/// column (the Art Director's placement note): the brand mark drawn in the Scene's colours,
/// Welcome and the closing step on the colour field, Archivo headings, flat buttons and tiles
/// with corner 14. Same steps and words as before.
final class OnboardingLookTests: XCTestCase {
    private func page() -> WebViewHarness {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        harness.load("index.html", in: self, injecting: [WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        return harness
    }

    private func json(_ harness: WebViewHarness, _ body: String) throws -> [String: Any] {
        let text = try XCTUnwrap(try harness.run("return JSON.stringify(await (async () => {\n\(body)\n})());", in: self) as? String)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    private let probe = """
        const root = getComputedStyle(document.documentElement);
        const paint = (prop, value) => { const d = document.createElement('div'); d.style[prop] = value; document.body.append(d); const v = getComputedStyle(d)[prop]; d.remove(); return v; };
        const role = r => paint('color', root.getPropertyValue('--' + r));
        const mix = (r, pct) => paint('backgroundColor', `color-mix(in srgb, var(--${r}) ${pct}%, transparent)`);
        const R = {}; for (const r of ['ground', 'field', 'on-field', 'field-muted', 'text', 'muted', 'accent', 'accent-text', 'on-accent', 'card', 'line', 'outline', 'lit', 'icon-bg', 'icon-ring', 'icon-dot']) R[r] = role(r);
        const step = async (name, prep = () => {}) => { prep(); show(name); await new Promise(f => setTimeout(f, 50)); return document.querySelector('.first-run'); };
        const st = el => { if (!el) throw new Error('missing element in step ' + document.querySelector('.first-run').dataset.step + ': ' + new Error().stack.split('\\n')[1]); return getComputedStyle(el); };
        const box = el => el.getBoundingClientRect();
        """

    /// IntroBrandMark: on the ground the 72 tile (icon background, ring, dot); on the field the
    /// ring and dot alone. The wordmark 158 wide, 24 under the mark, its letters in the text
    /// colour with the i's dot lit, or on the field in the field's ink with the icon's dot.
    func testTheBrandMarkIsDrawnInTheScenesColours() throws {
        let harness = page()
        let r = try json(harness, probe + """
            const read = async name => {
              const layer = await step(name), mark = layer.querySelector('.fr-mark'), word = layer.querySelector('.fr-wordmark');
              const tile = mark?.querySelector('.tile'), ring = mark?.querySelector('.ring'), dot = mark?.querySelector('.dot');
              return { mark: mark ? [box(mark).width, box(mark).height] : null, tile: tile ? st(tile).fill : null, ring: ring ? st(ring).stroke : null, dot: dot ? st(dot).fill : null,
                wordW: word ? box(word).width : 0, gap: word && mark ? box(word).top - box(mark).bottom : -1,
                letters: word?.querySelector('.fr-letters') ? st(word.querySelector('.fr-letters')).backgroundColor : null,
                idot: word?.querySelector('.fr-dot circle') ? st(word.querySelector('.fr-dot circle')).fill : null, imgs: layer.querySelectorAll('.fr-brand img').length };
            };
            return { R, splash: await read('splash'), welcome: await read('welcome') };
            """)
        let R = try XCTUnwrap(r["R"] as? [String: String])
        let splash = try XCTUnwrap(r["splash"] as? [String: Any]), welcome = try XCTUnwrap(r["welcome"] as? [String: Any])
        XCTAssertEqual(splash["mark"] as? [Double], [72, 72], "\(splash)")
        XCTAssertEqual(splash["tile"] as? String, R["icon-bg"])
        XCTAssertEqual(splash["ring"] as? String, R["icon-ring"])
        XCTAssertEqual(splash["dot"] as? String, R["icon-dot"])
        XCTAssertEqual(splash["wordW"] as! Double, 158, accuracy: 0.6)
        XCTAssertEqual(splash["gap"] as! Double, 24, accuracy: 0.6)
        XCTAssertEqual(splash["letters"] as? String, R["text"])
        XCTAssertEqual(splash["idot"] as? String, R["lit"])
        XCTAssertEqual(splash["imgs"] as? Int, 0, "no old image files")
        XCTAssertNil(welcome["tile"] as? String, "on the field the mark is the ring and dot alone")
        XCTAssertEqual(welcome["ring"] as? String, R["icon-ring"])
        XCTAssertEqual(welcome["letters"] as? String, R["on-field"])
        XCTAssertEqual(welcome["idot"] as? String, R["icon-dot"])
    }

    /// Welcome and the closing step sit on the Scene's colour field, in its ink: the heading and
    /// the main button in on-field (the button's label in the field colour), the text in
    /// field-muted, the link in on-field and underlined. Every other step sits on the ground.
    func testWelcomeAndTheClosingStepSitOnTheColourField() throws {
        let harness = page()
        let r = try json(harness, probe + """
            const welcome = await step('welcome');
            const w = { bg: st(welcome).backgroundColor, h: st(welcome.querySelector('h2')).color, p: st(welcome.querySelector('.fr-body p')).color,
              link: st(welcome.querySelector('.fr-pill.link')).color, underline: st(welcome.querySelector('.fr-pill.link')).textDecorationLine,
              pill: st(welcome.querySelector('.fr-pill.primary')).backgroundColor, label: st(welcome.querySelector('.fr-pill.primary')).color };
            const done = await step('complete'), ps = [...done.querySelectorAll('.fr-body p')];
            const c = { bg: st(done).backgroundColor, h: st(done.querySelector('h2')).color, first: st(ps[0]).color, last: st(ps[ps.length - 1]).color };
            const storage = await step('storage');
            return { R, w, c, ground: st(storage).backgroundColor };
            """)
        let R = try XCTUnwrap(r["R"] as? [String: String])
        let w = try XCTUnwrap(r["w"] as? [String: String]), c = try XCTUnwrap(r["c"] as? [String: String])
        XCTAssertEqual(w["bg"], R["field"]); XCTAssertEqual(w["h"], R["on-field"]); XCTAssertEqual(w["p"], R["field-muted"])
        XCTAssertEqual(w["link"], R["on-field"]); XCTAssertEqual(w["underline"], "underline")
        XCTAssertEqual(w["pill"], R["on-field"]); XCTAssertEqual(w["label"], R["field"])
        XCTAssertEqual(c["bg"], R["field"]); XCTAssertEqual(c["h"], R["on-field"])
        XCTAssertEqual(c["first"], R["on-field"], "the closing step's first line is in the field's main ink")
        XCTAssertEqual(c["last"], R["field-muted"])
        XCTAssertEqual(r["ground"] as? String, R["ground"])
    }

    /// Headings: Archivo at 560 and 120 width, 28, centred, in the text colour. The opening line is
    /// a heading too, in the muted colour, never italic. Body text: the system font, light, 16, muted.
    func testHeadingsTheOpeningLineAndBodyText() throws {
        let harness = page()
        let r = try json(harness, probe + """
            const look = el => { const s = st(el); return { size: s.fontSize, weight: s.fontWeight, axes: s.fontVariationSettings, family: s.fontFamily, align: s.textAlign, style: s.fontStyle, colour: s.color }; };
            const h = look((await step('storage')).querySelector('h2'));
            const p = look((await step('localWarning')).querySelector('.fr-body p'));
            const t = look((await step('splash')).querySelector('.fr-tagline'));
            return { R, h, p, t };
            """)
        let R = try XCTUnwrap(r["R"] as? [String: String])
        let h = try XCTUnwrap(r["h"] as? [String: String]), p = try XCTUnwrap(r["p"] as? [String: String]), t = try XCTUnwrap(r["t"] as? [String: String])
        XCTAssertEqual(h["size"], "28px"); XCTAssertEqual(h["axes"], "\"wdth\" 120, \"wght\" 560"); XCTAssertTrue(h["family"]!.contains("Archivo"), h["family"]!)
        XCTAssertEqual(h["align"], "center"); XCTAssertEqual(h["colour"], R["text"])
        XCTAssertEqual(p["size"], "16px"); XCTAssertEqual(p["weight"], "300"); XCTAssertEqual(p["colour"], R["muted"])
        XCTAssertEqual(t["size"], "28px"); XCTAssertEqual(t["axes"], "\"wdth\" 120, \"wght\" 560"); XCTAssertTrue(t["family"]!.contains("Archivo"), t["family"]!)
        XCTAssertEqual(t["style"], "normal"); XCTAssertEqual(t["colour"], R["muted"])
    }

    /// DockPill: 44 high, corner 14, the system font at 15 medium. The main button in the accent
    /// with its on-accent label; the second clear with a 1 outline edge and the text colour; a link
    /// in the accent's text colour with no underline. The splash's footer is a quiet outlined plate.
    func testButtonsLinksAndTheFooter() throws {
        let harness = page()
        let r = try json(harness, probe + """
            const warn = await step('localWarning');
            const pick = el => { const s = st(el); return { h: box(el).height, radius: s.borderTopLeftRadius, size: s.fontSize, weight: s.fontWeight, fill: s.backgroundColor, label: s.color, edge: s.borderTopWidth + ' ' + s.borderTopColor, underline: s.textDecorationLine }; };
            const main = pick(warn.querySelector('.fr-pill.primary')), second = pick(warn.querySelector('.fr-pill:not(.primary):not(.link)'));
            const restored = await step('restored'), link = pick(restored.querySelector('.fr-pill.link'));
            const splash = await step('splash'), foot = pick(splash.querySelector('.fr-foot'));
            return { R, main, second, link, foot };
            """)
        let R = try XCTUnwrap(r["R"] as? [String: String])
        let main = try XCTUnwrap(r["main"] as? [String: Any]), second = try XCTUnwrap(r["second"] as? [String: Any])
        let link = try XCTUnwrap(r["link"] as? [String: Any]), foot = try XCTUnwrap(r["foot"] as? [String: Any])
        for b in [main, second] {
            XCTAssertEqual(b["h"] as! Double, 44, accuracy: 0.6, "\(b)"); XCTAssertEqual(b["radius"] as? String, "14px")
            XCTAssertEqual(b["size"] as? String, "15px"); XCTAssertEqual(b["weight"] as? String, "500")
        }
        XCTAssertEqual(main["fill"] as? String, R["accent"]); XCTAssertEqual(main["label"] as? String, R["on-accent"])
        XCTAssertEqual(second["fill"] as? String, "rgba(0, 0, 0, 0)"); XCTAssertEqual(second["label"] as? String, R["text"])
        XCTAssertEqual(second["edge"] as? String, "1px \(R["outline"]!)")
        XCTAssertEqual(link["label"] as? String, R["accent-text"]); XCTAssertEqual(link["underline"] as? String, "none")
        XCTAssertEqual(link["size"] as? String, "15px"); XCTAssertEqual(link["weight"] as? String, "500")
        XCTAssertEqual(foot["edge"] as? String, "1px \(R["outline"]!)"); XCTAssertEqual(foot["radius"] as? String, "14px")
        XCTAssertEqual(foot["size"] as? String, "15px"); XCTAssertEqual(foot["weight"] as? String, "500"); XCTAssertEqual(foot["label"] as? String, R["muted"])
    }

    /// Storage cards, the phrase's words, the confirm slots and tiles, the restore cells and the
    /// basics rows, each as the iPhone builds them: flat, corner 14, a 1 edge, no shadow.
    func testCardsWordsSlotsTilesAndCells() throws {
        let harness = page()
        let r = try json(harness, probe + """
            const words = 'anchor badge canvas dawn ember fabric glimpse harbor island jacket kettle lantern'.split(' ');
            const storage = await step('storage'), card = storage.querySelector('.fr-card'), cs = st(card);
            const out = { R, card: { fill: cs.backgroundColor, edge: cs.borderTopWidth + ' ' + cs.borderTopColor, radius: cs.borderTopLeftRadius, pad: cs.paddingTop + ' ' + cs.paddingLeft, shadow: cs.boxShadow,
              title: [st(card.querySelector('b')).fontSize, st(card.querySelector('b')).fontWeight, st(card.querySelector('b')).color],
              desc: [st(card.querySelector('span')).fontSize, st(card.querySelector('span')).fontWeight, st(card.querySelector('span')).color] } };
            const reveal = await step('reveal', () => { fr.words = words; }), chip = reveal.querySelector('.fr-words li'), ch = st(chip);
            out.chip = { fill: ch.backgroundColor, edge: ch.borderTopWidth + ' ' + ch.borderTopColor, radius: ch.borderTopLeftRadius, h: box(chip).height,
              num: [st(chip.querySelector('span')).fontSize, st(chip.querySelector('span')).color], word: [ch.fontSize, ch.fontWeight, ch.color] };
            const confirm = await step('confirm', () => { fr.words = words; newConfirm(); fr.picked = [0]; });
            const slots = [...confirm.querySelectorAll('.fr-slot')], tiles = [...confirm.querySelectorAll('.fr-tile')];
            const s0 = st(slots[0]), s1 = st(slots[1]), used = st(tiles[0]), free = st(tiles[1]);
            out.slots = { filledEdge: s0.borderTopWidth + ' ' + s0.borderTopColor + ' ' + s0.borderTopStyle, emptyEdge: s1.borderTopWidth + ' ' + s1.borderTopColor + ' ' + s1.borderTopStyle,
              emptyFill: s1.backgroundColor, radius: s1.borderTopLeftRadius, h: box(slots[1]).height, gap: box(slots[1]).left - box(slots[0]).right, value: [s0.fontSize, s0.fontWeight] };
            out.tiles = { free: [free.backgroundColor, free.borderTopWidth + ' ' + free.borderTopColor, free.fontSize, free.fontWeight, free.color], used: [used.backgroundColor, used.borderTopColor, used.color, used.opacity], h: box(tiles[1]).height };
            const err = confirm.querySelector('.fr-error'); err.hidden = false; const es = st(err);
            out.error = { size: es.fontSize, colour: es.color, fill: es.backgroundColor, edge: es.borderTopWidth + ' ' + es.borderTopColor, mixFill: mix('accent', 12), mixEdge: mix('accent', 35) };
            const restore = await step('restore'), cell = restore.querySelector('.fr-entry li'), rs = st(cell), status = st(restore.querySelector('.fr-status'));
            out.cell = { fill: rs.backgroundColor, edge: rs.borderTopWidth + ' ' + rs.borderTopColor, h: box(cell).height, num: [st(cell.querySelector('span')).fontSize, st(cell.querySelector('span')).color], status: [status.fontSize, status.fontWeight] };
            const basics = await step('basics'), row = basics.querySelector('.fr-basic');
            out.basic = { title: [st(row.querySelector('b')).fontSize, st(row.querySelector('b')).fontWeight, st(row.querySelector('b')).color], body: [st(row.querySelector('p')).fontSize, st(row.querySelector('p')).fontWeight, st(row.querySelector('p')).color] };
            return out;
            """)
        let R = try XCTUnwrap(r["R"] as? [String: String])
        let card = try XCTUnwrap(r["card"] as? [String: Any])
        XCTAssertEqual(card["fill"] as? String, R["card"]); XCTAssertEqual(card["edge"] as? String, "1px \(R["line"]!)")
        XCTAssertEqual(card["radius"] as? String, "14px"); XCTAssertEqual(card["pad"] as? String, "16px 16px"); XCTAssertEqual(card["shadow"] as? String, "none")
        XCTAssertEqual(card["title"] as? [String], ["17px", "600", R["text"]!]); XCTAssertEqual(card["desc"] as? [String], ["16px", "300", R["muted"]!])
        let chip = try XCTUnwrap(r["chip"] as? [String: Any])
        XCTAssertEqual(chip["fill"] as? String, R["card"]); XCTAssertEqual(chip["edge"] as? String, "1px \(R["line"]!)"); XCTAssertEqual(chip["radius"] as? String, "14px")
        XCTAssertGreaterThanOrEqual(chip["h"] as! Double, 40); XCTAssertEqual(chip["num"] as? [String], ["12px", R["muted"]!]); XCTAssertEqual(chip["word"] as? [String], ["15px", "600", R["text"]!])
        let slots = try XCTUnwrap(r["slots"] as? [String: Any])
        XCTAssertEqual(slots["emptyEdge"] as? String, "1.5px \(R["muted"]!) solid"); XCTAssertEqual(slots["filledEdge"] as? String, "1.5px \(R["accent-text"]!) solid")
        XCTAssertEqual(slots["emptyFill"] as? String, "rgba(0, 0, 0, 0)"); XCTAssertEqual(slots["radius"] as? String, "14px")
        XCTAssertGreaterThanOrEqual(slots["h"] as! Double, 40); XCTAssertEqual(slots["gap"] as! Double, 10, accuracy: 0.6); XCTAssertEqual(slots["value"] as? [String], ["15px", "600"])
        let tiles = try XCTUnwrap(r["tiles"] as? [String: Any])
        XCTAssertEqual(tiles["free"] as? [String], [R["card"]!, "1px \(R["line"]!)", "15px", "400", R["text"]!])
        XCTAssertEqual(tiles["used"] as? [String], [R["line"]!, "rgba(0, 0, 0, 0)", R["muted"]!, "1"], "a used tile: line fill, no edge, muted label, not faded")
        XCTAssertGreaterThanOrEqual(tiles["h"] as! Double, 40)
        let error = try XCTUnwrap(r["error"] as? [String: String])
        XCTAssertEqual(error["size"], "13px"); XCTAssertEqual(error["colour"], R["accent-text"])
        XCTAssertEqual(error["fill"], error["mixFill"]); XCTAssertEqual(error["edge"], "1px \(error["mixEdge"]!)")
        let cell = try XCTUnwrap(r["cell"] as? [String: Any])
        XCTAssertEqual(cell["fill"] as? String, R["card"]); XCTAssertEqual(cell["edge"] as? String, "1px \(R["outline"]!)")
        XCTAssertGreaterThanOrEqual(cell["h"] as! Double, 44); XCTAssertEqual(cell["num"] as? [String], ["12px", R["muted"]!]); XCTAssertEqual(cell["status"] as? [String], ["14px", "400"])
        let basic = try XCTUnwrap(r["basic"] as? [String: Any])
        XCTAssertEqual(basic["title"] as? [String], ["16px", "600", R["text"]!]); XCTAssertEqual(basic["body"] as? [String], ["15px", "300", R["muted"]!])
    }
}
