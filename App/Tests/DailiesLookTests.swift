import WebKit
import XCTest

/// Dailies as the iPhone draws it after the redesign (DailiesToolbar, DailiesHeading, the Art
/// Director's Mac placement note): a flat toolbar panel at the foot of each column with each
/// icon over its name and Add's square filled, the heading on the left with today's date on the
/// right, and the month labels and scroll bars quiet.
final class DailiesLookTests: XCTestCase {
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

    private let probe = """
        const root = getComputedStyle(document.documentElement);
        const colour = c => { const d = document.createElement('div'); d.style.color = c; document.body.append(d); const v = getComputedStyle(d).color; d.remove(); return v; };
        const role = r => colour(root.getPropertyValue('--' + r));
        """

    /// Each column's toolbar is one panel 17 in from the column's sides and bottom, in the surface
    /// colour with a line edge and corner 14; each button is its icon over its name.
    func testEachColumnHasTheFlatToolbarPanel() throws {
        let harness = page()
        let r = try json(harness, probe + """
            const out = {};
            for (const [name, pane, bar] of [['dailies', '#sidebar', '#takes-dock'], ['scripts', '.scriptlist', '.scriptlist .dock']]) {
              const p = document.querySelector(pane).getBoundingClientRect(), d = document.querySelector(bar), b = d.getBoundingClientRect();
              const panel = getComputedStyle(d, '::after');
              out[name] = { left: b.left - p.left, right: p.right - b.right, bottom: p.bottom - b.bottom,
                fill: panel.backgroundColor, edge: panel.borderTopColor, radius: panel.borderTopLeftRadius,
                labels: [...d.querySelectorAll('.dock-btn')].map(x => x.querySelector('.lbl')?.textContent ?? null),
                iconAboveName: [...d.querySelectorAll('.dock-btn')].every(x => { const i = x.querySelector('svg, .icon').getBoundingClientRect(), l = x.querySelector('.lbl').getBoundingClientRect(); return i.bottom <= l.top + 0.5; }) };
            }
            const add = document.querySelector('#takes-dock [data-act="add"] .icon'), a = getComputedStyle(add);
            out.add = { w: add.getBoundingClientRect().width, h: add.getBoundingClientRect().height, fill: a.backgroundColor, radius: a.borderTopLeftRadius, glyph: a.color };
            out.colours = { surface: role('surface'), line: role('line'), accent: role('accent'), onAccent: role('on-accent') };
            return out;
            """)
        let colours = try XCTUnwrap(r["colours"] as? [String: String])
        for name in ["dailies", "scripts"] {
            let bar = try XCTUnwrap(r[name] as? [String: Any], name)
            XCTAssertEqual(bar["left"] as! Double, 17, accuracy: 0.6, name)
            XCTAssertEqual(bar["right"] as! Double, 17, accuracy: 0.6, name)
            XCTAssertEqual(bar["bottom"] as! Double, 17, accuracy: 0.6, name)
            XCTAssertEqual(bar["fill"] as? String, colours["surface"], name)
            XCTAssertEqual(bar["edge"] as? String, colours["line"], name)
            XCTAssertEqual(bar["radius"] as? String, "14px", name)
            XCTAssertEqual(bar["iconAboveName"] as? Bool, true, name)
        }
        XCTAssertEqual((r["dailies"] as? [String: Any])?["labels"] as? [String], ["Add", "Storyboard", "Sequence", "Search"])
        XCTAssertEqual((r["scripts"] as? [String: Any])?["labels"] as? [String], ["New", "Angle", "View", "Search"])
        let add = try XCTUnwrap(r["add"] as? [String: Any])
        XCTAssertEqual(add["w"] as! Double, 40, accuracy: 0.1); XCTAssertEqual(add["h"] as! Double, 40, accuracy: 0.1)
        XCTAssertEqual(add["fill"] as? String, colours["accent"])
        XCTAssertEqual(add["glyph"] as? String, colours["onAccent"])
        XCTAssertEqual(add["radius"] as? String, "13px", "a third of 40, rounded")
    }

