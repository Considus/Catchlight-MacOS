import XCTest
import CryptoKit
import CatchlightCore
import CatchlightCoreTestSupport
import CatchlightAppleStorage

// MARK: - Translation: every shape the page produces, through Core and back

final class TakeTranslationTests: XCTestCase {
    private let t0 = ISO8601.date(from: "2026-05-01T09:00:00.000Z")!
    private let t1 = ISO8601.date(from: "2026-05-02T10:30:00.000Z")!

    /// Takes covering every field the page edits and the ones it only carries.
    private func corpus() throws -> [Take] {
        var plain = Take(id: UUID(), createdAt: t0, modifiedAt: t1, blocks: [.textLine("A line with a link, catchlight.app")], isNote: true)
        plain.manualOrder = 1_777_000_000.25

        var checklist = TestFixtures.richTake()
        checklist.isImportant = true

        var obie = Take(id: UUID(), createdAt: t0, modifiedAt: t1, blocks: [.textLine("The one")], isNote: true)
        obie.isObie = true

        var weekly = Take(id: UUID(), createdAt: t0, modifiedAt: t1, blocks: [.textLine("Bins")], isNote: false)
        weekly.timeReminder = TimeReminder(scheduledDate: t1, isDelivered: true, notificationIdentifier: "n-1",
                                           alarmEnabled: false, isDone: false, isAllDay: false,
                                           recurrence: .weekly, weekdays: [2, 4, 6])

        // anchorDay is set only while decoding, which is the case this has to carry.
        var monthly = Take(id: UUID(), createdAt: t0, modifiedAt: t1, blocks: [.textLine("Rent")], isNote: false)
        monthly.timeReminder = TimeReminder(scheduledDate: ISO8601.date(from: "2026-02-28T09:00:00.000Z")!,
                                            notificationIdentifier: "n-2", isAllDay: true, recurrence: .monthly)
        var json = try JSONSerialization.jsonObject(with: PlatformJSON.encode(monthly)) as! [String: Any]
        var tr = json["timeReminder"] as! [String: Any]
        tr["anchorDay"] = 31
        json["timeReminder"] = tr
        monthly = try PlatformJSON.decode(Take.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(monthly.timeReminder?.anchorDay, 31)

        var place = Take(id: UUID(), createdAt: t0, modifiedAt: t1, blocks: [.textLine("Milk")], isNote: false)
        place.locationReminder = LocationTrigger(latitude: 51.5007, longitude: -0.1246, radiusMetres: 150,
                                                 triggerOnArrival: false, locationName: "Home")
        return [plain, checklist, obie, weekly, monthly, place]
    }

    func testUnchangedRoundTripIsIdentical() throws {
        for take in try corpus() {
            let back = try TakeTranslation.core(from: TakeTranslation.page(from: take), existing: take)
            XCTAssertEqual(back, take, "round trip changed \(take.blocks.first.map { "\($0)" } ?? "")")
        }
    }

    func testPageShapeCarriesWhatThePageReads() throws {
        let takes = try corpus()
        let weekly = try TakeTranslation.page(from: takes[3])["reminder"] as! [String: Any]
        XCTAssertEqual(weekly["kind"] as? String, "time")
        XCTAssertEqual(weekly["repeat"] as? String, "weekly")
        XCTAssertEqual(weekly["weekdays"] as? [Int], [2, 4, 6])
        XCTAssertEqual(weekly["notify"] as? Bool, false)
        let monthly = try TakeTranslation.page(from: takes[4])["reminder"] as! [String: Any]
        XCTAssertEqual(monthly["anchorDay"] as? Int, 31)
        XCTAssertEqual(monthly["allDay"] as? Bool, true)
        let place = try TakeTranslation.page(from: takes[5])["reminder"] as! [String: Any]
        XCTAssertEqual(place["kind"] as? String, "place")
        XCTAssertEqual(place["mode"] as? String, "leave")
        XCTAssertEqual(place["name"] as? String, "Home")
        let obie = try TakeTranslation.page(from: takes[2])
        XCTAssertEqual(obie["obie"] as? Bool, true)
        XCTAssertEqual(obie["isImportant"] as? Bool, true)
        let checklist = try TakeTranslation.page(from: takes[1])["blocks"] as! [[String: Any]]
        XCTAssertEqual(checklist.map { $0["k"] as? String }, ["text", "check", "check"])
        XCTAssertEqual(checklist.map { $0["done"] as? Bool }, [nil, false, true])
    }

    func testEditKeepsUnchangedBlockIDsAndMovesModifiedAt() throws {
        let take = TestFixtures.richTake()
        var page = try TakeTranslation.page(from: take)
        var blocks = page["blocks"] as! [[String: Any]]
        blocks[1]["text"] = "Kodak Portra 800"        // edited in place
        blocks.append(["k": "check", "text": "Spare battery", "done": false])
        page["blocks"] = blocks
        let now = ISO8601.date(from: "2026-06-01T12:00:00.000Z")!
        let edited = try TakeTranslation.core(from: page, existing: take, now: now)

        XCTAssertEqual(edited.blocks[0].id, take.blocks[0].id)
        XCTAssertEqual(edited.blocks[1].id, take.blocks[1].id, "an edited block keeps its place's id")
        XCTAssertEqual(edited.blocks[2].id, take.blocks[2].id)
        XCTAssertFalse([take.blocks[0].id, take.blocks[1].id, take.blocks[2].id].contains(edited.blocks[3].id))
        XCTAssertEqual(edited.modifiedAt, now)
        XCTAssertEqual(edited.timeReminder?.notificationIdentifier, take.timeReminder?.notificationIdentifier)
    }

    func testReorderedBlocksKeepTheirIDs() throws {
        let take = TestFixtures.richTake()
        var page = try TakeTranslation.page(from: take)
        page["blocks"] = Array((page["blocks"] as! [[String: Any]]).reversed())
        let moved = try TakeTranslation.core(from: page, existing: take)
        XCTAssertEqual(moved.blocks.map(\.id), take.blocks.map(\.id).reversed())
    }

    func testNewPageTakeBecomesACoreTake() throws {
        let id = UUID()
        let page: [String: Any] = [
            "id": id.uuidString.lowercased(), "at": "2026-07-04T16:00:00Z", "isNote": true,
            "blocks": [["k": "text", "text": "Before the weekend"], ["k": "check", "text": "Lens cloth", "done": true]],
            "reminder": ["when": "2026-07-05T09:00:00Z", "done": false],   // the prototype's legacy shape
        ]
        let take = try TakeTranslation.core(from: page, existing: nil)
        XCTAssertEqual(take.id, id)
        XCTAssertEqual(take.createdAt, ISO8601.date(from: "2026-07-04T16:00:00.000Z"))
        XCTAssertEqual(take.blocks.count, 2)
        XCTAssertEqual(take.timeReminder?.notificationIdentifier, id.uuidString)
        XCTAssertEqual(take.timeReminder?.alarmEnabled, true)
        XCTAssertEqual(take.schemaVersion, Take.currentSchemaVersion)
        // And it reads back as the page wrote it.
        let back = try TakeTranslation.page(from: take)
        XCTAssertEqual((back["blocks"] as! [[String: Any]]).map { $0["text"] as? String }, ["Before the weekend", "Lens cloth"])
    }

    func testMovingAReminderClearsDelivered() throws {
        let take = try corpus()[3]   // delivered weekly reminder
        var page = try TakeTranslation.page(from: take)
        var r = page["reminder"] as! [String: Any]
        r["when"] = "2026-08-01T09:00:00Z"
        page["reminder"] = r
        XCTAssertEqual(try TakeTranslation.core(from: page, existing: take).timeReminder?.isDelivered, false)
    }

    func testPlaceReminderSurvivesAnEditAndCannotBeMadeOnTheMac() throws {
        let take = try corpus()[5]
        var page = try TakeTranslation.page(from: take)
        page["blocks"] = [["k": "text", "text": "Milk and bread"]]
        let edited = try TakeTranslation.core(from: page, existing: take)
        XCTAssertEqual(edited.locationReminder, take.locationReminder)

        var r = page["reminder"] as! [String: Any]
        r["name"] = "The flat"; r["mode"] = "arrive"; r["radius"] = 300.0
        r.removeValue(forKey: "lat"); r.removeValue(forKey: "lon")   // the picker rebuilds it without them
        page["reminder"] = r
        let moved = try TakeTranslation.core(from: page, existing: take).locationReminder
        XCTAssertEqual(moved?.locationName, "The flat")
        XCTAssertEqual(moved?.triggerOnArrival, true)
        XCTAssertEqual(moved?.radiusMetres, 300)
        XCTAssertEqual(moved?.latitude, take.locationReminder?.latitude)
        XCTAssertEqual(moved?.longitude, take.locationReminder?.longitude)

        var fresh = page
        fresh["id"] = UUID().uuidString
        XCTAssertThrowsError(try TakeTranslation.core(from: fresh, existing: nil))
    }

    func testRemovingAReminderRemovesIt() throws {
        let take = try corpus()[3]
        var page = try TakeTranslation.page(from: take)
        page.removeValue(forKey: "reminder")
        XCTAssertNil(try TakeTranslation.core(from: page, existing: take).timeReminder)
    }

    func testAnIDThatIsNotAUUIDIsRefused() {
        let page: [String: Any] = ["id": "t1719000000000", "at": "2026-07-04T16:00:00Z", "blocks": [], "isNote": true]
        XCTAssertThrowsError(try TakeTranslation.core(from: page, existing: nil)) {
            XCTAssertEqual($0 as? TakeTranslation.Failure, .badID("t1719000000000"))
        }
    }
}

// MARK: - Library: the page's whole-list save as store operations

final class LibraryTests: XCTestCase {
    private var dir: URL!
    private var library: Library!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-library-\(UUID())")
        let keys = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
        library = Library(store: try EncryptedTakeStore(keys: keys, directoryURL: dir),
                          scripts: try ScriptVault(keys: keys, directory: dir.appendingPathComponent("Scripts")))
    }

