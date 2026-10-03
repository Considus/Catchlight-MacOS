import XCTest

final class NavigationRuleTests: XCTestCase {
    private func decide(_ s: String, followed: Bool) -> NavigationRule {
        NavigationRule.decide(URL(string: s), userFollowedLink: followed)
    }

    func testTheAppsOwnPagesLoad() {
        XCTAssertEqual(decide("catchlight://app/index.html", followed: false), .allow)
        XCTAssertEqual(decide("CATCHLIGHT://app/index.html", followed: true), .allow)
        XCTAssertEqual(decide("about:blank", followed: false), .allow)
        XCTAssertEqual(decide("about:srcdoc", followed: false), .allow)
    }

    func testAFollowedWebLinkOpensOutsideTheApp() {
        for s in ["https://catchlight.app/support/", "http://example.com/x", "mailto:someone@example.com"] {
            XCTAssertEqual(decide(s, followed: true), .openExternally(URL(string: s)!), s)
        }
    }

    func testEverythingElseIsCancelled() {
        // A web address the page navigates to by itself never loads, and never opens either.
        XCTAssertEqual(decide("https://example.com/", followed: false), .cancel)
        XCTAssertEqual(decide("mailto:someone@example.com", followed: false), .cancel)
        // Schemes neither the window nor the browser should take, followed or not.
        for s in ["file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/", "data:text/html,hi",
                  "blob:catchlight://app/1234", "about:config", "ws://example.com/", "x-apple.systempreferences:"] {
            XCTAssertEqual(decide(s, followed: true), .cancel, s)
            XCTAssertEqual(decide(s, followed: false), .cancel, s)
        }
        XCTAssertEqual(NavigationRule.decide(nil, userFollowedLink: true), .cancel)
    }
}
