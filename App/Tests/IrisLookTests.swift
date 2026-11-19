import WebKit
import XCTest

/// The redesign's Iris and Focus row in the real `ui/` (brand redesign spec R8 to R13, and the
/// iPhone's IrisGeometry, IrisView and FocusRowView): a rounded square of six lights with its
/// inner shape, sitting inside its card's top-left with no beam, and the Focus row's four square
/// marks along the card's bottom edge.
final class IrisLookTests: XCTestCase {
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

    /// Lights clockwise from the top: Important, Task, Audio, Note, Image, Reminder. The inner
    /// shape is the one type, four dots for two or more, and Note only when nothing else is on.
    func testTheIrisLightsAndInnerShape() throws {
        let harness = page()
        let r = try json(harness, """
            const read = (types, obie) => {
              const box = document.createElement('div'); box.innerHTML = iris(types, obie);
              const svg = box.firstElementChild;
              return { lit: [...svg.querySelectorAll('[data-light]')].filter(p => p.classList.contains('lit')).map(p => p.dataset.light).join(','),
                lights: [...svg.querySelectorAll('[data-light]')].map(p => p.dataset.light).join(','),
                shape: svg.dataset.shape, obie: !!svg.querySelector('.obie-square'), viewBox: svg.getAttribute('viewBox'),
                outline: svg.querySelector('.outline')?.getAttribute('rx') };
            };
            return { note: read(['note']), task: read(['note', 'task']), remind: read(['note', 'remind']), two: read(['task', 'remind']),
              important: read(['note', 'important']), obie: read(['note'], true) };
            """)
        func v(_ k: String) -> [String: Any] { r[k] as? [String: Any] ?? [:] }
        XCTAssertEqual(v("note")["lights"] as? String, "important,task,audio,note,image,reminder")
        XCTAssertEqual(v("note")["viewBox"] as? String, "0 0 44 44")
        XCTAssertEqual(v("note")["lit"] as? String, "note")
        XCTAssertEqual(v("note")["shape"] as? String, "note")
        XCTAssertEqual(v("task")["shape"] as? String, "task", "Note with a Task shows the tick")
        XCTAssertEqual(v("task")["lit"] as? String, "task,note")
        XCTAssertEqual(v("remind")["shape"] as? String, "reminder", "Note with a Reminder shows the clock")
        XCTAssertEqual(v("two")["shape"] as? String, "fourDots")
        XCTAssertEqual(v("important")["shape"] as? String, "note", "Important lights its edge but is not a type")
        XCTAssertEqual(v("important")["lit"] as? String, "important,note")
        XCTAssertEqual(v("obie")["obie"] as? Bool, true)
        XCTAssertEqual(v("obie")["lit"] as? String, "important,note")
        XCTAssertEqual(v("note")["obie"] as? Bool, false)
    }

    /// Lit lights are the lit colour at 3, unlit ones the unlit colour at 1.5.
    func testLitAndUnlitLightsTakeTheirRoles() throws {
        let harness = page()
        let r = try json(harness, """
            const card = document.querySelector('#takes .card');
            const lit = card.querySelector('[data-light].lit'), off = card.querySelector('[data-light]:not(.lit)');
            const root = getComputedStyle(document.documentElement);
            const probe = c => { const d = document.createElement('div'); d.style.color = c; document.body.append(d); const v = getComputedStyle(d).color; d.remove(); return v; };
            return { litStroke: getComputedStyle(lit).stroke, litWidth: getComputedStyle(lit).strokeWidth,
              offStroke: getComputedStyle(off).stroke, offWidth: getComputedStyle(off).strokeWidth,
              lit: probe(root.getPropertyValue('--lit')), unlit: probe(root.getPropertyValue('--unlit')) };
            """)
        XCTAssertEqual(r["litStroke"] as? String, r["lit"] as? String)
        XCTAssertEqual(r["offStroke"] as? String, r["unlit"] as? String)
        XCTAssertEqual(r["litWidth"] as? String, "3px")
        XCTAssertEqual(r["offWidth"] as? String, "1.5px")
    }