    override func tearDownWithError() throws {
        library = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func page(_ text: String, obie: Bool = false, id: UUID = UUID()) -> [String: Any] {
        ["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "obie": obie, "blocks": [["k": "text", "text": text]]]
    }

    func testSaveUpsertsChangesAndDeletesWhatThePageDropped() throws {
        let a = page("A"), b = page("B")
        XCTAssertEqual(try library.saveTakes([a, b]), Library.SaveReport(upserted: 2))
        XCTAssertEqual(try library.saveTakes([a, b]), Library.SaveReport(unchanged: 2))

        var a2 = a
        a2["blocks"] = [["k": "text", "text": "A, edited"]]
        XCTAssertEqual(try library.saveTakes([a2]), Library.SaveReport(upserted: 1, deleted: 1))
        XCTAssertEqual(try library.store.tombstones().map(\.id), [UUID(uuidString: b["id"] as! String)!])
        XCTAssertEqual(try library.pageTakes().count, 1)
    }

    func testDeletingTheLastTakeIsSaved() throws {
        _ = try library.saveTakes([page("A")])
        XCTAssertEqual(try library.saveTakes([]), Library.SaveReport(deleted: 1))
        XCTAssertEqual(try library.pageTakes().count, 0)
    }

    func testARejectedTakeKeepsItsStoredVersion() throws {
        var a = page("A")
        _ = try library.saveTakes([a])
        a["at"] = "not a date"
        let report = try library.saveTakes([a])
        XCTAssertEqual(report.rejected, [a["id"] as! String])
        XCTAssertEqual(report.deleted, 0)
        XCTAssertEqual(try library.pageTakes().count, 1)
    }

    func testMovingTheObieLeavesExactlyOne() throws {
        let first = page("First", obie: true), second = page("Second")
        _ = try library.saveTakes([first, second])
        var demoted = first, promoted = second
        demoted["obie"] = false
        promoted["obie"] = true
        _ = try library.saveTakes([demoted, promoted])
        let obies = try library.store.allTakes().filter(\.isObie)
        XCTAssertEqual(obies.map(\.id), [UUID(uuidString: second["id"] as! String)!])
    }

    // MARK: Saves diff against the page's snapshot, not the store (M3: sync writes the store too)

    /// What sync does to the store while the page holds its list: write a Take directly.
    private func syncWrites(_ item: [String: Any], modified: Date = Date(timeIntervalSinceNow: 60)) throws -> Take {
        let id = UUID(uuidString: item["id"] as! String)!
        var take = try TakeTranslation.core(from: item, existing: try library.store.take(id: id), now: modified)
        take.modifiedAt = modified
        try library.store.upsert(take)
        return try library.store.take(id: id)!
    }

    private func id(_ item: [String: Any]) -> UUID { UUID(uuidString: item["id"] as! String)! }

    func testATakeSyncAddedSurvivesASaveOfTheOlderList() throws {
        let a = page("A")
        _ = try library.saveTakes([a])
        let gen = try library.snapshot().generation
        let fromPhone = page("From the iPhone")
        _ = try syncWrites(fromPhone)

        var a2 = a
        a2["blocks"] = [["k": "text", "text": "A, edited"]]
        let report = try library.saveTakes([a2], generation: gen)
        XCTAssertEqual(report.upserted, 1)
        XCTAssertEqual(report.deleted, 0)
        XCTAssertNotNil(try library.store.take(id: id(fromPhone)), "a Take sync added is not the page's to delete")
    }

    func testATakeSyncUpdatedIsNotRevertedByTheStaleCopy() throws {
        let a = page("A"), b = page("B")
        _ = try library.saveTakes([a, b])
        let gen = try library.snapshot().generation
        var bRemote = b
        bRemote["blocks"] = [["k": "text", "text": "B, edited on the iPhone"]]
        _ = try syncWrites(bRemote)

        var a2 = a
        a2["blocks"] = [["k": "text", "text": "A, edited"]]
        let report = try library.saveTakes([a2, b], generation: gen)   // b as the page last saw it
        XCTAssertEqual(report, Library.SaveReport(upserted: 1, unchanged: 1))
        XCTAssertEqual(try library.store.take(id: id(b))?.plainText, "B, edited on the iPhone")
    }

    func testBothSidesChangedKeepsBoth() throws {
        let a = page("A")
        _ = try library.saveTakes([a])
        let gen = try library.snapshot().generation
        var remote = a
        remote["blocks"] = [["k": "text", "text": "A, from the iPhone"]]
        _ = try syncWrites(remote)

        var mine = a
        mine["blocks"] = [["k": "text", "text": "A, from the Mac"]]
        let report = try library.saveTakes([mine], generation: gen)
        XCTAssertEqual(report.keptBoth.count, 1)
        XCTAssertEqual(try library.store.take(id: id(a))?.plainText, "A, from the Mac")
        XCTAssertEqual(try library.store.take(id: report.keptBoth[0])?.plainText, "A, from the iPhone")
        XCTAssertEqual(try library.store.allTakes().count, 2)
    }

    func testDeletingATakeSyncChangedKeepsTheChange() throws {
        let a = page("A"), b = page("B")
        _ = try library.saveTakes([a, b])
        let gen = try library.snapshot().generation
        var bRemote = b
        bRemote["blocks"] = [["k": "text", "text": "B, edited on the iPhone"]]
        _ = try syncWrites(bRemote)

        let report = try library.saveTakes([a], generation: gen)   // the page deleted b
        XCTAssertEqual(report.deleted, 0)
        XCTAssertEqual(report.keptOverDelete, [id(b)])
        XCTAssertEqual(try library.store.take(id: id(b))?.plainText, "B, edited on the iPhone")
    }

    func testASaveFromTheOlderSnapshotIsDiffedAgainstIt() throws {
        let a = page("A")
        _ = try library.saveTakes([a])
        let older = try library.snapshot().generation
        let fromPhone = page("From the iPhone")
        _ = try syncWrites(fromPhone)
        let newer = try library.snapshot().generation   // the page asked for a refresh...
        XCTAssertGreaterThan(newer, older)

        // ...but a save it sent before the refresh arrived still describes the older list.
        let report = try library.saveTakes([a], generation: older)
        XCTAssertEqual(report, Library.SaveReport(unchanged: 1))
        XCTAssertNotNil(try library.store.take(id: id(fromPhone)))
    }

    func testASnapshotTooOldIsRefusedAndWritesNothing() throws {
        let a = page("A")
        _ = try library.saveTakes([a])
        let oldest = try library.snapshot().generation
        for _ in 0..<8 { _ = try library.snapshot() }
        XCTAssertThrowsError(try library.saveTakes([], generation: oldest)) {
            XCTAssertEqual($0 as? Library.Failure, .staleSnapshot(oldest))
        }
        XCTAssertEqual(try library.store.allTakes().count, 1)
    }

    func testATakeSyncDeletedIsNotBroughtBackByLaterSaves() throws {
        let a = page("A"), b = page("B")
        _ = try library.saveTakes([a, b])
        let gen = try library.snapshot().generation
        try library.store.delete(id: id(b))   // sync applied another device's deletion

        var a2 = a
        a2["blocks"] = [["k": "text", "text": "A, edited"]]
        _ = try library.saveTakes([a2, b], generation: gen)   // the page still lists b
        var a3 = a2
        a3["blocks"] = [["k": "text", "text": "A, edited again"]]
        _ = try library.saveTakes([a3, b], generation: gen)
        XCTAssertNil(try library.store.take(id: id(b)), "a Take deleted elsewhere stays deleted")
    }

    func testGenerationsNeverRepeatAcrossLibraries() throws {
        let first = try library.snapshot().generation
        let keys = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
        let other = Library(store: try EncryptedTakeStore(keys: keys, directoryURL: dir.appendingPathComponent("other")),
                            scripts: try ScriptVault(keys: keys, directory: dir.appendingPathComponent("other/Scripts")))
        XCTAssertGreaterThan(try other.snapshot().generation, first)
        XCTAssertThrowsError(try other.saveTakes([], generation: first), "another library's snapshot is never diffed against")
    }

    func testMovingTheObieIsNotReadAsAChangeElsewhere() throws {
        let first = page("First", obie: true), second = page("Second")
        _ = try library.saveTakes([first, second])
        let gen = try library.snapshot().generation
        var promoted = second
        promoted["obie"] = true
        var demoted = first
        demoted["obie"] = false
        _ = try library.saveTakes([demoted, promoted], generation: gen)
        // The store demoted `first` itself; the page's next edit of it is the only change.
        var edited = demoted
        edited["blocks"] = [["k": "text", "text": "First, edited"]]
        let report = try library.saveTakes([edited, promoted], generation: gen)
        XCTAssertEqual(report.keptBoth, [])
        XCTAssertEqual(report.upserted, 1)
        XCTAssertEqual(try library.store.allTakes().count, 2)
    }
}

// MARK: - Scripts: sealed on disk, one file each

final class ScriptVaultTests: XCTestCase {
    func testScriptsRoundTripSealedAndAreRemovedWhenDropped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-scripts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try ScriptVault(keys: KeyHierarchy(masterKey: SymmetricKey(size: .bits256)), directory: dir)
        let a: [String: Any] = ["id": UUID().uuidString, "at": "2026-06-12", "mode": "a4", "blocks": ["# Plan", "| a | b |\n|---|---|\n| 1 | 2 |", "- [x] done"]]
        let b: [String: Any] = ["id": UUID().uuidString, "at": "2026-07-03", "mode": "continuous", "blocks": ["Secret word: aubergine"]]
        try vault.replaceAll(with: [a, b])

        let back = try vault.all()
        XCTAssertEqual(back.count, 2)
        XCTAssertTrue(NSDictionary(dictionary: back[0]).isEqual(to: a))
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            XCTAssertNil(try String(data: Data(contentsOf: file), encoding: .utf8).flatMap { $0.contains("aubergine") ? $0 : nil },
                         "a Script is on disk as plain-text")
        }

        try vault.replaceAll(with: [b])
        XCTAssertEqual(try vault.all().map { $0["id"] as? String }, [b["id"] as? String])
    }

