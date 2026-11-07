import AppKit

/// The page's Writing Tools setting (Settings ▸ Security): Off, Panel or Inline. Writing Tools
/// sends text to Apple Intelligence, so anything missing or unknown is Off.
enum WritingToolsSetting: String {
    case off, panel, inline

    /// Where the setting is kept (`setWritingTools` in ShellBridge).
    static let key = "writingTools"

    init(_ raw: String?) {
        self = raw.flatMap(Self.init(rawValue:)) ?? .off
    }

    /// What the web view's configuration gets. Off ignores the view, Panel is the overlay
    /// experience, Inline the full in-place one. A Mac below macOS 15 has no Writing Tools.
    @available(macOS 15.0, *)
    var behavior: NSWritingToolsBehavior {
        switch self {
        case .off: return .none
        case .panel: return .limited
        case .inline: return .complete
        }
    }
}
