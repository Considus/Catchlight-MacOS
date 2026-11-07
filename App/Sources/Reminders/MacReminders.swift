import CatchlightCore
import Foundation
import UserNotifications

/// The parts of `UNUserNotificationCenter` the reminders use, so a test can stand in a fake.
protocol NotificationCentre: AnyObject {
    func add(_ request: UNNotificationRequest)
    func removePending(_ ids: [String])
    func removeDelivered(_ ids: [String])
    func pendingIdentifiers(_ done: @escaping ([String]) -> Void)
    func deliveredIdentifiers(_ done: @escaping ([String]) -> Void)
    func removeAll()
    func authorizationStatus(_ done: @escaping (UNAuthorizationStatus) -> Void)
    func requestAuthorization(_ done: @escaping (Bool) -> Void)
}

extension UNUserNotificationCenter: NotificationCentre {
    func add(_ request: UNNotificationRequest) {
        add(request, withCompletionHandler: nil)
    }

    func removePending(_ ids: [String]) {
        removePendingNotificationRequests(withIdentifiers: ids)
    }

    func removeDelivered(_ ids: [String]) {
        removeDeliveredNotifications(withIdentifiers: ids)
    }

    func pendingIdentifiers(_ done: @escaping ([String]) -> Void) {
        getPendingNotificationRequests { done($0.map(\.identifier)) }
    }

    func deliveredIdentifiers(_ done: @escaping ([String]) -> Void) {
        getDeliveredNotifications { done($0.map(\.request.identifier)) }
    }

    func removeAll() {
        removeAllPendingNotificationRequests()
        removeAllDeliveredNotifications()
    }

    func authorizationStatus(_ done: @escaping (UNAuthorizationStatus) -> Void) {
        getNotificationSettings { done($0.authorizationStatus) }
    }

    func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        requestAuthorization(options: [.alert, .sound]) { granted, _ in done(granted) }
    }
}

/// Time reminders as local notifications, a port of the iPhone's `ReminderScheduler` without
/// snooze, follow-ups, catch-up or places. A one-shot reminder has the Take's UUID as its
/// notification id; a repeating one is a window of single alarms `<uuid>#0` to `<uuid>#11`,
/// because a calendar trigger can't skip one date. The title is the Take's outstanding text,
/// the only place Take text leaves the encrypted store.
final class MacReminders {
    /// Occurrences scheduled ahead for a repeating reminder.
    static let recurrenceWindow = 12
    /// Pending requests kept, soonest first. macOS holds 64; the rest is headroom.
    static let maxPending = 56
    /// The hour an all-day reminder fires.
    static let allDayFireHour = 9

    private let centre: NotificationCentre
    private let now: () -> Date
    private let calendar: Calendar

    init(centre: NotificationCentre, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.centre = centre
        self.now = now
        self.calendar = calendar
    }

    /// The requests the Takes want now: at most `maxPending`, soonest first.
    func plan(_ takes: [Take]) -> [UNNotificationRequest] {
        let current = now()
        return takes
            .flatMap { plannedAlarms(for: $0, now: current) }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(Self.maxPending)
            .map(\.request)
    }

    /// Removes every pending and delivered notification. This app's centre holds only its own,
    /// so nothing foreign is lost. For an erase or a replaced account.
    func removeAll() {
        centre.removeAll()
    }

    /// Replaces this app's pending requests with the plan, and removes the delivered banner of
    /// every Take that no longer reminds (deleted, done, turned into a Script). Foreign ids are
    /// left alone. Main thread only. One reconcile runs at a time: one asked for while another is
    /// in flight waits, and the ones waiting run once, with the newest Takes, so a stale snapshot
    /// of the pending list never leaves a request behind. `completion` runs on the main thread
    /// after the removals and additions are issued.
    func reconcile(_ takes: [Take], completion: (() -> Void)? = nil) {
        let completions = completion.map { [$0] } ?? []
        guard !isReconciling else {
            waiting = (takes, (waiting?.completions ?? []) + completions)
            return
        }
        isReconciling = true
        run(takes, completions: completions)
    }

    private var isReconciling = false
    private var waiting: (takes: [Take], completions: [() -> Void])?

