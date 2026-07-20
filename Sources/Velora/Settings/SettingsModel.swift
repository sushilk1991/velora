import AppKit
import Combine
import Foundation
import ServiceManagement

/// Notifications for settings changes that other components react to live.
extension Notification.Name {
    /// Hotkey choice changed — the hotkey monitor re-reads its config.
    static let veloraHotkeyChanged = Notification.Name("VeloraHotkeyChanged")
    /// Accessibility flipped from denied to granted (onboarding live-poll) —
    /// the hotkey monitor reinstalls so a pre-grant dead event tap comes back
    /// without an app relaunch.
    static let veloraAccessibilityGranted = Notification.Name("VeloraAccessibilityGranted")
}

/// A model the running engine advertises via the `status` reply. Drives the
/// dynamic STT picker (new engine models appear without an app update) and the
/// History reprocess menu.
struct EngineModel: Identifiable, Equatable {
    let id: String
    /// "stt" | "cleanup"
    let kind: String
    let backend: String
    let size: String
    let description: String

    /// Short human label — the description if present, else the repo basename.
    var displayName: String {
        if !description.isEmpty { return description }
        return id.split(separator: "/").last.map(String.init) ?? id
    }

    /// Decodes the array under `status.models`; tolerates missing/typed fields.
    static func parse(_ raw: Any?) -> [EngineModel] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let id = dict["id"] as? String else { return nil }
            let size: String
            if let s = dict["size"] as? String { size = s }
            else if let n = dict["size"] as? NSNumber { size = "\(n) GB" }
            else { size = "" }
            return EngineModel(
                id: id,
                kind: dict["kind"] as? String ?? "stt",
                backend: dict["backend"] as? String ?? "",
                size: size,
                description: dict["description"] as? String ?? "")
        }
    }
}

/// Observable bridge between the SwiftUI settings/onboarding UI and
/// `AppConfig` + the engine. Writing a property persists it and, where
/// relevant, pushes `reload_config` / `set_model` to the engine.
final class SettingsModel: ObservableObject {
    private let config = AppConfig.shared
    private weak var supervisor: EngineSupervisor?
    private var statusObserver: NSObjectProtocol?
    private var hudPrefsObserver: NSObjectProtocol?
    private var updateStateObserver: NSObjectProtocol?
    let dictionary: DictionaryRepository
    let dictionarySync: ICloudDictionarySync
    private var dictionaryRowsObserver: AnyCancellable?
    private var dictionarySyncObserver: AnyCancellable?

    @Published var dictionaryRows: [DictionaryRow] = []
    @Published var dictionarySyncStatus: DictionarySyncStatus = .idle

    func addDictionaryEntry(writeAs: String, heardAs: String?) throws {
        _ = try dictionary.add(writeAs: writeAs, heardAs: heardAs)
    }

    func updateDictionaryEntry(
        _ row: DictionaryRow,
        writeAs: String,
        heardAs: String?
    ) throws {
        try dictionary.update(id: row.id, writeAs: writeAs, heardAs: heardAs)
    }

    func promoteLearnedEntry(
        _ row: DictionaryRow,
        writeAs: String,
        heardAs: String
    ) throws {
        try dictionary.promoteLearned(
            id: row.id, writeAs: writeAs, heardAs: heardAs)
    }

    func removeDictionaryEntry(_ row: DictionaryRow) throws {
        try dictionary.remove(id: row.id)
    }

    func clearDictionaryEntries(_ source: DictionarySource) throws {
        switch source {
        case .added: try dictionary.clear(.manual)
        case .learned: try dictionary.clear(.learned)
        case .automatic: try dictionary.clear(.auto)
        }
    }

    func retryDictionarySync() { dictionarySync.syncNow() }

    func resolveDictionaryAccountChange(_ decision: DictionaryAccountDecision) {
        dictionarySync.resolveAccountChange(decision)
    }

    var dictionaryFolderIsAvailable: Bool { dictionarySync.folderURL != nil }