    /// Each Iris sits inside its card, 14 from the top, centred under the first toolbar column,
    /// with the text starting as far right of it as it sits in. No beam, no lean, no shadow.
    func testTheIrisSitsInsideItsCardWithNoBeam() throws {
        let harness = page()
        let r = try json(harness, """
            const side = document.querySelector('#sidebar').getBoundingClientRect();
            const out = [];
            for (const card of document.querySelectorAll('#takes .card, #pinned .card')) {
              const c = card.getBoundingClientRect(), i = card.querySelector('.iris-wrap').getBoundingClientRect();
              const b = card.querySelector('.body').getBoundingClientRect();
              out.push({ top: i.top - c.top, left: i.left - c.left, right: c.right - i.right, w: i.width, h: i.height, cx: i.left + i.width / 2 - side.left,
                textLeft: b.left - c.left, minH: c.height, cardLeft: c.left - side.left, cardRight: side.right - c.right});
            }
            const tl = getComputedStyle(document.querySelector('#takes'));
            return { cards: out, width: side.width, beam: tl.backgroundImage, after: getComputedStyle(document.querySelector('#takes .card'), '::after').content,
              defs: document.querySelectorAll('#iris-sheen, #glint-bloom, .glints, .iris-shadow').length };
            """)
        let width = try XCTUnwrap(r["width"] as? Double)
        let addColumnX = 17 + (width - 34) / 8
        let inset = addColumnX - 17 - 22
        let cards = try XCTUnwrap(r["cards"] as? [[String: Double]])
        XCTAssertGreaterThan(cards.count, 2)
        for c in cards {
            XCTAssertEqual(c["top"]!, 14, accuracy: 0.6, "\(c)")
            XCTAssertEqual(c["w"]!, 44, accuracy: 0.1); XCTAssertEqual(c["h"]!, 44, accuracy: 0.1)
            XCTAssertEqual(c["cx"]!, addColumnX, accuracy: 0.6, "under the first toolbar column")
            XCTAssertEqual(c["left"]!, inset, accuracy: 0.6)
            XCTAssertEqual(c["textLeft"]!, inset * 2 + 44, accuracy: 0.6, "text as far from the Iris as the Iris from the edge")
            XCTAssertGreaterThanOrEqual(c["minH"]!, 72 - 0.5)
            XCTAssertEqual(c["cardLeft"]!, 17, accuracy: 0.6); XCTAssertEqual(c["cardRight"]!, 17, accuracy: 0.6)
        }
        XCTAssertEqual(r["beam"] as? String, "none")
        XCTAssertEqual(r["after"] as? String, "none")
        XCTAssertEqual(r["defs"] as? Int, 0)
    }

