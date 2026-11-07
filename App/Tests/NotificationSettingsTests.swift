import UserNotifications
import WebKit
import XCTest

/// M4: Settings shows the Mac's real notification permission and lets the user grant it. The real
/// `ui/` in a WKWebView with the real bridge and a fake notification centre.
final class NotificationSettingsTests: XCTestCase {
    private let centre = FakeCentre()
    private var opened: [URL] = []

    private func page() -> WebViewHarness {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.notifications = centre
        bridge.openExternally = { [unowned self] in opened.append($0) }
        bridge.install(in: harness.webView.configuration.userContentController)
        // The page keeps its settings in localStorage, which outlives a test's page.
        harness.load("index.html", in: self, injecting: [WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        bridgeKeepAlive = bridge
        return harness
    }
    private var bridgeKeepAlive: ShellBridge?

    private func ask(_ harness: WebViewHarness, _ call: String) throws -> String? {
        try harness.run("return await window.catchlightBridge.shell.\(call);", in: self) as? String
    }

    func testTheBridgeAnswersEachStatus() throws {
        let harness = page()
        let expected: [(UNAuthorizationStatus, String)] = [(.authorized, "enabled"), (.provisional, "enabled"), (.denied, "denied"), (.notDetermined, "ask")]
        for (status, answer) in expected {
            centre.status = status
            XCTAssertEqual(try ask(harness, "notificationStatus()"), answer, "status \(status.rawValue)")
        }
    }

    func testEnablingWhenNotDeterminedAsksOnceAndDoesNotOpenSystemSettings() throws {
        let harness = page()
        centre.status = .notDetermined
        XCTAssertEqual(try ask(harness, "enableNotifications()"), "enabled", "the answer is the status after the prompt")
        XCTAssertEqual(centre.authorizationAsked, 1)
        XCTAssertTrue(opened.isEmpty)
    }

    func testEnablingWhenDeniedOpensTheNotificationsPaneAndDoesNotAsk() throws {
        let harness = page()
        centre.status = .denied
        XCTAssertEqual(try ask(harness, "enableNotifications()"), "denied")
        XCTAssertEqual(centre.authorizationAsked, 0)
        let id = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertEqual(opened.map(\.absoluteString), ["x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)"])
    }

    func testEnablingWhenAlreadyEnabledDoesNothing() throws {
        let harness = page()
        centre.status = .authorized
        XCTAssertEqual(try ask(harness, "enableNotifications()"), "enabled")
        XCTAssertEqual(centre.authorizationAsked, 0)
        XCTAssertTrue(opened.isEmpty)
    }

    /// The row's value as the page paints it, once Settings has read the status from the shell.
    private func rowText(_ harness: WebViewHarness) throws -> String {
        try harness.run("""
            openSettings();
            for (let i = 0; i < 100 && !document.querySelector('[data-open="notifications"] .sdot'); i++) await new Promise(r => setTimeout(r, 20));
            return document.querySelector('[data-open="notifications"]').textContent.trim();
            """, in: self) as? String ?? ""
    }

    func testTheRowShowsEnabledWhenTheShellSaysEnabled() throws {
        centre.status = .authorized
        XCTAssertTrue(try rowText(page()).hasSuffix("Enabled"))
    }

    func testTheRowShowsDisabledAndOpensSystemSettingsWhenDenied() throws {
        centre.status = .denied
        let harness = page()
        XCTAssertTrue(try rowText(harness).hasSuffix("Disabled"))
        _ = try harness.run("document.querySelector('[data-open=\"notifications\"]').click(); await window.catchlightBridge.flush(); return true;", in: self)
        XCTAssertEqual(opened.count, 1)
    }

    func testTheRowReadsTheStatusAgainWhenTheWindowRegainsFocus() throws {
        centre.status = .denied
        let harness = page()
        _ = try rowText(harness)
        centre.status = .authorized
        let text = try harness.run("""
            dispatchEvent(new Event('focus'));
            for (let i = 0; i < 100 && !document.querySelector('[data-open="notifications"] .sdot.ok'); i++) await new Promise(r => setTimeout(r, 20));
            return document.querySelector('[data-open="notifications"]').textContent.trim();
            """, in: self) as? String
        XCTAssertEqual(text?.hasSuffix("Enabled"), true, text ?? "no row")
    }
}
