import Foundation
import CatchlightCore
import os

/// The open library: Takes in Core's `TakeStore`, Scripts in the `ScriptVault`. The page saves its
/// whole Take list at once (`saveTakes()` in `ui/takes.js`), so a save is a diff against the
/// store: a Take whose content changed is upserted, a Take the page no longer holds is deleted,
/// which leaves the tombstone sync needs (M3).
final class Library {
    struct SaveReport: Equatable {
        var upserted = 0
        var deleted = 0
        var unchanged = 0
        /// Takes the page sent that could not be translated; the stored version is left alone.
        var rejected: [String] = []
    }

    enum Failure: Error, Equatable {
        /// An empty list against a non-empty store. The page has no "delete everything" except
        /// Erase, which goes through the Vault, so this is a bug and nothing is deleted.
        case refusedToEmpty(stored: Int)
    }

    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "library")

    let store: TakeStore
    let scripts: ScriptVault

    init(store: TakeStore, scripts: ScriptVault) {
        self.store = store
        self.scripts = scripts
    }

    /// Every Take in the page's shape, oldest first (as the store returns them).
    func pageTakes() throws -> [[String: Any]] {
        try store.allTakes().map(TakeTranslation.page(from:))
    }

    func saveTakes(_ page: [[String: Any]], now: Date = Date()) throws -> SaveReport {
        let stored = Dictionary(uniqueKeysWithValues: try store.allTakes().map { ($0.id, $0) })
        if page.isEmpty, !stored.isEmpty { throw Failure.refusedToEmpty(stored: stored.count) }

        var report = SaveReport()
        var seen = Set<UUID>()
        var changed: [Take] = []
        for item in page {
            let id = (item["id"] as? String).flatMap(UUID.init(uuidString:))
            if let id { seen.insert(id) }
            do {
                let take = try TakeTranslation.core(from: item, existing: id.flatMap { stored[$0] }, now: now)
                if take == stored[take.id] { report.unchanged += 1 } else { changed.append(take) }
            } catch {
                report.rejected.append(item["id"] as? String ?? "?")
                Self.log.error("a Take did not translate: \(String(describing: error), privacy: .public)")
            }
        }
        // The Obie last: upserting it demotes any other, so the page's choice is the one that stands.
        for take in changed.sorted(by: { !$0.isObie && $1.isObie }) {
            try store.upsert(take)
            report.upserted += 1
        }
        // A rejected Take keeps its stored version: only ids the page did not send are deletions.
        for id in stored.keys where !seen.contains(id) {
            try store.delete(id: id)
            report.deleted += 1
        }
        return report
    }

    func pageScripts() throws -> [[String: Any]] { try scripts.all() }

    func saveScripts(_ page: [[String: Any]]) throws { try scripts.replaceAll(with: page) }
}