    private func run(_ takes: [Take], completions: [() -> Void]) {
        let requests = plan(takes)
        let reminding = Set(takes.filter(Self.isReminding).map(\.id.uuidString))
        let finish = { [weak self] in
            let complete = {
                completions.forEach { $0() }
                guard let self else { return }
                self.isReconciling = false
                if let next = self.waiting {
                    self.waiting = nil
                    self.isReconciling = true
                    self.run(next.takes, completions: next.completions)
                }
            }
            if Thread.isMainThread { complete() } else { DispatchQueue.main.async(execute: complete) }
        }
        centre.pendingIdentifiers { [centre] pending in
            centre.deliveredIdentifiers { delivered in
                let ours = pending.filter(Self.isOurs)
                let planned = Set(requests.map(\.identifier))
                if !ours.isEmpty { centre.removePending(ours) }
                let stale = ours.filter { !planned.contains($0) }
                let orphaned = delivered.filter { Self.isOurs($0) && !reminding.contains(Self.takeID(of: $0)) }
                let outdated = Array(Set(stale + orphaned))
                if !outdated.isEmpty { centre.removeDelivered(outdated) }
                guard !requests.isEmpty else { return finish() }
                centre.authorizationStatus { status in
                    if status == .notDetermined {
                        centre.requestAuthorization { _ in
                            requests.forEach(centre.add)
                            finish()
                        }
                    } else {
                        requests.forEach(centre.add)
                        finish()
                    }
                }
            }
        }
    }

    private struct PlannedAlarm {
        let request: UNNotificationRequest
        let fireDate: Date
    }

    /// The Take's UUID: the notification id up to any `#`.
    private static func takeID(of identifier: String) -> String {
        String(identifier.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    private static func isOurs(_ identifier: String) -> Bool {
        UUID(uuidString: takeID(of: identifier)) != nil
    }

    /// A Take that wants a time reminder: an enabled one, not done, with something outstanding.
    private static func isReminding(_ take: Take) -> Bool {
        guard take.kind == nil, let reminder = take.timeReminder, reminder.alarmEnabled, !reminder.isDone
        else { return false }
        return !hasNothingOutstanding(take, reminder: reminder)
    }

    private static func hasNothingOutstanding(_ take: Take, reminder: TimeReminder) -> Bool {
        guard !reminder.repeats, take.isTask, take.isComplete else { return false }
        return take.blocks.allSatisfy(\.isCheck)
    }

    private func plannedAlarms(for take: Take, now: Date) -> [PlannedAlarm] {
        guard Self.isReminding(take), let reminder = take.timeReminder else { return [] }
        let base = take.id.uuidString

        if reminder.repeats {
            var series = reminder
            if series.isAllDay { series = series.retimed(to: resolvedFireDate(reminder)) }
            var occurrence = series.effectiveNextDue(now: now, calendar: calendar)
            var out: [PlannedAlarm] = []
            for index in 0..<Self.recurrenceWindow {
                out.append(PlannedAlarm(
                    request: calendarRequest(for: take, occurrence: occurrence, isAllDay: reminder.isAllDay,
                                             identifier: "\(base)#\(index)"),
                    fireDate: occurrence))
                occurrence = series.nextOccurrence(after: occurrence, calendar: calendar)
            }
            return out
        }

        let fireDate = resolvedFireDate(reminder)
        guard fireDate > now else { return [] }
        return [PlannedAlarm(
            request: calendarRequest(for: take, occurrence: fireDate, isAllDay: reminder.isAllDay, identifier: base),
            fireDate: fireDate)]
    }

    /// The stored time, or the all-day fire hour on the stored day.
    private func resolvedFireDate(_ reminder: TimeReminder) -> Date {
        guard reminder.isAllDay else { return reminder.scheduledDate }
        return calendar.date(bySettingHour: Self.allDayFireHour, minute: 0, second: 0,
                             of: reminder.scheduledDate) ?? reminder.scheduledDate
    }

    private func title(for take: Take) -> String {
        let text = String(take.outstandingText.prefix(100))
        return text.isEmpty ? String(localized: "Untitled Take") : text
    }

    private func subtitle(for date: Date, isAllDay: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = isAllDay ? .none : .short
        return formatter.string(from: date)
    }

    private func calendarRequest(for take: Take, occurrence: Date, isAllDay: Bool,
                                 identifier: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title(for: take)
        content.subtitle = subtitle(for: occurrence, isAllDay: isAllDay)
        content.sound = .default
        content.threadIdentifier = take.id.uuidString
        content.userInfo["takeID"] = take.id.uuidString
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: occurrence)
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }
}
