import AppKit
import WebKit
import CatchlightCore
import os

/// What the Mac reports about itself, for About and Report an Issue (`shell.systemInfo`).
enum SystemInfo {
    /// `15.8`, or `15.8.1` when there is a patch number.
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The hardware model identifier, such as `Mac16,1` (`sysctl hw.model`).
    static var model: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: buffer)
    }
}

/// The page's way into Swift: one `WKScriptMessageHandlerWithReply` named `catchlight`, in the
/// page content world, and a script injected at document start that hands the page the values
/// it reads synchronously. The page's half is `ui/bridge.js`.
///
/// Messages are `{cmd, ...}`:
/// - `menu {model}`: the menu model as JSON, pushed whenever it may have changed;
/// - `copy {text}`: write plain text to the clipboard;
/// - `openURL {url}`: open an http(s) or mailto address in the default app;
/// - `dragWindow`, `titlebarDoubleClick`: the page's toolbar standing in for the title bar;
/// - `save {kind: 'takes'|'scripts', list, generation}`: the page's whole list, diffed against the
///   snapshot it came from and written to the library;
/// - `validatePhrase {words}`, `createAccount {words, restored}`, `replaceAccount {words}`,
///   `revealPhrase`, `eraseEverything`: the account, through the `Vault`;
/// - `chooseFolder`, `forgetFolder`: the sync folder, through `SyncFolder` (the open panel);
/// - `sync {trigger}`: one sync pass through `SyncService`, answered with what it did;
/// - `changeKind {item, to: 'takes'|'scripts'}`: Take ⇄ Script on the same id (D-313);
/// - `conflicts`, `resolveConflict {id, choice}`: the waiting conflicts and the user's choice.
final class ShellBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "catchlight"
    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "bridge")

    weak var window: NSWindow?
    var onMenuModel: (([MenuEntry]) -> Void)?
    var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var vault: Vault?
    /// The sync folder. Nil in tests that don't need one, and then the page offers none.
    var syncFolder: SyncFolder?
    /// Sync (M3). Nil in tests that don't need it, and then a `sync` request is answered as skipped.
    var sync: SyncService?
    /// Set when the library could not be read at launch. The page then holds empty lists, and
    /// a save from it would be applied as the whole library, so every save is refused.
    private(set) var libraryUnreadable = false

    /// Defines `window.catchlightShell` before any of the page's own scripts run, with the values
    /// baked in, so `shell.systemInfo()` stays synchronous. `folder` is the sync folder's path as
    /// the page shows it, or absent when none is chosen or its bookmark no longer opens.
    static func injectedValues(folder: String? = nil) -> WKUserScript {
        var values: [String: String] = ["platform": "mac", "osName": "macOS", "osVersion": SystemInfo.osVersion, "model": SystemInfo.model]
        if let folder { values["folder"] = folder }
        let json = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let source = "window.catchlightShell = Object.freeze(\(json));"
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    /// `window.catchlightLibrary`: whether there is an account, the decrypted Takes and Scripts,
    /// and on first run a fresh phrase, so the page's synchronous reads keep working. Built once,
    /// before the page loads; the page owns the lists from then on and saves them back.
    func injectedLibrary() -> WKUserScript {
        var value: [String: Any] = ["account": false, "takes": [Any](), "scripts": [Any]()]
        if let vault {
            if let library = vault.library {
                value["account"] = true
                do {
                    let snapshot = try library.snapshot()
                    value["takes"] = snapshot.takes
                    value["generation"] = snapshot.generation
                    value["scripts"] = snapshot.scripts
                    // A damaged Script is kept on disk but can't be shown: the page says so.
                    if !library.scripts.unreadable.isEmpty { value["unreadableScripts"] = library.scripts.unreadable.count }
                } catch {
                    Self.log.fault("the library did not load: \(String(describing: error), privacy: .public)")
                    value = ["account": true, "takes": [Any](), "scripts": [Any](), "loadError": String(describing: error)]
                    libraryUnreadable = true
                }
            } else if let words = try? Vault.newPhrase() {
                value["newPhrase"] = words
            }
        }
        // Whether Scripts sync, with or without a library open yet: first run keeps this object
        // (Greptile on #55).
        value["syncScripts"] = sync?.holdsScripts ?? false
        let json = (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return WKUserScript(source: "window.catchlightLibrary = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    func install(in controller: WKUserContentController) {
        addUserScripts(to: controller)
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.name)
    }

    /// Rebuilds the document-start scripts from the library as it is NOW. Before any reload:
    /// the library script is a snapshot, and a page reloaded on a stale one would save that
    /// snapshot back over everything written since (the WebContent crash path, #43 review).
    func refreshUserScripts(in controller: WKUserContentController) {
        controller.removeAllUserScripts()
        libraryUnreadable = false
        addUserScripts(to: controller)
    }

    private func addUserScripts(to controller: WKUserContentController) {
        controller.addUserScript(Self.injectedValues(folder: syncFolder?.displayPath))
        if vault != nil { controller.addUserScript(injectedLibrary()) }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        // Only the app's own page may use the bridge.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == UIResourceSchemeHandler.scheme,
              let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            replyHandler(nil, "refused")
            return
        }
        // These must not overlap a sync pass (SyncService.whenIdle); the flush's `ping` waits too,
        // so everything the page sent before quitting is written before the app goes.
        if ["save", "changeKind", "reload", "createAccount", "replaceAccount", "eraseEverything", "resolveConflict", "ping"].contains(cmd), let sync, sync.isSyncing {
            sync.whenIdle { [weak self] in
                self?.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
            }
            return
        }
        switch cmd {
        case "menu":
            guard let json = body["model"] as? String else { return replyHandler(nil, "menu needs a model") }
            do {
                onMenuModel?(try .decode(json: json))
                replyHandler(true, nil)
            } catch {
                Self.log.error("menu model did not decode: \(String(describing: error), privacy: .public)")
                replyHandler(nil, "menu model did not decode")
            }
        case "copy":
            guard let text = body["text"] as? String else { return replyHandler(nil, "copy needs text") }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            replyHandler(pasteboard.setString(text, forType: .string), nil)
        case "openURL":
            guard let string = body["url"] as? String,
                  case .openExternally(let url) = NavigationRule.decide(URL(string: string), userFollowedLink: true) else {
                return replyHandler(nil, "not an address the browser or mail app opens")
            }
            openExternally(url)
            replyHandler(true, nil)
        case "dragWindow":
            // The mouse is still down: hand the drag to the window server as the title bar would.
            if let window, let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseDragged].contains(event.type) {
                window.performDrag(with: event)
            }
            replyHandler(true, nil)
        case "titlebarDoubleClick":
            // What a double-click on a title bar does, as set in System Settings ▸ Desktop & Dock.
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window?.performMiniaturize(nil)
            case "None": break
            default: window?.performZoom(nil)
            }
            replyHandler(true, nil)
        case "chooseFolder":
            // The open panel, as a sheet on the window. The answer is the path to show, or null
            // when the user cancels; the bookmark stays here.
            guard let syncFolder else { return replyHandler(nil, "no sync folder in this build") }
            syncFolder.choose(in: window) {
                switch $0 {
                case .success(let path): replyHandler(path ?? NSNull(), nil)
                case .failure(let error): replyHandler(nil, error.localizedDescription)
                }
            }
        case "forgetFolder":
            syncFolder?.forget()
            replyHandler(true, nil)
        case "conflicts":
            // Both versions in the page's shape, for the choice screen.
            guard let sync, vault?.library != nil else { return replyHandler([Any](), nil) }
            do {
                // Each side in its own kind's shape: a Take made a Script here can conflict with
                // the Take another device edited.
                func side(_ take: Take) throws -> [String: Any] {
                    var page = take.isScript ? ScriptTranslation.page(from: take) : try TakeTranslation.page(from: take)
                    page["kind"] = take.isScript ? "script" : "take"
                    page["modifiedAt"] = (take.modifiedAt.timeIntervalSince1970 * 1000).rounded()
                    return page
                }
                replyHandler(try sync.conflicts.pending.map { pair -> [String: Any] in
                    ["id": pair.local.id.uuidString.lowercased(), "local": try side(pair.local), "remote": try side(pair.remote)]
                }, nil)
            } catch {
                Self.log.error("conflicts did not translate: \(String(describing: error), privacy: .public)")
                replyHandler(nil, "the waiting conflicts could not be read")
            }
        case "resolveConflict":
            guard let sync, let library = vault?.library,
                  let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let choice = (body["choice"] as? String).flatMap(ConflictQueue.Choice.init(rawValue:)) else {
                return replyHandler(nil, "resolveConflict needs an id and a choice")
            }
            do {
                try sync.conflicts.resolve(id: id, choice: choice, store: library.store)
                replyHandler(true, nil)
            } catch {
                Self.log.error("a conflict choice was not saved: \(String(describing: error), privacy: .public)")
                replyHandler(nil, (error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
        case "sync":
            guard let sync, !libraryUnreadable else { return replyHandler(["skipped": true], nil) }
            let before = (pending: sync.conflicts.pending.count, unverified: sync.conflicts.unverified.count)
            sync.run { outcome in
                switch outcome {
                case .skipped:
                    replyHandler(["skipped": true], nil)
                case .failed(let error):
                    replyHandler(["error": SyncService.notice(for: error) as Any? ?? NSNull()], nil)
                case .finished(let r):
                    let fresh = sync.conflicts.pending.count - before.pending
                    let freshScripts = fresh > 0 ? sync.conflicts.pending.suffix(fresh).filter { $0.local.isScript || $0.remote.isScript }.count : 0
                    replyHandler(["newConflictScripts": freshScripts, "applied": r.applied.count, "deleted": r.deletedLocally.count, "uploaded": r.uploaded.count,
                                  "conflicts": sync.conflicts.count,
                                  "newConflicts": max(0, sync.conflicts.pending.count - before.pending),
                                  "newUnverified": max(0, sync.conflicts.unverified.count - before.unverified),
                                  "quarantined": r.quarantined.count, "heldBack": r.heldBack.count], nil)
                }
            }
        case "ping":
            // A round trip: messages are handled in order, so everything sent before it is done.
            replyHandler(true, nil)
        case "save", "changeKind", "reload", "validatePhrase", "createAccount", "replaceAccount", "revealPhrase", "eraseEverything":
            handleLibrary(cmd, body, replyHandler)
        default:
            replyHandler(nil, "unknown command \(cmd)")
        }
    }

    // MARK: The library and the account

    private func libraryContents(_ vault: Vault) throws -> [String: Any] {
        guard let library = vault.library else { return ["takes": [Any](), "scripts": [Any]()] }
        let snapshot = try library.snapshot()
        return ["takes": snapshot.takes, "generation": snapshot.generation, "scripts": snapshot.scripts]
    }

    private func handleLibrary(_ cmd: String, _ body: [String: Any], _ reply: @escaping (Any?, String?) -> Void) {
        guard let vault else { return reply(nil, "no library in this build") }
        let words = (body["words"] as? [String]) ?? []
        do {
            switch cmd {
            case "save":
                guard let library = vault.library else { return reply(nil, "locked") }
                guard !libraryUnreadable else { return reply(nil, "the library could not be read, so nothing is saved over it") }
                guard let list = body["list"] as? [[String: Any]] else { return reply(nil, "save needs a list") }
                let kind = body["kind"] as? String
                guard let pageList: Library.PageList = kind == "takes" ? .takes : kind == "scripts" ? .scripts : nil else {
                    return reply(nil, "save needs kind takes or scripts")
                }
                // An item changed here and by sync since the page's snapshot: the user chooses,
                // and the other version is on disk before this Mac's edit replaces it.
                let report = try library.save(list, as: pageList, generation: body["generation"] as? Int,
                                              syncing: pageList == .takes || sync?.holdsScripts == true,
                                              keepConflict: { [sync] pair in try sync?.conflicts.keep(pair) })
                Self.log.info("\(kind ?? "", privacy: .public) saved: \(report.upserted) written, \(report.deleted) deleted, \(report.rejected.count) rejected, \(report.conflicts.count) to the conflict screen, \(report.keptOverDelete.count) kept over a delete")
                if !report.rejected.isEmpty { Self.log.error("save kept \(report.rejected.count) items it could not read") }
                reply(["upserted": report.upserted, "deleted": report.deleted, "rejected": report.rejected,
                       "conflicts": report.conflicts.count, "keptOverDelete": report.keptOverDelete.count], nil)
            case "changeKind":
                guard let library = vault.library else { return reply(nil, "locked") }
                guard !libraryUnreadable else { return reply(nil, "the library could not be read, so nothing is saved over it") }
                let to = body["to"] as? String
                guard let item = body["item"] as? [String: Any],
                      let pageList: Library.PageList = to == "takes" ? .takes : to == "scripts" ? .scripts : nil else {
                    return reply(nil, "changeKind needs an item and takes or scripts")
                }
                var conflicts = 0
                try library.changeKind(item, to: pageList, generation: body["generation"] as? Int,
                                       keepConflict: { [sync] pair in try sync?.conflicts.keep(pair); conflicts += 1 })
                reply(["conflicts": conflicts], nil)
            case "reload":
                // The page asks for the library as it is now (after a sync, say). Everything it
                // sent before this has been handled, because messages are handled in order.
                guard let library = vault.library else { return reply(nil, "locked") }
                guard !libraryUnreadable else { return reply(nil, "the library could not be read") }
                let snapshot = try library.snapshot()
                reply(["generation": snapshot.generation, "takes": snapshot.takes, "scripts": snapshot.scripts], nil)
            case "validatePhrase":
                reply(Vault.isValid(words), nil)
            // Both answer with the library now open, so after a restore the page shows what the
            // phrase opened rather than saving its own empty list over it.
            case "createAccount":
                try vault.createAccount(words: words, restored: body["restored"] as? Bool ?? false)
                libraryUnreadable = false
                reply(try libraryContents(vault), nil)
            case "replaceAccount":
                // Settings ▸ Second device, as the iPhone, but nothing is erased first
                // (Vault.replaceAccount).
                guard Vault.isValid(words) else { return reply(nil, "invalid phrase") }
                try vault.replaceAccount(words: words)
                // The old cloud folder belongs to the account being replaced (AppModel, as iOS).
                syncFolder?.forget()
                libraryUnreadable = false
                reply(try libraryContents(vault), nil)
            case "revealPhrase":
                reply(vault.phrase() as Any? ?? NSNull(), nil)
            case "eraseEverything":
                try vault.eraseEverything()
                syncFolder?.forget()   // nothing of the erased account stays connected
                reply(true, nil)
            default:
                reply(nil, "unknown command \(cmd)")
            }
        } catch {
            Self.log.error("\(cmd, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            reply(nil, (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }
}
