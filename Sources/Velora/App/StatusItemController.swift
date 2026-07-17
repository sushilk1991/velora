import AppKit
import Foundation

/// Actions the menubar can trigger; implemented by the AppDelegate.
protocol StatusItemControllerDelegate: AnyObject {
    func statusItemToggleDictation()
    func statusItemReformatLast(mode: String)
    func statusItemPasteLastRaw()
    func statusItemTranscribeFile()
    func statusItemCancelTranscription()
    func statusItemStartMeeting()
    func statusItemStopMeeting()
    func statusItemDiscardMeeting()
    func statusItemOpenMeetings()
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
    var meetingRecordingTitle: String? { didSet { updateIcon() } }
    var meetingPreparingTitle: String?
    var meetingProcessingLabel: String?

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

    /// A newer release exists; the menu offers its release page. Menus
    /// rebuild on open, so setting this is enough.
    var updateAvailable: UpdateChecker.Update?

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
        // Preserve the explicit state computed in `menuNeedsUpdate`. Cocoa's
        // default auto-enable pass otherwise re-enables items that have an
        // action even when a meeting or dictation deliberately disables them.
        menu.autoenablesItems = false
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
        if meetingRecordingTitle != nil {
            symbolName = "record.circle"
        } else { switch effectiveState {
        case .idle: symbolName = "waveform"
        case .recording: symbolName = "waveform"
        case .transcribing:
            symbolName = NSImage(systemSymbolName: "waveform.badge.magnifyingglass",
                                 accessibilityDescription: nil) != nil
                ? "waveform.badge.magnifyingglass" : "ellipsis"
        case .error: symbolName = "waveform.badge.exclamationmark"
        } }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Velora")
        image?.isTemplate = true
        imageView.image = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        imageView.contentTintColor = .labelColor

