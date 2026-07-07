import Foundation

/// Client-side mirror of the engine's bundle-id → app-category map
/// (`engine/src/velora_engine/formatting.py`, `CATEGORY_BY_BUNDLE`).
///
/// The engine only reports the resolved mode with the `final` event — too
/// late for the HUD's context chip, which appears the moment recording
/// starts — so the HUD derives a display label from this table instead.
/// This duplication is deliberate; keep the bundle ids in sync with the
/// engine when adding apps.
enum ModeCategory: String {
    case chat, email, notes, code, browser

    /// Human label shown in the HUD context chip.
    var displayName: String {
        switch self {
        case .chat: return "Message"
        case .email: return "Email"
        case .notes: return "Notes"
        case .code: return "Code"
        case .browser: return "Browser"
        }
    }

    /// Known bundle ids, mirrored from the engine's `CATEGORY_BY_BUNDLE`.
    static let byBundleID: [String: ModeCategory] = [
        // chat
        "com.tinyspeck.slackmacgap": .chat,
        "com.apple.MobileSMS": .chat,
        "com.hnc.Discord": .chat,
        "ru.keepcoder.Telegram": .chat,
        "net.whatsapp.WhatsApp": .chat,
        // email
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.SparkDesktop": .email,
        "com.readdle.smartemail-Mac": .email,
        // notes
        "com.apple.Notes": .notes,
        "md.obsidian": .notes,
        "notion.id": .notes,
        "net.shinyfrog.bear": .notes,
        "com.lukilabs.lukiapp": .notes,
        // code editors / terminals
        "com.microsoft.VSCode": .code,
        "com.todesktop.230313mzl4w4u92": .code,  // Cursor
        "com.apple.Terminal": .code,
        "com.googlecode.iterm2": .code,
        "com.mitchellh.ghostty": .code,
        "dev.warp.Warp-Stable": .code,
        "dev.zed.Zed": .code,
        "com.cmuxterm.app": .code,  // cmux
        // browsers
        "com.apple.Safari": .browser,
        "com.google.Chrome": .browser,
        "company.thebrowser.Browser": .browser,  // Arc
    ]

    /// Chip label for a bundle id. Unknown apps fall back to the engine's
    /// default mode, presented as plain "Text".
    static func displayName(forBundleID bundleID: String?) -> String {
        guard let bundleID, let category = byBundleID[bundleID] else { return "Text" }
        return category.displayName
    }
}
