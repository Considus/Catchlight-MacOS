import AppKit

/// One entry of `catchlightMenu.model()` (ui/menu.js, D-342): a separator, a submenu, or an item.
enum MenuEntry: Decodable, Equatable {
    case separator
    case submenu(title: String, items: [MenuEntry])
    case item(MenuItemModel)

    private enum Keys: String, CodingKey { case separator, title, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if try c.decodeIfPresent(Bool.self, forKey: .separator) == true {
            self = .separator
        } else if let items = try c.decodeIfPresent([MenuEntry].self, forKey: .items) {
            self = .submenu(title: try c.decode(String.self, forKey: .title), items: items)
        } else {
            self = .item(try MenuItemModel(from: decoder))
        }
    }
}

struct MenuItemModel: Decodable, Equatable {
    let id: String
    let label: String
    let shortcut: String?
    let role: String?
    let enabled: Bool
    let checked: Bool?
}

extension Array where Element == MenuEntry {
    static func decode(json: String) throws -> [MenuEntry] {
        try JSONDecoder().decode([MenuEntry].self, from: Data(json.utf8))
    }

    /// Every item, submenus included, by id.
    var itemsByID: [String: MenuItemModel] {
        var out: [String: MenuItemModel] = [:]
        func walk(_ entries: [MenuEntry]) {
            for entry in entries {
                switch entry {
                case .item(let item): out[item.id] = item
                case .submenu(_, let items): walk(items)
                case .separator: break
                }
            }
        }
        walk(self)
        return out
    }

    /// The menu's structure without its state: what the bar would look like with every label,
    /// tick and greyed item set aside. A change here means rebuilding the bar; any other change
    /// is applied to the items already in it.
    var shape: String {
        map { entry in
            switch entry {
            case .separator: return "-"
            case .item(let item): return "\(item.id):\(item.role ?? ""):\(item.shortcut ?? "")"
            case .submenu(let title, let items): return "\(title)[\(items.shape)]"
            }
        }.joined(separator: ",")
    }
}

/// The AppKit side of each `role` in the model: the platform's own items, which AppKit runs
/// itself through the responder chain. `catchlightMenu.run` is never called for these.
enum MenuRole {
    static let selectors: [String: Selector] = [
        "cut": #selector(NSText.cut(_:)),
        "copy": #selector(NSText.copy(_:)),
        "paste": #selector(NSText.paste(_:)),
        "pasteAndMatchStyle": #selector(NSTextView.pasteAsPlainText(_:)),
        "selectAll": #selector(NSText.selectAll(_:)),
        "emoji": #selector(NSApplication.orderFrontCharacterPalette(_:)),
        "toggleFullScreen": #selector(NSWindow.toggleFullScreen(_:)),
        "minimize": #selector(NSWindow.performMiniaturize(_:)),
        "zoom": #selector(NSWindow.performZoom(_:)),
        "front": #selector(NSApplication.arrangeInFront(_:)),
        "close": #selector(NSWindow.performClose(_:)),
        "hide": #selector(NSApplication.hide(_:)),
        "hideOthers": #selector(NSApplication.hideOtherApplications(_:)),
        "unhide": #selector(NSApplication.unhideAllApplications(_:)),
        "quit": #selector(NSApplication.terminate(_:)),
    ]
    /// Not a selector: AppKit fills the Services submenu once it is `NSApp.servicesMenu`.
    static let services = "services"
}