    /// Dailies' heading sits on the left, in from the cards' edge by its share of the card's width,
    /// with today's date on the right in the muted colour at 14.
    func testTheDailiesHeadingIsOnTheLeftWithTodaysDate() throws {
        let harness = page()
        let r = try json(harness, probe + """
            const side = document.querySelector('#sidebar').getBoundingClientRect();
            const h = document.querySelector('#dailies-heading'), title = h.querySelector('.title') ?? h, date = document.querySelector('#dailies-date');
            const range = document.createRange(); range.selectNodeContents(title); const t = range.getBoundingClientRect();
            const d = date.getBoundingClientRect(), ds = getComputedStyle(date);
            return { width: side.width, titleLeft: t.left - side.left, titleText: title.textContent, dateRight: side.right - d.right,
              dateText: date.textContent, dateSize: ds.fontSize, dateColour: ds.color, muted: role('muted'), align: getComputedStyle(h).textAlign,
              sameLine: Math.abs((t.top + t.bottom) / 2 - (d.top + d.bottom) / 2) < 20 };
            """)
        let width = try XCTUnwrap(r["width"] as? Double)
        let inset = 17 + 5.16 / 220.16 * (width - 34)
        XCTAssertEqual(r["titleText"] as? String, "Dailies")
        XCTAssertEqual(r["titleLeft"] as! Double, inset, accuracy: 1.5)
        XCTAssertEqual(r["dateRight"] as! Double, inset, accuracy: 1.5)
        XCTAssertEqual(r["dateSize"] as? String, "14px")
        XCTAssertEqual(r["dateColour"] as? String, r["muted"] as? String)
        XCTAssertEqual(r["sameLine"] as? Bool, true)
        let weekday = DateFormatter(); weekday.locale = Locale(identifier: "en_GB"); weekday.dateFormat = "EEEE"
        XCTAssertTrue((r["dateText"] as? String)?.hasPrefix(weekday.string(from: Date())) == true, "\(r["dateText"] ?? "")")
    }

    /// The date reads as the iPhone writes it: the day with its English ordinal, French 1er.
    func testTheDateTakesTheIPhonesOrdinals() throws {
        let harness = page()
        let r = try json(harness, """
            const d = (y, m, day, lang) => dailiesDate(new Date(y, m - 1, day), lang);
            return { gb: d(2026, 11, 12, 'en-GB'), us: d(2026, 11, 22, 'en-US'), first: d(2026, 11, 1, 'en-GB'), thirteenth: d(2026, 11, 13, 'en-GB'),
              fr: d(2026, 11, 1, 'fr-FR'), fr2: d(2026, 11, 2, 'fr-FR'), de: d(2026, 11, 3, 'de-DE'),
              frMonth: sentenceCase('novembre 2026', 'fr-FR'), trMonth: sentenceCase('ilkbahar 2026', 'tr-TR') };
            """)
        XCTAssertEqual(r["gb"] as? String, "Thursday 12th November")
        XCTAssertEqual(r["us"] as? String, "Sunday, November 22nd")
        XCTAssertEqual(r["first"] as? String, "Sunday 1st November")
        XCTAssertEqual(r["thirteenth"] as? String, "Friday 13th November")
        XCTAssertEqual(r["fr"] as? String, "dimanche 1er novembre")
        XCTAssertEqual(r["fr2"] as? String, "lundi 2 novembre")
        XCTAssertEqual(r["de"] as? String, "Dienstag, 3. November")
        // Month labels: the first letter capitalised in the language's own way (Turkish i to İ).
        XCTAssertEqual(r["frMonth"] as? String, "Novembre 2026")
        XCTAssertEqual(r["trMonth"] as? String, "İlkbahar 2026")
    }

