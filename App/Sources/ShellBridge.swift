import AppKit
import WebKit
import CatchlightCore
import os
import UniformTypeIdentifiers
import UserNotifications

/// What the Mac reports about itself, for About and Report an Issue (`shell.systemInfo`).
enum SystemInfo {
    /// `15.8`, or `15.8.1` when there is a patch number.
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The app's version as people see it (`CFBundleShortVersionString`, from `MARKETING_VERSION`).
    static var appVersion: String {
        Bundle(for: ShellBridge.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
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
/// - `setSpotlight {level}`: the Spotlight setting (`none` or `type`; the text levels clamp to `type`);
/// - `setWritingTools {level}`: the Writing Tools setting (`off`, `panel` or `inline`; anything else
///   is `off`), kept in UserDefaults. A change that differs from the stored value calls
///   `writingToolsChanged`, after the reply, so the window can rebuild its web view;
/// - `sync {trigger}`: one sync pass through `SyncService`, answered with what it did;
/// - `changeKind {item, to: 'takes'|'scripts'}`: Take ⇄ Script on the same id;
/// - `conflicts`, `resolveConflict {id, choice}`: the waiting conflicts and the user's choice. A
///   waiting item is held: `save` and `changeKind` refuse to change it (a save answers its id in
///   `held`) and sync never uploads it, until `resolveConflict {id, choice, revision}`, which
///   alone writes it, and only for the pair the page read (`revision`, from `conflicts`). A pair
///   marked `converted` has no `remote`: its other side is now a Script on another device, and
///   its choices are `new` (keep this Mac's version as a new Take) and `letGo`. An entry marked
///   `unverified` is a cloud copy that failed its check (`local` and `cloud`, either may be
///   missing). It is not held; `resolveUnverified {id, choice: 'local'|'cloud'|'skip'}` keeps
///   a side, as a fresh edit, or skips it until the next sync finds it again;
/// - `notificationStatus`: the Mac's notification permission, `enabled`, `denied` or `ask`;
/// - `enableNotifications`: asks for the permission when it was never asked, opens System
///   Settings' Notifications pane for the app when it was denied, and answers the status after;
/// - `importNotes`, `importFile`: notes from the sync folder's Import folder, or from files the
///   user picks, imported as Takes (`NoteImport`);
/// - `exportFile {name, text}`: the save panel as a sheet on the window, suggesting `name` (Markdown);
///   writes `text` as UTF-8, atomically, and answers `{saved: true}` or `{cancelled: true}`.
final class ShellBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "catchlight"
    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "bridge")

    weak var window: NSWindow?
    var onMenuModel: (([MenuEntry]) -> Void)?
    var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The notification centre `notificationStatus` and `enableNotifications` ask. Nil in tests that don't need one.
    var notifications: NotificationCentre?
    var vault: Vault?
    /// Where `setWritingTools` keeps the setting. Tests pass their own.
    var defaults: UserDefaults = .standard
    /// The sync folder. Nil in tests that don't need one, and then the page offers none.
    var syncFolder: SyncFolder?
    /// Sync (M3). Nil in tests that don't need it, and then a `sync` request is answered as skipped.
    var sync: SyncService?
    /// Set when the library could not be read at launch. The page then holds empty lists, and
    /// a save from it would be applied as the whole library, so every save is refused.
    private(set) var libraryUnreadable = false
    /// Called after the library has changed: a save, a conflict choice, an import, a sync that
    /// brought changes, or an account change. The window controller points it at the
    /// `LibraryMirror`. Trailing debounce: it runs `libraryChangeDelay` after the last change.
    var libraryChanged: () -> Void = {}
    /// Called after an erase or a replaced account, so the notifications and the Spotlight index
    /// of the old account go at once rather than after the debounce.
    var accountWiped: () -> Void = {}
    /// How long after the last change `libraryChanged` runs. The page saves on every edit.
    var libraryChangeDelay: TimeInterval = 0.5
    /// The longest a change waits, so continuous saving still refreshes this often.
    var libraryChangeMaxWait: TimeInterval = 2
    private var libraryChangeSince: Date?
    /// `setSpotlight {level}`: the page's Spotlight setting, handed to the `LibraryMirror`.
    var setSpotlight: (String) -> Void = { _ in }
    /// The stored Writing Tools setting just changed. The window rebuilds its web view, because a
    /// web view's configuration is copied when it is made.
    var writingToolsChanged: () -> Void = {}
    private var libraryChangeTimer: DispatchWorkItem?

    /// Call after any successful write to the library. A later change restarts the wait, and the
    /// last change always runs, and never later than `libraryChangeMaxWait` after the first
    /// change that is still waiting.
    func notifyLibraryChanged() {
        libraryChangeTimer?.cancel()
        let now = Date()
        let since = libraryChangeSince ?? now
        libraryChangeSince = since
        let wait = min(libraryChangeDelay, max(0, libraryChangeMaxWait - now.timeIntervalSince(since)))
        let run = DispatchWorkItem { [weak self] in
            self?.libraryChangeTimer = nil
            self?.libraryChangeSince = nil
            self?.libraryChanged()
        }
        libraryChangeTimer = run
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: run)
    }

