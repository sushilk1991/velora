import Foundation

/// Small, thread-safe mirror of user-authored app assignments. Loading JSON is
/// kept off the hotkey path: the cache is populated at controller startup and
/// refreshed whenever the Modes editor writes or deletes a mode.
final class ModeApplicationIndex {
    static let shared = ModeApplicationIndex()

    private let lock = NSLock()
    private var namesByBundleID: [String: String] = [:]

    static func build(_ assignments: [(name: String, applications: [String])]) -> [String: String] {
        var result: [String: String] = [:]
        for assignment in assignments {
            for application in assignment.applications {
                let key = application.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty, result[key] == nil else { continue }
                result[key] = assignment.name
            }
        }
        return result
    }

    func reload(directory: URL = AppConfig.modesDirectory) {
        let urls = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let assignments = urls.compactMap { url -> (String, [String])? in
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let name = object["name"] as? String,
                  let applications = object["apps"] as? [String]
            else { return nil }
            return (name, applications)
        }
        let refreshed = Self.build(assignments)
        lock.lock()
        namesByBundleID = refreshed
        lock.unlock()
    }

    func modeName(forBundleID bundleID: String?) -> String? {
        guard let key = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return namesByBundleID[key]
    }
}

/// Client-side mirror of the engine's bundle-id → app-category map
/// (`engine/src/velora_engine/formatting.py`, `CATEGORY_BY_BUNDLE`).
///
/// The engine only reports the resolved mode with the `final` event — too late
/// for the HUD's context chip. User-authored assignments come from the cached
/// `ModeApplicationIndex`; this table supplies the automatic category fallback.
/// This duplication is deliberate; keep the bundle ids in sync with the
/// engine when adding apps.
enum ModeCategory: String {
    case chat, email, notes, code, terminal, browser

    /// Human label shown in the HUD context chip.
    var displayName: String {
        switch self {
        case .chat: return "Message"
        case .email: return "Email"
        case .notes: return "Notes"
        case .code: return "Code"
        case .terminal: return "Terminal"
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
        "org.telegram.desktop": .chat,
        "net.whatsapp.WhatsApp": .chat,
        "org.whispersystems.signal-desktop": .chat,
        "com.microsoft.teams2": .chat,
        "com.microsoft.teams": .chat,
        "com.facebook.archon": .chat,  // Messenger
        // email
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.SparkDesktop": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.mimestream.Mimestream": .email,
        // notes / documents
        "com.apple.Notes": .notes,
        "md.obsidian": .notes,
        "notion.id": .notes,
        "net.shinyfrog.bear": .notes,
        "com.lukilabs.lukiapp": .notes,  // Craft
        "com.apple.TextEdit": .notes,
        "com.microsoft.Word": .notes,
        "com.apple.iWork.Pages": .notes,
        "com.agiletortoise.Drafts-OSX": .notes,
        "com.culturedcode.ThingsMac": .notes,
        // code editors
        "com.microsoft.VSCode": .code,
        "com.todesktop.230313mzl4w4u92": .code,  // Cursor
        "dev.zed.Zed": .code,
        "com.sublimetext.4": .code,
        "com.sublimetext.3": .code,
        "com.apple.dt.Xcode": .code,
        "com.exafunction.windsurf": .code,
        "com.jetbrains.intellij": .code,
        "com.jetbrains.intellij.ce": .code,
        "com.jetbrains.pycharm": .code,
        "com.jetbrains.pycharm.ce": .code,
        "com.jetbrains.WebStorm": .code,
        "com.jetbrains.goland": .code,
        "com.jetbrains.rider": .code,
        "com.jetbrains.CLion": .code,
        "com.jetbrains.PhpStorm": .code,
        "com.jetbrains.rubymine": .code,
        "com.jetbrains.datagrip": .code,
        // terminals
        "com.apple.Terminal": .terminal,
        "com.googlecode.iterm2": .terminal,
        "com.mitchellh.ghostty": .terminal,
        "dev.warp.Warp-Stable": .terminal,
        "org.alacritty": .terminal,
        "net.kovidgoyal.kitty": .terminal,
        "com.cmuxterm.app": .terminal,  // cmux
        "com.github.wez.wezterm": .terminal,
        // browsers
        "com.apple.Safari": .browser,
        "com.google.Chrome": .browser,
        "company.thebrowser.Browser": .browser,  // Arc
        "company.thebrowser.dia": .browser,  // Dia
        "org.mozilla.firefox": .browser,
        "com.brave.Browser": .browser,
        "com.microsoft.edgemac": .browser,
        "com.vivaldi.Vivaldi": .browser,
        "com.operasoftware.Opera": .browser,
        "com.kagi.kagimacOS": .browser,  // Orion
        "app.zen-browser.zen": .browser,
    ]

    /// Web-app site slug → category, mirroring the engine's `_SITE_CATEGORY`.
    /// Lets the HUD chip say "Email" in Gmail instead of the generic
    /// "Browser" — the same refinement the engine applies to the mode.
    static let bySiteSlug: [String: ModeCategory] = [
        "gmail": .email, "outlook": .email, "proton": .email,
        "fastmail": .email, "superhuman": .email, "hey": .email,
        "zoho": .email, "yahoo": .email,
        "gdocs": .notes, "notion": .notes, "obsidian": .notes,
        "linear": .notes, "keep": .notes, "evernote": .notes,
        "onenote": .notes, "coda": .notes, "craft": .notes,
        "confluence": .notes,
        "slack": .chat, "discord": .chat, "whatsapp": .chat,
        "messenger": .chat, "telegram": .chat, "teams": .chat,
        "gchat": .chat, "instagram": .chat,
    ]

    /// Chip label for a bundle id. Unknown apps fall back to the engine's
    /// default mode, presented as plain "Text". A browser with a detected
    /// web-app site shows that site's category instead of "Browser".
    static func displayName(forBundleID bundleID: String?, siteSlug: String? = nil) -> String {
        guard let bundleID, let category = byBundleID[bundleID] else { return "Text" }
        if category == .browser, let siteSlug,
           let refined = bySiteSlug[siteSlug.lowercased()] {
            return refined.displayName
        }
        return category.displayName
    }

    /// The category for a bundle id, or nil for unknown apps.
    static func category(forBundleID bundleID: String?) -> ModeCategory? {
        guard let bundleID else { return nil }
        return byBundleID[bundleID]
    }
}