        imageView.removeAllSymbolEffects()
        if effectiveState == .recording || meetingRecordingTitle != nil {
            imageView.addSymbolEffect(.variableColor.iterative.dimInactiveLayers)
        }
    }

    // MARK: - Menu (rebuilt on every open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let meeting = meetingRecordingTitle {
            let stop = NSMenuItem(
                title: "Stop \(Self.truncate(meeting, to: 34)) & Create Notes",
                action: #selector(stopMeeting), keyEquivalent: "")
            stop.target = self
            stop.attributedTitle = NSAttributedString(
                string: stop.title,
                attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold),
                             .foregroundColor: NSColor.systemRed])
            menu.addItem(stop)
            let discard = NSMenuItem(
                title: "Discard Meeting Recording…",
                action: #selector(discardMeeting), keyEquivalent: "")
            discard.target = self
            menu.addItem(discard)
        } else {
            let record = NSMenuItem(
                title: meetingPreparingTitle ?? "Record Meeting…",
                action: #selector(startMeeting), keyEquivalent: "")
            record.target = self
            record.isEnabled = meetingPreparingTitle == nil
                && iconState == .idle
                && transcriptionProgress == nil
            menu.addItem(record)
        }

        let startTitle = iconState == .recording ? "Stop Dictation" : "Start Dictation"
        let start = NSMenuItem(title: startTitle, action: #selector(toggleDictation), keyEquivalent: "")
        start.target = self
        // Consent/preparation does not use the microphone. Only an actual
        // meeting recording excludes foreground dictation.
        start.isEnabled = meetingRecordingTitle == nil
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

        // Recent transcripts live on the HUD pill's right-click menu — the
        // menubar stays a compact control surface (design round 2026-07).
        // When the pill is disabled, the menubar remains their only quick
        // access, so they come back here.
        if !AppConfig.shared.hudAlwaysVisible {
            let usable = history.recent(limit: 10)
                .filter { !$0.final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .prefix(3)
            if !usable.isEmpty {
                let header = NSMenuItem(
                    title: "Recent Transcriptions", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for record in usable {
                    let item = NSMenuItem(
                        title: Self.truncate(record.final, to: 40),
                        action: #selector(copyRecent(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = record.final
                    item.toolTip = "Click to copy"
                    item.indentationLevel = 1
                    menu.addItem(item)
                }
            }
        }

        let recents = history.recent(limit: 1)

        // "Reformat Last as…" — re-run the most recent dictation's cleanup in a
        // different mode and paste it back. The re-run modes need the archived
        // clip to STILL exist — retention pruning deletes old clips but history
        // keeps the row, and offering a reformat that can only fail is worse
        // than not offering it (review finding). "As Heard" needs only the
        // stored raw text, so it survives clip pruning: it's the escape hatch
        // for when cleanup got it wrong and the user just wants the words.
        let lastRaw = recents.first?.raw.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clipExists = recents.first?.audioPath
            .flatMap(AppConfig.archivedAudioURL(name:))
            .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if !lastRaw.isEmpty || clipExists {
            let reformat = NSMenuItem(title: "Reformat Last as", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            if !lastRaw.isEmpty {
                let rawItem = NSMenuItem(
                    title: "As Heard (original)", action: #selector(pasteLastRaw),
                    keyEquivalent: "")
                rawItem.target = self
                rawItem.toolTip = "Paste exactly what was transcribed, before any cleanup"
                submenu.addItem(rawItem)
            }
            if clipExists {
                if !lastRaw.isEmpty { submenu.addItem(.separator()) }
                for mode in DictationController.reformatModes {
                    let modeItem = NSMenuItem(
                        title: mode, action: #selector(reformatLast(_:)), keyEquivalent: "")
                    modeItem.target = self
                    modeItem.representedObject = mode
                    submenu.addItem(modeItem)
                }
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

        if let meetingProcessingLabel {
            let item = NSMenuItem(title: meetingProcessingLabel, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        addUpdateItems(to: menu)

        let historyItem = NSMenuItem(
            title: "History…", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        historyItem.image = NSImage(
            systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        menu.addItem(historyItem)

        let meetingsItem = NSMenuItem(
            title: "Meetings…", action: #selector(openMeetings), keyEquivalent: "")
        meetingsItem.target = self
        meetingsItem.image = NSImage(
            systemSymbolName: "person.2", accessibilityDescription: nil)
        menu.addItem(meetingsItem)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let assistant = NSMenuItem(
            title: "Setup Assistant…", action: #selector(openSetupAssistant), keyEquivalent: "")
        assistant.target = self
        assistant.image = NSImage(
            systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
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

    /// One menu line reflecting the updater's state: an offer to update
    /// in-place, live download progress, or a restart button once a verified
    /// build is staged. Falls back to the releases page when in-place
    /// installs are impossible (dev builds, unwritable /Applications, …).
    private func addUpdateItems(to menu: NSMenu) {
        func disabled(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = NSImage(
                systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            menu.addItem(item)
        }
        switch UpdateInstaller.shared.state {
        case .downloading(let version, let progress):
            disabled("Downloading Velora \(version) — \(Int(progress * 100))%")
        case .verifying(let version):
            disabled("Verifying Velora \(version)…")
        case .installing:
            disabled("Installing Update…")
        case .ready(let version):
            let item = NSMenuItem(
                title: "Restart to Update to \(version)",
                action: #selector(installStagedUpdate), keyEquivalent: "")
            item.target = self
            item.image = NSImage(
                systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(item)
        case .idle, .failed:
            guard let update = updateAvailable else {
                // A resume-adopted update that failed at install time has no
                // checker discovery to fall back on — still leave the user a
                // path forward.
                if case .failed(let reason) = UpdateInstaller.shared.state {
                    let item = NSMenuItem(
                        title: "Update Failed — Open Releases Page…",
                        action: #selector(openUpdatePage), keyEquivalent: "")
                    item.target = self
                    item.toolTip = reason
                    item.representedObject = URL(
                        string: "https://github.com/\(UpdateChecker.repoSlug)/releases/latest")
                    item.image = NSImage(
                        systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
                    menu.addItem(item)
                }
                return
            }
            let item: NSMenuItem
            if update.asset != nil, UpdateInstaller.canInstallInPlace {
                item = NSMenuItem(
                    title: "Update to Velora \(update.version)…",
                    action: #selector(startUpdate), keyEquivalent: "")
                item.representedObject = update
            } else {
                item = NSMenuItem(
                    title: "Update Available — \(update.version)…",
                    action: #selector(openUpdatePage), keyEquivalent: "")
                item.representedObject = update.page
            }
            if case .failed(let reason) = UpdateInstaller.shared.state {
                item.toolTip = "Last attempt failed: \(reason)"
            }
            item.target = self
            item.image = NSImage(
                systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            menu.addItem(item)
        }
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

    @objc private func pasteLastRaw() {
        delegate?.statusItemPasteLastRaw()
    }

    @objc private func transcribeFile() {
        delegate?.statusItemTranscribeFile()
    }

    @objc private func cancelTranscription() {
        delegate?.statusItemCancelTranscription()
    }

    @objc private func startMeeting() { delegate?.statusItemStartMeeting() }

    @objc private func stopMeeting() { delegate?.statusItemStopMeeting() }

    @objc private func discardMeeting() { delegate?.statusItemDiscardMeeting() }

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

    @objc private func openMeetings() { delegate?.statusItemOpenMeetings() }

    @objc private func openUpdatePage(_ sender: NSMenuItem) {
        guard let page = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(page)
    }

    @objc private func startUpdate(_ sender: NSMenuItem) {
        guard let update = sender.representedObject as? UpdateChecker.Update else { return }
        UpdateInstaller.shared.begin(update)
    }

    @objc private func installStagedUpdate() {
        UpdateInstaller.shared.installAndRelaunch()
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
