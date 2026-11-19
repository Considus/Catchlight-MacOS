import WebKit
import XCTest

/// The iPhone redesign's look in the real `ui/`: the five colour Scenes from the iPhone's own
/// tokens, Archivo headings over the system font, one corner radius and flat surfaces
/// (brand redesign spec R1, R2, R5 and R7).
final class SceneLookTests: XCTestCase {
    private var repo: URL { WebViewHarness.repoUI.deletingLastPathComponent() }

    /// `ui/scenes.css` and `ui/scenes.js` are what the generator writes from `design/tokens.json`.
    func testTheSceneColoursAreCurrent() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("no python3 on this machine") }
        let process = Process()
        process.executableURL = python
        process.arguments = [repo.appendingPathComponent("scripts/design/gen_scene_tokens.py").path, "--check"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertEqual(text.components(separatedBy: "current: ").count - 1, 2, text)
    }

    private func page() -> WebViewHarness {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        harness.load("index.html", in: self, injecting: [WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        return harness
    }

    private func tokens() throws -> (default: String, scenes: [String: [String: Any]]) {
        let data = try Data(contentsOf: repo.appendingPathComponent("design/tokens.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (try XCTUnwrap(json["default"] as? String), try XCTUnwrap(json["scenes"] as? [String: [String: Any]]))
    }

    private func rgb(_ hex: String) -> String {
        let v = UInt32(hex.dropFirst(), radix: 16)!
        return "rgb(\(v >> 16 & 0xFF), \(v >> 8 & 0xFF), \(v & 0xFF))"
    }

    /// Every Scene in both appearances paints the page's ground and text from its own tokens, and
    /// with nothing chosen the page is the default Scene.
    func testEverySceneAndModePaintsThePageFromItsTokens() throws {
        let (fallback, scenes) = try tokens()
        XCTAssertEqual(scenes.count, 5)
        let harness = page()
        for (id, scene) in scenes {
            for mode in ["dark", "light"] {
                let palette = try XCTUnwrap(scene[mode] as? [String: String])
                let painted = try harness.run("""
                    const root = document.documentElement;
                    root.dataset.scene = '\(id)'; root.dataset.mode = '\(mode)';
                    const b = getComputedStyle(document.body);
                    return [b.backgroundColor, b.color, getComputedStyle(root).colorScheme].join(' / ');
                    """, in: self) as? String
                XCTAssertEqual(painted, "\(rgb(palette["ground"]!)) / \(rgb(palette["text"]!)) / \(mode)", "\(id) \(mode)")
            }
        }
        let unchosen = try harness.run("""
            delete document.documentElement.dataset.scene;
            return getComputedStyle(document.body).backgroundColor;
            """, in: self) as? String
        let fallbackLight = try XCTUnwrap(scenes[fallback]?["light"] as? [String: String])
        XCTAssertEqual(unchosen, rgb(fallbackLight["ground"]!), "no Scene chosen is \(fallback)")
    }

    /// The scene setting the page already keeps (System, Dark, Light) sets the appearance.
    func testTheModeFollowsTheStoredSetting() throws {
        let harness = page()
        let modes = try harness.run("""
            const out = [];
            for (const s of ['night', 'daylight']) { setScene(s); out.push(document.documentElement.dataset.mode); }
            return out.join(',');
            """, in: self) as? String
        XCTAssertEqual(modes, "dark,light")
    }

    /// Headings are Archivo, set expanded, and everything else is the system font. No other face
    /// is bundled or named.
    func testHeadingsAreArchivoAndBodyTextIsTheSystemFont() throws {
        let harness = page()
        let result = try harness.run("""
            await document.fonts.load('34px Archivo');
            const h = getComputedStyle(document.querySelector('.page-heading'));
            const faces = [...document.fonts].map(f => f.family.replace(/"/g, ''));
            const named = new Set();
            for (const sheet of document.styleSheets) for (const rule of sheet.cssRules) {
              const f = rule.style && rule.style.fontFamily;
              if (f) f.split(',').forEach(x => named.add(x.trim().replace(/"/g, '')));
            }
            return JSON.stringify({ heading: h.fontFamily.replace(/"/g, ''), variation: h.fontVariationSettings,
              body: getComputedStyle(document.body).fontFamily, faces: [...new Set(faces)], named: [...named].sort(),
              loaded: document.fonts.check('34px Archivo') });
            """, in: self) as? String
        let r = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result).utf8)) as? [String: Any])
        XCTAssertTrue((r["heading"] as? String)?.hasPrefix("Archivo") == true, result!)
        XCTAssertEqual(r["variation"] as? String, "\"wdth\" 120, \"wght\" 560", result!)   // WebKit lists the axes sorted
        XCTAssertTrue((r["body"] as? String)?.hasPrefix("-apple-system") == true, result!)
        XCTAssertEqual(r["faces"] as? [String], ["Archivo"], result!)
        XCTAssertEqual(r["loaded"] as? Bool, true, result!)
        let named = try XCTUnwrap(r["named"] as? [String])
        for gone in ["Cormorant Garamond", "DM Sans"] { XCTAssertFalse(named.contains(gone), result!) }
    }

    /// Scans every visible element: each corner is the one radius, 14, or a third of the height for
    /// an item under 42 tall, or concentric with the rounded box it sits in; nothing is a pill; and
    /// nothing casts a shadow (an inset hairline is a line, not a shadow).
    private let scan = """
        const bad = [];
        const radius = el => parseFloat(getComputedStyle(el).borderTopLeftRadius) || 0;
        for (const el of document.querySelectorAll('body *')) {
          const r = el.getBoundingClientRect();
          if (!r.width || !r.height || el.closest('.lights, svg, [hidden]')) continue;
          const cs = getComputedStyle(el);
          if (cs.visibility === 'hidden' || cs.opacity === '0') continue;   // an invisible native control laid over a row
          const name = el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\\s+/).join('.') : '');
          for (const part of cs.boxShadow === 'none' ? [] : cs.boxShadow.split(/,(?![^(]*\\))/)) {
            const lengths = part.replace(/rgba?\\([^)]*\\)/, '').match(/-?[\\d.]+px/g) || [];
            if (!/inset/.test(part) || parseFloat(lengths[2] || 0) > 0) bad.push('shadow ' + name + ': ' + part.trim());
          }
          const k = radius(el);
          if (!k) continue;
          const h = Math.min(r.width, r.height);
          if (k >= h / 2 - 0.5) { bad.push('pill ' + name + ': ' + k + ' at ' + h); continue; }
          const own = h >= 42 ? 14 : h / 3;
          if (Math.abs(k - own) <= 1) continue;
          let concentric = false;
          for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
            const pk = radius(p);
            if (!pk) continue;
            const pr = p.getBoundingClientRect();
            const inset = Math.min(r.left - pr.left, r.top - pr.top, pr.right - r.right, pr.bottom - r.bottom);
            concentric = inset >= 0 && Math.abs(k - (pk - inset)) <= 1;
            break;
          }
          if (!concentric) bad.push('corner ' + name + ': ' + k + ' at ' + h);
        }
        return bad.join('\\n');
        """

    func testEveryCornerIsTheOneRadiusAndNothingCastsAShadow() throws {
        let harness = page()
        for mode in ["dark", "light"] {
            let firstRun = try harness.run("document.documentElement.dataset.mode = '\(mode)';\n" + scan, in: self) as? String
            XCTAssertEqual(firstRun, "", "first run, \(mode)")
            let dailies = try harness.run("""
                document.querySelector('.first-run').hidden = true; document.body.classList.remove('first-running');
                """ + scan, in: self) as? String
            XCTAssertEqual(dailies, "", "the window, \(mode)")
            let settings = try harness.run("""
                openSettings(); await new Promise(r => setTimeout(r, 400));
                const found = (() => {\n\(scan)\n})();
                closeSettings(); await new Promise(r => setTimeout(r, 400));
                return found;
                """, in: self) as? String
            XCTAssertEqual(settings, "", "Settings, \(mode)")
        }
    }
}