    /// Greptile on #43: one damaged Script made the whole library unreadable.
    func testADamagedScriptIsSkippedAndKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-scripts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try ScriptVault(keys: KeyHierarchy(masterKey: SymmetricKey(size: .bits256)), directory: dir)
        let good: [String: Any] = ["id": UUID().uuidString, "at": "2026-06-12", "mode": "a4", "blocks": ["Fine"]]
        try vault.replaceAll(with: [good])
        let damaged = dir.appendingPathComponent("\(UUID().uuidString.lowercased()).sealed")
        try Data("not a sealed box".utf8).write(to: damaged)

        XCTAssertEqual(try vault.all().map { $0["id"] as? String }, [good["id"] as? String])
        try vault.replaceAll(with: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path), "a damaged Script is never deleted")
    }

    func testAScriptFileDoesNotOpenUnderAnotherID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-scripts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try ScriptVault(keys: KeyHierarchy(masterKey: SymmetricKey(size: .bits256)), directory: dir)
        let id = UUID()
        let sealed = try vault.seal(["id": id.uuidString, "blocks": ["x"]], id: id)
        XCTAssertThrowsError(try vault.open(sealed, id: UUID()))
    }
}

// MARK: - Vault: first run, relaunch, and the phrase the iPhone would derive the same key from

