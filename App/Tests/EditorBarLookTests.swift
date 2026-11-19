import WebKit
import XCTest

/// The editor bar and Settings as the iPhone draws them after the redesign (EditorKeyboardBar,
/// TakeEditCard, SettingsView, SettingsRow): the editor bar is the Dailies toolbar's panel with
/// four columns, each an icon over its name, the editing card 8 above it, and Settings' status
/// dot and Start over row in the iPhone's colours.
final class EditorBarLookTests: XCTestCase {
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
        const roles = { muted: role('muted'), faint: role('faint'), accentText: role('accent-text'), outline: role('outline'), text: role('text'), accent: role('accent') };
        const bar = () => [...document.querySelectorAll('#editor-bar .dock-btn')].map(b => ({
          lbl: b.querySelector('.lbl')?.textContent ?? null, label: b.getAttribute('aria-label'), colour: getComputedStyle(b).color,
          iconAboveName: !!b.querySelector('.icon') && !!b.querySelector('.lbl') && b.querySelector('.icon').getBoundingClientRect().bottom <= b.querySelector('.lbl').getBoundingClientRect().top + 0.5 }));
        """

    /// A note's bar: Cancel, Remind, Important, Mark done, each an icon over its name. Cancel is
    /// the plus turned to a cross in a 40 square outlined at 1.5; Mark done is faint, since a note
    /// can't be done; Remind and Important are muted until on, then the accent's text colour.
    func testANotesBarIsFourColumnsInTheIPhonesColours() throws {
        let harness = page()
        let r = try json(harness, probe + """
            const note = takes.find(t => !isTask(t) && !t.reminder && !t.obie && !t.isImportant);
            beginEdit(note);
            const off = bar();
            const cancel = document.querySelector('#editor-bar .dock-btn .icon'), cs = getComputedStyle(cancel), glyph = getComputedStyle(cancel.querySelector('svg'));
            draft.isImportant = true; draft.reminder = { at: new Date(Date.now() + 864e5).toISOString() }; paintBar();
            const on = bar();
            const panel = getComputedStyle(document.querySelector('#editor-bar'), '::after');
            return { off, on, roles, cancel: { w: cancel.getBoundingClientRect().width, h: cancel.getBoundingClientRect().height,
              edge: cs.borderTopColor, edgeWidth: cs.borderTopWidth, dpr: window.devicePixelRatio, radius: cs.borderTopLeftRadius, fill: cs.backgroundColor, turn: glyph.transform },
              panel: { fill: panel.backgroundColor, radius: panel.borderTopLeftRadius }, surface: role('surface') };
            """)
        let roles = try XCTUnwrap(r["roles"] as? [String: String])
        let off = try XCTUnwrap(r["off"] as? [[String: Any]])
        let on = try XCTUnwrap(r["on"] as? [[String: Any]])
        XCTAssertEqual(off.map { $0["lbl"] as? String }, ["Cancel", "Remind", "Important", "Mark done"])
        XCTAssertEqual(off.map { $0["label"] as? String }, ["Discard changes", "Add reminder", "Important", "Mark done"])
        for c in off { XCTAssertEqual(c["iconAboveName"] as? Bool, true, "\(c)") }
        XCTAssertEqual(off.map { $0["colour"] as? String }, [roles["muted"], roles["muted"], roles["muted"], roles["faint"]])
        // With a reminder the Take can be done, so Mark done wakes, muted until it is done.
        XCTAssertEqual(on.map { $0["colour"] as? String }, [roles["muted"], roles["accentText"], roles["accentText"], roles["muted"]])
        XCTAssertEqual(on[1]["label"] as? String, "Edit reminder")
        let cancel = try XCTUnwrap(r["cancel"] as? [String: Any])
        XCTAssertEqual(cancel["w"] as! Double, 40, accuracy: 0.1); XCTAssertEqual(cancel["h"] as! Double, 40, accuracy: 0.1)
        XCTAssertEqual(cancel["edge"] as? String, roles["outline"])
        // 1.5 as the iPhone draws it; WebKit snaps a border down to whole device pixels, so a 1x
        // screen (the CI Mac) shows 1 px and a 2x screen 1.5.
        let dpr = try XCTUnwrap(cancel["dpr"] as? Double)
        let snapped = (1.5 * dpr).rounded(.down) / dpr
        XCTAssertEqual(cancel["edgeWidth"] as? String, snapped == 1.5 ? "1.5px" : "\(Int(snapped))px", "at \(dpr)x")
        XCTAssertEqual(cancel["radius"] as? String, "13px", "a third of 40, rounded")
        XCTAssertEqual(cancel["fill"] as? String, "rgba(0, 0, 0, 0)")
        let turn = try XCTUnwrap(cancel["turn"] as? String)
        XCTAssertTrue(turn.hasPrefix("matrix(0.707"), "the plus turned 45 degrees: \(turn)")
        let panel = try XCTUnwrap(r["panel"] as? [String: String])
        XCTAssertEqual(panel["fill"], r["surface"] as? String)
        XCTAssertEqual(panel["radius"], "14px")
    }

    /// A task's bar puts the Shot List third; Mark done turns the accent's text colour once done.
    /// On the Obie, Important is faint and disabled.
    func testATasksBarAndTheObiesBar() throws {
        let harness = page()
        let r = try json(harness, probe + """
            beginEdit(takes.find(t => isTask(t) && canBeMarkedDone(t) && !isDone(t)));
            const task = bar();
            commitEdit();
            const done = takes.find(t => isTask(t) && isDone(t));
            let finished = null;
            if (done) { beginEdit(done); finished = bar(); commitEdit(); }
            beginEdit(takes.find(t => t.obie));
            const obie = bar(), important = document.querySelectorAll('#editor-bar .dock-btn')[2].disabled;
            return { task, finished, obie, important, roles };
            """)
        let roles = try XCTUnwrap(r["roles"] as? [String: String])
        let task = try XCTUnwrap(r["task"] as? [[String: Any]])
        XCTAssertEqual(task.map { $0["lbl"] as? String }, ["Cancel", "Remind", "Shot List", "Mark done"])
        XCTAssertEqual(task[2]["colour"] as? String, roles["muted"])
        XCTAssertEqual(task[3]["colour"] as? String, roles["muted"])
        if let finished = r["finished"] as? [[String: Any]] {
            XCTAssertEqual(finished[3]["colour"] as? String, roles["accentText"])
            XCTAssertEqual(finished[3]["label"] as? String, "Mark not done")
        }
        let obie = try XCTUnwrap(r["obie"] as? [[String: Any]])
        XCTAssertEqual(obie[2]["lbl"] as? String, "Important")
        XCTAssertEqual(obie[2]["colour"] as? String, roles["faint"])
        XCTAssertEqual(r["important"] as? Bool, true)
    }

    /// The editing card's bottom sits 8 above the bar's panel, as TakeEditCard keeps it.
    func testTheEditingCardSitsEightAboveTheBar() throws {
        let harness = page()
        let r = try json(harness, """
            beginEdit(takes.find(t => !t.obie));
            const card = document.querySelector('#take-editor').getBoundingClientRect(), panel = document.querySelector('#editor-bar').getBoundingClientRect();
            return { gap: panel.top - card.bottom };
            """)
        XCTAssertEqual(r["gap"] as! Double, 8, accuracy: 0.6)
    }

    /// The bar's labels wrap when the column narrows mid-edit; the card moves up with the taller
    /// bar and keeps its 8 rather than running under it.
    func testTheEditingCardKeepsEightWhenTheBarGrowsMidEdit() throws {
        let harness = page()
        let r = try json(harness, """
            widths.dailies = 640; applyLayout();
            beginEdit(takes.find(t => !t.obie));
            const before = document.querySelector('#editor-bar').offsetHeight;
            widths.dailies = 300; applyLayout();
            await new Promise(f => setTimeout(f, 200));
            const card = document.querySelector('#take-editor').getBoundingClientRect(), panel = document.querySelector('#editor-bar').getBoundingClientRect();
            return { before, after: panel.height, gap: panel.top - card.bottom };
            """)
        XCTAssertGreaterThan(r["after"] as! Double, r["before"] as! Double, "the narrow column wraps a label, so the bar grows: \(r)")
        XCTAssertEqual(r["gap"] as! Double, 8, accuracy: 0.6, "\(r)")
    }

    /// Notifications: Enabled is an 8 dot in the accent, Disabled an 8 ring at 1.5 in the muted
    /// colour (fill against ring, so they differ without colour). Start over is an ordinary row:
    /// its label is the text colour and its icon the accent's text colour, as on the iPhone.
    func testTheStatusDotsAndTheStartOverRow() throws {
        let harness = page()
        let r = try json(harness, probe + """
            const read = async state => {
              settings.notifications = state; openSettings(); await new Promise(r => setTimeout(r, 300));
              const dot = document.querySelector('[data-open="notifications"] .sdot');
              const b = dot.getBoundingClientRect(), c = dot.querySelector('circle'), cs = getComputedStyle(c);
              const out = { w: b.width, h: b.height, tag: dot.tagName.toLowerCase(), fill: cs.fill, stroke: cs.stroke, strokeWidth: cs.strokeWidth };
              closeSettings(); await new Promise(r => setTimeout(r, 300));
              return out;
            };
            const enabled = await read('enabled'), denied = await read('denied');
            openSettings(); await new Promise(r => setTimeout(r, 300));
            const row = document.querySelector('[data-open="start-over"]');
            const start = { label: getComputedStyle(row.querySelector('.srow-label')).color, icon: getComputedStyle(row.querySelector('.srow-icon')).color };
            return { enabled, denied, start, roles };
            """)
        let roles = try XCTUnwrap(r["roles"] as? [String: String])
        let enabled = try XCTUnwrap(r["enabled"] as? [String: Any]), denied = try XCTUnwrap(r["denied"] as? [String: Any])
        for d in [enabled, denied] {
            XCTAssertEqual(d["tag"] as? String, "svg", "a circle, drawn as one")
            XCTAssertEqual(d["w"] as! Double, 8, accuracy: 0.1); XCTAssertEqual(d["h"] as! Double, 8, accuracy: 0.1)
        }
        XCTAssertEqual(enabled["fill"] as? String, roles["accent"])
        XCTAssertEqual(enabled["stroke"] as? String, "none")
        XCTAssertEqual(denied["fill"] as? String, "none")
        XCTAssertEqual(denied["stroke"] as? String, roles["muted"])
        XCTAssertEqual(denied["strokeWidth"] as? String, "1.5px")
        let start = try XCTUnwrap(r["start"] as? [String: String])
        XCTAssertEqual(start["label"], roles["text"])
        XCTAssertEqual(start["icon"], roles["accentText"])
    }

    /// Every toolbar label in every language fits its column at the column's narrowest width
    /// (Dailies 310, Scripts 295; Mark 2026-11-19: "Raise the minimum"): no word is cut, and none
    /// runs past three lines, the iPhone label's limit (ToolbarColumn). Thai and Chinese have no spaces, so they break between
    /// characters, as on the iPhone; only their line count is checked.
    func testTranslatedToolbarLabelsFitTheNarrowestColumns() throws {
        let catalogURL = WebViewHarness.repoUI.appendingPathComponent("l10n/Localizable.xcstrings")
        let strings = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])?["strings"] as? [String: Any])
        let keys = ["Add", "Storyboard", "Sequence", "Search", "Cancel", "Remind", "Shot List", "Important", "Mark done", "New", "Angle", "View"]
        var table: [String: [String: String]] = ["en": Dictionary(uniqueKeysWithValues: keys.map { ($0, $0) })]
        for key in keys {
            let locs = try XCTUnwrap((strings[key] as? [String: Any])?["localizations"] as? [String: Any], key)
            for (lang, entry) in locs {
                let value = try XCTUnwrap(((entry as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String, "\(key) \(lang)")
                table[lang, default: [:]][key] = value
            }
        }
        XCTAssertEqual(table.count, 19, "English and the 18 other languages")
        let harness = page()
        let data = String(decoding: try JSONSerialization.data(withJSONObject: table), as: UTF8.self)
        let r = try json(harness, """
            const table = \(data);
            widths.dailies = LIMIT.dailies[0]; widths.scripts = LIMIT.scripts[0]; applyLayout();
            beginEdit(takes.find(t => !t.obie));
            const bars = { dailies: ['#takes-dock', ['Add', 'Storyboard', 'Sequence', 'Search']], editor: ['#editor-bar', ['Cancel', 'Remind', 'Shot List', 'Mark done']],
              editorNote: ['#editor-bar', ['Cancel', 'Remind', 'Important', 'Mark done']], scripts: ['.scriptlist .dock', ['New', 'Angle', 'View', 'Search']] };
            const bad = [], widthsSeen = {};
            for (const [lang, words] of Object.entries(table)) for (const [name, [sel, keys]] of Object.entries(bars)) {
              const bar = document.querySelector(sel);
              // The editor bar shows while editing; the Dailies bar is measured with it hidden.
              document.querySelector('#sidebar').classList.toggle('editing', sel === '#editor-bar');
              const labels = [...bar.querySelectorAll('.dock-btn:not(.chip) .lbl')];
              keys.forEach((k, i) => { labels[i].textContent = words[k]; });
              fitDockLabels(bar);
              labels.forEach((l, i) => {
                const room = l.parentElement.clientWidth, lh = parseFloat(getComputedStyle(l).lineHeight) || parseFloat(getComputedStyle(l).fontSize) * 1.15;
                widthsSeen[name] = room;
                if (!/^(th|zh|ja)/.test(lang)) for (const w of l.textContent.split(/\\s+/)) {
                  const span = document.createElement('span'); span.style.whiteSpace = 'nowrap'; span.textContent = w; l.append(span);
                  const ww = span.getBoundingClientRect().width; span.remove();
                  if (ww > room + 0.5) bad.push(`${lang} ${name} "${w}" ${ww.toFixed(1)} > ${room}`);
                }
                const lines = Math.round(l.getBoundingClientRect().height / lh);
                if (lines > 3) bad.push(`${lang} ${name} "${l.textContent}" ${lines} lines`);
              });
            }
            return { bad, widthsSeen };
            """)
        XCTAssertEqual(r["bad"] as? [String], [], "\(r["widthsSeen"] ?? "")")
        XCTAssertEqual(try harness.run("return JSON.stringify([LIMIT.dailies[0], LIMIT.scripts[0]]);", in: self) as? String, "[310,295]")
    }

    /// A column saved narrower than the new minimum (dragged there before it rose) opens at the
    /// minimum.
    func testASavedNarrowerColumnOpensAtTheMinimum() throws {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let saved = "localStorage.clear(); localStorage.setItem('cl.widths', JSON.stringify({ dailies: 300, scripts: 260, editor: 760 }));"
        harness.load("index.html", in: self, injecting: [WKUserScript(source: saved, injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        let r = try json(harness, "return { dailies: widths.dailies, scripts: widths.scripts, drawnD: document.querySelector('#sidebar').getBoundingClientRect().width, drawnS: document.querySelector('#scriptlist').getBoundingClientRect().width };")
        XCTAssertEqual(r["dailies"] as? Double, 310, "\(r)")
        XCTAssertEqual(r["scripts"] as? Double, 295, "\(r)")
    }

    /// Settings' group headings are sentence case, 13 medium in the muted colour, with no extra
    /// tracking (SheetType.sheetSectionLabel; Mark 2026-11-19: "Sentence case").
    func testSettingsGroupHeadingsAreSentenceCase() throws {
        let harness = page()
        let r = try json(harness, probe + """
            openSettings(); await new Promise(r => setTimeout(r, 300));
            const h = document.querySelector('.sgroup-head'), cs = getComputedStyle(h);
            return { shown: h.innerText.trim(), text: h.textContent.trim(), transform: cs.textTransform, tracking: cs.letterSpacing, size: cs.fontSize, weight: cs.fontWeight, colour: cs.color, muted: roles.muted };
            """)
        XCTAssertEqual(r["shown"] as? String, r["text"] as? String, "drawn as written, not in capitals")
        XCTAssertEqual(r["shown"] as? String, "Appearance")
        XCTAssertEqual(r["transform"] as? String, "none")
        XCTAssertEqual(r["tracking"] as? String, "normal")
        XCTAssertEqual(r["size"] as? String, "13px")
        XCTAssertEqual(r["weight"] as? String, "500")
        XCTAssertEqual(r["colour"] as? String, r["muted"] as? String)
    }
}