    /// The Focus row: four 44 square marks, Note, Task, Reminder, Important, 16 apart, centred on
    /// the card, their centres on the card's bottom edge once it has grown by half a mark. Off is
    /// the ground with a half-strength lit edge and a lit glyph; on is the accent with an
    /// on-accent glyph.
    func testTheFocusRowRestsAlongTheCardsBottomEdge() throws {
        let harness = page()
        let r = try json(harness, """
            const card = [...document.querySelectorAll('#takes .card')].find(c => !c.classList.contains('obie'));
            const before = card.getBoundingClientRect();
            card.querySelector('.iris-wrap').click();
            // The resting state: every animation of the open run to its end.
            document.getAnimations().forEach(a => a.finish());
            const lifted = document.querySelector('#focus-ring .lifted').getBoundingClientRect();
            const marks = [...document.querySelectorAll('#focus-ring .mark')].map(m => {
              const b = m.getBoundingClientRect(), cs = getComputedStyle(m);
              return { key: m.dataset.key, x: b.left + b.width / 2, y: b.top + b.height / 2, w: b.width, h: b.height,
                radius: cs.borderTopLeftRadius, bg: cs.backgroundColor, edge: cs.borderTopColor, glyph: cs.color, on: m.classList.contains('on') };
            });
            const root = getComputedStyle(document.documentElement);
            const probe = c => { const d = document.createElement('div'); d.style.color = c; document.body.append(d); const v = getComputedStyle(d).color; d.remove(); return v; };
            const colours = { ground: probe(root.getPropertyValue('--ground')), lit: probe(root.getPropertyValue('--lit')), accent: probe(root.getPropertyValue('--accent')),
              onAccent: probe(root.getPropertyValue('--on-accent')), halfLit: probe('color-mix(in srgb, ' + root.getPropertyValue('--lit') + ' 50%, transparent)') };
            return { marks, colours, card: { top: before.top, bottom: before.bottom, cx: before.left + before.width / 2 }, lifted: { top: lifted.top, bottom: lifted.bottom } };
            """)
        let marks = try XCTUnwrap(r["marks"] as? [[String: Any]])
        let card = try XCTUnwrap(r["card"] as? [String: Double])
        let lifted = try XCTUnwrap(r["lifted"] as? [String: Double])
        let colours = try XCTUnwrap(r["colours"] as? [String: String])
        XCTAssertEqual(marks.map { $0["key"] as? String }, ["note", "task", "remind", "important"])
        XCTAssertEqual(lifted["bottom"]! - card["bottom"]!, 22, accuracy: 0.6, "the card grows half a mark")
        let xs = marks.map { $0["x"] as! Double }
        for i in 1..<xs.count { XCTAssertEqual(xs[i] - xs[i - 1], 60, accuracy: 0.6, "16 between 44 marks") }
        XCTAssertEqual((xs.first! + xs.last!) / 2, card["cx"]!, accuracy: 0.6, "centred on the card")
        for m in marks {
            XCTAssertEqual(m["y"] as! Double, lifted["bottom"]!, accuracy: 0.6, "on the grown bottom edge")
            XCTAssertEqual(m["w"] as! Double, 44, accuracy: 0.1); XCTAssertEqual(m["h"] as! Double, 44, accuracy: 0.1)
            XCTAssertEqual(m["radius"] as? String, "14px")
            if m["on"] as? Bool == true {
                XCTAssertEqual(m["bg"] as? String, colours["accent"]); XCTAssertEqual(m["glyph"] as? String, colours["onAccent"])
            } else {
                XCTAssertEqual(m["bg"] as? String, colours["ground"]); XCTAssertEqual(m["glyph"] as? String, colours["lit"])
                XCTAssertEqual(m["edge"] as? String, colours["halfLit"])
            }
        }
        XCTAssertTrue(marks.contains { $0["on"] as? Bool == true } && marks.contains { $0["on"] as? Bool == false })
    }

    /// Closing shrinks the card from its grown size back to its resting size: no extra growth
    /// first, whether the row had finished opening or not.
    func testClosingShrinksTheCardFromItsGrownSize() throws {
        let harness = page()
        let r = try json(harness, """
            // Record each padding animation as it starts: a zero-length one (Reduce Motion) is
            // over before getAnimations() could list it.
            const started = [], animate = Element.prototype.animate;
            Element.prototype.animate = function (frames, opts) { if (frames[0]?.paddingBottom) started.push(frames); return animate.call(this, frames, opts); };
            const close = async finishOpen => {
              // Closing repaints the timeline, so find the card afresh each time.
              [...document.querySelectorAll('#takes .card')].find(c => !c.classList.contains('obie')).querySelector('.iris-wrap').click();
              if (finishOpen) document.getAnimations().forEach(a => a.finish());
              const opened = started.at(-1);
              closeFocusRing(false);
              const frames = started.at(-1);
              document.getAnimations().forEach(a => a.finish());
              // The row clears itself once the close has run.
              for (let i = 0; i < 100 && !document.querySelector('#focus-ring').hidden; i++) await new Promise(r => setTimeout(r, 50));
              return { rest: parseFloat(opened[0].paddingBottom), from: parseFloat(frames[0].paddingBottom), to: parseFloat(frames[frames.length - 1].paddingBottom) };
            };
            return { finished: await close(true), midway: await close(false) };
            """)
        for key in ["finished", "midway"] {
            let c = try XCTUnwrap(r[key] as? [String: Double], key)
            XCTAssertEqual(c["to"]!, c["rest"]!, accuracy: 0.5, "\(key): ends at the resting size")
            XCTAssertLessThanOrEqual(c["from"]!, c["rest"]! + 22.5, "\(key): starts no bigger than grown")
            if key == "finished" { XCTAssertEqual(c["from"]!, c["rest"]! + 22, accuracy: 0.5, "starts from the grown size") }
        }
    }

