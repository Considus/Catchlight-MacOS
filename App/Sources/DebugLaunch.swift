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
/// - `-CLDebugNoExternalOpen YES`: log the address a link would open instead of opening it.
/// - `-CLDebugEval '<js>'`: once the page has loaded, run `<js>` as an async function body in the
///   page and log what it returns (`log show --predicate 'subsystem == "com.considus.catchlight.mac"'`).
enum DebugLaunch {
    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "debug")
    private static var defaults: UserDefaults { .standard }

    static func vault() -> Vault? {
        guard defaults.bool(forKey: "CLDebugAccount") else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-debug-\(UUID().uuidString)/Catchlight")
        let vault = Vault(secrets: MemorySecrets(), directory: directory)
        do {
            try vault.createAccount(words: try Vault.newPhrase(), restored: true)
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