final class VaultTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-vault-\(UUID())/Catchlight")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    func testNewPhraseIsTwelveDistinctValidWords() throws {
        let words = try Vault.newPhrase()
        XCTAssertEqual(words.count, 12)
        XCTAssertEqual(Set(words).count, 12)
        XCTAssertTrue(Vault.isValid(words))
        // Fixed vectors, not a shuffled phrase: the checksum is 4 bits, so 1 in 16 reorderings
        // still pass (this test failed that way once in four runs).
        XCTAssertTrue(Vault.isValid(Array(repeating: "abandon", count: 11) + ["about"]))
        XCTAssertFalse(Vault.isValid(Array(repeating: "abandon", count: 12)), "a wrong last word fails its checksum")
        XCTAssertFalse(Vault.isValid(Array(words.dropLast())))
    }

    func testFirstRunThenRelaunchOpensTheSameLibrary() throws {
        let secrets = MemorySecrets()
        let words = try Vault.newPhrase()
        let vault = Vault(secrets: secrets, directory: dir)
        XCTAssertEqual("\(try vault.start())", "\(Vault.State.noAccount)")
        try vault.createAccount(words: words, restored: false)
        XCTAssertEqual(secrets.phrase(reason: ""), words)
        let id = UUID()
        _ = try vault.library!.saveTakes([["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "blocks": [["k": "text", "text": "Kept"]]]])

        // Relaunch: a new Vault on the same folder and secrets.
        XCTAssertNotNil(try vault.library?.store.take(id: id), "the running app stays on the old account")
        let again = Vault(secrets: secrets, directory: dir)
        try again.start()
        XCTAssertNotNil(try again.library!.store.take(id: id))
        XCTAssertEqual(try again.library!.pageTakes().first?["id"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testTheKeyIsTheOneThePhraseDerivesEverywhere() throws {
        let secrets = MemorySecrets()
        let words = try Vault.newPhrase()
        try Vault(secrets: secrets, directory: dir).createAccount(words: words, restored: false)
        let stored = try secrets.masterKey(reason: "").withUnsafeBytes { Data($0) }
        XCTAssertEqual(stored, MasterKeyDerivation.deriveRaw(from: words))
    }

    func testRestoreWithTheSamePhraseReadsTheLibraryAndANewPhraseMovesItAside() throws {
        let words = try Vault.newPhrase()
        let first = Vault(secrets: MemorySecrets(), directory: dir)
        try first.createAccount(words: words, restored: false)
        let id = UUID()
        _ = try first.library!.saveTakes([["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "blocks": [["k": "text", "text": "Mine"]]]])

        // The Keychain is gone (a new Mac user, say), the folder is not: the same phrase reads it.
        let restored = Vault(secrets: MemorySecrets(), directory: dir)
        try restored.createAccount(words: words, restored: true)
        XCTAssertNotNil(try restored.library!.store.take(id: id))

        // A different phrase can't read it, so it is moved aside, never deleted.
        let fresh = Vault(secrets: MemorySecrets(), directory: dir)
        try fresh.createAccount(words: try Vault.newPhrase(), restored: false)
        XCTAssertEqual(try fresh.library!.store.allTakes().count, 0)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("Catchlight-before-") }, "\(siblings)")
    }

    /// Greptile on #43: `restored` comes from the page, so a phrase that can't open the library
    /// on disk must move it aside rather than leave it under a key the app no longer holds.
    func testARestoreWithAPhraseThatDoesNotOpenTheLibraryMovesItAside() throws {
        let first = Vault(secrets: MemorySecrets(), directory: dir)
        try first.createAccount(words: try Vault.newPhrase(), restored: false)
        _ = try first.library!.saveTakes([["id": UUID().uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "blocks": [["k": "text", "text": "Other account"]]]])

        let other = Vault(secrets: MemorySecrets(), directory: dir)
        try other.createAccount(words: try Vault.newPhrase(), restored: true)
        XCTAssertEqual(try other.library!.store.allTakes().count, 0)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("Catchlight-before-") }, "\(siblings)")
    }

    /// Greptile on #43: Second device erased the old account before the new one existed.
    func testReplaceAccountErasesNothingFirst() throws {
        let secrets = MemorySecrets()
        let words = try Vault.newPhrase()
        let vault = Vault(secrets: secrets, directory: dir)
        try vault.createAccount(words: words, restored: false)
        let id = UUID()
        _ = try vault.library!.saveTakes([["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "blocks": [["k": "text", "text": "Mine"]]]])

        // The same account again: the library stays.
        try vault.replaceAccount(words: words)
        XCTAssertNotNil(try vault.library!.store.take(id: id))

        // Another account: the old library is moved aside, not deleted, and the secrets are the new ones.
        let other = try Vault.newPhrase()
        try vault.replaceAccount(words: other)
        XCTAssertEqual(secrets.phrase(reason: ""), other)
        XCTAssertEqual(try vault.library!.store.allTakes().count, 0)
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path).first { $0.hasPrefix("Catchlight-before-") }
        let moved = try XCTUnwrap(aside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent(moved).appendingPathComponent("Database/catchlight.db").path))
    }

    /// Owner, 2026-10-04: a launch asked for the password twice, once for the existence check
    /// and once for the key. Launch now makes one call that can prompt, and a missing key is
    /// no account without any.
    func testLaunchAsksForTheKeyOnceAndNeverChecksExistenceFirst() throws {
        final class Counting: Secrets {
            let inner = MemorySecrets()
            var existenceChecks = 0, keyRequests = 0
            var hasAccount: Bool { existenceChecks += 1; return inner.hasAccount }
            func storePhrase(_ words: [String]) throws { try inner.storePhrase(words) }
            func storeMasterKey(_ raw: Data) throws { try inner.storeMasterKey(raw) }
            func masterKey(reason: String) throws -> SymmetricKey { keyRequests += 1; return try inner.masterKey(reason: reason) }
            func phrase(reason: String) -> [String]? { inner.phrase(reason: reason) }
            func deleteMasterKey() { inner.deleteMasterKey() }
            func deleteAll() { inner.deleteAll() }
        }
        let secrets = Counting()
        XCTAssertEqual("\(try Vault(secrets: secrets, directory: dir).start())", "\(Vault.State.noAccount)")
        try Vault(secrets: secrets, directory: dir).createAccount(words: try Vault.newPhrase(), restored: false)
        secrets.existenceChecks = 0; secrets.keyRequests = 0

        let vault = Vault(secrets: secrets, directory: dir)
        try vault.start()
        XCTAssertNotNil(vault.library)
        XCTAssertEqual(secrets.keyRequests, 1)
        XCTAssertEqual(secrets.existenceChecks, 0)
    }

    /// #43 review: a failed Keychain write left the old library moved aside under the old key.
    func testAFailedKeychainWritePutsTheOldLibraryBack() throws {
        final class FailingKey: Secrets {
            let inner = MemorySecrets(); var failKey = false
            var hasAccount: Bool { inner.hasAccount }
            func storePhrase(_ words: [String]) throws { try inner.storePhrase(words) }
            func storeMasterKey(_ raw: Data) throws { if failKey { throw KeychainError.storeFailed(-1) }; try inner.storeMasterKey(raw) }
            func masterKey(reason: String) throws -> SymmetricKey { try inner.masterKey(reason: reason) }
            func phrase(reason: String) -> [String]? { inner.phrase(reason: reason) }
            func deleteMasterKey() { inner.deleteMasterKey() }
            func deleteAll() { inner.deleteAll() }
        }
        let secrets = FailingKey()
        let vault = Vault(secrets: secrets, directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: false)
        let id = UUID()
        _ = try vault.library!.saveTakes([["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "blocks": [["k": "text", "text": "Mine"]]]])

        let oldPhrase = secrets.phrase(reason: "")
        secrets.failKey = true
        XCTAssertThrowsError(try vault.replaceAccount(words: try Vault.newPhrase()))
        XCTAssertEqual(secrets.phrase(reason: ""), oldPhrase, "the phrase still matches the key")
        let again = Vault(secrets: secrets, directory: dir)
        try again.start()
        XCTAssertNotNil(try again.library!.store.take(id: id), "the old key opens its library where it was")
    }

    /// #43 review (Greptile): a library holding only Scripts passed the restore check under any key.
    func testAScriptsOnlyLibraryUnderAnotherKeyIsMovedAside() throws {
        let first = Vault(secrets: MemorySecrets(), directory: dir)
        try first.createAccount(words: try Vault.newPhrase(), restored: false)
        try first.library!.saveScripts([["id": UUID().uuidString, "at": "2026-06-12", "mode": "a4", "blocks": ["Theirs"]]])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Database"))

        let other = Vault(secrets: MemorySecrets(), directory: dir)
        try other.createAccount(words: try Vault.newPhrase(), restored: true)
        XCTAssertEqual(try other.library!.pageScripts().count, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path).contains { $0.hasPrefix("Catchlight-before-") })
    }

    /// #44 review: the phrase write failing after the key was replaced must put the old key back.
    func testAFailedPhraseWriteOnReplacePutsTheOldKeyBack() throws {
        final class FailingPhrase: Secrets {
            let inner = MemorySecrets(); var failPhrase = false
            var hasAccount: Bool { inner.hasAccount }
            func storePhrase(_ words: [String]) throws { if failPhrase { throw KeychainError.storeFailed(-1) }; try inner.storePhrase(words) }
            func storeMasterKey(_ raw: Data) throws { try inner.storeMasterKey(raw) }
            func masterKey(reason: String) throws -> SymmetricKey { try inner.masterKey(reason: reason) }
            func phrase(reason: String) -> [String]? { inner.phrase(reason: reason) }
            func deleteMasterKey() { inner.deleteMasterKey() }
            func deleteAll() { inner.deleteAll() }
        }
        let secrets = FailingPhrase()
        let words = try Vault.newPhrase()
        let vault = Vault(secrets: secrets, directory: dir)
        try vault.createAccount(words: words, restored: false)
        secrets.failPhrase = true
        XCTAssertThrowsError(try vault.replaceAccount(words: try Vault.newPhrase()))
        let key = try secrets.masterKey(reason: "").withUnsafeBytes { Data($0) }
        XCTAssertEqual(key, MasterKeyDerivation.deriveRaw(from: words), "the key matches the phrase that was kept")
        XCTAssertEqual(secrets.phrase(reason: ""), words)
    }

    /// #44 review: when the old key can't be put back either, the new key goes, so the phrase the
    /// owner has still restores the library.
    func testAFailedRollbackLeavesNoKeyRatherThanAMismatchedOne() throws {
        final class FailingBoth: Secrets {
            let inner = MemorySecrets(); var failing = false; var keyWrites = 0
            var hasAccount: Bool { inner.hasAccount }
            func storePhrase(_ words: [String]) throws { if failing { throw KeychainError.storeFailed(-1) }; try inner.storePhrase(words) }
            func storeMasterKey(_ raw: Data) throws {
                keyWrites += 1
                if failing && keyWrites > 1 { throw KeychainError.storeFailed(-2) }   // the rollback write fails
                try inner.storeMasterKey(raw)
            }
            func masterKey(reason: String) throws -> SymmetricKey { try inner.masterKey(reason: reason) }
            func phrase(reason: String) -> [String]? { inner.phrase(reason: reason) }
            func deleteMasterKey() { inner.deleteMasterKey() }
            func deleteAll() { inner.deleteAll() }
        }
        let secrets = FailingBoth()
        let words = try Vault.newPhrase()
        let vault = Vault(secrets: secrets, directory: dir)
        try vault.createAccount(words: words, restored: false)
        let id = UUID()
        _ = try vault.library!.saveTakes([["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "blocks": [["k": "text", "text": "Mine"]]]])
        secrets.failing = true; secrets.keyWrites = 0
        XCTAssertThrowsError(try vault.replaceAccount(words: try Vault.newPhrase())) {
            guard case Vault.Failure.restoreNeeded = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertNil(vault.library, "the session closes with the key, so nothing more is written")
        XCTAssertFalse(secrets.hasAccount, "no key is left beside the old phrase")
        XCTAssertEqual(secrets.phrase(reason: ""), words)

        // Next launch: first run; restoring with the phrase the owner has reopens the library.
        secrets.failing = false
        let next = Vault(secrets: secrets, directory: dir)
        XCTAssertEqual("\(try next.start())", "\(Vault.State.noAccount)")
        try next.createAccount(words: words, restored: true)
        XCTAssertNotNil(try next.library!.store.take(id: id))
    }

    /// #44 review: damaged Scripts must not move readable Takes aside on a correct-phrase restore.
    func testDamagedScriptsDoNotHideReadableTakes() throws {
        let words = try Vault.newPhrase()
        let first = Vault(secrets: MemorySecrets(), directory: dir)
        try first.createAccount(words: words, restored: false)
        let id = UUID()
        _ = try first.library!.saveTakes([["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "blocks": [["k": "text", "text": "Readable"]]]])
        try Data("damaged".utf8).write(to: first.library!.scripts.directory.appendingPathComponent("\(UUID().uuidString.lowercased()).sealed"))

        let restored = Vault(secrets: MemorySecrets(), directory: dir)
        try restored.createAccount(words: words, restored: true)
        XCTAssertNotNil(try restored.library!.store.take(id: id))
    }

    /// #43 review: Erase left moved-aside libraries behind.
    func testEraseEverythingAlsoRemovesLibrariesMovedAside() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: false)
        _ = try vault.library!.saveTakes([["id": UUID().uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "blocks": [["k": "text", "text": "Old"]]]])
        try vault.createAccount(words: try Vault.newPhrase(), restored: false)   // moves the first aside
        try vault.eraseEverything()
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path)
        XCTAssertFalse(left.contains { $0.hasPrefix("Catchlight") }, "\(left)")
    }

    /// #44 review: a failed erase must leave the account open, not report no account.
    func testAFailedEraseKeepsTheAccountOpen() throws {
        let secrets = MemorySecrets()
        let vault = Vault(secrets: secrets, directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: false)
        let parent = dir.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)   // can't remove children
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        XCTAssertThrowsError(try vault.eraseEverything())
        XCTAssertNotNil(vault.library)
        XCTAssertTrue(secrets.hasAccount)
    }

    func testAnInvalidPhraseStoresNothing() throws {
        let secrets = MemorySecrets()
        XCTAssertThrowsError(try Vault(secrets: secrets, directory: dir).createAccount(words: ["abandon"], restored: false))
        XCTAssertFalse(secrets.hasAccount)
        XCTAssertNil(secrets.phrase(reason: ""))
    }

    func testEraseEverythingLeavesNoAccountAndNoLibrary() throws {
        let secrets = MemorySecrets()
        let vault = Vault(secrets: secrets, directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: false)
        try vault.eraseEverything()
        XCTAssertFalse(secrets.hasAccount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
