import AppKit
import WebKit
import CatchlightCore
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

    /// `vault` is nil only in tests that load the page without a library; the page then keeps
    /// the browser prototype's localStorage behaviour.
    /// `notifications`, `mirror`, `defaults` and `uiRoot` are the app's own except in tests, which
    /// have no notification centre to ask, and serve the repo's `ui/` rather than a bundle's.
    init(vault: Vault?,
         notifications: NotificationCentre = UNUserNotificationCenter.current(),
         mirror: LibraryMirror? = nil,
         defaults: UserDefaults = .standard,
         uiRoot: URL? = nil) {
        self.defaults = defaults
        self.uiRoot = uiRoot
        bridge.defaults = defaults
        bridge.vault = vault
        var syncDefaults = UserDefaults.standard
        #if DEBUG
        syncDefaults = DebugLaunch.syncDefaults() ?? syncDefaults
        #endif
        bridge.syncFolder = SyncFolder(defaults: syncDefaults)
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
        // Restore the last frame; centre the default size on first launch.
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
        wireMenu()
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
        takeOpener.open(id)
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
