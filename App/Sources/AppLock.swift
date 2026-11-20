import Foundation

/// How long Catchlight may sit away before coming back asks for the user again. Mirrors the
/// iPhone's `AppModel.noteEnteredBackground` and `relockIfAwayTooLong`, with the setting
/// `SettingsViewModel.LockAfter` (stored here as a number of seconds).
final class AppLock {
    static let lockAfterKey = "catchlight.lockAfter"
    private static let allowed: Set<TimeInterval> = [30, 60, 300, 1800, 3600]
    private static let fallback: TimeInterval = 60

    private let defaults: UserDefaults
    private let now: () -> Date
    private var wentAwayAt: Date?

    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// The setting, read fresh each time. A missing, unreadable or unlisted value is one minute.
    var lockAfter: TimeInterval {
        let stored = defaults.object(forKey: Self.lockAfterKey)
        let seconds: TimeInterval?
        switch stored {
        case let text as String: seconds = TimeInterval(text)
        case let number as NSNumber: seconds = number.doubleValue
        default: seconds = nil
        }
        guard let seconds, Self.allowed.contains(seconds) else { return Self.fallback }
        return seconds
    }

    func noteWentAway() { wentAwayAt = now() }

    /// True when the app was away for at least the setting. Always clears the timestamp, and is
    /// false when there is none (a cold launch).
    func shouldLockOnReturn() -> Bool {
        let since = wentAwayAt
        wentAwayAt = nil
        guard let since else { return false }
        return now().timeIntervalSince(since) >= lockAfter
    }
}
