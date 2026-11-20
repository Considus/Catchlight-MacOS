import AppKit
import WebKit
import CatchlightAppleStorage
import CatchlightCore
import CryptoKit
import UserNotifications
import os

/// The one window: a WKWebView showing the bundled ui/ through the `catchlight://` scheme
/// (UIResourceSchemeHandler), never `file://`, under the real title bar and traffic lights.
/// The web view is made again when the Writing Tools setting changes (`rebuildWebView`).
final class MainWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    static let startURL = URL(string: "\(UIResourceSchemeHandler.scheme)://\(UIResourceSchemeHandler.host)/index.html")!
    private static let frameAutosaveName = "CatchlightMainWindow"
    private static let fullScreenKey = "CatchlightMainWindowFullScreen"
    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "window")

    /// Replaced by `rebuildWebView` when the Writing Tools setting changes: a configuration is
    /// copied when the web view is made, so its Writing Tools behavior cannot be changed live.
    private(set) var webView: WKWebView
    let bridge = ShellBridge()
    let menuController = MenuController()
    private var libraryMirror: LibraryMirror?
    /// Set once the web-address block has compiled; every web view made afterwards carries it.
    private var addressBlock: WKContentRuleList?
    private let defaults: UserDefaults
    private let uiRoot: URL?
    private(set) lazy var takeOpener = TakeOpener { [weak self] id, reply in self?.callPage("catchlightOpenTake", id, completion: reply) }
    /// The away timer behind Settings ▸ Lock after. Nil in tests that don't lock, and then
    /// nothing locks on its own.
    private let lock: AppLock?
    /// Who is waiting on the unlock that is running; empty when none is.
    private var unlockReplies: [(String?) -> Void] = []
    /// A Take clicked while locked or relocking, opened after the next unlock (the iPhone's pending reveal).
    private var takeHeldWhileLocked: UUID?
    /// From the start of a relock until the library has closed: a click then is held too.
    private var relocking = false
    /// Posted to every app as the Mac's screen locks.
    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")

    /// Posted to every app as the Mac's screen unlocks.
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    /// Whether the app is the active one; tests say.
    var isAppActive: () -> Bool = { NSApp.isActive }
    /// Tests only: runs in a relock after the page has saved, just before the library closes.
    var beforeRelockClose: (() -> Void)?

    /// `vault` is nil only in tests that load the page without a library; the page then keeps
    /// the browser prototype's localStorage behaviour.
    /// `notifications`, `mirror`, `defaults` and `uiRoot` are the app's own except in tests, which
    /// have no notification centre to ask, and serve the repo's `ui/` rather than a bundle's.
    /// `lock` is the app's away timer; tests pass one with their own clock.
    init(vault: Vault?,
         notifications: NotificationCentre = UNUserNotificationCenter.current(),
         mirror: LibraryMirror? = nil,
         defaults: UserDefaults = .standard,
         uiRoot: URL? = nil,
         lock: AppLock? = nil) {
        self.defaults = defaults
        self.uiRoot = uiRoot
        self.lock = lock
        bridge.defaults = defaults
        bridge.vault = vault
        var syncDefaults = UserDefaults.standard
        #if DEBUG
        syncDefaults = DebugLaunch.syncDefaults() ?? syncDefaults
        #endif
        bridge.syncFolder = SyncFolder(defaults: syncDefaults)
        #if DEBUG
        DebugLaunch.useFolder(bridge.syncFolder)   // before the web view, which reads the folder once at load
        #endif
        if let vault, let folder = bridge.syncFolder { bridge.sync = SyncService(vault: vault, folder: folder, defaults: syncDefaults) }
        // Reminders and Spotlight follow the library; one pass now, with the library open.
        bridge.notifications = notifications
        let mirror = mirror ?? LibraryMirror(reminders: MacReminders(centre: notifications), spotlight: CoreSpotlightIndexer())
        libraryMirror = mirror
        bridge.setSpotlight = { [weak mirror] in mirror?.setExposure($0) }
        bridge.accountWiped = { [weak mirror] in mirror?.accountWiped() }
        if vault != nil { bridge.notifyLibraryChanged() }
        webView = Self.makeWebView(bridge: bridge, addressBlock: nil, defaults: defaults, uiRoot: uiRoot)

        // The page's toolbar is the title bar: the content runs under it, and the page leaves
        // room for the real traffic lights (`.in-shell` in app.css).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Catchlight"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 900, height: 600)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        super.init(window: window)
        window.delegate = self
        adopt(webView)
        bridge.window = window
        bridge.writingToolsChanged = { [weak self] in self?.rebuildWebView() }
        bridge.libraryChanged = { [weak self] in self?.mirrorLibrary(inBackground: true) }
        bridge.unlock = { [weak self] reply in self?.unlock(reply) }
        wireMenu()
        observeLockTriggers()
        #if DEBUG
        DebugLaunch.attach(to: self)
        #endif

        // Nothing loads until the web-address block is in place.
        WebAddressBlock.compile { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let list):
                self.addressBlock = list
                self.webView.configuration.userContentController.add(list)
                self.webView.load(URLRequest(url: Self.startURL))
            case .failure(let error):
                Self.log.fault("web-address block did not compile; the page is not loaded: \(String(describing: error), privacy: .public)")
                self.showErrorPage()
            }
        }
    }

    /// A web view as the app sets one up: the bundled `ui/` through its scheme, the bridge
    /// installed, and Writing Tools as the setting says (off when it was never set).
    private static func makeWebView(bridge: ShellBridge, addressBlock: WKContentRuleList?, defaults: UserDefaults, uiRoot: URL?) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(uiRoot.map { UIResourceSchemeHandler(root: $0) } ?? UIResourceSchemeHandler(), forURLScheme: UIResourceSchemeHandler.scheme)
        // Offline: no Safe Browsing lookups either.
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        if #available(macOS 15.0, *) {
            configuration.writingToolsBehavior = WritingToolsSetting(defaults.string(forKey: WritingToolsSetting.key)).behavior
        }
        bridge.install(in: configuration.userContentController)
        if let addressBlock { configuration.userContentController.add(addressBlock) }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true   // Safari ▸ Develop, debug builds only
        }
        #endif
        return webView
    }

    /// Makes a new web view, now that the Writing Tools setting has changed, and loads the page in it.
    /// Reading `webView.configuration` gives a copy, and the web view takes its Writing Tools
    /// behavior from its configuration when it is made (WKWebViewConfiguration.h documents no
    /// way to change it afterwards), so a new web view is the only way. It goes through the
    /// path the app already uses to reload the page (`catchlightBridge.flush`, then the
    /// bridge's scripts rebuilt from the library as it is now), after the page has saved what
    /// is on screen, so nothing typed is lost.
    private func rebuildWebView() {
        flushPage { [weak self] in
            guard let self, let window = self.window else { return }
            let old = self.webView
            old.navigationDelegate = nil
            old.uiDelegate = nil
            old.stopLoading()
            old.configuration.userContentController.removeScriptMessageHandler(forName: ShellBridge.name, contentWorld: .page)
            self.takeOpener.pageDidUnload()
            let made = Self.makeWebView(bridge: self.bridge, addressBlock: self.addressBlock, defaults: self.defaults, uiRoot: self.uiRoot)
            self.webView = made
            self.adopt(made)
            window.contentView = made
            window.makeFirstResponder(made)
            made.load(URLRequest(url: Self.startURL))
        }
    }

    private func adopt(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if UserDefaults.standard.bool(forKey: Self.fullScreenKey), let window, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    /// A click on a Take's notification or Spotlight result: the window comes forward and the page
    /// opens the Take (`catchlightOpenTake`, ui/takes.js), once it has loaded.
    func openTake(_ id: UUID) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if case .locked = bridge.vault?.state {
            takeHeldWhileLocked = id
            return
        }
        if relocking {
            takeHeldWhileLocked = id
            return
        }
        takeOpener.open(id)
    }

    // MARK: Lock

    // As the iPhone's RootView: going away starts the timer; coming back relocks after Settings ▸
    // Lock after and then asks for the user at once if the library is locked; the screen locking
    // relocks straight away (AppModel's device-lock relock).
    private func observeLockTriggers() {
        guard lock != nil else { return }
        let centre = NotificationCenter.default
        centre.addObserver(self, selector: #selector(appWentAway(_:)), name: NSApplication.didResignActiveNotification, object: nil)
        centre.addObserver(self, selector: #selector(appCameBack(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenDidLock(_:)), name: Self.screenLockedNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenDidUnlock(_:)), name: Self.screenUnlockedNotification, object: nil)
    }

    /// The login prompt makes the app inactive while it is up: that is not time away.
    @objc private func appWentAway(_ notification: Notification) {
        guard unlockReplies.isEmpty else { return }
        lock?.noteWentAway()
    }

    @objc private func appCameBack(_ notification: Notification) {
        guard let lock else { return }
        if lock.shouldLockOnReturn() {
            relock { [weak self] in self?.unlockOnReturn() }
        } else {
            unlockOnReturn()
        }
    }

    @objc func screenDidLock(_ notification: Notification) {
        relock()
    }

    /// The Mac's screen unlocking with Catchlight in front: ask for the user as the iPhone does when
    /// it comes back, unless the library is open, a failure is showing or an unlock is running.
    @objc func screenDidUnlock(_ notification: Notification) {
        guard isAppActive() else { return }
        unlockOnReturn()
    }

    /// The iPhone asks on return whenever the library is locked, unless a failure is showing
    /// (then Try Again asks) or an unlock is already running. The lock screen shows it is asking,
    /// as the iPhone's does (a page still loading is told once it has, in `didFinish`). A failure
    /// reloads the page so it opens on Try Again; a success has reloaded it already.
    private func unlockOnReturn() {
        guard case .locked = bridge.vault?.state, bridge.lockFailure == nil, unlockReplies.isEmpty else { return }
        showUnlocking()
        unlock { [weak self] failure in
            if failure != nil { self?.reloadPage() }
        }
    }

    /// Closes the library, as the iPhone's `relock`: the page saves what is open first, while the
    /// library still is, then the library closes and the page loads again as the lock screen.
    /// A sync pass started after the save (the old page can still start one) is stopped and waited
    /// for, so none runs on with the closed library's keys. A Take clicked on the way, or waiting
    /// for the page to load, is held for the next unlock. Does nothing unless the library is open.
    func relock(completion: (() -> Void)? = nil) {
        guard bridge.vault?.library != nil else { completion?(); return }
        relocking = true
        flushPage { [weak self] in
            guard let self, let vault = self.bridge.vault else { completion?(); return }
            let close = { [weak self] in
                guard let self else { completion?(); return }
                self.beforeRelockClose?()
                vault.lock()
                self.bridge.sync?.forgetLibrary()
                self.relocking = false
                self.bridge.lockFailure = nil
                // A click held during the relock is newer than one still waiting for the page.
                let waiting = self.takeOpener.withdrawWaiting()
                if self.takeHeldWhileLocked == nil { self.takeHeldWhileLocked = waiting }
                self.reloadPage()
                completion?()
            }
            // The page has saved: from here it takes no input, so nothing typed is lost to the
            // closing library, and no save is refused as "locked" (`catchlightRelocking`, ui/lock.js).
            self.webView.evaluateJavaScript("window.catchlightRelocking?.()") { _, _ in
                if let sync = self.bridge.sync {
                    sync.cancel()
                    sync.whenIdle(close)
                } else {
                    close()
                }
            }
        }
    }

    /// The lock screen's Unlock and Try Again, and the ask on return: opens the library and
    /// answers nil, else `"cancelled"` for any key error (a cancelled or refused prompt, or a key
    /// gone: the iPhone says "Couldn't unlock" for all of them, and the vault stays locked rather
    /// than offer first run) or `"unopenable"` when the key reads but the library won't open.
    /// Only the prompt (`Vault.readKey`, which blocks) runs off the main thread, as the iPhone's
    /// runs off the main actor; the library opens on main, where the vault is only ever changed.
    /// A second ask while one runs waits for the same answer.
    func unlock(_ reply: @escaping (String?) -> Void) {
        guard let vault = bridge.vault, case .locked = vault.state else { return reply(nil) }
        unlockReplies.append(reply)
        guard unlockReplies.count == 1 else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let key = Result { try vault.readKey() }
            DispatchQueue.main.async { self?.finishUnlock(vault, key) }
        }
    }

    private func finishUnlock(_ vault: Vault, _ key: Result<SymmetricKey, Error>) {
        let failure: String?
        do {
            try vault.open(with: key.get())
            failure = nil
        } catch {
            Self.log.error("start failed: \(String(describing: error), privacy: .public)")
            failure = error is KeychainError ? "cancelled" : "unopenable"
        }
        bridge.lockFailure = failure
        if failure == nil {
            lock?.forgetWentAway()
            bridge.justUnlocked = true
            reloadPage()
            mirrorLibrary(inBackground: true)
            if let id = takeHeldWhileLocked {
                takeHeldWhileLocked = nil
                takeOpener.open(id)
            }
        }
        let replies = unlockReplies
        unlockReplies = []
        replies.forEach { $0(failure) }
    }

    /// Puts the lock screen into its unlocking state (`catchlightLockUnlocking`, ui/lock.js).
    private func showUnlocking() {
        webView.evaluateJavaScript("window.catchlightLockUnlocking?.()")
    }

    /// Loads the page again on the library as it is now (locked or open): the scripts are
    /// rebuilt first, and a Take waiting to open waits for the new page.
    private func reloadPage() {
        takeOpener.pageDidUnload()
        bridge.refreshUserScripts(in: webView.configuration.userContentController)
        webView.reload()
    }

    // MARK: Menu

    private func wireMenu() {
        menuController.install(menuController.update(with: MenuController.bootstrapModel)!)
        bridge.onMenuModel = { [weak self] model in
            guard let self, let bar = self.menuController.update(with: model) else { return }
            self.menuController.install(bar)
        }
        menuController.runCommand = { [weak self] id in
            self?.callPage("catchlightMenu.run", id) { result in
                if result as? Bool != true { Self.log.info("menu command \(id, privacy: .public) did not run (unavailable now)") }
            }
        }
        // Ask for the model as a menu opens; the page answers through the bridge.
        menuController.refreshModel = { [weak self] in
            self?.webView.evaluateJavaScript("window.catchlightBridge?.pushMenu(true)")
        }
    }

    // MARK: Saving on the way out

    private var closeAfterFlush = false

    /// Asks the page to save what is on screen (`catchlightBridge.flush()` in `ui/bridge.js`):
    /// a Take open in the editor, a Script edit still waiting on its debounce. `completion` runs
    /// once, when the page answers or after `timeout`, so a page that never answers can't stop
    /// the app quitting. A save is milliseconds; the timeout is for a hung page, and is logged.
    func flushPage(timeout: TimeInterval = 10, completion: @escaping () -> Void) {
        // A running sync stops at its next Take, so the page's last save (which waits for a pass,
        // SyncService.whenIdle) isn't kept waiting behind it, for a closing window as for quitting.
        bridge.sync?.cancel()
        var done = false
        var completed = false
        let complete = {
            guard !completed else { return }
            completed = true
            completion()
        }
        let finish = { [weak self] in
            guard !done else { return }
            done = true
            // Mirror once more on the way out, always: a change may still be waiting out its delay,
            // or its background read may be in flight (this read supersedes it). Quitting waits for
            // the reminders to be reconciled, so a removal isn't cut short.
            guard let self else { return complete() }
            _ = self.bridge.takePendingLibraryChange()
            self.mirrorLibrary(inBackground: false, completion: complete)
        }
        webView.callAsyncJavaScript("return await (window.catchlightBridge?.flush?.() ?? false);", arguments: [:], in: nil, in: .page) { result in
            if case .failure(let error) = result { Self.log.error("flush failed: \(String(describing: error), privacy: .public)") }
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !done { Self.log.error("flush timed out; closing anyway") }
            finish()
            if !completed { Self.log.error("mirroring on the way out timed out; closing anyway") }
            complete()
        }
    }

    /// Brings reminders and Spotlight in step with the library (`LibraryMirror.mirror`).
    /// `completion` runs once the reminders are reconciled, or at once when there is nothing to do.
    private func mirrorLibrary(inBackground: Bool, completion: (() -> Void)? = nil) {
        guard let mirror = libraryMirror, let read = LibraryMirror.reader(for: bridge.vault) else {
            completion?()
            return
        }
        mirror.mirror(using: read, inBackground: inBackground, completion: completion)
    }

    /// Closing the window ends the app (AppDelegate), so the page saves first.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeAfterFlush { return true }
        flushPage { [weak self] in
            self?.closeAfterFlush = true
            sender.close()
        }
        return false
    }

    /// Calls a page function with one string argument, JSON-encoded so nothing in it is code.
    private func callPage(_ function: String, _ argument: String, completion: ((Any?) -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: [argument]),
              let array = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("\(function)(...\(array))") { result, error in
            if let error { Self.log.error("\(function, privacy: .public) failed: \(String(describing: error), privacy: .public)") }
            completion?(result)
        }
    }

    // MARK: Full screen

    // Full screen hides the traffic lights, so the page drops the room it leaves for them
    // (`.full-screen` on <html>). The state is kept so the next launch opens the same way.
    func windowWillEnterFullScreen(_ notification: Notification) {
        markFullScreen(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        markFullScreen(false)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        markFullScreen(false)
    }

    private func markFullScreen(_ on: Bool) {
        webView.evaluateJavaScript("document.documentElement.classList.toggle('full-screen', \(on))")
        UserDefaults.standard.set(on, forKey: Self.fullScreenKey)
    }

    // MARK: Navigation: the page stays on catchlight://, links go to the browser

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let followed = navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil
        decisionHandler(follow(NavigationRule.decide(navigationAction.request.url, userFollowedLink: followed), for: navigationAction.request.url))
    }

    /// `target=_blank` and `window.open`: never a second web view.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        _ = follow(NavigationRule.decide(navigationAction.request.url, userFollowedLink: true), for: navigationAction.request.url)
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page loaded in full screen (the launch restored it, or a reload) needs telling.
        if window?.styleMask.contains(.fullScreen) == true { markFullScreen(true) }
        // Only the app's own page: the error page and a failed load have no catchlightOpenTake.
        if webView.url?.absoluteString == Self.startURL.absoluteString { takeOpener.pageDidLoad() }
        // A lock screen loaded while the shell is asking shows that it is.
        if !unlockReplies.isEmpty { showUnlocking() }
        #if DEBUG
        DebugLaunch.pageDidLoad(webView)
        #endif
    }

    /// Reload once after the page's process ends; a second end within a minute shows the error
    /// page instead, so a page that crashes WebKit on every load cannot loop.
    private var lastTermination: Date?

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        takeOpener.pageDidUnload()
        let now = Date()
        defer { lastTermination = now }
        if let last = lastTermination, now.timeIntervalSince(last) < 60 {
            Self.log.fault("web content process terminated twice within a minute; not reloading")
            showErrorPage()
            return
        }
        Self.log.error("web content process terminated; reloading")
        bridge.refreshUserScripts(in: webView.configuration.userContentController)
        webView.reload()
    }

    private func showErrorPage() {
        let message = String(localized: "Catchlight could not start its web view safely. Please quit and reopen it.")
        webView.loadHTMLString("<p style='font: 14px system-ui; padding: 2em'>\(message)</p>", baseURL: nil)
    }

    private func follow(_ rule: NavigationRule, for url: URL?) -> WKNavigationActionPolicy {
        switch rule {
        case .allow:
            return .allow
        case .openExternally(let url):
            // The address is the user's: it stays out of the log outside debug builds.
            #if DEBUG
            Self.log.info("opening in the default app: \(url.absoluteString, privacy: .public)")
            #else
            Self.log.info("opening a \(url.scheme ?? "", privacy: .public) link in the default app")
            #endif
            bridge.openExternally(url)
            return .cancel
        case .cancel:
            #if DEBUG
            Self.log.info("navigation refused: \(url?.absoluteString ?? "(none)", privacy: .public)")
            #endif
            return .cancel
        }
    }
}
