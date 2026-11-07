import AppKit
import WebKit
import XCTest

/// M4: Export Take and Export Takes save through the Mac's save panel. The panel is stubbed
/// (`pickSaveURL`); the real bridge and the real `ui/` do the rest.
final class ExportPanelTests: XCTestCase {
    private var folder: URL!
    private var bridgeKeepAlive: ShellBridge?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExportPanelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func page(chooses target: URL?, asked names: @escaping (String) -> Void = { _ in }) -> WebViewHarness {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.pickSaveURL = { _, name, done in names(name); done(target) }
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self, injecting: [WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true)])
        bridgeKeepAlive = bridge
        return harness
    }

    private func exportFile(_ harness: WebViewHarness, name: String, text: String) throws -> [String: Bool]? {
        let reply = try harness.run("return await window.catchlightBridge.shell.exportFile(\(json(name)), \(json(text)));", in: self)
        return reply as? [String: Bool]
    }

    private func json(_ string: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [string]), encoding: .utf8)!.dropFirst().dropLast().description
    }

    func testExportFileWritesExactlyTheTextAndAnswersSaved() throws {
        let target = folder.appendingPathComponent("out.md")
        var asked: [String] = []
        let text = "---\ntakes: 1\n---\n\n## Note\nCaf\u{E9} \u{1F514}\n"
        let reply = try exportFile(page(chooses: target, asked: { asked.append($0) }), name: "catchlight-2026-11-07.md", text: text)
        XCTAssertEqual(reply, ["saved": true])
        XCTAssertEqual(asked, ["catchlight-2026-11-07.md"])
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), text)
    }

    func testExportFileCancelledAnswersCancelledAndWritesNothing() throws {
        let reply = try exportFile(page(chooses: nil), name: "catchlight-2026-11-07.md", text: "text")
        XCTAssertEqual(reply, ["cancelled": true])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testExportTakeInTheShellSendsASuggestedNameAndTheMarkdown() throws {
        let target = folder.appendingPathComponent("take.md")
        var asked: [String] = []
        let harness = page(chooses: target, asked: { asked.append($0) })
        let ran = try harness.run("""
            try { exportTake({ id: 'x', at: '2026-11-01T09:00:00.000Z', isNote: true, blocks: [{ k: 'text', text: 'Hello export' }] }); } catch (e) { return String(e); }
            await window.catchlightBridge.flush();
            return 'ok';
            """, in: self)
        // The write follows the page's call on another queue: wait for the file.
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: target.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let name = try XCTUnwrap(asked.first)
        XCTAssertNotNil(name.range(of: #"^catchlight-\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression), name)
        let written = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("---\nexported: "), written)
        XCTAssertTrue(written.contains("takes: 1\n"), written)
        XCTAssertTrue(written.contains("Hello export"), written)
    }
}
