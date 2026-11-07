import Foundation

/// Opens a Take in the page for a click on its notification or its Spotlight result. A click can
/// arrive before the page has loaded (a cold launch from a notification), so the latest one waits
/// until `pageDidLoad`.
final class TakeOpener {
    private let callPage: (String) -> Void
    private var pageLoaded = false
    private var waiting: UUID?

    /// `callPage` runs `catchlightOpenTake` in the page with the id it is given.
    init(callPage: @escaping (String) -> Void) { self.callPage = callPage }

    func open(_ id: UUID) {
        guard pageLoaded else { waiting = id; return }
        callPage(id.uuidString.lowercased())
    }

    func pageDidLoad() {
        pageLoaded = true
        if let id = waiting { waiting = nil; open(id) }
    }
}
