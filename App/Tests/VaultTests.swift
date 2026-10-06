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

// MARK: - ScriptTranslation: the page's Script ⇄ a Core Take of kind Script

final class ScriptTranslationTests: XCTestCase {
    /// Every shape the Script editor writes (ui/app.js classify): one line each, or a fenced code
    /// block or table kept whole.
    private let every: [String] = [
        "# Title", "## Heading", "### Subheading", "Body with **bold**, *italic*, ~~strike~~ and `code`.",
        "- A bullet", "* Another bullet", "1. A numbered line", "> A quote", "---",
        "```\nlet x = 1\n\nprint(x)\n```", "| a | b |\n|---|---|\n| 1 | 2 |",
        "A [link](https://catchlight.app) in a line", "- [ ] Still to do", "- [x] Done", "", "Last line",
    ]

    private func page(_ blocks: [String], mode: String = "a4", id: UUID = UUID()) -> [String: Any] {
        ["id": id.uuidString.lowercased(), "at": "2026-07-03T08:30:00.000Z", "mode": mode, "blocks": blocks]
    }

    func testEveryShapeRoundTripsExactly() throws {
        let p = page(every)
        let core = try ScriptTranslation.core(from: p, existing: nil)
        XCTAssertTrue(core.isScript)
        XCTAssertEqual(core.blocks.count, every.count, "one Core block per page block")
        let back = ScriptTranslation.page(from: core)
        XCTAssertEqual(back["blocks"] as? [String], every)
        XCTAssertEqual(back["mode"] as? String, "a4")
        XCTAssertEqual(back["at"] as? String, "2026-07-03T08:30:00.000Z")
        XCTAssertEqual(back["id"] as? String, p["id"] as? String)
    }

    func testChecklistLinesAreChecklistItems() throws {
        let core = try ScriptTranslation.core(from: page(["- [ ] Frame size", "- [x] Paper", "-[ ] not a check", "- [ ]"]), existing: nil)
        guard case .check(let open) = core.blocks[0], case .check(let done) = core.blocks[1] else { return XCTFail("checks") }
        XCTAssertEqual(open.text, "Frame size"); XCTAssertFalse(open.isComplete)
        XCTAssertEqual(done.text, "Paper"); XCTAssertTrue(done.isComplete)
        guard case .text = core.blocks[2], case .text = core.blocks[3] else { return XCTFail("anything else stays text") }
    }

    func testContinuousIsNoPageMode() throws {
        let core = try ScriptTranslation.core(from: page(["x"], mode: "continuous"), existing: nil)
        XCTAssertNil(core.pageMode)
        XCTAssertEqual(ScriptTranslation.page(from: core)["mode"] as? String, "continuous")
        XCTAssertEqual(try ScriptTranslation.core(from: page(["x"], mode: "letter"), existing: nil).pageMode, Take.PageMode.usLetter)
    }

