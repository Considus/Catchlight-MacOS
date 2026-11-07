import CatchlightCore
import UserNotifications
import XCTest

final class FakeCentre: NotificationCentre {
    var added: [UNNotificationRequest] = []
    var pending: [String] = []
    var removedPending: [String] = []
    var removedDelivered: [String] = []
    var status: UNAuthorizationStatus = .authorized
    var authorizationAsked = 0

    func add(_ request: UNNotificationRequest) { added.append(request) }
    func removePending(_ ids: [String]) { removedPending += ids }
    func removeDelivered(_ ids: [String]) { removedDelivered += ids }
    func pendingIdentifiers(_ done: @escaping ([String]) -> Void) { done(pending) }
    func authorizationStatus(_ done: @escaping (UNAuthorizationStatus) -> Void) { done(status) }
    func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        authorizationAsked += 1
        status = .authorized
        done(true)
    }
}

final class MacRemindersTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "GMT")!
        return c
    }()
    // Saturday 7 November 2026, 12:00 GMT.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
    private let centre = FakeCentre()

    private func reminders() -> MacReminders {
        MacReminders(centre: centre, now: { self.now }, calendar: calendar)
    }

    private func date(_ day: Int, _ hour: Int, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func take(_ text: String = "Call the vet", at when: Date, allDay: Bool = false,
                      recurrence: TimeReminder.Recurrence = .none, alarm: Bool = true,
                      done: Bool = false, blocks: [TakeBlock]? = nil, kind: String? = nil) -> Take {
        let id = UUID()
        let reminder = TimeReminder(scheduledDate: when, notificationIdentifier: id.uuidString,
                                    alarmEnabled: alarm, isDone: done, isAllDay: allDay,
                                    recurrence: recurrence)
        return Take(id: id, blocks: blocks ?? [.textLine(text)], timeReminder: reminder, kind: kind)
    }

    private func components(_ request: UNNotificationRequest) -> DateComponents? {
        (request.trigger as? UNCalendarNotificationTrigger)?.dateComponents
    }

    func testOneShotTomorrowGivesOneRequestWithTheTakeID() throws {
        let t = take(at: date(8, 10))
        let plan = reminders().plan([t])
        XCTAssertEqual(plan.count, 1)
        let request = try XCTUnwrap(plan.first)
        XCTAssertEqual(request.identifier, t.id.uuidString)
        XCTAssertEqual(request.content.title, "Call the vet")
        XCTAssertEqual(request.content.threadIdentifier, t.id.uuidString)
        XCTAssertEqual(request.content.userInfo["takeID"] as? String, t.id.uuidString)
        XCTAssertEqual(request.content.sound, .default)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertFalse(trigger.repeats)
        let c = trigger.dateComponents
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 11, 8, 10, 0, 0])
        XCTAssertEqual(c.timeZone, calendar.timeZone)
    }

    private func expectedSubtitle(_ date: Date, allDay: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = allDay ? .none : .short
        return formatter.string(from: date)
    }

    func testSubtitleIsTheOccurrenceAsDateAndTime() {
        let when = date(8, 10)
        let plan = reminders().plan([take(at: when)])
        XCTAssertEqual(plan.first?.content.subtitle, expectedSubtitle(when, allDay: false))
    }

    func testAllDaySubtitleIsTheDateOnly() {
        let when = date(9, 0)
        let plan = reminders().plan([take(at: when, allDay: true)])
        XCTAssertEqual(plan.first?.content.subtitle, expectedSubtitle(when, allDay: true))
        XCTAssertNotEqual(plan.first?.content.subtitle, expectedSubtitle(when, allDay: false))
    }

    func testPastOneShotGivesNone() {
        XCTAssertTrue(reminders().plan([take(at: date(7, 11))]).isEmpty)
        XCTAssertTrue(reminders().plan([take(at: date(7, 12))]).isEmpty)
    }

    func testAllDayOneShotFiresAtNine() throws {
        let plan = reminders().plan([take(at: date(9, 0), allDay: true)])
        let c = try XCTUnwrap(plan.first.flatMap(components))
        XCTAssertEqual([c.day, c.hour, c.minute], [9, 9, 0])
    }

    func testDailyRepeatGivesTwelveRequestsADayApart() throws {
        let t = take(at: date(8, 10), recurrence: .daily)
        let plan = reminders().plan([t])
        XCTAssertEqual(plan.count, 12)
        XCTAssertEqual(plan.map(\.identifier), (0..<12).map { "\(t.id.uuidString)#\($0)" })
        let days = try plan.map { try XCTUnwrap(components($0)?.day) }
        XCTAssertEqual(days, Array(8...19))
    }

    func testAllDayRepeatFiresAtNine() throws {
        let plan = reminders().plan([take(at: date(8, 0), allDay: true, recurrence: .daily)])
        XCTAssertEqual(plan.count, 12)
        XCTAssertTrue(plan.allSatisfy { components($0)?.hour == 9 })
    }

    func testNothingForDoneAlarmOffScriptOrFinishedChecklist() {
        let ticked: [TakeBlock] = [.checkItem("Milk", isComplete: true), .checkItem("Eggs", isComplete: true)]
        let takes = [
            take(at: date(8, 10), done: true),
            take(at: date(8, 10), alarm: false),
            take(at: date(8, 10), kind: "script"),
            take(at: date(8, 10), blocks: ticked),
        ]
        XCTAssertTrue(reminders().plan(takes).isEmpty)
    }

    func testAnUnfinishedChecklistStillFires() {
        let blocks: [TakeBlock] = [.checkItem("Milk", isComplete: true), .checkItem("Eggs")]
        XCTAssertEqual(reminders().plan([take(at: date(8, 10), blocks: blocks)]).count, 1)
    }

    func testTenDailyRepeatsAreCappedAtFiftySixSoonestFirst() throws {
        let takes = (0..<10).map { take(at: date(8, 10 + $0), recurrence: .daily) }
        let plan = reminders().plan(takes)
        XCTAssertEqual(plan.count, MacReminders.maxPending)
        let fires = try plan.map { try XCTUnwrap(calendar.date(from: components($0)!)) }
        XCTAssertEqual(fires, fires.sorted())
        // 120 planned; the 56 soonest end partway through 13 November.
        XCTAssertEqual(try XCTUnwrap(components(plan.last!)?.day), 13)
    }

    func testEmptyTitleBecomesUntitledTake() throws {
        let plan = reminders().plan([take("", at: date(8, 10))])
        XCTAssertEqual(plan.first?.content.title, String(localized: "Untitled Take"))
        XCTAssertFalse(try XCTUnwrap(plan.first?.content.title).isEmpty)
    }

    func testTitleIsCappedAtOneHundredCharacters() {
        let plan = reminders().plan([take(String(repeating: "a", count: 300), at: date(8, 10))])
        XCTAssertEqual(plan.first?.content.title.count, 100)
    }

    func testReconcileRemovesAStaleIDOfOursAndLeavesAForeignOne() {
        let stale = "\(UUID().uuidString)#3"
        centre.pending = [stale, "other"]
        reminders().reconcile([])
        XCTAssertTrue(centre.removedPending.contains(stale))
        XCTAssertFalse(centre.removedPending.contains("other"))
        XCTAssertTrue(centre.removedDelivered.contains(stale))
        XCTAssertFalse(centre.removedDelivered.contains("other"))
        XCTAssertTrue(centre.added.isEmpty)
    }

    func testReconcileAddsThePlan() {
        let t = take(at: date(8, 10))
        centre.pending = [t.id.uuidString]
        reminders().reconcile([t])
        XCTAssertEqual(centre.added.map(\.identifier), [t.id.uuidString])
        XCTAssertEqual(centre.removedPending, [t.id.uuidString])
    }

    func testReconcileAsksAuthorisationOnceWhenNotDeterminedAndThePlanHasRequests() {
        centre.status = .notDetermined
        let r = reminders()
        r.reconcile([take(at: date(8, 10))])
        XCTAssertEqual(centre.authorizationAsked, 1)
        XCTAssertEqual(centre.added.count, 1)
        r.reconcile([take(at: date(8, 10))])
        XCTAssertEqual(centre.authorizationAsked, 1)
    }

    func testReconcileDoesNotAskAuthorisationForAnEmptyPlan() {
        centre.status = .notDetermined
        reminders().reconcile([])
        XCTAssertEqual(centre.authorizationAsked, 0)
    }
}
