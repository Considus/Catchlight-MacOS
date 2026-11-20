import WebKit
import XCTest

/// `catchlightLockUnlocking()`: the shell asks for the user on its own as the app comes back, and
/// the lock screen shows it as the iPhone's does, Authenticating… with Unlocking… disabled. The
/// harness has no shell, so the page gets a stand-in bridge before any script runs.
final class LockUnlockingTests: XCTestCase {
    private func page(_ library: String) -> WebViewHarness {
        let setup = """
            localStorage.clear();
            window.catchlightLibrary = { account: true, takes: [], scripts: [], \(library) };
            window.unlockCalls = 0;
            window.catchlightBridge = { shell: {
              setSpotlight() {}, setWritingTools() {}, setLockAfter: () => Promise.resolve(),
              unlock: () => { window.unlockCalls += 1; return new Promise(() => {}); },
            } };
            """
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        harness.load("index.html", in: self, injecting: [WKUserScript(source: setup, injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        return harness
    }

    private func json(_ harness: WebViewHarness, _ body: String) throws -> [String: Any] {
        let text = try XCTUnwrap(try harness.run("return JSON.stringify(await (async () => {\n\(body)\n})());", in: self) as? String)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    private let read = """
        const tick = () => new Promise(f => setTimeout(f, 30));
        const read = () => ({
          message: document.querySelector('#lock .lock-message')?.textContent,
          button: document.querySelector('#lock .lock-button')?.textContent,
          disabled: document.querySelector('#lock .lock-button')?.disabled,
          live: document.querySelector('#lock [aria-live="assertive"]')?.textContent,
        });
        """

    func testItShowsAuthenticatingWithTheButtonDisabled() throws {
        let harness = page("locked: true")
        let r = try json(harness, read + """
            const exists = typeof window.catchlightLockUnlocking === 'function';
            if (exists) window.catchlightLockUnlocking();
            await tick(); document.getAnimations().forEach(a => a.finish()); await tick();
            document.querySelector('#lock .lock-button').click();
            await tick();
            return { exists, ...read(), unlockCalls: window.unlockCalls };
            """)
        XCTAssertEqual(r["exists"] as? Bool, true, "the page has no catchlightLockUnlocking")
        XCTAssertEqual(r["message"] as? String, "Authenticating…")
        XCTAssertEqual(r["button"] as? String, "Unlocking…")
        XCTAssertEqual(r["disabled"] as? Bool, true)
        XCTAssertTrue((r["live"] as? String ?? "").isEmpty, "unlocking is not announced, as on the iPhone: \(r)")
        XCTAssertEqual(r["unlockCalls"] as? Int, 0, "the page asks again while the shell is asking")
    }

    func testItLeavesTryAgainAloneWhenAFailureIsShowing() throws {
        // The shell asks on its own only when no failure shows; if one does, Try Again stays.
        let harness = page("locked: true, lockFailure: 'cancelled'")
        let r = try json(harness, read + """
            window.catchlightLockUnlocking?.();
            await tick();
            return read();
            """)
        XCTAssertEqual(r["button"] as? String, "Try again")
    }

    func testItDoesNothingOnAnOpenLibrary() throws {
        let harness = page("")
        let r = try json(harness, """
            const exists = typeof window.catchlightLockUnlocking === 'function';
            if (exists) window.catchlightLockUnlocking();
            return { exists, lock: !!document.querySelector('#lock') };
            """)
        XCTAssertEqual(r["exists"] as? Bool, true)
        XCTAssertEqual(r["lock"] as? Bool, false)
    }
}