    func testAnUnchangedSaveIsIdenticalAndAnEditMovesModifiedAt() throws {
        let p = page(["# Plan", "- [ ] Frame size"])
        let first = try ScriptTranslation.core(from: p, existing: nil, now: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(try ScriptTranslation.core(from: ScriptTranslation.page(from: first), existing: first, now: Date(timeIntervalSince1970: 1_790_000_000)), first)

        var edited = p
        edited["blocks"] = ["# Plan", "- [x] Frame size"]
        let later = Date(timeIntervalSince1970: 1_790_000_000)
        let second = try ScriptTranslation.core(from: edited, existing: first, now: later)
        XCTAssertEqual(second.modifiedAt, later)
        XCTAssertEqual(second.blocks.map(\.id), first.blocks.map(\.id), "block ids are kept")
    }

    func testADateOnlyScriptKeepsItsStoredMoment() throws {
        let stored = try ScriptTranslation.core(from: page(["x"]), existing: nil)
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.timeZone = .current
        var p = ScriptTranslation.page(from: stored)
        p["at"] = day.string(from: stored.createdAt)
        XCTAssertEqual(try ScriptTranslation.core(from: p, existing: stored).createdAt, stored.createdAt)
    }

    func testAnIDThatIsNotAUUIDIsRefused() {
        XCTAssertThrowsError(try ScriptTranslation.core(from: ["id": "s1", "at": "2026-06-12", "mode": "a4", "blocks": ["x"]], existing: nil))
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

    private func script(_ text: String, id: UUID = UUID()) -> [String: Any] {
        ["id": id.uuidString, "at": "2026-07-01T09:00:00.000Z", "mode": "a4", "blocks": [text]]
    }

    /// M3b: Takes and Scripts share the store, and each list's save touches only its own kind.
    func testATakesSaveNeverDeletesAScriptAndTheOtherWayRound() throws {
        let t = page("A Take"), s = script("# A Script")
        try library.saveTakes([t])
        try library.saveScripts([s])
        XCTAssertEqual(try library.saveTakes([t]), Library.SaveReport(unchanged: 1))
        XCTAssertEqual(try library.saveScripts([]), Library.SaveReport(deleted: 1))
        XCTAssertEqual(try library.pageTakes().count, 1, "deleting the last Script left the Take")
        try library.saveScripts([script("# Another")])
        XCTAssertEqual(try library.saveTakes([]), Library.SaveReport(deleted: 1))
        XCTAssertEqual(try library.pageScripts().count, 1, "deleting the last Take left the Script")
    }

    /// M3b step 2 (D-313): Take ⇄ Script is a change of kind on the same id. No copy, no
    /// deletion record, and neither list's next save reads it as deleted or as new.
    func testTakeToScriptAndBackIsAChangeOfKindOnTheSameId() throws {
        let id = UUID()
        try library.saveTakes([page("Captured\n- [ ] not a check here", id: id)])
        let gen = try library.snapshot().generation
        let blockID = try XCTUnwrap(try library.store.take(id: id)).blocks.first?.id

        let asScript = script("# Captured", id: id)
        try library.changeKind(asScript, to: .scripts)
        let stored = try XCTUnwrap(try library.store.take(id: id))
        XCTAssertTrue(stored.isScript)
        XCTAssertEqual(stored.blocks.first?.id, blockID, "block ids are kept")
        XCTAssertEqual(try library.store.tombstones().count, 0)
        // The page's next saves, from the snapshot it held before: nothing deleted, nothing new.
        XCTAssertEqual(try library.saveTakes([], generation: gen), Library.SaveReport())
        XCTAssertEqual(try library.saveScripts([asScript], generation: gen), Library.SaveReport(unchanged: 1))
        XCTAssertEqual(try library.pageScripts().count, 1)
        XCTAssertEqual(try library.pageTakes().count, 0)

        var asTake = page("# Captured", id: id)
        asTake["modifiedAt"] = Date().timeIntervalSince1970 * 1000
        try library.changeKind(asTake, to: .takes)
        XCTAssertNil(try library.store.take(id: id)?.kind)
        XCTAssertNil(try library.store.take(id: id)?.pageMode)
        XCTAssertEqual(try library.saveScripts([]), Library.SaveReport())
        XCTAssertEqual(try library.pageTakes().map { $0["id"] as? String }, [id.uuidString.lowercased()])
        XCTAssertEqual(try library.store.tombstones().count, 0)
    }

    /// Code review: a change of kind made from a list older than a sync change must not write
    /// over that change unseen; the other version goes to the conflict screen first, as a save's does.
    func testAChangeOfKindFromAStaleListKeepsTheSyncedVersion() throws {
        let id = UUID()
        try library.saveTakes([page("Captured", id: id)])
        let gen = try library.snapshot().generation
        var synced = try XCTUnwrap(try library.store.take(id: id))
        synced.blocks = [.text(TextBlock(text: "Captured, edited on the iPhone"))]
        synced.modifiedAt = Date()
        try library.store.upsert(synced)   // sync, while the page holds the older list

        var kept: [(local: Take, remote: Take)] = []
        try library.changeKind(script("# Captured", id: id), to: .scripts, generation: gen, keepConflict: { kept.append($0) })
        XCTAssertEqual(kept.first?.remote.plainText, "Captured, edited on the iPhone")
        XCTAssertTrue(kept.first?.local.isScript ?? false)
    }

    /// Greptile on #56: what a Take carries beyond its text (a reminder, Important, its place in
    /// a manual order) survives being a Script and coming back.
    func testATakeMadeAScriptAndBackKeepsItsReminderAndImportant() throws {
        let id = UUID()
        var take = page("Call the framer", id: id)
        take["isImportant"] = true
        take["manualOrder"] = 42.0
        take["reminder"] = ["kind": "time", "when": "2026-12-01T09:00:00.000Z", "done": false, "allDay": false,
                            "notify": true, "repeat": "none", "weekdays": [Int]()]
        try library.saveTakes([take])
        try library.changeKind(script("Call the framer", id: id), to: .scripts)
        // The page's Take from a Script carries only its text, as takeFromScript makes it.
        let back = try library.changeKind(["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true,
                                           "blocks": [["k": "text", "text": "Call the framer, today"]]], to: .takes)
        XCTAssertNotNil(back.timeReminder)
        XCTAssertTrue(back.isImportant)
        XCTAssertEqual(back.manualOrder, 42)
        XCTAssertEqual(back.plainText, "Call the framer, today")
    }

    func testAScriptIsNeverTheObie() throws {
        let id = UUID()
        try library.saveTakes([page("The one", obie: true, id: id)])
        try library.changeKind(script("The one", id: id), to: .scripts)
        XCTAssertFalse(try XCTUnwrap(try library.store.take(id: id)).isObie)
    }

    /// While Scripts don't sync, a Script's deletion stays on this Mac: no record goes to the folder.
    func testAScriptDeletedWhileScriptsDontSyncLeavesNoDeletionRecord() throws {
        let s = script("Mac only")
        try library.saveScripts([s])
        XCTAssertEqual(try library.saveScripts([], syncing: false), Library.SaveReport(deleted: 1))
        XCTAssertEqual(try library.store.tombstones().count, 0)
        try library.saveScripts([script("Synced")])
        try library.saveScripts([])
        XCTAssertEqual(try library.store.tombstones().count, 1, "with Scripts syncing, the deletion goes out")
    }

    func testAScriptSyncAddedSurvivesASaveOfTheOlderList() throws {
        let mine = script("Mine")
        try library.saveScripts([mine])
        let gen = try library.snapshot().generation
        let theirs = try ScriptTranslation.core(from: script("Theirs"), existing: nil)
        try library.store.upsert(theirs)   // sync, while the page holds the older list
        XCTAssertEqual(try library.saveScripts([mine], generation: gen), Library.SaveReport(unchanged: 1))
        XCTAssertNotNil(try library.store.take(id: theirs.id))
    }

    func testAScriptChangedHereAndBySyncGoesToTheConflictScreen() throws {
        let id = UUID()
        try library.saveScripts([script("Draft", id: id)])
        let gen = try library.snapshot().generation
        var elsewhere = try XCTUnwrap(try library.store.take(id: id))
        elsewhere.blocks = [.text(TextBlock(text: "Draft, edited elsewhere"))]
        elsewhere.modifiedAt = Date()
        try library.store.upsert(elsewhere)
        var kept: [(local: Take, remote: Take)] = []
        let report = try library.saveScripts([script("Draft, edited here", id: id)], generation: gen, keepConflict: { kept.append($0) })
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertEqual(kept.first?.remote.plainText, "Draft, edited elsewhere")
        XCTAssertTrue(kept.first?.local.isScript ?? false)
    }

    /// Until Take ⇄ Script is a change of kind, a save naming an id the store holds as the
    /// other kind is refused for that item, so a copy can never write over it.
    func testAnIdOfTheOtherKindIsLeftAlone() throws {
        let id = UUID()
        try library.saveTakes([page("A Take", id: id)])
        let report = try library.saveScripts([script("Over it", id: id)])
        XCTAssertEqual(report.rejected, [id.uuidString])
        XCTAssertEqual(try library.store.take(id: id)?.kind, nil)
        XCTAssertEqual(try library.store.take(id: id)?.plainText, "A Take")
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

    func testBothSidesChangedGoesToTheConflictScreen() throws {
        let a = page("A")
        _ = try library.saveTakes([a])
        let gen = try library.snapshot().generation
        var remote = a
        remote["blocks"] = [["k": "text", "text": "A, from the iPhone"]]
        _ = try syncWrites(remote)

        var mine = a
        mine["blocks"] = [["k": "text", "text": "A, from the Mac"]]
        let report = try library.saveTakes([mine], generation: gen)
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertEqual(report.conflicts.first?.local.plainText, "A, from the Mac")
        XCTAssertEqual(report.conflicts.first?.remote.plainText, "A, from the iPhone")
        XCTAssertEqual(try library.store.take(id: id(a))?.plainText, "A, from the Mac", "the Mac's edit stands until the user chooses")
        XCTAssertEqual(try library.store.allTakes().count, 1)
    }

    /// #52 review (Greptile): the other version is kept before this Mac's edit replaces it; if
    /// keeping it fails, the save writes nothing and fails, so the page says so.
    func testAConflictThatCannotBeKeptStopsTheSave() throws {
        let a = page("A")
        _ = try library.saveTakes([a])
        let gen = try library.snapshot().generation
        var remote = a
        remote["blocks"] = [["k": "text", "text": "A, from the iPhone"]]
        _ = try syncWrites(remote)
        var mine = a
        mine["blocks"] = [["k": "text", "text": "A, from the Mac"]]
        struct Refused: Error {}
        XCTAssertThrowsError(try library.saveTakes([mine], generation: gen, keepConflict: { _ in throw Refused() }))
        XCTAssertEqual(try library.store.take(id: id(a))?.plainText, "A, from the iPhone", "nothing written")
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
        XCTAssertTrue(report.conflicts.isEmpty)
        XCTAssertEqual(report.upserted, 1)
        XCTAssertEqual(try library.store.allTakes().count, 2)
    }
}

// MARK: - Scripts saved before M3b: sealed files, moved into the library

final class ScriptVaultTests: XCTestCase {
    private var dir: URL!
    private let keys = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-scripts-\(UUID())")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func library() throws -> Library {
        Library(store: try EncryptedTakeStore(keys: keys, directoryURL: dir),
                scripts: try ScriptVault(keys: keys, directory: dir.appendingPathComponent("Scripts")))
    }

    /// A Script file as the Mac wrote it before M3b.
    @discardableResult
    private func writeOld(_ script: [String: Any], to vault: ScriptVault) throws -> URL {
        let id = UUID(uuidString: script["id"] as! String)!
        let url = vault.directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("sealed")
        try vault.seal(script, id: id).write(to: url)
        return url
    }

    func testOldScriptsMoveIntoTheLibraryWithTheirIdsAndTheFilesGo() throws {
        let lib = try library()
        let a: [String: Any] = ["id": UUID().uuidString, "at": "2026-06-12", "mode": "a4",
                                "blocks": ["# Plan", "| a | b |\n|---|---|\n| 1 | 2 |", "- [x] Paper stock", "- [ ] Frame size"]]
        let b: [String: Any] = ["id": UUID().uuidString, "at": "2026-07-03", "mode": "continuous", "blocks": ["Secret word: aubergine"]]
        let fileA = try writeOld(a, to: lib.scripts), fileB = try writeOld(b, to: lib.scripts)

        XCTAssertEqual(lib.moveScriptsIn(), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileB.path))

        let stored = try XCTUnwrap(try lib.store.take(id: UUID(uuidString: a["id"] as! String)!))
        XCTAssertTrue(stored.isScript)
        XCTAssertEqual(stored.pageMode, Take.PageMode.a4)
        XCTAssertEqual(stored.blocks.count, 4)
        guard case .check(let done) = stored.blocks[2], case .check(let open) = stored.blocks[3] else { return XCTFail("checklist lines are checklist items") }
        XCTAssertTrue(done.isComplete); XCTAssertEqual(done.text, "Paper stock")
        XCTAssertFalse(open.isComplete)
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.timeZone = .current
        XCTAssertEqual(day.string(from: stored.createdAt), "2026-06-12", "a date-only Script is that local day")

        let page = try lib.pageScripts()
        XCTAssertEqual(page.map { $0["blocks"] as? [String] }, [a["blocks"] as? [String], b["blocks"] as? [String]])
        XCTAssertEqual(page.map { $0["mode"] as? String }, ["a4", "continuous"])
        XCTAssertEqual(try lib.pageTakes().count, 0, "a Script is never one of the page's Takes")
        XCTAssertEqual(lib.moveScriptsIn(), 0, "nothing left to move")
    }

    /// Greptile on #43: one damaged Script made the whole library unreadable.
    func testADamagedScriptIsSkippedAndKept() throws {
        let lib = try library()
        let good: [String: Any] = ["id": UUID().uuidString, "at": "2026-06-12", "mode": "a4", "blocks": ["Fine"]]
        try writeOld(good, to: lib.scripts)
        let damaged = lib.scripts.directory.appendingPathComponent("\(UUID().uuidString.lowercased()).sealed")
        try Data("not a sealed box".utf8).write(to: damaged)

        XCTAssertEqual(lib.moveScriptsIn(), 1)
        XCTAssertEqual(lib.scripts.unreadable.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path), "a damaged Script is never deleted")
        XCTAssertEqual(try lib.pageScripts().count, 1)
    }