/// Builds the menu bar from the model and keeps it current.
///
/// NSMenu validation is synchronous and `evaluateJavaScript` is not, so the page pushes its model
/// whenever it may have changed (ui/bridge.js) and validation reads the latest push. A menu that
/// opens also asks the page again and applies the answer while it is open.
final class MenuController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    /// Runs a command in the page: `catchlightMenu.run(id)`.
    var runCommand: ((String) -> Void)?
    /// Asks the page for its model now; the answer comes back through `update(with:)`.
    var refreshModel: (() -> Void)?

    private(set) var model: [MenuEntry] = []
    private var items: [String: MenuItemModel] = [:]
    private var openMenus: [NSMenu] = []
    /// The Services submenu of the last bar built, for `NSApp.servicesMenu`.
    private(set) var servicesMenu: NSMenu?

    /// The bar before the page has pushed a model: the app menu with Quit, so the app can always
    /// be quit, built by the same code as the full bar.
    static let bootstrapModel: [MenuEntry] = [
        .submenu(title: "Catchlight", items: [
            .item(MenuItemModel(id: "quit", label: "Quit Catchlight", shortcut: "Mod+Q", role: "quit", enabled: true, checked: nil)),
        ]),
    ]

    /// Applies a model from the page. Returns a new main menu when the structure changed, or nil
    /// when the existing items were brought up to date in place.
    @discardableResult
    func update(with newModel: [MenuEntry]) -> NSMenu? {
        let rebuild = model.isEmpty || newModel.shape != model.shape
        model = newModel
        items = newModel.itemsByID
        if rebuild { return build(newModel) }
        openMenus.forEach { $0.update() }   // a menu open now shows the new state at once
        return nil
    }

    /// The whole bar for `entries`.
    func build(_ entries: [MenuEntry]) -> NSMenu {
        let bar = NSMenu(title: "Main Menu")
        servicesMenu = nil
        for entry in entries {
            guard case .submenu(let title, let children) = entry else { continue }   // the bar holds menus only
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = makeMenu(title: title, children)
            bar.addItem(top)
        }
        return bar
    }

    private func makeMenu(title: String, _ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.delegate = self
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .submenu(let subtitle, let children):
                let item = NSMenuItem(title: subtitle, action: nil, keyEquivalent: "")
                item.submenu = makeMenu(title: subtitle, children)
                menu.addItem(item)
            case .item(let model):
                menu.addItem(makeItem(model))
            }
        }
        return menu
    }

    private func makeItem(_ model: MenuItemModel) -> NSMenuItem {
        let item = NSMenuItem(title: model.label, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(model.id)
        if let notation = model.shortcut, let shortcut = Shortcut(notation) {
            item.keyEquivalent = shortcut.keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
        if let role = model.role {
            if role == MenuRole.services {
                let services = NSMenu(title: model.label)
                item.submenu = services
                servicesMenu = services
            } else {
                // Target nil: the first responder that implements it runs it (the window, the
                // web view, the app), and validates it too.
                item.action = MenuRole.selectors[role]
            }
        } else {
            item.target = self
            item.action = #selector(runPageCommand(_:))
            item.state = model.checked == true ? .on : .off
        }
        return item
    }

    @objc func runPageCommand(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue else { return }
        runCommand?(id)
    }

    // MARK: Keeping labels, ticks and greyed items current

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(runPageCommand(_:)),
              let id = menuItem.identifier?.rawValue, let model = items[id] else { return false }
        apply(model, to: menuItem)
        return model.enabled
    }

    func menuWillOpen(_ menu: NSMenu) {
        openMenus.append(menu)
        refreshModel?()
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenus.removeAll { $0 === menu }
    }

    private func apply(_ model: MenuItemModel, to item: NSMenuItem) {
        if item.title != model.label { item.title = model.label }
        let state: NSControl.StateValue = model.checked == true ? .on : .off
        if item.state != state { item.state = state }
    }
}

extension MenuController {
    /// Makes `bar` the app's main menu, with the menus AppKit treats specially registered as
    /// such: Window gets the window list, Help the search field, Services its entries.
    func install(_ bar: NSMenu, in app: NSApplication = .shared) {
        app.mainMenu = bar
        app.servicesMenu = servicesMenu
        for top in bar.items {
            switch top.submenu?.title {
            case "Window": app.windowsMenu = top.submenu
            case "Help": app.helpMenu = top.submenu
            default: break
            }
        }
    }
}