    /// Month labels are the iPhone's (UIKitTimeline): sentence case at 14, tracked 0.2, muted. The timelines hide their
    /// scroll bars, as the iPhone does. A selected card is tinted with the accent.
    func testMonthLabelsScrollBarsAndTheSelectedCard() throws {
        let harness = page()
        let r = try json(harness, probe + """
            const m = getComputedStyle(document.querySelector('#takes .month'));
            const sel = getComputedStyle(document.querySelector('.scriptlist .card.selected'));
            const label = document.querySelector('#takes .month .month-label') ?? document.querySelector('#takes .month');
            return { size: m.fontSize, tracking: m.letterSpacing, text: label.textContent.trim(), colour: m.color, muted: role('muted'),
              bars: [...document.querySelectorAll('.timeline')].map(t => getComputedStyle(t).scrollbarWidth),
              selectedEdge: sel.borderTopColor, accentText: role('accent-text'), selectedFill: sel.backgroundColor,
              tint: colour('color-mix(in srgb, ' + root.getPropertyValue('--accent') + ' 9%, ' + root.getPropertyValue('--card') + ')') };
            """)
        XCTAssertEqual(r["size"] as? String, "14px")
        XCTAssertEqual(r["tracking"] as? String, "0.2px")
        let text = try XCTUnwrap(r["text"] as? String)
        XCTAssertNotEqual(text, text.uppercased(), "sentence case, not capitals (Mark 2026-11-19)")
        XCTAssertEqual(String(text.prefix(1)), text.prefix(1).uppercased(), "the first letter is a capital")
        XCTAssertEqual(r["colour"] as? String, r["muted"] as? String)
        XCTAssertEqual(Set((r["bars"] as? [String]) ?? []), ["none"])
        XCTAssertEqual(r["selectedEdge"] as? String, r["accentText"] as? String)
        XCTAssertEqual(r["selectedFill"] as? String, r["tint"] as? String)
    }

    /// Only the Dailies and Scripts headings, in their heading rows, may wrap. Every other page
    /// heading (the Script area's title, Settings) stays on one line and ends in an ellipsis when
    /// too long, as before.
    func testOtherPageHeadingsStayOnOneLine() throws {
        let harness = page()
        let r = try json(harness, """
            const h = document.querySelector('#script-heading');
            h.textContent = 'A very long first line that runs far past the width of the Script area so it would wrap';
            const cs = getComputedStyle(h), lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.05;
            return { wrap: cs.whiteSpace, overflow: cs.textOverflow, lines: Math.round(h.getBoundingClientRect().height / lh),
              dailiesWrap: getComputedStyle(document.querySelector('#dailies-heading')).whiteSpace };
            """)
        XCTAssertEqual(r["wrap"] as? String, "nowrap")
        XCTAssertEqual(r["overflow"] as? String, "ellipsis")
        XCTAssertEqual(r["lines"] as? Int, 1)
        XCTAssertNotEqual(r["dailiesWrap"] as? String, "nowrap", "the Dailies heading row may wrap")
    }

    /// With the page in English, the date follows an English system's own style (US or British)
    /// and is never written in a language the page isn't showing: an unsupported system language
    /// falls back to British English, as the month labels do.
    func testTheDateIsInThePagesLanguage() throws {
        let harness = page()
        let r = try json(harness, """
            return { lang: L10N.lang, us: dailiesLocale('en-US'), gb: dailiesLocale('en-GB'), ru: dailiesLocale('ru-RU'), none: dailiesLocale('') };
            """)
        XCTAssertEqual(r["lang"] as? String, "en")
        XCTAssertEqual(r["us"] as? String, "en-US")
        XCTAssertEqual(r["gb"] as? String, "en-GB")
        XCTAssertEqual(r["ru"] as? String, "en-GB", "not Russian under an English page")
        XCTAssertEqual(r["none"] as? String, "en-GB")
    }
}
