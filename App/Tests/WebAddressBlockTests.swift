import WebKit
import XCTest

/// The rule list, measured in a real WKWebView against a server that counts what reaches it.
final class WebAddressBlockTests: XCTestCase {
    private var page: URL!

    override func setUpWithError() throws {
        page = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-block-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: page, withIntermediateDirectories: true)
        try Data("<!doctype html><title>t</title><p>page</p>".utf8).write(to: page.appendingPathComponent("index.html"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: page)
    }

    private func compiledRuleList() throws -> WKContentRuleList {
        let done = expectation(description: "compiled")
        var outcome: Result<WKContentRuleList, Error>?
        WebAddressBlock.compile { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 20)
        return try XCTUnwrap(outcome).get()
    }

    /// Tries a fetch and an image load from the page; returns what the page saw.
    private func tryLoads(_ base: String, harness: WebViewHarness) throws -> [String: String] {
        let body = """
        const out = {};
        try { const r = await fetch('\(base)/fetch'); out.fetch = 'loaded ' + r.status; } catch (e) { out.fetch = 'failed'; }
        out.image = await new Promise(res => { const i = new Image(); i.onload = () => res('loaded'); i.onerror = () => res('failed'); i.src = '\(base)/x.png'; });
        return out;
        """
        return try XCTUnwrap(harness.run(body, in: self) as? [String: String])
    }

    func testTheRuleListCompiles() throws {
        _ = try compiledRuleList()
    }

    func testWithoutTheBlockTheServerIsReached() throws {
        // The control: proves the measurement below can see a load when one happens.
        let server = try CountingServer()
        let harness = WebViewHarness(root: page, ruleList: nil)
        harness.load("index.html", in: self)
        _ = try tryLoads("http://127.0.0.1:\(server.port)", harness: harness)
        XCTAssertGreaterThan(server.requests, 0)
    }

    func testWithTheBlockNothingReachesTheServer() throws {
        let server = try CountingServer()
        let harness = WebViewHarness(root: page, ruleList: try compiledRuleList())
        harness.load("index.html", in: self)
        let seen = try tryLoads("http://127.0.0.1:\(server.port)", harness: harness)
        XCTAssertEqual(seen["fetch"], "failed")
        XCTAssertEqual(seen["image"], "failed")
        XCTAssertEqual(server.requests, 0, "a blocked load reached the server")
    }

    func testTheAppsOwnFilesStillLoad() throws {
        try Data("ok".utf8).write(to: page.appendingPathComponent("file.txt"))
        let harness = WebViewHarness(root: page, ruleList: try compiledRuleList())
        harness.load("index.html", in: self)
        let text = try harness.run("return await (await fetch('catchlight://app/file.txt')).text();", in: self) as? String
        XCTAssertEqual(text, "ok")
    }
}
