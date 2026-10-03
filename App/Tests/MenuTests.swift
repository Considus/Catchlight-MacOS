import AppKit
import WebKit
import XCTest

final class MenuTests: XCTestCase {
    private let fixture = """
    [
      {"title": "Catchlight", "items": [
        {"id": "about", "label": "About Catchlight", "shortcut": null, "shortcutLabel": "", "role": null, "enabled": true, "checked": null},
        {"separator": true},
        {"id": "services", "label": "Services", "shortcut": null, "shortcutLabel": "", "role": "services", "enabled": true, "checked": null},
        {"id": "quit", "label": "Quit Catchlight", "shortcut": "Mod+Q", "shortcutLabel": "⌘Q", "role": "quit", "enabled": true, "checked": null}
      ]},
      {"title": "View", "items": [
        {"id": "storyboard", "label": "Storyboard", "shortcut": "Mod+2", "shortcutLabel": "⌘2", "role": null, "enabled": false, "checked": true},
        {"title": "Scene", "items": [
          {"id": "sceneNight", "label": "Night", "shortcut": null, "shortcutLabel": "", "role": null, "enabled": true, "checked": false}
        ]},
        {"id": "fullScreen", "label": "Enter Full Screen", "shortcut": "Ctrl+Mod+F", "shortcutLabel": "⌃⌘F", "role": "toggleFullScreen", "enabled": true, "checked": null}
      ]},
      {"title": "Window", "items": [
        {"id": "minimize", "label": "Minimize", "shortcut": "Mod+M", "shortcutLabel": "⌘M", "role": "minimize", "enabled": true, "checked": null}
      ]}
    ]
    """

    private func item(_ bar: NSMenu, _ id: String) -> NSMenuItem? {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for i in menu.items {
                if i.identifier?.rawValue == id { return i }
                if let sub = i.submenu, let hit = find(sub) { return hit }
            }
            return nil
        }
        return find(bar)
    }

    func testTheFixtureBuildsTheBar() throws {
        let controller = MenuController()
        let bar = try XCTUnwrap(controller.update(with: .decode(json: fixture)))
        XCTAssertEqual(bar.items.map(\.title), ["Catchlight", "View", "Window"])
        XCTAssertEqual(bar.items[0].submenu?.items.count, 4)
        XCTAssertTrue(bar.items[0].submenu!.items[1].isSeparatorItem)

        let quit = try XCTUnwrap(item(bar, "quit"))
        XCTAssertEqual(quit.action, #selector(NSApplication.terminate(_:)))
        XCTAssertNil(quit.target, "a role goes to the responder chain")
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, [.command])

        let full = try XCTUnwrap(item(bar, "fullScreen"))
        XCTAssertEqual(full.action, #selector(NSWindow.toggleFullScreen(_:)))
        XCTAssertEqual(full.keyEquivalentModifierMask, [.control, .command])

        XCTAssertNotNil(item(bar, "services")?.submenu)
        XCTAssertTrue(item(bar, "services")?.submenu === controller.servicesMenu)

        // A page command: the controller runs it, with the page's state.
        let storyboard = try XCTUnwrap(item(bar, "storyboard"))
        XCTAssertTrue(storyboard.target === controller)
        XCTAssertEqual(storyboard.keyEquivalent, "2")
        XCTAssertFalse(controller.validateMenuItem(storyboard))
        XCTAssertEqual(storyboard.state, .on)
        XCTAssertEqual(item(bar, "sceneNight")?.target as? MenuController, controller, "submenus are walked")
    }

    func testAStateChangeUpdatesInPlaceAndAShapeChangeRebuilds() throws {
        let controller = MenuController()
        let bar = try XCTUnwrap(controller.update(with: .decode(json: fixture)))
        let storyboard = try XCTUnwrap(item(bar, "storyboard"))

        let changed = fixture.replacingOccurrences(of: #""Storyboard", "shortcut": "Mod+2", "shortcutLabel": "⌘2", "role": null, "enabled": false, "checked": true"#,
                                                   with: #""Storyboard!", "shortcut": "Mod+2", "shortcutLabel": "⌘2", "role": null, "enabled": true, "checked": false"#)
        XCTAssertNotEqual(changed, fixture)
        XCTAssertNil(controller.update(with: try .decode(json: changed)), "same shape: no rebuild")
        XCTAssertTrue(controller.validateMenuItem(storyboard))
        XCTAssertEqual(storyboard.title, "Storyboard!")
        XCTAssertEqual(storyboard.state, .off)

        let reshaped = fixture.replacingOccurrences(of: #""shortcut": "Mod+2""#, with: #""shortcut": "Mod+3""#)
        XCTAssertNotNil(controller.update(with: try .decode(json: reshaped)), "a new shortcut rebuilds the bar")
    }

    func testChoosingAPageItemRunsItsID() throws {
        let controller = MenuController()
        let bar = try XCTUnwrap(controller.update(with: .decode(json: fixture)))
        var ran: [String] = []
        controller.runCommand = { ran.append($0) }
        let storyboard = try XCTUnwrap(item(bar, "storyboard"))
        controller.runPageCommand(storyboard)
        XCTAssertEqual(ran, ["storyboard"])
    }

    func testTheBootstrapBarCanQuit() throws {
        let bar = try XCTUnwrap(MenuController().update(with: MenuController.bootstrapModel))
        XCTAssertEqual(item(bar, "quit")?.action, #selector(NSApplication.terminate(_:)))
    }

    /// The real model, from the real ui/menu.js in a WKWebView set up as the app sets it up:
    /// every item gets an action, every shortcut parses, every role is known, no key is shared.
    func testTheRealModelBuildsACompleteBar() throws {
        let shell = WKUserScript(source: "window.catchlightShell = Object.freeze({platform:'mac', osName:'macOS', osVersion:'15.8', model:'Mac16,1'});",
                                 injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        harness.load("index.html", in: self, injecting: [shell])
        let json = try XCTUnwrap(harness.run("return JSON.stringify({model: catchlightMenu.model(), collisions: catchlightMenu.collisions(), platform: catchlightMenu.platform});", in: self) as? String)

        struct Snapshot: Decodable { let model: [MenuEntry]; let collisions: [String]; let platform: String }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.platform, "mac")
        XCTAssertEqual(snapshot.collisions, [])

        let controller = MenuController()
        let bar = try XCTUnwrap(controller.update(with: snapshot.model))
        XCTAssertEqual(bar.items.map(\.title), ["Catchlight", "File", "Edit", "Take", "Format", "View", "Window", "Help"])

        var checked = 0
        func walk(_ entries: [MenuEntry]) {
            for entry in entries {
                switch entry {
                case .separator: break
                case .submenu(_, let items): walk(items)
                case .item(let model):
                    checked += 1
                    let built = item(bar, model.id)
                    XCTAssertNotNil(built, model.id)
                    if let role = model.role {
                        XCTAssertTrue(role == MenuRole.services || MenuRole.selectors[role] != nil, "unknown role \(role)")
                    }
                    if model.role != MenuRole.services { XCTAssertNotNil(built?.action, "\(model.id) has no action") }
                    if let shortcut = model.shortcut {
                        XCTAssertNotNil(Shortcut(shortcut), "\(model.id): \(shortcut) did not parse")
                        XCTAssertFalse(built?.keyEquivalent.isEmpty ?? true, model.id)
                    }
                }
            }
        }
        walk(snapshot.model)
        XCTAssertGreaterThan(checked, 60, "the whole model was walked")
        print("MenuTests: \(checked) items checked")
    }
}
