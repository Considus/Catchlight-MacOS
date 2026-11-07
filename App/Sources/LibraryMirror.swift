import CatchlightCore
import Foundation

/// Keeps the two things the OS holds in step with the library: the pending reminders
/// (`MacReminders`) and the Spotlight index. The bridge calls `refresh` after every library
/// change. Only Takes are mirrored, never Scripts. Spotlight takes the type label only: the
/// text levels are locked, so any level past `.type` clamps to `.type`.
final class LibraryMirror {
    static let spotlightKey = "spotlightExposure"

    private let reminders: MacReminders
    private let spotlight: SpotlightIndexing
    private let defaults: UserDefaults
    private(set) var exposure: SpotlightExposure
    private var lastTakes: [Take]?
    /// What was indexed by the last refresh, so a Take that is gone can be removed.
    private var indexed: Set<UUID> = []
    /// Set when the level changes to `.none`; the next refresh clears the index once.
    private var clearPending = false

    init(reminders: MacReminders, spotlight: SpotlightIndexing, defaults: UserDefaults = .standard) {
        self.reminders = reminders
        self.spotlight = spotlight
        self.defaults = defaults
        exposure = Self.level(from: defaults.string(forKey: Self.spotlightKey) ?? "none")
    }

    /// `none` stays `none`; every other level is `.type`.
    private static func level(from raw: String) -> SpotlightExposure {
        raw == SpotlightExposure.none.rawValue ? .none : .type
    }

    func setExposure(_ raw: String) {
        let level = Self.level(from: raw)
        defaults.set(level.rawValue, forKey: Self.spotlightKey)
        guard level != exposure else { return }
        if level == .none { clearPending = true }
        exposure = level
        if let lastTakes { refresh(takes: lastTakes) }
    }

    func refresh(takes: [Take]) {
        lastTakes = takes
        reminders.reconcile(takes)
        switch exposure {
        case .none:
            indexed = []
            if clearPending {
                clearPending = false
                spotlight.deindexAll()
            }
        default:
            clearPending = false
            spotlight.exposure = .type
            let current = takes.filter { $0.kind == nil }
            for take in current { spotlight.index(take) }
            let ids = Set(current.map(\.id))
            for gone in indexed.subtracting(ids) { spotlight.deindex(takeID: gone) }
            indexed = ids
        }
    }

    /// The Takes to mirror, or nil when there is nothing to do: locked, or a library that can't be
    /// read. With no account (first run, or just erased) the library is empty, so every
    /// notification and Spotlight item of ours goes.
    static func takes(from vault: Vault?) -> [Take]? {
        guard let vault else { return nil }
        switch vault.state {
        case .open(let library): return try? library.store.allTakes()
        case .noAccount: return []
        case .locked: return nil
        }
    }
}
