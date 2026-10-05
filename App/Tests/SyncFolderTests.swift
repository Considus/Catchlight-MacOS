import XCTest
import WebKit

/// The sync folder: the bookmark kept across launches, the panel's answer, and the page seeing
/// only the path. The panel itself is replaced, because a test can't click one.
final class SyncFolderTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-folder-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Cloud/Catchlight"), withIntermediateDirectories: true)
        suite = "catchlight.tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(picking url: URL?) -> SyncFolder {
        let folder = SyncFolder(defaults: defaults)
        folder.pick = { _, done in done(url) }
        return folder
    }

    private func choose(_ folder: SyncFolder) -> String? {
        var answer: String?? = .none
        folder.choose(in: nil) { answer = .some(try? $0.get()) }
        return answer ?? "never answered"
    }

    func testAChosenFolderOpensAgainLikeAfterARelaunch() throws {
        let picked = root.appendingPathComponent("Cloud/Catchlight")
        XCTAssertNotNil(choose(folder(picking: picked)))

        let relaunched = SyncFolder(defaults: defaults)   // a new instance reads only the stored bookmark
        let cloud = try XCTUnwrap(relaunched.open())
        XCTAssertEqual(cloud.folderURL.resolvingSymlinksInPath().path, picked.resolvingSymlinksInPath().path)
        try cloud.write(Data("x".utf8), to: "probe.clk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.appendingPathComponent("probe.clk").path))
    }

    func testCancellingKeepsTheFolderThatWasThere() {
        let picked = root.appendingPathComponent("Cloud/Catchlight")
        _ = choose(folder(picking: picked))
        let before = defaults.data(forKey: SyncFolder.bookmarkKey)
        XCTAssertNil(choose(folder(picking: nil)))
        XCTAssertEqual(defaults.data(forKey: SyncFolder.bookmarkKey), before)
    }

    func testForgetLeavesNoFolder() {
        let f = folder(picking: root.appendingPathComponent("Cloud/Catchlight"))
        _ = choose(f)
        f.forget()
        XCTAssertFalse(f.hasFolder)
        XCTAssertNil(f.open())
        XCTAssertNil(f.displayPath)
    }

    func testADeletedFolderReadsAsNone() throws {
        let picked = root.appendingPathComponent("Cloud/Catchlight")
        let f = folder(picking: picked)
        _ = choose(f)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Cloud"))
        XCTAssertNil(f.displayPath, "a folder that is gone must not look connected")
    }

    func testThePathShowsHomeAsATilde() {
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir!)
        XCTAssertEqual(SyncFolder.display(URL(fileURLWithPath: home + "/Library/Mobile Documents/Catchlight")),
                       "~/Library/Mobile Documents/Catchlight")
        XCTAssertEqual(SyncFolder.display(URL(fileURLWithPath: "/Volumes/Drive/Catchlight")), "/Volumes/Drive/Catchlight")
        XCTAssertEqual(SyncFolder.display(URL(fileURLWithPath: home + "x/Catchlight")), home + "x/Catchlight", "only the home folder itself becomes ~")
    }

    /// The real page asks through the bridge and gets the path, never the bookmark.
    func testThePageGetsThePathThroughTheBridge() throws {
        let picked = root.appendingPathComponent("Cloud/Catchlight")
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.syncFolder = folder(picking: picked)
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)

        let answer = try harness.run("return await catchlightBridge.shell.chooseFolder();", in: self) as? String
        XCTAssertEqual(answer, SyncFolder.display(picked))
        XCTAssertNotNil(defaults.data(forKey: SyncFolder.bookmarkKey))
    }

    /// A folder that can't be bookmarked is an error the page shows, never a quiet cancel.
    func testAFolderThatCantBeBookmarkedIsAnError() {
        let f = folder(picking: root.appendingPathComponent("Not There"))
        var result: Result<String?, Error>?
        f.choose(in: nil) { result = $0 }
        XCTAssertThrowsError(try result?.get())
        XCTAssertFalse(f.hasFolder)
    }

    /// Erase everything and Second device let the old account's folder go, as on iOS.
    func testEraseEverythingForgetsTheFolder() throws {
        let f = folder(picking: root.appendingPathComponent("Cloud/Catchlight"))
        _ = choose(f)
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("Library"))
        try vault.createAccount(words: try Vault.newPhrase(), restored: false)
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.vault = vault
        bridge.syncFolder = f
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)

        _ = try harness.run("return await catchlightBridge.shell.eraseEverything();", in: self)
        XCTAssertFalse(f.hasFolder)
    }

    func testSecondDeviceForgetsTheFolder() throws {
        let f = folder(picking: root.appendingPathComponent("Cloud/Catchlight"))
        _ = choose(f)
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("Library"))
        try vault.createAccount(words: try Vault.newPhrase(), restored: false)
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.vault = vault
        bridge.syncFolder = f
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)

        let words = try Vault.newPhrase()
        let json = String(data: try JSONSerialization.data(withJSONObject: words), encoding: .utf8)!
        _ = try harness.run("return await catchlightBridge.shell.replaceAccount(\(json));", in: self)
        XCTAssertFalse(f.hasFolder)
    }

    /// #51 review (Claude): a folder picked in first run, then local storage chosen instead,
    /// must not come back as connected.
    func testChoosingLocalStorageLetsAPickedFolderGo() throws {
        let f = folder(picking: root.appendingPathComponent("Cloud/Catchlight"))
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.syncFolder = f
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)

        _ = try harness.run("""
            await catchlightBridge.shell.chooseFolder();
            const b = document.createElement('button'); b.dataset.fr = 'local';
            layer.append(b); b.click();
            await window.webkit.messageHandlers.catchlight.postMessage({cmd: 'ping'});
            return true;
            """, in: self)
        XCTAssertFalse(f.hasFolder)
    }
}
