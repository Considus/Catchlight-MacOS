#if DEBUG
import AppKit
import WebKit
import os

/// Launch arguments for proving the shell from the command line. Debug builds only: none of this
/// is compiled into Release.
///
/// - `-CLDebugAccount YES`: open with a throwaway account held in memory and a library in a
///   temporary folder, so the page opens on the main window rather than first run and nothing
///   touches the Keychain or the real library.
/// - `-CLDebugPhrase "<12 words>"`: with `-CLDebugAccount`, restore that phrase instead of making a
///   new one, so a second app (the iPhone simulator) with the same words reads the same folder.
///   A phrase that isn't valid ends the launch.
/// - `-CLDebugFolder <path>`: with `-CLDebugAccount`, use that folder for sync, through the same
///   `SyncFolder.choose` path as the open panel. The sync settings (folder bookmark, device id,
///   script switch) then live in a separate defaults domain, so the app's real ones are never
///   touched.
/// - `-CLDebugNoExternalOpen YES`: log the address a link would open instead of opening it.
/// - `-CLDebugEval '<js>'`: once the page has loaded, run `<js>` as an async function body in the
///   page and log what it returns (`log show --predicate 'subsystem == "com.considus.catchlight.mac"'`).
enum DebugLaunch {
    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "debug")
    private static var defaults: UserDefaults { .standard }

    /// The words after `-CLDebugPhrase`, or nil when there are none.
    static func phrase(_ defaults: UserDefaults = .standard) -> [String]? {
        guard let text = defaults.string(forKey: "CLDebugPhrase") else { return nil }
        let words = Vault.cleaned(text.split(whereSeparator: \.isWhitespace).map(String.init))
        return words.isEmpty ? nil : words
    }

    /// Where the throwaway account keeps its sync settings: a domain of its own, emptied at each
    /// launch. Nil outside a throwaway account, which keeps the real ones.
    static func syncDefaults() -> UserDefaults? {
        guard defaults.bool(forKey: "CLDebugAccount") else { return nil }
        let name = "com.considus.catchlight.mac.debug-sync"
        defaults.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)
    }

    /// Point `folder` at `-CLDebugFolder`, if given and a throwaway account is open.
    static func useFolder(_ folder: SyncFolder?, _ defaults: UserDefaults = .standard) {
        guard let path = defaults.string(forKey: "CLDebugFolder"), !path.isEmpty, let folder else { return }
        guard defaults.bool(forKey: "CLDebugAccount") else {
            log.error("CLDebugFolder ignored: it needs -CLDebugAccount YES")
            return
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        folder.pick = { _, done in done(url) }
        folder.choose(in: nil) { result in
            switch result {
            case .success: log.info("CLDebugFolder: sync folder set to \(url.path, privacy: .public)")
            case .failure(let error): log.error("CLDebugFolder: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func vault() -> Vault? {
        guard defaults.bool(forKey: "CLDebugAccount") else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-debug-\(UUID().uuidString)/Catchlight")
        let vault = Vault(secrets: MemorySecrets(), directory: directory)
        do {
            let words = try phrase() ?? Vault.newPhrase()
            guard Vault.isValid(words) else {
                log.error("CLDebugPhrase: not a valid 12 word phrase")
                exit(2)
            }
            try vault.createAccount(words: words, restored: true)
            log.info("CLDebugAccount: throwaway account in \(directory.path, privacy: .public)")
            return vault
        } catch {
            log.error("CLDebugAccount: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func attach(to controller: MainWindowController) {
        if defaults.bool(forKey: "CLDebugNoExternalOpen") {
            controller.bridge.openExternally = { url in
                log.info("CLDebugNoExternalOpen: would open \(url.absoluteString, privacy: .public)")
            }
        }
    }

    static func pageDidLoad(_ webView: WKWebView) {
        guard let script = defaults.string(forKey: "CLDebugEval"), !script.isEmpty else { return }
        // A second for the page to settle and push its menu model first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    log.info("CLDebugEval result: \(String(describing: value), privacy: .public)")
                case .failure(let error):
                    log.error("CLDebugEval error: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
#endif
