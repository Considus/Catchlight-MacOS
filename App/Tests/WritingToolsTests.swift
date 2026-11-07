import AppKit
import CatchlightCore
import WebKit
import XCTest

/// M5: Settings > Security's Writing Tools choice (Off, Panel, Inline) governs the web view.
/// Off is the default and means off: the web view's own default may resolve to Writing Tools on.
final class WritingToolsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var dir: URL!
    private var controllers: [MainWindowController] = []

    override func setUp() {
        suite = "catchlight-writing-tools-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-wt-\(UUID())/Catchlight")
    }

    override func tearDown() {
        controllers.forEach { $0.window?.close() }
        controllers = []
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func controller(vault: Vault? = nil) -> MainWindowController {
        let mirror = LibraryMirror(reminders: MacReminders(centre: FakeCentre()), spotlight: RecordingSpotlightIndexer(), defaults: defaults)
        let made = MainWindowController(vault: vault, notifications: FakeCentre(), mirror: mirror, defaults: defaults, uiRoot: WebViewHarness.repoUI)
        // The page keeps its settings in localStorage, which outlives a test's page. Added before the page loads (it waits for the address block to compile).
        made.webView.configuration.userContentController.addUserScript(WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controllers.append(made)
        return made
    }

    /// Spins the run loop (not a page timer) until the controller's web view has finished loading the app's page.
    private func pageIsLoaded(_ controller: MainWindowController, replacing old: WKWebView? = nil) {
        let deadline = Date().addingTimeInterval(30)
        func loaded() -> Bool {
            controller.webView !== old && !controller.webView.isLoading
                && controller.webView.url?.absoluteString == MainWindowController.startURL.absoluteString
        }
        while !loaded() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(loaded(), "the page did not load")
    }

    private func runInPage(_ controller: MainWindowController, _ body: String) throws -> Any? {
        let done = expectation(description: "script ran")
        var outcome: Result<Any, Error> = .failure(CocoaError(.featureUnsupported))
        controller.webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 20)
        return try outcome.get()
    }

    @available(macOS 15.0, *)
    private func behavior(_ controller: MainWindowController) -> NSWritingToolsBehavior {
        controller.webView.configuration.writingToolsBehavior
    }

    // MARK: The configuration a new web view gets

    func testANewWebViewHasWritingToolsOffWhenNothingIsStored() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Writing Tools starts at macOS 15") }
        XCTAssertEqual(behavior(controller()), NSWritingToolsBehavior.none)
    }

    func testANewWebViewFollowsTheStoredSetting() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Writing Tools starts at macOS 15") }
        let expected: [(String, NSWritingToolsBehavior)] = [("off", .none), ("panel", .limited), ("inline", .complete), ("nonsense", .none)]
        for (stored, behavior) in expected {
            defaults.set(stored, forKey: "writingTools")
            XCTAssertEqual(self.behavior(controller()), behavior, "stored \(stored)")
        }
    }

    // MARK: The bridge

    private func bridgePage() -> WebViewHarness {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.defaults = defaults
        bridge.install(in: harness.webView.configuration.userContentController)
        bridgeKeepAlive = bridge
        harness.load("index.html", in: self, injecting: [WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        return harness
    }
    private var bridgeKeepAlive: ShellBridge?

    private func send(_ harness: WebViewHarness, _ level: String) throws -> Bool? {
        try harness.run("return await window.webkit.messageHandlers.catchlight.postMessage({cmd: 'setWritingTools', level: \(level.debugDescription)});", in: self) as? Bool
    }

    func testSettingTheLevelThroughTheBridgeStoresIt() throws {
        let harness = bridgePage()
        XCTAssertEqual(try send(harness, "inline"), true)
        XCTAssertEqual(defaults.string(forKey: "writingTools"), "inline")
        XCTAssertEqual(try send(harness, "panel"), true)
        XCTAssertEqual(defaults.string(forKey: "writingTools"), "panel")
    }

    func testAnUnknownLevelStoresOff() throws {
        let harness = bridgePage()
        _ = try send(harness, "inline")
        XCTAssertEqual(try send(harness, "everything"), true)
        XCTAssertEqual(defaults.string(forKey: "writingTools"), "off")
    }

    func testThePageSendsItsSettingAtLoad() throws {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.defaults = defaults
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self, injecting: [WKUserScript(source: "localStorage.clear(); localStorage.setItem('cl.settings', JSON.stringify({ writingTools: 'panel' }));", injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        _ = try harness.run("return await window.webkit.messageHandlers.catchlight.postMessage({cmd: 'ping'});", in: self)
        XCTAssertEqual(defaults.string(forKey: "writingTools"), "panel")
        withExtendedLifetime(bridge) {}
    }

    // MARK: A change reaches the live web view

    func testAChangeReachesTheLiveWebViewAndLosesNothingTyped() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Writing Tools starts at macOS 15") }
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let live = controller(vault: vault)
        pageIsLoaded(live)
        let before = live.webView
        XCTAssertEqual(behavior(live), NSWritingToolsBehavior.none)

        // A Script edit still waiting on its debounce, then the change, without waiting for either.
        _ = try runInPage(live, """
            newScript(['# Draft']);
            script().blocks[0] = '# Typed just before the change'; changed();
            settings.writingTools = 'inline'; saveSettings();   // as the Settings row does
            return await window.catchlightBridge.shell.setWritingTools('inline');
            """)
        pageIsLoaded(live, replacing: before)

        XCTAssertNotIdentical(live.webView, before)
        XCTAssertEqual(behavior(live), NSWritingToolsBehavior.complete)
        XCTAssertIdentical(live.window?.contentView, live.webView, "the window shows the new web view")
        XCTAssertEqual(try vault.library!.pageScripts().first?["blocks"] as? [String], ["# Typed just before the change"])
        // The new page works and shows what was saved.
        XCTAssertEqual(try runInPage(live, "return script().blocks[0];") as? String, "# Typed just before the change")
    }

    func testTheSameLevelDoesNotRebuildTheWebView() throws {
        let live = controller()
        pageIsLoaded(live)
        let before = live.webView
        _ = try runInPage(live, "return await window.catchlightBridge.shell.setWritingTools('off');")
        XCTAssertIdentical(live.webView, before)
    }
}