    /// As the Focus row starts to close from the timeline, the card and the picture of it lifted
    /// above the veil both stay grown, and the cards below stay where they were: nothing snaps
    /// before the shrink. Once it has run, the card is back to its resting size.
    func testTheCardStaysGrownAsTheCloseBegins() throws {
        let harness = page()
        let r = try json(harness, """
            const cards = () => [...document.querySelectorAll('#takes .card')];
            const card = cards().find(c => !c.classList.contains('obie') && c.nextElementSibling?.classList.contains('card'));
            const id = card.dataset.take, pad = el => parseFloat(getComputedStyle(el).paddingBottom);
            const rest = pad(card);
            card.querySelector('.iris-wrap').click();
            document.getAnimations().forEach(a => a.finish());
            const real = () => document.querySelector(`#takes .card[data-take="${id}"]`);
            const below = () => real().nextElementSibling.getBoundingClientRect().top;
            const open = { real: pad(real()), lifted: pad(document.querySelector('#focus-ring .lifted')), below: below() };
            const lifted = document.querySelector('#focus-ring .lifted');
            closeFocusRing(false);
            const closing = { real: pad(real()), lifted: pad(lifted), below: below() };
            document.getAnimations().forEach(a => a.finish());
            const closed = { real: pad(real()) };
            return { rest, open, closing, closed };
            """)
        let rest = try XCTUnwrap(r["rest"] as? Double)
        let open = try XCTUnwrap(r["open"] as? [String: Double]), closing = try XCTUnwrap(r["closing"] as? [String: Double])
        XCTAssertEqual(open["real"]!, rest + 22, accuracy: 0.5, "open: the card has grown")
        XCTAssertEqual(closing["real"]!, rest + 22, accuracy: 0.5, "closing: the card is still grown")
        XCTAssertEqual(closing["lifted"]!, rest + 22, accuracy: 0.5, "closing: the lifted picture is still grown")
        XCTAssertEqual(closing["below"]!, open["below"]!, accuracy: 0.5, "closing: the cards below haven't jumped")
        XCTAssertEqual((r["closed"] as? [String: Double])?["real"] ?? 0, rest, accuracy: 0.5, "closed: back to rest")
    }

    /// Opening the row again while it is still closing keeps the new row: the old close's tidy-up
    /// doesn't clear it.
    func testReopeningWhileClosingKeepsTheNewRow() throws {
        let harness = page()
        let r = try json(harness, """
            const iris = () => [...document.querySelectorAll('#takes .card')].find(c => !c.classList.contains('obie')).querySelector('.iris-wrap');
            iris().click(); document.getAnimations().forEach(a => a.finish());
            closeFocusRing(false);
            iris().click();
            await new Promise(r => setTimeout(r, 1200));   // past the close's tidy-up
            const ring = document.querySelector('#focus-ring');
            return { open: !!focusRing, hidden: ring.hidden, marks: ring.querySelectorAll('.mark').length, lifted: ring.querySelectorAll('.lifted').length };
            """)
        XCTAssertEqual(r["open"] as? Bool, true)
        XCTAssertEqual(r["hidden"] as? Bool, false)
        XCTAssertEqual(r["marks"] as? Int, 4)
        XCTAssertEqual(r["lifted"] as? Int, 1)
    }
}
