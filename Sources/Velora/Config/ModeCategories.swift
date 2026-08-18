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
        // code editors
        "com.microsoft.VSCode": .code,
        "com.todesktop.230313mzl4w4u92": .code,  // Cursor
        "dev.zed.Zed": .code,
        // terminals
        "com.apple.Terminal": .terminal,
        "com.googlecode.iterm2": .terminal,
        "com.mitchellh.ghostty": .terminal,
        "dev.warp.Warp-Stable": .terminal,
        "org.alacritty": .terminal,
        "net.kovidgoyal.kitty": .terminal,
        "com.cmuxterm.app": .terminal,  // cmux
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

    /// The category for a bundle id, or nil for unknown apps.
    static func category(forBundleID bundleID: String?) -> ModeCategory? {
        guard let bundleID else { return nil }
        return byBundleID[bundleID]
    }
}
