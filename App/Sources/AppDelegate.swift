import AppKit
import CatchlightAppleStorage
import CoreSpotlight
import UserNotifications
import os

// The menu bar is built from the page's own model (MenuController), so there is no default
// menu here: until the page pushes it, the bar is the app menu with Quit.

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var windowController: MainWindowController?
    /// A Take clicked before the window exists (a launch from a notification, or the unlock still open).
    private var takeToOpen: UUID?

    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set before anything else: a notification that launched the app is delivered once this is set.
        UNUserNotificationCenter.current().delegate = self
        guard let vault = unlockedVault() else { NSApp.terminate(nil); return }
        let controller = MainWindowController(vault: vault)
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
        if let id = takeToOpen { takeToOpen = nil; controller.openTake(id) }
    }

    // MARK: Opening a Take from a notification or Spotlight

    private func openTake(_ id: UUID) {
        if let windowController { windowController.openTake(id) } else { takeToOpen = id }
    }

    /// A reminder that fires while Catchlight is in front still shows.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let text = response.notification.request.content.userInfo["takeID"] as? String,
           let id = UUID(uuidString: text) {
            openTake(id)
        }
        completionHandler()
    }

    /// A click on a Spotlight result: the item's identifier is the Take's UUID.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let text = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let id = UUID(uuidString: text) else { return false }
        openTake(id)
        return true
    }

    /// The account's library, opened before the window loads so the page starts with its Takes.
    /// Opening asks for the user (Touch ID or the login password) when there is an account; a
    /// cancelled or failed unlock offers another try or Quit, and nothing is shown until then.
    private func unlockedVault() -> Vault? {
        #if DEBUG
        if let vault = DebugLaunch.vault() { return vault }
        #endif
        let vault: Vault
        do {
            vault = Vault(secrets: KeychainSecrets(), directory: try Vault.defaultDirectory())
        } catch {
            Self.log.fault("no Application Support folder: \(String(describing: error), privacy: .public)")
            return nil
        }
        while true {
            do {
                try vault.start()
                return vault
            } catch {
                Self.log.error("start failed: \(String(describing: error), privacy: .public)")
                let alert = NSAlert()
                if error is KeychainError {
                    alert.messageText = String(localized: "Catchlight is locked")
                    alert.informativeText = String(localized: "Your Takes stay encrypted until you unlock them with Touch ID or your Mac's password.")
                } else {
                    // Unlocked, but the library didn't open: say so, with what to report.
                    alert.messageText = String(localized: "Catchlight couldn't open your Takes")
                    alert.informativeText = String(localized: "Nothing has been changed or deleted. If trying again doesn't help, report it with this detail: \(String(describing: error))")
                }
                alert.addButton(withTitle: String(localized: "Try Again"))
                alert.addButton(withTitle: String(localized: "Quit"))
                if alert.runModal() != .alertFirstButtonReturn { return nil }
            }
        }
    }

    /// ⌘Q, or Quit from the Dock: the page saves what is on screen before the app goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = windowController else { return .terminateNow }
        controller.flushPage { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
