import Network
import WebKit
import XCTest

/// A WKWebView on a `catchlight://app/` page served from `root`, as the app sets one up, for tests.
final class WebViewHarness: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var loaded: XCTestExpectation?   // fulfilled by didFinish; a failed load times out and is retried

    init(root: URL, ruleList: WKContentRuleList?) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(UIResourceSchemeHandler(root: root), forURLScheme: UIResourceSchemeHandler.scheme)
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        if let ruleList { configuration.userContentController.add(ruleList) }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    /// Loads `path`, trying a second time if the first load stalls: on a heavily loaded machine
    /// WebKit's GPU process can miss its responsiveness check and be killed, leaving the page
    /// unfinished (seen on the Intel iMac at a load average in the hundreds; never when idle).
    func load(_ path: String, in test: XCTestCase, injecting scripts: [WKUserScript] = []) {
        scripts.forEach(webView.configuration.userContentController.addUserScript)
        let request = URLRequest(url: URL(string: "catchlight://app/\(path)")!)
        for attempt in 1...2 {
            let expectation = XCTestExpectation(description: "page loaded (attempt \(attempt))")
            loaded = expectation
            webView.load(request)
            if XCTWaiter().wait(for: [expectation], timeout: 30) == .completed { return }
        }
        XCTFail("the page did not load in two attempts")
    }

    /// Runs `body` as an async function in the page and returns its result.
    func run(_ body: String, in test: XCTestCase) throws -> Any? {
        let done = test.expectation(description: "script ran")
        var outcome: Result<Any, Error> = .failure(CocoaError(.featureUnsupported))
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
            outcome = result
            done.fulfill()
        }
        test.wait(for: [done], timeout: 20)
        return try outcome.get()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.fulfill() }

    static var repoUI: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ui", isDirectory: true)
    }
}

/// An HTTP server on 127.0.0.1 that counts the requests it is sent and answers each with "ok".
final class CountingServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "CountingServer")
    private var count = 0
    var requests: Int { queue.sync { count } }
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if data != nil { self.count += 1 }
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else {
            throw CocoaError(.featureUnsupported)
        }
        self.port = port
    }

    deinit { listener.cancel() }
}
