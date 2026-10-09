import XCTest
import CatchlightCore

/// Catchlight-Core#29: a Take waiting for a conflict choice that another device then turns into a
/// Script this Mac doesn't hold (`syncScripts` off) is never let go or forked by sync. Core names it
/// in `SyncReport.heldConverted` on every pass, and the queue marks the pair converted. Resolving
/// it must never write the Take's own id, which the folder now lists as that Script: the usual
/// choice re-stamps the kept version, and the next push would send it into the Script.
///
/// Seams: `ConflictQueue` (`markConverted`, `resolve`) and Core's real `SyncEngine` on both devices
/// over one `InMemoryCloudFolder`, as they share a sync folder. `syncThisMac` hands each report to
/// the queue as `SyncService.run` does.
final class HeldConvertedTests: XCTestCase {
    private let keys = KeyHierarchy(masterKeyBytes: Data(repeating: 7, count: 32))
    private let cloud = InMemoryCloudFolder()
    /// This Mac, which keeps no Scripts in the folder, and a device that does.
    private let mac = InMemoryTakeStore(), desk = InMemoryTakeStore()
    private let macDevice = UUID(), deskDevice = UUID()
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-held-converted-\(UUID())", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func syncThisMac(_ queue: ConflictQueue) throws -> SyncReport {
        let report = try SyncEngine(store: mac, cloud: cloud, keys: keys, deviceId: macDevice)
            .sync(holding: queue.heldIDs)
        queue.enqueue(report.conflicts)
        queue.markConverted(report.heldConverted)
        queue.release(Set(report.deletedLocally + report.forkedFromScripts))
        return report
    }

    @discardableResult
    private func syncDesk() throws -> SyncReport {
        try SyncEngine(store: desk, cloud: cloud, keys: keys, deviceId: deskDevice, holdsScripts: true).sync()
    }

    private func edit(_ store: InMemoryTakeStore, _ id: UUID, _ text: String) throws {
        var take = try XCTUnwrap(store.take(id: id))
        take.blocks = [.text(TextBlock(text: text))]
        take.modifiedAt = Date()
        try store.upsert(take)
    }

    private func manifestEntry(_ id: UUID) throws -> ManifestEntry? {
        let data = try XCTUnwrap(cloud.read(Manifest.fileName))
        return try Manifest.opening(ManifestEnvelope.parse(data), with: keys.manifestEncryptionKey())
            .takes.first { $0.uuid == id }
    }

    private func tombstoned(_ id: UUID) throws -> Bool {
        let data = try XCTUnwrap(cloud.read(Manifest.fileName))
        return try Manifest.opening(ManifestEnvelope.parse(data), with: keys.manifestEncryptionKey())
            .tombstones.contains { $0.uuid == id }
    }

    /// A Take with a reminder on both devices, edited on both, the conflict waiting on this Mac; then
    /// the desk turns it into a Script and syncs, and this Mac's next pass finds it converted.
    private func convertedPair(queue: ConflictQueue, obie: Bool = false) throws -> UUID {
        var take = Take(createdAt: Date(timeIntervalSince1970: 1_780_000_000), blocks: [.text(TextBlock(text: "Original"))], isObie: obie)
        take.timeReminder = TimeReminder(scheduledDate: Date().addingTimeInterval(86_400), notificationIdentifier: take.id.uuidString)
        try desk.upsert(take)
        try syncDesk()
        try syncThisMac(queue)
        try edit(mac, take.id, "Edited on this Mac")
        try edit(desk, take.id, "Edited on the desk")
        try syncDesk()
        try syncThisMac(queue)
        XCTAssertEqual(queue.pending.map(\.local.id), [take.id], "the conflict waits on this Mac")

        var script = try XCTUnwrap(desk.take(id: take.id))
        script.kind = ManifestEntry.Kind.script
        script.modifiedAt = Date()
        try desk.upsert(script)
        try syncDesk()
        XCTAssertEqual(try manifestEntry(take.id)?.kind, ManifestEntry.Kind.script)

        let report = try syncThisMac(queue)
        XCTAssertEqual(report.heldConverted, [take.id])
        XCTAssertEqual(report.deletedLocally, [], "held, the Take is not let go")
        XCTAssertEqual(report.forkedFromScripts, [], "nor forked")
        XCTAssertEqual(queue.converted, [take.id])
        XCTAssertEqual(queue.heldIDs, [take.id])
        XCTAssertEqual(try mac.take(id: take.id)?.plainText, "Edited on this Mac")
        return take.id
    }

    /// The required case: Keep this version as a new Take makes a NEW Take and never writes the
    /// original id, so the next sync leaves the Script's entry and file exactly as the desk wrote them.
    func testKeepAsNewMakesANewTakeAndNeverWritesTheScript() throws {
        let queue = ConflictQueue()
        let id = try convertedPair(queue: queue)
        let original = try XCTUnwrap(mac.take(id: id))
        let entryBefore = try XCTUnwrap(manifestEntry(id))
        let fileBefore = try XCTUnwrap(cloud.read(CloudBlob.fileName(for: id)))

        // The usual choice would re-stamp the Take on its own id: refused, and nothing is written.
        XCTAssertThrowsError(try queue.resolve(id: id, choice: .local, store: mac)) {
            XCTAssertEqual($0 as? ConflictQueue.Failure, .choiceDoesNotFit)
        }
        XCTAssertEqual(try mac.take(id: id), original)

        let copy = try XCTUnwrap(try queue.resolve(id: id, choice: .asNew, store: mac))
        XCTAssertNotEqual(copy.id, id)
        XCTAssertNil(try mac.take(id: id), "the original leaves this Mac")
        XCTAssertEqual(try mac.allTakes().map(\.id), [copy.id])
        XCTAssertEqual(copy.plainText, "Edited on this Mac")
        XCTAssertEqual(copy.createdAt, original.createdAt)
        XCTAssertEqual(copy.timeReminder?.notificationIdentifier, copy.id.uuidString, "its own reminder id")
        XCTAssertFalse(copy.isObie)
        XCTAssertTrue(queue.heldIDs.isEmpty)
        XCTAssertTrue(queue.converted.isEmpty)

        let next = try syncThisMac(queue)
        XCTAssertEqual(next.uploaded, [copy.id], "only the new Take goes up")
        XCTAssertEqual(try manifestEntry(id), entryBefore, "the Script's entry is untouched")
        XCTAssertEqual(try cloud.read(CloudBlob.fileName(for: id)), fileBefore, "and so is its file")
        XCTAssertFalse(try tombstoned(id), "no deletion record for the Script")

        try syncDesk()
        XCTAssertEqual(try desk.take(id: id)?.plainText, "Edited on the desk")
        XCTAssertEqual(try desk.take(id: id)?.isScript, true, "the desk's Script is as it left it")
        XCTAssertEqual(try desk.take(id: copy.id)?.plainText, "Edited on this Mac", "and the kept version reaches it as a new Take")
    }

    /// The original was the Obie: the copy takes over the Obie, once the original has gone.
    func testKeepAsNewOfTheObieMakesTheCopyTheObie() throws {
        let queue = ConflictQueue()
        let id = try convertedPair(queue: queue, obie: true)

        let copy = try XCTUnwrap(try queue.resolve(id: id, choice: .asNew, store: mac))

        XCTAssertTrue(copy.isObie)
        XCTAssertEqual(try mac.currentObie()?.id, copy.id)
        XCTAssertNil(try mac.take(id: id))
    }

    /// Let it go: the hold and the pair are dropped, the Take leaves this Mac with no deletion record,
    /// and the Script is left exactly as it was.
    func testLetItGoDropsTheHoldAndLeavesTheScript() throws {
        let queue = ConflictQueue()
        let id = try convertedPair(queue: queue)
        let entryBefore = try XCTUnwrap(manifestEntry(id))
        let fileBefore = try XCTUnwrap(cloud.read(CloudBlob.fileName(for: id)))

        XCTAssertNil(try queue.resolve(id: id, choice: .letGo, store: mac))

        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertTrue(queue.heldIDs.isEmpty)
        XCTAssertNil(try mac.take(id: id))
        let next = try syncThisMac(queue)
        XCTAssertEqual(next.uploaded, [])
        XCTAssertEqual(try manifestEntry(id), entryBefore)
        XCTAssertEqual(try cloud.read(CloudBlob.fileName(for: id)), fileBefore)
        XCTAssertFalse(try tombstoned(id))
        XCTAssertNil(try mac.take(id: id), "and it doesn't come back")
    }

    /// Picking a version doesn't fit a converted pair, and `.asNew` / `.letGo` don't fit an ordinary one.
    func testAnOrdinaryPairRefusesTheConvertedChoices() throws {
        let store = InMemoryTakeStore()
        let local = Take(blocks: [.text(TextBlock(text: "Mine"))])
        try store.upsert(local)
        var remote = local
        remote.blocks = [.text(TextBlock(text: "Theirs"))]
        let queue = ConflictQueue()
        queue.enqueue([(local: local, remote: remote)])

        for choice in [ConflictQueue.Choice.asNew, .letGo] {
            XCTAssertThrowsError(try queue.resolve(id: local.id, choice: choice, store: store))
        }
        XCTAssertEqual(try store.allTakes(), [local])
        XCTAssertEqual(queue.heldIDs, [local.id])
    }

    /// The mark is kept in the pair's sealed file: a relaunch reads the pair as converted, still held.
    func testTheMarkSurvivesARelaunch() throws {
        let local = Take(blocks: [.text(TextBlock(text: "Mine"))])
        var remote = local
        remote.blocks = [.text(TextBlock(text: "Theirs"))]
        let queue = ConflictQueue(directory: directory, keys: keys)
        queue.enqueue([(local: local, remote: remote)])
        let before = queue.revision(local.id)
        queue.markConverted([local.id, UUID()])   // an id with no pair is left alone
        XCTAssertNotEqual(queue.revision(local.id), before, "a pick made before the mark is refused")

        let relaunched = ConflictQueue(directory: directory, keys: keys)
        XCTAssertEqual(relaunched.converted, [local.id])
        XCTAssertEqual(relaunched.heldIDs, [local.id])
        XCTAssertEqual(relaunched.pending.first?.local, local)

        _ = try relaunched.resolve(id: local.id, choice: .letGo, store: InMemoryTakeStore())
        XCTAssertTrue(ConflictQueue(directory: directory, keys: keys).heldIDs.isEmpty, "resolved, nothing waits after a relaunch")
    }
}
