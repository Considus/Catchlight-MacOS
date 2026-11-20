import Foundation

/// Opens a Take in the page for a click on its notification or its Spotlight result. A click can
/// arrive before the page has loaded (a cold launch from a notification), so the latest one waits
/// until `pageDidLoad`. The page answers "busy" while something owns the keyboard (a Focus row,
/// the reminder picker, Settings, an alert...) and changes nothing, so the click is asked again a
/// second later, for up to a minute.
final class TakeOpener {
    static let retryDelay: TimeInterval = 1
    static let retryLimit = 60

    private let callPage: (String, @escaping (Any?) -> Void) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var pageLoaded = false
    private var waiting: UUID?
    /// The latest click until the page has answered it with anything but "busy": through its
    /// retries too, so a relock can withdraw it.
    private var pending: UUID?
    private var generation = 0   // each click gets one; a retry of an older click does nothing

    /// `callPage` runs `catchlightOpenTake` in the page with the id it is given and passes on its answer.
    init(callPage: @escaping (String, @escaping (Any?) -> Void) -> Void,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.callPage = callPage
        self.schedule = schedule
    }

    func open(_ id: UUID) {
        generation += 1
        pending = id
        attempt(id, generation: generation, retriesLeft: Self.retryLimit)
    }

    private func attempt(_ id: UUID, generation: Int, retriesLeft: Int) {
        guard pageLoaded else { waiting = id; return }
        callPage(id.uuidString.lowercased()) { [weak self] answer in
            guard let self, self.generation == generation else { return }
            guard answer as? String == "busy", retriesLeft > 0 else { self.pending = nil; return }
            self.schedule(Self.retryDelay) { [weak self] in
                guard let self, self.generation == generation else { return }
                self.attempt(id, generation: generation, retriesLeft: retriesLeft - 1)
            }
        }
    }

    func pageDidLoad() {
        pageLoaded = true
        if let id = waiting { waiting = nil; open(id) }
    }

    /// The page's process ended: until it loads again there is nothing to call.
    func pageDidUnload() { pageLoaded = false }

    /// Hands back the click still on its way, if any (waiting for the page to load, or for a busy
    /// page's retry), and forgets it: the lock is about to replace the page with one that has no Takes.
    func withdrawWaiting() -> UUID? {
        defer {
            waiting = nil
            pending = nil
            generation += 1   // a retry already scheduled does nothing
        }
        return waiting ?? pending
    }
}
