#if DEBUG
import XCTest

final class DebugLaunchTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "debug-launch-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testPhraseIsSplitIntoWords() throws {
        let d = suite()
        XCTAssertNil(DebugLaunch.phrase(d))
        let words = try Vault.newPhrase()
        d.set("  " + words.joined(separator: "  ") + " ", forKey: "CLDebugPhrase")
        XCTAssertEqual(DebugLaunch.phrase(d), words)
        XCTAssertEqual(DebugLaunch.phrase(d)?.count, 12)
    }

    func testFolderOptionNeedsTheThrowawayAccount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbg-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let d = suite()
        d.set(dir.path, forKey: "CLDebugFolder")
        let folder = SyncFolder(defaults: suite())
        DebugLaunch.useFolder(folder, d)
        XCTAssertFalse(folder.hasFolder, "without CLDebugAccount the option must do nothing")
        d.set(true, forKey: "CLDebugAccount")
        DebugLaunch.useFolder(folder, d)
        XCTAssertTrue(folder.hasFolder)
        XCTAssertEqual(folder.open()?.folderURL.standardizedFileURL.resolvingSymlinksInPath(), dir.standardizedFileURL.resolvingSymlinksInPath())
    }
}
#endif
