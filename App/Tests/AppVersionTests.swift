import XCTest
import WebKit

/// About and Report an issue show the version the app is built with, not a fixed label.
final class AppVersionTests: XCTestCase {
    func testTheBuiltVersionIsOneZero() {
        XCTAssertEqual(Bundle(for: ShellBridge.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.0")
    }

    func testAboutShowsTheShellsVersionAndNoPrototypeLabel() throws {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let controller = harness.webView.configuration.userContentController
        controller.addUserScript(ShellBridge.injectedValues())
        ShellBridge().install(in: controller)
        harness.load("index.html", in: self)
        let shown = try harness.run("return [shell.version(), '', supportInfo().split('\\n')[0]];", in: self) as? [Any]
        XCTAssertEqual(shown?[0] as? String, SystemInfo.appVersion)
        XCTAssertFalse(SystemInfo.appVersion.isEmpty)
        XCTAssertEqual(shown?[2] as? String, "Catchlight \(SystemInfo.appVersion)")
    }
}