    func openDictionaryFolder() {
        guard let folder = dictionarySync.folderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// One-line outcome of the last dictionary import/export, shown inline.
    @Published var dictionaryTransferResult: String?

    /// One-line outcome of the last full settings import/export.
    @Published var settingsTransferResult: String?

    func exportSettings() {
        settingsTransferResult = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "velora-settings.json"
        panel.title = "Export Velora Settings"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.config.exportSettingsData().write(to: url, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
                self.settingsTransferResult = "Settings exported"
            } catch {
                self.settingsTransferResult = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func importSettings() {
        settingsTransferResult = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import Velora Settings"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let imported = try AppConfig.portableSettings(from: Data(contentsOf: url))
                let confirmation = NSAlert()
                confirmation.messageText = "Replace your Velora settings?"
                var details =
                    "This changes preferences, shortcuts, and the selected speech model. "
                    + "History, dictionary, modes, permissions, microphone choice, "
                    + "Calendar access, and local-agent access stay unchanged."
                if imported.models.speech != self.sttModel {
                    details += " The selected speech model may need a large download on this Mac."
                }
                let currentEngine = self.config.portableEngineSettings
                if imported.engine.audioRetentionDays < currentEngine.audioRetentionDays {
                    details += " Dictation recordings older than \(Int(imported.engine.audioRetentionDays)) days will be removed during cleanup."
                }
                let importedCap = imported.engine.audioMaximumMegabytes
                let currentCap = currentEngine.audioMaximumMegabytes
                if importedCap > 0, currentCap == 0 || importedCap < currentCap {
                    details += " Dictation recordings beyond \(Int(importedCap)) MB total will be removed during cleanup."
                }
                if imported.meetings.audioRetentionDays < self.meetingAudioRetentionDays {
                    details += " Meeting audio older than \(imported.meetings.audioRetentionDays) days will be removed."
                }
                confirmation.informativeText = details
                confirmation.addButton(withTitle: "Import")
                confirmation.addButton(withTitle: "Cancel")
                guard confirmation.runModal() == .alertFirstButtonReturn else { return }

                try self.config.applyPortableSettings(imported)
                self.applyImportedSettings(imported)
                self.settingsTransferResult = "Settings imported"
            } catch {
                self.settingsTransferResult = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    /// Exports the personal dictionary (corrections + vocabulary) to a JSON
    /// file the user picks — Superwhisper can't move vocab between Macs;
    /// Velora can.
    func exportDictionary() {
        dictionaryTransferResult = nil
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "velora-dictionary.json"
        panel.title = "Export Dictionary"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let data = try self.dictionary.exportData()
                try data.write(to: url)
                self.dictionaryTransferResult = "Exported \(self.dictionary.rows.count) active entries"
            } catch {
                self.dictionaryTransferResult = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Imports active entries additively. Existing local entries win and an
    /// imported clear/tombstone can never remove data from this Mac.
    func importDictionary() {
        dictionaryTransferResult = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.title = "Import Dictionary"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let result = try self.dictionary.importData(Data(contentsOf: url))
                if result.added == 0 {
                    self.dictionaryTransferResult = "No new entries — kept \(result.keptExisting) existing"
                } else if result.keptExisting == 0 {
                    self.dictionaryTransferResult = "Imported \(result.added) entries"
                } else {
                    self.dictionaryTransferResult = "Imported \(result.added), kept \(result.keptExisting) existing"
                }
            } catch {
                self.dictionaryTransferResult = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    /// Models advertised by the running engine (from the `status` reply). Empty
    /// until the first reply arrives; the UI falls back to the static catalog.
    @Published var engineModels: [EngineModel] = []
    /// Retention window for archived clips, reported by the engine (days).
    @Published var audioRetentionDays: Double = 180

    /// The active cleanup model and the one the engine recommends for this Mac's
    /// RAM (from the `status` reply). Empty until the first status lands.
    @Published var cleanupModel: String = ""
    @Published var recommendedCleanupModel: String = ""

    /// STT models the engine offers, in advertised order.
    var sttEngineModels: [EngineModel] { engineModels.filter { $0.kind == "stt" } }
    /// Cleanup/formatting LLMs the engine offers, smallest first.
    var cleanupEngineModels: [EngineModel] { engineModels.filter { $0.kind == "cleanup" } }

    /// Reads the engine-owned `cleanup_model` straight from config.json (used to
    /// seed the picker/guard before the engine's status reply arrives).
    private static func cleanupModelFromDisk() -> String? {
        guard let data = try? Data(contentsOf: AppConfig.configFileURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["cleanup_model"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    /// Switches the cleanup LLM (engine downloads on demand, persists the choice).
    func setCleanupModel(_ id: String) {
        guard !id.isEmpty, id != cleanupModel else { return }
        cleanupModel = id
        config.cleanupModel = id
        supervisor?.send(["cmd": "set_model", "model": id, "kind": "cleanup"])
    }

    init(
        supervisor: EngineSupervisor?,
        dictionary: DictionaryRepository,
        dictionarySync: ICloudDictionarySync
    ) {
        self.supervisor = supervisor
        self.dictionary = dictionary
        self.dictionarySync = dictionarySync
        dictionaryRows = dictionary.rows
        dictionarySyncStatus = dictionarySync.status
        launchAtLogin = Self.launchAtLoginEnabled
        hotkey = config.hotkey
        editHotkey = config.editHotkey
        voiceEdit = config.voiceEdit
        hotkeyMode = config.hotkeyMode
        inputDeviceUID = config.inputDeviceUID
        soundsEnabled = config.soundsEnabled
        soundVolume = config.soundVolume
        hudPosition = config.hudPosition
        hudAlwaysVisible = config.hudAlwaysVisible
        appearance = config.appearance
        language = config.language
        autoPunctuation = config.autoPunctuation
        romanizeOutput = config.romanizeOutput
        learnFromEdits = config.learnFromEdits
        voiceCommands = config.voiceCommands
        vocabMining = config.vocabMining
        smartTerminal = config.smartTerminal
        sttModel = config.sttModel
        saveAudio = config.saveAudio
        typingWPM = config.typingWPM
        localAgentAccess = config.localAgentAccess
        updateChecks = config.updateChecks
        autoInstallUpdates = config.autoInstallUpdates
        updateState = UpdateInstaller.shared.state
        availableUpdate = UpdateChecker.shared.available
        meetingSuggestions = config.meetingSuggestions
        meetingCalendar = config.meetingCalendar
        meetingAudioRetentionDays = config.meetingAudioRetentionDays
        meetingDiarization = config.meetingDiarization
        // Seed the active cleanup model from config.json so the model-cache
        // "in use" delete-guard holds even before the engine's status reply
        // lands (the engine owns this key; status refreshes it).
        cleanupModel = config.cleanupModel ?? Self.cleanupModelFromDisk() ?? ""
        config.launchAtLogin = launchAtLogin

        statusObserver = NotificationCenter.default.addObserver(
            forName: .veloraEngineStatus, object: nil, queue: .main
        ) { [weak self] note in
            self?.applyStatus(note.userInfo?["payload"] as? [String: Any])
        }
        // A position change made from the HUD's context menu (or a drag that
        // flips it to Custom) must reflect in an open Settings window.
        hudPrefsObserver = NotificationCenter.default.addObserver(
            forName: .veloraHUDPrefsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.syncingHUDPrefs = true
            if self.hudPosition != self.config.hudPosition {
                self.hudPosition = self.config.hudPosition
            }
            if self.hudAlwaysVisible != self.config.hudAlwaysVisible {
                self.hudAlwaysVisible = self.config.hudAlwaysVisible
            }
            if self.inputDeviceUID != self.config.inputDeviceUID {
                self.inputDeviceUID = self.config.inputDeviceUID
            }
            self.syncingHUDPrefs = false
        }
        dictionaryRowsObserver = dictionary.$rows.sink { [weak self] _ in
            self?.dictionaryRows = dictionary.rows
        }
        dictionarySyncObserver = dictionarySync.$status.sink { [weak self] status in
            self?.dictionarySyncStatus = status
        }
        updateStateObserver = NotificationCenter.default.addObserver(
            forName: .veloraUpdateStateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.updateState = UpdateInstaller.shared.state
            self.availableUpdate = UpdateChecker.shared.available
        }
        requestStatus()
    }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        if let hudPrefsObserver { NotificationCenter.default.removeObserver(hudPrefsObserver) }
        if let updateStateObserver { NotificationCenter.default.removeObserver(updateStateObserver) }
    }

    /// Asks the engine for its current status (models, retention, …). Cheap;
    /// safe to call whenever a settings surface appears.
    func requestStatus() {
        supervisor?.send(["cmd": "status"])
    }

    /// Refreshes every live setting surface after the validated document has
    /// been committed. Persistence observers are suppressed, then the few
    /// required runtime effects are applied once.
    private func applyImportedSettings(_ imported: SettingsDocument.PortableSettings) {
        let previousSTTModel = sttModel
        applyingImportedSettings = true
        appearance = imported.general.appearance
        soundsEnabled = imported.general.soundsEnabled
        soundVolume = imported.general.soundVolume
        hudPosition = imported.hud.position
        hudAlwaysVisible = imported.hud.alwaysVisible

        hotkey = imported.shortcuts.dictation
        editHotkey = imported.shortcuts.editSelection
        voiceEdit = imported.shortcuts.voiceEdit
        hotkeyMode = imported.shortcuts.behavior

        language = imported.dictation.language
        autoPunctuation = imported.dictation.autoPunctuation
        saveAudio = imported.dictation.saveAudio
        romanizeOutput = imported.dictation.romanizeOutput
        learnFromEdits = imported.dictation.learnFromEdits
        vocabMining = imported.dictation.vocabularyMining
        smartTerminal = imported.dictation.smartTerminal
        voiceCommands = imported.dictation.voiceCommands
        typingWPM = imported.dictation.typingWordsPerMinute
        audioRetentionDays = imported.engine.audioRetentionDays

        meetingSuggestions = imported.meetings.suggestions
        meetingAudioRetentionDays = imported.meetings.audioRetentionDays
        meetingDiarization = imported.meetings.diarization
        updateChecks = imported.updates.checkAutomatically
        autoInstallUpdates = imported.updates.installAutomatically

        sttModel = imported.models.speech
        applyingImportedSettings = false

        // The custom HUD origin/edge and typing fallback list have no published
        // SettingsModel properties; AppConfig already owns their imported values.
        Self.applyAppearance(imported.general.appearance)
        NotificationCenter.default.post(name: .veloraHUDPrefsChanged, object: nil)
        NotificationCenter.default.post(name: .veloraHotkeyChanged, object: nil)
        if imported.models.speech != previousSTTModel {
            supervisor?.send(["cmd": "set_model", "model": imported.models.speech])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.requestStatus()
            }
        }
        supervisor?.send(["cmd": "reload_config"])
    }

    private func applyStatus(_ payload: [String: Any]?) {
        guard let payload else { return }
        let models = EngineModel.parse(payload["models"])
        if !models.isEmpty { engineModels = models }
        if let days = payload["audio_retention_days"] as? NSNumber {
            audioRetentionDays = days.doubleValue
        }
        if let active = payload["cleanup_model"] as? String, !active.isEmpty {
            cleanupModel = active
            config.cleanupModel = active
        }
        if let rec = payload["recommended_cleanup_model"] as? String {
            recommendedCleanupModel = rec
        }
        // The engine is the authority on the ACTIVE STT model: a set_model it
        // refused (busy dictating/reprocessing) must not leave the picker and
        // config claiming a switch that never happened (review finding). The
        // sync path skips the engine send but reconciles config.json too.
        if let stt = payload["stt_model"] as? String, !stt.isEmpty, stt != sttModel {
            syncingFromEngine = true
            sttModel = stt
            syncingFromEngine = false
        }
    }

    /// True while adopting engine-reported state — property observers must
    /// not echo a `set_model` back for it.
    private var syncingFromEngine = false
    /// The import transaction already committed AppConfig in one write. This
    /// prevents published-property observers from writing it dozens more times
    /// or starting unrelated work such as an updater download.
    private var applyingImportedSettings = false

    // MARK: - General

    /// Guards the silent revert below: without it a failing revert re-enters
    /// didSet and ping-pongs register/unregister until stack overflow.
    private var revertingLaunchAtLogin = false

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, !revertingLaunchAtLogin else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                config.launchAtLogin = launchAtLogin
            } catch {
                NSLog("Velora: launch-at-login toggle failed: \(error)")
                // Revert silently (fails for non-bundled dev binaries).
                revertingLaunchAtLogin = true
                launchAtLogin = oldValue
                revertingLaunchAtLogin = false
                config.launchAtLogin = oldValue
            }
        }
    }

    private static var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @Published var hudPosition: HUDPosition {
        didSet {
            guard !applyingImportedSettings, !syncingHUDPrefs,
                  hudPosition != oldValue else { return }
            config.hudPosition = hudPosition
            NotificationCenter.default.post(name: .veloraHUDPrefsChanged, object: nil)
        }
    }

    @Published var hudAlwaysVisible: Bool {
        didSet {
            guard !applyingImportedSettings, !syncingHUDPrefs,
                  hudAlwaysVisible != oldValue else { return }
            config.hudAlwaysVisible = hudAlwaysVisible
            NotificationCenter.default.post(name: .veloraHUDPrefsChanged, object: nil)
        }
    }

    /// True while adopting a change made from the HUD's own context menu —
    /// the didSet observers must not echo it back as another notification.
    private var syncingHUDPrefs = false

    @Published var appearance: String {
        didSet {
            guard !applyingImportedSettings else { return }
            config.appearance = appearance
            Self.applyAppearance(appearance)
        }
    }

    static func applyAppearance(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: - Dictation

    @Published var hotkeyMode: HotkeyMode {
        didSet {
            guard !applyingImportedSettings else { return }
            config.hotkeyMode = hotkeyMode
        }
    }

    /// Microphone UID to record from; nil follows the system default. Applied
    /// at the next capture start — no engine push needed.
    @Published var inputDeviceUID: String? {
        didSet {
            guard inputDeviceUID != oldValue else { return }
            config.inputDeviceUID = inputDeviceUID
        }
    }

    @Published var language: String {
        didSet {
            guard !applyingImportedSettings else { return }
            config.language = language
            supervisor?.send(["cmd": "reload_config"])
        }
    }

    @Published var autoPunctuation: Bool {
        didSet {
            guard !applyingImportedSettings else { return }
            config.autoPunctuation = autoPunctuation
            supervisor?.send(["cmd": "reload_config"])
        }
    }

    @Published var romanizeOutput: Bool {
        didSet {
            guard !applyingImportedSettings, romanizeOutput != oldValue else { return }
            config.romanizeOutput = romanizeOutput
            supervisor?.send(["cmd": "reload_config"])
        }
    }

    @Published var learnFromEdits: Bool {
        didSet {
            guard !applyingImportedSettings else { return }
            config.learnFromEdits = learnFromEdits
        }
    }

    @Published var voiceCommands: Bool {
        didSet {
            guard !applyingImportedSettings else { return }
            config.voiceCommands = voiceCommands
        }
    }

    /// Typing speed the "time saved" metrics compare against (Intelligence tab).
    @Published var typingWPM: Int {
        didSet {
            guard !applyingImportedSettings else { return }
            config.typingWPM = typingWPM
        }
    }

    @Published var localAgentAccess: Bool {
        didSet { config.localAgentAccess = localAgentAccess }
    }

    // MARK: Agent integration (CLI on PATH + agent skill)

    @Published var cliInstallPath: String?
    @Published var agentSkillInstalled = false
    @Published var agentIntegrationError: String?

    func refreshAgentIntegration() {
        cliInstallPath = AgentIntegration.installedCLIPath()
        agentSkillInstalled = AgentIntegration.skillInstalled()
    }

    func installCLITool() {
        do {
            cliInstallPath = try AgentIntegration.installCLI()
            agentIntegrationError = nil
        } catch {
            agentIntegrationError = error.localizedDescription
        }
    }

    func installAgentSkill() {
        do {
            _ = try AgentIntegration.installSkill()
            agentSkillInstalled = true
            agentIntegrationError = nil
        } catch {
            agentIntegrationError = error.localizedDescription
        }
    }

    @Published var updateChecks: Bool {
        didSet {
            guard !applyingImportedSettings else { return }
            config.updateChecks = updateChecks
        }
    }

    @Published var autoInstallUpdates: Bool {
        didSet {
            guard !applyingImportedSettings else { return }
            config.autoInstallUpdates = autoInstallUpdates
            // Flipping the toggle on with an update already discovered should
            // act on it now, not wait for tomorrow's check.
            if autoInstallUpdates, let update = availableUpdate,
               UpdateInstaller.canInstallInPlace {
                UpdateInstaller.shared.begin(update)
            }
        }
    }

    /// Manual "Check Now" state for the General tab; nil = never ran.
    @Published var updateCheckStatus: String?

    /// Mirrors UpdateInstaller.shared.state / UpdateChecker.shared.available
    /// for the Updates section (kept fresh by the state-change observer).
    @Published var updateState: UpdateInstaller.State
    @Published var availableUpdate: UpdateChecker.Update?

    func checkForUpdatesNow() {
        updateCheckStatus = "Checking…"
        UpdateChecker.shared.check { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .upToDate:
                self.updateCheckStatus = "You're on the latest version."
            case .updateAvailable(let update):
                self.updateCheckStatus = "Velora \(update.version) is available."
                self.availableUpdate = update
            case .failed(let reason):
                self.updateCheckStatus = reason
            }
        }
    }

    /// Whether the Updates section can offer a one-click in-place install.
    var canInstallUpdateInPlace: Bool {
        availableUpdate?.asset != nil && UpdateInstaller.canInstallInPlace
    }

    func startUpdateInstall() {
        guard let update = availableUpdate else { return }
        UpdateInstaller.shared.begin(update)
    }

    func installStagedUpdate() {
        UpdateInstaller.shared.installAndRelaunch()
    }

    func discardStagedUpdate() {
        UpdateInstaller.shared.discardStagedUpdate()
    }

    func cancelUpdateDownload() {
        UpdateInstaller.shared.cancelDownload()
    }

    func openReleasesPage() {
        let url = availableUpdate?.page
            ?? URL(string: "https://github.com/\(UpdateChecker.repoSlug)/releases/latest")!
        NSWorkspace.shared.open(url)
    }

    @Published var meetingSuggestions: Bool {
        didSet {
            guard !applyingImportedSettings else { return }
            config.meetingSuggestions = meetingSuggestions
        }
    }

    @Published var meetingCalendar: Bool {
        didSet { config.meetingCalendar = meetingCalendar }
    }

    @Published var meetingAudioRetentionDays: Int {
        didSet {
            guard !applyingImportedSettings else { return }
            config.meetingAudioRetentionDays = meetingAudioRetentionDays
        }
    }

    @Published var meetingDiarization: Bool {
        didSet {
            guard !applyingImportedSettings, meetingDiarization != oldValue else { return }
            config.meetingDiarization = meetingDiarization
            supervisor?.send(["cmd": "reload_config"])
        }
    }

    @Published var vocabMining: Bool {
        didSet {
            guard !applyingImportedSettings, vocabMining != oldValue else { return }
            config.vocabMining = vocabMining
            supervisor?.send(["cmd": "reload_config"])
        }
    }

    @Published var smartTerminal: Bool {
        didSet {
            guard !applyingImportedSettings, smartTerminal != oldValue else { return }
            config.smartTerminal = smartTerminal
            supervisor?.send(["cmd": "reload_config"])
        }
    }

    @Published var soundsEnabled: Bool {
        didSet {
            guard !applyingImportedSettings else { return }
            config.soundsEnabled = soundsEnabled
        }
    }

    @Published var soundVolume: Double {
        didSet {
            guard !applyingImportedSettings else { return }
            config.soundVolume = soundVolume
        }
    }

    // MARK: - Model

    @Published var sttModel: String {
        didSet {
            guard !applyingImportedSettings, sttModel != oldValue else { return }
            config.sttModel = sttModel
            guard !syncingFromEngine else { return }
            supervisor?.send(["cmd": "set_model", "model": sttModel])
            // Re-read the authoritative state: if the engine refused (busy),
            // the status reply reverts the picker instead of drifting. A slow
            // model download queues the status reply behind it, so this can't
            // race an in-progress accepted switch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.requestStatus()
            }
        }
    }

    @Published var saveAudio: Bool {
        didSet {
            guard !applyingImportedSettings, saveAudio != oldValue else { return }
            config.saveAudio = saveAudio
            supervisor?.send(["cmd": "reload_config"])
        }
    }

    // MARK: - Shortcuts

    @Published var hotkey: Hotkey {
        didSet {
            guard !applyingImportedSettings, hotkey != oldValue else { return }
            guard hotkey != editHotkey else {
                editHotkeyConflict = true
                hotkey = oldValue
                return
            }
            editHotkeyConflict = false
            config.hotkey = hotkey
            NotificationCenter.default.post(name: .veloraHotkeyChanged, object: nil)
        }
    }

    @Published var editHotkey: Hotkey {
        didSet {
            guard !applyingImportedSettings, editHotkey != oldValue else { return }
            // The monitor deliberately ignores an edit hotkey equal to the
            // dictation hotkey (dictation wins) — accepting the recording
            // would silently disable Voice Edit, so reject it visibly.
            guard editHotkey != hotkey else {
                editHotkeyConflict = true
                editHotkey = oldValue
                return
            }
            editHotkeyConflict = false
            config.editHotkey = editHotkey
            NotificationCenter.default.post(name: .veloraHotkeyChanged, object: nil)
        }
    }

    /// Set when either recorder would make the two shortcuts collide.
    @Published var editHotkeyConflict = false

    @Published var voiceEdit: Bool {
        didSet {
            guard !applyingImportedSettings, voiceEdit != oldValue else { return }
            config.voiceEdit = voiceEdit
            NotificationCenter.default.post(name: .veloraHotkeyChanged, object: nil)
        }
    }
}
