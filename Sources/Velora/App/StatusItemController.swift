import AppKit
import Foundation

/// Actions the menubar can trigger; implemented by the AppDelegate.
protocol StatusItemControllerDelegate: AnyObject {
    func statusItemToggleDictation()
    func statusItemReformatLast(mode: String)
    func statusItemTranscribeFile()
    func statusItemCancelTranscription()
    func statusItemOpenSettings()
    func statusItemOpenHistory()
    func statusItemOpenSetupAssistant()
    func statusItemCheckPermissions()
}

/// The menubar presence (design brief §3): template SF Symbol that swaps per
/// state, and a minimal menu — Start Dictation, last three transcriptions
/// (click copies), Settings…, Setup Assistant…, Check Permissions… (degraded
/// only), Quit.
final class StatusItemController: NSObject, NSMenuDelegate {
    enum IconState {
        case idle, recording, transcribing, error
    }

    weak var delegate: StatusItemControllerDelegate?

    private var statusItem: NSStatusItem?
    private var imageView: NSImageView?
    private let history: HistoryStore
    private var iconState: IconState = .idle
    /// Engine/permission degradation reason, shown in the menu when set.
    var degradedReason: String? {
        didSet { updateIcon() }
    }

    /// Non-nil while a file transcription runs ("Transcribing… 45%"); the
    /// menu shows progress + cancel instead of the transcribe action.
    var transcriptionProgress: String?

    /// First-run setup status ("Downloading the speech model (1.6 GB) — 42%");
    /// shown as a disabled menu line + button tooltip while models download.
    var setupStatus: String? {
        didSet {
            guard setupStatus != oldValue else { return }
            statusItem?.button?.toolTip = setupStatus ?? "Velora"
            // Menus only rebuild on open — tick the row live if it's showing
            // (a first-run user plausibly sits watching this exact line).
            if let setupMenuItem, let setupStatus {
                setupMenuItem.title = setupStatus
            }
        }
    }

    /// The live progress row, while the menu is open (weak: menus rebuild).
    private weak var setupMenuItem: NSMenuItem?

    init(history: HistoryStore) {
        self.history = history
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            // Symbol effects (variableColor while recording) need an
            // NSImageView; NSStatusBarButton.image can't animate symbols.
            let view = NSImageView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.imageScaling = .scaleProportionallyDown
            button.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                view.widthAnchor.constraint(lessThanOrEqualToConstant: 18),
                view.heightAnchor.constraint(lessThanOrEqualToConstant: 18),
            ])
            imageView = view
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        updateIcon()
    }

    // MARK: - Icon states (design brief §3 table)

    func setIconState(_ state: IconState) {
        iconState = state
        updateIcon()
    }

    private func updateIcon() {
        guard let imageView else { return }

        let effectiveState: IconState =
            (degradedReason != nil && iconState == .idle) ? .error : iconState

        let symbolName: String
        switch effectiveState {
        case .idle: symbolName = "waveform"
        case .recording: symbolName = "waveform"
        case .transcribing:
            symbolName = NSImage(systemSymbolName: "waveform.badge.magnifyingglass",
                                 accessibilityDescription: nil) != nil
                ? "waveform.badge.magnifyingglass" : "ellipsis"
        case .error: symbolName = "waveform.badge.exclamationmark"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Velora")
        image?.isTemplate = true
        imageView.image = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        imageView.contentTintColor = .labelColor

        imageView.removeAllSymbolEffects()
        if effectiveState == .recording {
            imageView.addSymbolEffect(.variableColor.iterative.dimInactiveLayers)
        }
    }

    // MARK: - Menu (rebuilt on every open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let startTitle = iconState == .recording ? "Stop Dictation" : "Start Dictation"
        let start = NSMenuItem(title: startTitle, action: #selector(toggleDictation), keyEquivalent: "")
        start.target = self
        start.attributedTitle = NSAttributedString(
            string: startTitle,
            attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
        menu.addItem(start)

        // First-run setup: models are downloading — say so instead of letting
        // a dead "Start Dictation" mystify a brand-new user.
        if let setupStatus {
            let item = NSMenuItem(title: setupStatus, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            setupMenuItem = item
        }

        let recents = history.recent(limit: 3)
        if !recents.isEmpty {
            let header = NSMenuItem(title: "Last transcription", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for record in recents {
                let title = Self.truncate(record.final, to: 40)
                let item = NSMenuItem(title: title, action: #selector(copyRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = record.final
                item.toolTip = "Click to copy"
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        // "Reformat Last as…" — re-run the most recent dictation's cleanup in a
        // different mode and paste it back. Only when the archived clip STILL
        // exists — retention pruning deletes old clips but history keeps the
        // row, and offering a reformat that can only fail is worse than not
        // offering it (review finding).
        if let clip = recents.first?.audioPath,
           FileManager.default.fileExists(
               atPath: AppConfig.audioDirectory.appendingPathComponent(clip).path) {
            let reformat = NSMenuItem(title: "Reformat Last as", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for mode in DictationController.reformatModes {
                let modeItem = NSMenuItem(
                    title: mode, action: #selector(reformatLast(_:)), keyEquivalent: "")
                modeItem.target = self
                modeItem.representedObject = mode
                submenu.addItem(modeItem)
            }
            reformat.submenu = submenu
            menu.addItem(reformat)
        }

        if let progress = transcriptionProgress {
            let item = NSMenuItem(
                title: "\(progress) — Cancel", action: #selector(cancelTranscription),
                keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(
                title: "Transcribe Audio File…", action: #selector(transcribeFile),
                keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let historyItem = NSMenuItem(
            title: "History…", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let assistant = NSMenuItem(
            title: "Setup Assistant…", action: #selector(openSetupAssistant), keyEquivalent: "")
        assistant.target = self
        menu.addItem(assistant)

        if degradedReason != nil || Permissions.anyMissing {
            let check = NSMenuItem(
                title: "Check Permissions…", action: #selector(checkPermissions), keyEquivalent: "")
            check.target = self
            if let reason = degradedReason { check.toolTip = reason }
            menu.addItem(check)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Velora", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit - 1)) + "…"
    }

    // MARK: - Actions

    @objc private func toggleDictation() {
        delegate?.statusItemToggleDictation()
    }

    @objc private func reformatLast(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        delegate?.statusItemReformatLast(mode: mode)
    }

    @objc private func transcribeFile() {
        delegate?.statusItemTranscribeFile()
    }

    @objc private func cancelTranscription() {
        delegate?.statusItemCancelTranscription()
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func openSettings() {
        delegate?.statusItemOpenSettings()
    }

    @objc private func openHistory() {
        delegate?.statusItemOpenHistory()
    }

    @objc private func openSetupAssistant() {
        delegate?.statusItemOpenSetupAssistant()
    }

    @objc private func checkPermissions() {
        delegate?.statusItemCheckPermissions()
    }
}

private extension NSFont {
    /// Returns a copy of this font with the given weight.
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