    /// Drops a change still waiting and says whether there was one, so a quitting app can run it
    /// now instead of losing it.
    func takePendingLibraryChange() -> Bool {
        guard let run = libraryChangeTimer else { return false }
        run.cancel()
        libraryChangeTimer = nil
        libraryChangeSince = nil
        return true
    }

    /// The open panel for Import from a File. Replaced in tests, which can't drive a panel.
    var pickImportFiles: (NSWindow?, @escaping ([URL]?) -> Void) -> Void = NoteImport.pickFiles

    /// The save panel for Export Take and Export Takes: the suggested file name, then the chosen
    /// file or nil when cancelled. Replaced in tests, which can't drive a panel.
    var pickSaveURL: (NSWindow?, String, @escaping (URL?) -> Void) -> Void = ShellBridge.runSavePanel

    static func runSavePanel(in window: NSWindow?, suggestedName: String, _ done: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { done($0 == .OK ? panel.url : nil) }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// The language the page speaks: the bundle's own choice for `String(localized:)` (the first of
    /// the user's preferred languages among the `.lproj` folders the String Catalogs built), so the
    /// page and the native menus and alerts always agree. English when none is available.
    static var preferredLanguage: String { language(from: .main) }

    static func language(from bundle: Bundle) -> String {
        bundle.preferredLocalizations.first { $0 != "Base" } ?? "en"
    }

    /// The page's language. Tests set it to load the page in one.
    var language = ShellBridge.preferredLanguage

    /// Defines `window.catchlightShell` before any of the page's own scripts run, with the values
    /// baked in, so `shell.systemInfo()` stays synchronous. `folder` is the sync folder's path as
    /// the page shows it, or absent when none is chosen or its bookmark no longer opens; `language`
    /// is the one the page reads in (`ui/i18n.js`).
    static func injectedValues(folder: String? = nil, language: String = preferredLanguage) -> WKUserScript {
        var values: [String: String] = ["platform": "mac", "osName": "macOS", "osVersion": SystemInfo.osVersion, "model": SystemInfo.model, "version": SystemInfo.appVersion, "language": language]
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
                    // What waits for a conflict choice, so the page shows it read-only from the
                    // first paint, before it asks for the conflicts (Auto-Delete runs at load).
                    value["held"] = (sync?.conflicts.heldIDs ?? []).map { $0.uuidString.lowercased() }.sorted()
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

    /// Also used for the new web view a Writing Tools change makes, so the unreadable flag is
    /// cleared here: it describes the library as this install reads it, not an earlier read.
    func install(in controller: WKUserContentController) {
        libraryUnreadable = false
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
        controller.addUserScript(Self.injectedValues(folder: syncFolder?.displayPath, language: language))
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
        if ["save", "changeKind", "reload", "createAccount", "replaceAccount", "eraseEverything", "resolveConflict", "resolveUnverified", "ping"].contains(cmd), let sync, sync.isSyncing {
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
                // `stored`: the held item as the store has it, in its own list's shape, which the
                // page puts back over any change (`keepHeld`); never the page's own copy, which may
                // carry an edit the shell refused. `revision`: sent back with the choice.
                let store = vault?.library?.store
                replyHandler(try sync.conflicts.pending.map { pair -> [String: Any] in
                    let stored = try store?.take(id: pair.local.id) ?? pair.local
                    var entry: [String: Any] = ["id": pair.local.id.uuidString.lowercased(), "local": try Self.conflictSide(pair.local),
                            "stored": stored.isScript ? ScriptTranslation.page(from: stored) : try TakeTranslation.page(from: stored),
                            "storedKind": stored.isScript ? "scripts" : "takes",
                            "revision": sync.conflicts.revision(pair.local.id) ?? ""]
                    // Converted: the other side is now a Script on another device, which this Mac
                    // never reads, so the version the pair held before is not shown either.
                    if sync.conflicts.converted.contains(pair.local.id) { entry["converted"] = true }
                    else { entry["remote"] = try Self.conflictSide(pair.remote) }
                    return entry
                } + sync.conflicts.damaged.subtracting(sync.conflicts.pending.map(\.local.id)).sorted { $0.uuidString < $1.uuidString }.map { id -> [String: Any] in
                    // A conflict that doesn't open: no versions to show, but its Take is held.
                    var entry: [String: Any] = ["id": id.uuidString.lowercased(), "damaged": true]
                    if let stored = try store?.take(id: id) {
                        entry["stored"] = stored.isScript ? ScriptTranslation.page(from: stored) : try TakeTranslation.page(from: stored)
                        entry["storedKind"] = stored.isScript ? "scripts" : "takes"
                    }
                    return entry
                } + sync.conflicts.unverified.filter { !sync.conflicts.heldIDs.contains($0.id) }.map { item -> [String: Any] in
                    // Not held: nothing stored is put back, and editing it is not refused.
                    var entry: [String: Any] = ["id": item.id.uuidString.lowercased(), "unverified": true]
                    if let local = item.local { entry["local"] = try Self.conflictSide(local) }
                    if let cloud = item.cloud { entry["cloud"] = try Self.conflictSide(cloud) }
                    return entry
                }, nil)
            } catch {
                Self.log.error("conflicts did not translate: \(String(describing: error), privacy: .public)")
                replyHandler(nil, "the waiting conflicts could not be read")
            }
        case "resolveUnverified":
            guard let sync, let library = vault?.library,
                  let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let choice = body["choice"] as? String, ["local", "cloud", "skip"].contains(choice) else {
                return replyHandler(nil, "resolveUnverified needs an id and a choice of local, cloud or skip")
            }
            do {
                switch choice {
                case "local": try sync.conflicts.keepLocalUnverified(id: id, store: library.store)
                case "cloud": try sync.conflicts.keepCloudUnverified(id: id, store: library.store)
                default: sync.conflicts.skipUnverified(id: id)
                }
                if choice != "skip" { notifyLibraryChanged() }
                replyHandler(true, nil)
            } catch {
                Self.log.error("an unverified choice was not saved: \(String(describing: error), privacy: .public)")
                replyHandler(nil, (error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
        case "resolveConflict":
            guard let sync, let library = vault?.library,
                  let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let choice = (body["choice"] as? String).flatMap(ConflictQueue.Choice.init(rawValue:)),
                  let revision = body["revision"] as? String else {
                return replyHandler(nil, "resolveConflict needs an id, a choice and the revision it was made against")
            }
            do {
                // Refused if a pass replaced the pair after the page read it (the choice may have
                // waited behind that pass): the user chooses again between the versions now waiting.
                try sync.conflicts.resolve(id: id, choice: choice, store: library.store, revision: revision)
                notifyLibraryChanged()
                replyHandler(true, nil)
            } catch {
                Self.log.error("a conflict choice was not saved: \(String(describing: error), privacy: .public)")
                replyHandler(nil, (error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
        case "sync":
            guard let sync, !libraryUnreadable else { return replyHandler(["skipped": true], nil) }
            let before = (pending: sync.conflicts.pending.count, unverified: sync.conflicts.unverified.count)
            sync.run { [weak self] outcome in
                switch outcome {
                case .skipped:
                    replyHandler(["skipped": true], nil)
                case .failed(let error):
                    replyHandler(["error": SyncService.notice(for: error) as Any? ?? NSNull()], nil)
                case .finished(let r):
                    let fresh = sync.conflicts.pending.count - before.pending
                    if !r.applied.isEmpty || !r.deletedLocally.isEmpty || fresh > 0 { self?.notifyLibraryChanged() }
                    let freshScripts = fresh > 0 ? sync.conflicts.pending.suffix(fresh).filter { $0.local.isScript || $0.remote.isScript }.count : 0
                    replyHandler(["newConflictScripts": freshScripts, "applied": r.applied.count, "deleted": r.deletedLocally.count, "uploaded": r.uploaded.count,
                                  "conflicts": sync.conflicts.count,
                                  "newConflicts": max(0, sync.conflicts.pending.count - before.pending),
                                  "newUnverified": max(0, sync.conflicts.unverified.count - before.unverified),
                                  "quarantined": r.quarantined.count, "heldBack": r.heldBack.count], nil)
                }
            }
        case "importNotes", "importFile":
            guard vault?.library != nil, !libraryUnreadable else { return replyHandler(nil, "locked") }
            // Opening the folder and reading it can block on a cloud provider, so both run off the
            // main thread (as SyncService opens it); the write waits for any sync pass, as a save does.
            enum Read { case noFolder, unreadable, done(NoteImport.Outcome) }
            let parse: (@escaping () -> Read) -> Void = { [weak self] read in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = read()
                    DispatchQueue.main.async {
                        let outcome: NoteImport.Outcome
                        switch result {
                        case .noFolder: return replyHandler(["noFolder": true], nil)
                        case .unreadable: return replyHandler(["unreadable": true], nil)
                        case .done(let o): outcome = o
                        }
                        // Always answered: the page awaits it.
                        let write: () -> Void = {
                            guard let self else { return replyHandler(nil, "the window closed before the import was written") }
                            self.writeImport(outcome, replyHandler)
                        }
                        if let sync = self?.sync { sync.whenIdle(write) } else { write() }
                    }
                }
            }
            if cmd == "importNotes" {
                let folder = syncFolder
                parse {
                    guard let cloud = folder?.open() else { return .noFolder }
                    return (try? NoteImport.parseImportFolder(cloud)).map(Read.done) ?? .unreadable
                }
            } else {
                pickImportFiles(window) { urls in
                    guard let urls else { return replyHandler(["cancelled": true], nil) }
                    parse { .done(NoteImport.parse(urls)) }
                }
            }
        case "exportFile":
            guard let name = body["name"] as? String, let text = body["text"] as? String else { return replyHandler(nil, "exportFile needs a name and text") }
            pickSaveURL(window, name) { url in
                guard let url else { return replyHandler(["cancelled": true], nil) }
                // The chosen place can be a cloud folder, so the write stays off the main thread.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try Data(text.utf8).write(to: url, options: .atomic)
                        DispatchQueue.main.async { replyHandler(["saved": true], nil) }
                    } catch {
                        DispatchQueue.main.async { replyHandler(nil, error.localizedDescription) }
                    }
                }
            }
        case "notificationStatus", "enableNotifications":
            guard let notifications else { return replyHandler(nil, "no notifications in this build") }
            // The system answers off the main thread; the reply goes back on it.
            let answer = { (status: UNAuthorizationStatus) in
                DispatchQueue.main.async { replyHandler(Self.notificationAnswer(status), nil) }
            }
            notifications.authorizationStatus { [weak self] status in
                guard cmd == "enableNotifications" else { return answer(status) }
                switch status {
                case .notDetermined:
                    notifications.requestAuthorization { _ in notifications.authorizationStatus(answer) }
                case .denied:
                    DispatchQueue.main.async { self?.openNotificationSettings() }
                    answer(status)
                default:
                    answer(status)
                }
            }
        case "setSpotlight":
            guard let level = body["level"] as? String else { return replyHandler(nil, "setSpotlight needs a level") }
            setSpotlight(level)
            replyHandler(true, nil)
        case "setWritingTools":
            let level = WritingToolsSetting(body["level"] as? String)
            let changed = level != WritingToolsSetting(defaults.string(forKey: WritingToolsSetting.key))
            defaults.set(level.rawValue, forKey: WritingToolsSetting.key)
            replyHandler(true, nil)
            if changed { writingToolsChanged() }
        case "ping":
            // A round trip: messages are handled in order, so everything sent before it is done.
            replyHandler(true, nil)
        case "save", "changeKind", "reload", "validatePhrase", "createAccount", "replaceAccount", "revealPhrase", "eraseEverything":
            handleLibrary(cmd, body, replyHandler)
        default:
            replyHandler(nil, "unknown command \(cmd)")
        }
    }

    // MARK: Notifications

    /// What the page is told: `enabled` for authorized, provisional and ephemeral (as the iPhone's
    /// Settings row), `denied`, and `ask` for a permission never asked for.
    static func notificationAnswer(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: return "enabled"
        case .denied: return "denied"
        case .notDetermined: return "ask"
        @unknown default: return "ask"
        }
    }

    /// System Settings' Notifications pane for this app.
    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") { openExternally(url) }
    }

    // MARK: Import

    /// Writes what an import parsed and answers what it did. On success a short summary Take is
    /// added too, dated now, so a record of the import lands at the recent end of Dailies (as the
    /// iPhone's `announceImport`).
    private func writeImport(_ outcome: NoteImport.Outcome, _ reply: @escaping (Any?, String?) -> Void) {
        guard let library = vault?.library, !libraryUnreadable else { return reply(nil, "locked") }
        let done = library.importItems(outcome.items, holding: sync?.conflicts.heldIDs ?? [])
        if done.takes + done.scripts > 0 {
            let summary = Self.importSummary(done.takes, done.scripts)
            _ = library.importItems([Take(createdAt: Date(), modifiedAt: Date(), blocks: [.text(TextBlock(text: summary))], isNote: true)])
        }
        notifyLibraryChanged()
        Self.log.info("import: \(done.takes) Takes, \(done.scripts) Scripts, \(done.failed) failed, \(outcome.skipped) files skipped")
        reply(["takes": done.takes, "scripts": done.scripts, "failed": done.failed,
               "scanned": outcome.scanned, "skipped": outcome.skipped], nil)
    }

    /// One side of a conflict in its own kind's shape: a Take made a Script here can conflict with
    /// the Take another device edited.
    private static func conflictSide(_ take: Take) throws -> [String: Any] {
        var page = take.isScript ? ScriptTranslation.page(from: take) : try TakeTranslation.page(from: take)
        page["kind"] = take.isScript ? "script" : "take"
        page["modifiedAt"] = (take.modifiedAt.timeIntervalSince1970 * 1000).rounded()
        return page
    }

    /// The summary Take an import leaves in Dailies: "Import successful. 3 Takes added.", or "1 Take
    /// and 2 Scripts". Always English, as the iPhone writes it (`SettingsView.announceImport`): it is
    /// a stored Take that syncs, so both apps write the same words whatever the device language.
    static func importSummary(_ takes: Int, _ scripts: Int) -> String {
        let t = "\(takes) \(takes == 1 ? "Take" : "Takes")", s = "\(scripts) \(scripts == 1 ? "Script" : "Scripts")"
        return "Import successful. \(scripts == 0 ? t : takes == 0 ? s : "\(t) and \(s)") added."
    }

    // MARK: The library and the account

    private func libraryContents(_ vault: Vault) throws -> [String: Any] {
        guard let library = vault.library else { return ["takes": [Any](), "scripts": [Any]()] }
        let snapshot = try library.snapshot()
        return ["takes": snapshot.takes, "generation": snapshot.generation, "scripts": snapshot.scripts,
                "held": (sync?.conflicts.heldIDs ?? []).map { $0.uuidString.lowercased() }]
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
                // and the other version is on disk before this Mac's edit replaces it. An item
                // already waiting for that choice is not changed at all (owner, 2026-10-07).
                let report = try library.save(list, as: pageList, generation: body["generation"] as? Int,
                                              syncing: pageList == .takes || sync?.holdsScripts == true,
                                              holding: sync?.conflicts.saveRefusedIDs ?? [],
                                              keepConflict: { [sync] pair in try sync?.conflicts.keep(pair) })
                Self.log.info("\(kind ?? "", privacy: .public) saved: \(report.upserted) written, \(report.deleted) deleted, \(report.rejected.count) rejected, \(report.held.count) held for a conflict choice, \(report.conflicts.count) to the conflict screen, \(report.keptOverDelete.count) kept over a delete")
                if !report.rejected.isEmpty { Self.log.error("save kept \(report.rejected.count) items it could not read") }
                notifyLibraryChanged()
                reply(["upserted": report.upserted, "deleted": report.deleted, "rejected": report.rejected, "held": report.held,
                       "forked": report.forked.count,
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
                let changed = try library.changeKind(item, to: pageList, generation: body["generation"] as? Int,
                                                     holding: sync?.conflicts.saveRefusedIDs ?? [],
                                                     keepConflict: { [sync] pair in try sync?.conflicts.keep(pair); conflicts += 1 })
                // The item as stored, in its new list's shape: the page keeps this one, so its next
                // save carries what the page's own copy didn't (a reminder, Important).
                let shaped = pageList == .scripts ? ScriptTranslation.page(from: changed) : try TakeTranslation.page(from: changed)
                notifyLibraryChanged()
                reply(["conflicts": conflicts, "item": shaped], nil)
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
                notifyLibraryChanged()
                reply(try libraryContents(vault), nil)
            case "replaceAccount":
                // Settings ▸ Second device, as the iPhone, but nothing is erased first
                // (Vault.replaceAccount).
                guard Vault.isValid(words) else { return reply(nil, "invalid phrase") }
                try vault.replaceAccount(words: words)
                // The old cloud folder belongs to the account being replaced (AppModel, as iOS).
                syncFolder?.forget()
                libraryUnreadable = false
                accountWiped()
                notifyLibraryChanged()
                reply(try libraryContents(vault), nil)
            case "revealPhrase":
                reply(vault.phrase() as Any? ?? NSNull(), nil)
            case "eraseEverything":
                try vault.eraseEverything()
                syncFolder?.forget()   // nothing of the erased account stays connected
                accountWiped()
                notifyLibraryChanged()
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
