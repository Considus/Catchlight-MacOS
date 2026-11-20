import XCTest
import CatchlightCore

/// HeldEdits on its own: what it holds is sealed, it opens under the keys that sealed it, and one
/// that won't open is counted as lost rather than dropped without a word (review on Catchlight-iOS#475).
final class HeldEditsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-held-\(UUID())", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func library() throws -> (Library, KeyHierarchy, [String: Any]) {
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("Library"))
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let library = try XCTUnwrap(vault.library)
        _ = try library.saveTakes([["id": UUID().uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true,
                                    "blocks": [["k": "text", "text": "Stored"]]]])
        var edited = try XCTUnwrap(library.pageTakes().first)
        edited["blocks"] = [["k": "text", "text": "Typed, not saved"]]
        return (library, try XCTUnwrap(vault.keys), edited)
    }

    func testItHoldsOnlyWhatChangedSealedAndOpensUnderTheSameKeys() throws {
        let (library, keys, edited) = try library()
        let unchanged = try XCTUnwrap(library.pageTakes().first)
        var held = HeldEdits.seal(takes: [edited], scripts: nil, library: library, keys: keys)
        XCTAssertEqual(held.count, 1)
        XCTAssertNil(try XCTUnwrap(held.sealedData.first).range(of: Data("Typed, not saved".utf8)), "held readable")
        XCTAssertTrue(HeldEdits.seal(takes: [unchanged], scripts: nil, library: library, keys: keys).isEmpty, "nothing changed, nothing held")

        let back = held.open(keys: keys, library: library)
        XCTAssertEqual(back.lost, 0)
        XCTAssertEqual((back.takes.first?["blocks"] as? [[String: Any]])?.first?["text"] as? String, "Typed, not saved")
        held.wipe()
        XCTAssertTrue(held.isEmpty)
    }

    func testOneThatWontOpenIsCountedAsLost() throws {
        let (library, keys, edited) = try library()
        let held = HeldEdits.seal(takes: [edited], scripts: nil, library: library, keys: keys)
        let back = held.open(keys: KeyHierarchy(masterKeyBytes: Data(repeating: 9, count: 32)), library: library)
        XCTAssertEqual(back.lost, 1, "a held edit that won't open must be reported, not dropped")
        XCTAssertTrue(back.takes.isEmpty)
    }
}
