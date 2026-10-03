import AppKit
import CatchlightAppleStorage
import os

// The menu bar is built from the page's own model (MenuController), so there is no default
// menu here: until the page pushes it, the bar is the app menu with Quit.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let vault = unlockedVault() else { NSApp.terminate(nil); return }
        let controller = MainWindowController(vault: vault)
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
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
                    alert.messageText = "Catchlight is locked"
                    alert.informativeText = "Your Takes stay encrypted until you unlock them with Touch ID or your Mac's password."
                } else {
                    // Unlocked, but the library didn't open: say so, with what to report.
                    alert.messageText = "Catchlight couldn't open your Takes"
                    alert.informativeText = "Nothing has been changed or deleted. If trying again doesn't help, report it with this detail: \(error)"
                }
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Quit")
                if alert.runModal() != .alertFirstButtonReturn { return nil }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