    func testAScriptFileWhoseIdIsATakeIsKept() throws {
        let lib = try library()
        let id = UUID()
        try lib.store.upsert(Take(id: id, createdAt: Date(), modifiedAt: Date(), blocks: [.text(TextBlock(text: "A Take"))]))
        let file = try writeOld(["id": id.uuidString, "at": "2026-06-12", "mode": "a4", "blocks": ["A Script"]], to: lib.scripts)

        XCTAssertEqual(lib.moveScriptsIn(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(try lib.store.take(id: id)?.kind, "the Take is left alone")
    }

    func testAScriptFileDoesNotOpenUnderAnotherID() throws {
        let vault = try ScriptVault(keys: keys, directory: dir)
        let id = UUID()
        let sealed = try vault.seal(["id": id.uuidString, "blocks": ["x"]], id: id)
        XCTAssertThrowsError(try vault.open(sealed, id: UUID()))
    }

    func testAnOldScriptFileIsNotPlainText() throws {
        let vault = try ScriptVault(keys: keys, directory: dir)
        let url = try writeOld(["id": UUID().uuidString, "at": "2026-07-03", "mode": "continuous", "blocks": ["Secret word: aubergine"]], to: vault)
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("aubergine"))
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
        // A Scripts file as the Mac kept them before M3b, and no Takes.
        let id = UUID()
        try first.library!.scripts.seal(["id": id.uuidString, "at": "2026-06-12", "mode": "a4", "blocks": ["Theirs"]], id: id)
            .write(to: first.library!.scripts.directory.appendingPathComponent("\(id.uuidString.lowercased()).sealed"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Database"))

        let other = Vault(secrets: MemorySecrets(), directory: dir)
        try other.createAccount(words: try Vault.newPhrase(), restored: true)
        XCTAssertEqual(try other.library!.pageScripts().count, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path).contains { $0.hasPrefix("Catchlight-before-") })
    }

    /// M3b: Scripts live in the store now, so a library holding only Scripts there is checked as
    /// Takes are.
    func testAScriptsOnlyStoreUnderAnotherKeyIsMovedAside() throws {
        let first = Vault(secrets: MemorySecrets(), directory: dir)
        try first.createAccount(words: try Vault.newPhrase(), restored: false)
        try first.library!.saveScripts([["id": UUID().uuidString, "at": "2026-06-12T09:00:00.000Z", "mode": "a4", "blocks": ["Theirs"]]])
        XCTAssertEqual(try first.library!.store.allTakes().count, 1)

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

// MARK: - A store that fails on demand

/// Delegates to a real store and throws from `upsert` once `failUpserts` is set.
private final class FailingStore: TakeStore {
    struct Refused: Error {}
    let real: TakeStore
    var failUpserts = false
    private(set) var allTakesReads = 0
    init(_ real: TakeStore) { self.real = real }
    func upsert(_ take: Take) throws { if failUpserts { throw Refused() }; try real.upsert(take) }
    func delete(id: UUID) throws { try real.delete(id: id) }
    func take(id: UUID) throws -> Take? { try real.take(id: id) }
    func allTakes() throws -> [Take] { allTakesReads += 1; return try real.allTakes() }
    func takesModified(since date: Date?) throws -> [Take] { try real.takesModified(since: date) }
    func search(_ query: String) throws -> [Take] { try real.search(query) }
    func upsert(_ sequence: CatchlightSequence) throws { try real.upsert(sequence) }
    func sequence(id: UUID) throws -> CatchlightSequence? { try real.sequence(id: id) }
    func allSequences() throws -> [CatchlightSequence] { try real.allSequences() }
    func deleteSequence(id: UUID) throws { try real.deleteSequence(id: id) }
    func currentObie() throws -> Take? { try real.currentObie() }
    func setObie(id: UUID, replaceExisting: Bool) throws { try real.setObie(id: id, replaceExisting: replaceExisting) }
    func lastSyncDate() -> Date? { real.lastSyncDate() }
    func setLastSyncDate(_ date: Date) { real.setLastSyncDate(date) }
    func tombstones() throws -> [Tombstone] { try real.tombstones() }
    func purgeTombstones(ids: [UUID]) throws { try real.purgeTombstones(ids: ids) }
    func applyRemote(_ take: Take) throws -> Bool { try real.applyRemote(take) }
    func release(id: UUID, ifNotModifiedAfter cutoff: Date) throws -> Bool { try real.release(id: id, ifNotModifiedAfter: cutoff) }
}

final class LibraryStoreFailureTests: XCTestCase {
    /// #50 review (Greptile): a store failure while saving a Take both sides changed fails the
    /// whole save, as any store failure does, rather than reporting the Take as unreadable.
    func testAStoreFailureOnAConflictFailsTheSave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-failing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
        let store = FailingStore(try EncryptedTakeStore(keys: keys, directoryURL: dir))
        let library = Library(store: store, scripts: try ScriptVault(keys: keys, directory: dir.appendingPathComponent("Scripts")))
        let id = UUID()
        let a: [String: Any] = ["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "blocks": [["k": "text", "text": "A"]]]
        _ = try library.saveTakes([a])
        let gen = try library.snapshot().generation
        var remote = a
        remote["blocks"] = [["k": "text", "text": "A, from the iPhone"]]
        var synced = try TakeTranslation.core(from: remote, existing: try store.take(id: id), now: Date(timeIntervalSinceNow: 60))
        synced.modifiedAt = Date(timeIntervalSinceNow: 60)
        try store.upsert(synced)

        var mine = a
        mine["blocks"] = [["k": "text", "text": "A, from the Mac"]]
        store.failUpserts = true
        XCTAssertThrowsError(try library.saveTakes([mine], generation: gen))
        XCTAssertEqual(try store.take(id: id)?.plainText, "A, from the iPhone", "nothing half-written")
    }

    /// Code review on M3b: a Script save comes after every pause in typing, so it reads only the
    /// items it names, never every Take in the library.
    func testAScriptSaveNeverReadsTheWholeLibrary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-counting-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
        let store = FailingStore(try EncryptedTakeStore(keys: keys, directoryURL: dir))
        let library = Library(store: store, scripts: try ScriptVault(keys: keys, directory: dir.appendingPathComponent("Scripts")))
        _ = try library.saveTakes((0..<20).map { ["id": UUID().uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "blocks": [["k": "text", "text": "Take \($0)"]]] })
        var script: [String: Any] = ["id": UUID().uuidString, "at": "2026-07-01T09:00:00.000Z", "mode": "a4", "blocks": ["Draft"]]
        _ = try library.snapshot()
        let before = store.allTakesReads
        _ = try library.saveScripts([script])
        script["blocks"] = ["Draft, typed on"]
        _ = try library.saveScripts([script])
        _ = try library.saveScripts([])
        XCTAssertEqual(store.allTakesReads, before)
        XCTAssertEqual(try library.pageTakes().count, 20)
    }
}
