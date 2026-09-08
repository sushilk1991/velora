import SwiftUI

/// The ⌘, Settings window's rail, System Settings-style: five coloured-tile
/// rows, in this order. Everything that is content rather than preference
/// (History, Stats, Meetings, Dictionary, Modes) lives in the main window's
/// `MainPane`; About is its own small window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, dictation, shortcuts, models, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .shortcuts: return "Shortcuts"
        case .models: return "Models"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .dictation: return "mic.fill"
        case .shortcuts: return "keyboard.fill"
        case .models: return "cpu.fill"
        case .advanced: return "slider.horizontal.3"
        }
    }

    /// Sidebar icon tile color — deliberate, System Settings-style palette
    /// (one hue per section, not per row).
    var tileColor: Color {
        switch self {
        case .general: return .gray
        case .dictation: return .red
        case .shortcuts: return .blue
        case .models: return .purple
        case .advanced: return Color(nsColor: .darkGray)
        }
    }
}

/// Bundle identity shared by the sidebar header and the About pane — one
/// source for the marketing version, build number, and the real app icon.
enum VeloraAppInfo {
    static var shortVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.1.0"
    }

    static var buildNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// The real bundled app icon — never an SF Symbol stand-in (a bare
    /// `swift build` binary falls back to the generic app icon).
    static var icon: NSImage {
        if let bundled = Bundle.main.image(forResource: "AppIcon") { return bundled }
        return NSApp.applicationIconImage ?? NSImage()
    }
}

// MARK: - Shared form pieces

/// Grouped-form section footer in the System Settings idiom: caption-sized,
/// secondary. Every footer goes through this so panes can't drift apart again
/// (they used to mix `.callout` and `.caption` and read as two designs).
struct SettingsFooter: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Small capsule marking a feature that ships behind lowered expectations —
/// it works, it is tested, and it is still earning trust.
struct ExperimentalBadge: View {
    var body: some View {
        Text("EXPERIMENTAL")
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.5)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(VeloraStatus.warning)
            .background(
                Capsule().fill(VeloraStatus.warning.opacity(0.15))
            )
            .accessibilityLabel("Experimental feature")
    }
}

/// The bordered search field used by list-style panes (History, Dictionary) —
/// one look for in-pane search everywhere.
struct SettingsSearchBox: View {
    let prompt: String
    @Binding var query: String
    var accessibilityLabel: String?

    var body: some View {
        HStack(spacing: VeloraSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel(accessibilityLabel ?? prompt)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, VeloraSpacing.s)
        .padding(.vertical, 6)
        // Card, not textBackgroundColor: the semantic color drops to #1E1E1E
        // in dark mode and reads as a hole in the canvas.
        .background(RoundedRectangle(cornerRadius: VeloraRadius.tile).fill(VeloraPanel.card))
        .overlay(RoundedRectangle(cornerRadius: VeloraRadius.tile).strokeBorder(Color(.separatorColor)))
    }
}


// MARK: - General

/// General: appearance, the pill, and the update check — the settings a
/// first-day user reaches for. Everything operational moved to Advanced.
struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $model.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                Toggle("Launch Velora at login", isOn: $model.launchAtLogin)
                Toggle("Play sounds", isOn: $model.soundsEnabled)
            }
            Section {
                Toggle("Show pill", isOn: $model.hudVisible)
                Toggle("Keep pill on screen when idle", isOn: $model.hudAlwaysVisible)
                    .disabled(!model.hudVisible)
            } header: {
                Text("Pill")
            } footer: {
                SettingsFooter("Right-click the pill to close it. Bring it back from the menubar.")
            }
            Section {
                Toggle("Check for updates automatically", isOn: $model.updateChecks)
                LabeledContent("Velora \(VeloraAppInfo.shortVersion)") {
                    UpdateActionRow(model: model)
                }
            } header: {
                Text("Updates")
            } footer: {
                SettingsFooter("Asks GitHub once a day whether a newer release exists. The request carries nothing about you or your dictations.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// Update controls mirroring the updater's state with the shared
/// `UpdateCopy` vocabulary: check → download progress → verify → restart.
/// Failures show the reason and keep both Try Again and Check Now within
/// reach. Shared by Settings › General › Updates and the About window.
struct UpdateActionRow: View {
    @ObservedObject var model: SettingsModel
    /// The idle-state button title ("Check Now" in the Updates section,
    /// "Check for Updates" in About).
    var checkLabel = "Check Now"

    private static let progressWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: VeloraSpacing.m) {
            switch model.updateState {
            case .downloading(_, let progress):
                ProgressView(value: progress)
                    .frame(maxWidth: Self.progressWidth)
                caption(stateCaption)
                Button("Cancel") { model.cancelUpdateDownload() }
            case .verifying, .installing:
                ProgressView().controlSize(.small)
                caption(stateCaption)
            case .ready:
                Button(model.updateInstallsWhenReady
                       ? UpdateCopy.waitingTitle : UpdateCopy.restartTitle) {
                    model.installStagedUpdate()
                }
                .disabled(model.updateInstallsWhenReady)
                if model.availableUpdate != nil {
                    Button("Release Notes…") { model.showUpdateWindow() }
                }
                caption(stateCaption)
            case .failed:
                if model.canInstallUpdateInPlace {
                    Button(UpdateCopy.tryAgainTitle) { model.showUpdateWindow() }
                } else {
                    Button(UpdateCopy.releasesPageTitle) { model.openReleasesPage() }
                }
                Button(checkLabel) { model.checkForUpdatesNow() }
                caption(stateCaption)
                caption(model.updateCheckStatus)
            case .idle:
                Button(checkLabel) { model.checkForUpdatesNow() }
                if let update = model.availableUpdate {
                    if model.canInstallUpdateInPlace {
                        Button(UpdateCopy.updateTitle(update.version)) {
                            model.showUpdateWindow()
                        }
                    } else {
                        Button(UpdateCopy.releasesPageTitle) { model.openReleasesPage() }
                    }
                }
                caption(model.updateCheckStatus)
            }
        }
    }

    private var stateCaption: String? {
        UpdateCopy.caption(
            for: model.updateState, installsWhenReady: model.updateInstallsWhenReady)
    }

    @ViewBuilder
    private func caption(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Dictation

/// Dictation: input (mic, language, how the shortcut behaves), writing
/// behaviour, and recordings. Terminal cleanup moved to Advanced › Terminals.
struct DictationSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var archiveSize: String = "…"
    @State private var inputDevices: [AudioInputDevices.Device] = []

    /// Whisper language codes, weighted toward the most-spoken languages.
    private static let languages: [(String, String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("hi", "Hindi"),
        ("es", "Spanish"), ("zh", "Mandarin Chinese"), ("ar", "Arabic"),
        ("fr", "French"), ("pt", "Portuguese"), ("de", "German"),
        ("it", "Italian"), ("ja", "Japanese"),
    ]

    private static let daysPerMonth = 30

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $model.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(inputDevices, id: \.uid) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                    // A chosen mic that is unplugged right now must stay
                    // selected (an unmatched tag renders the picker empty);
                    // it wins again automatically when it reconnects.
                    if let uid = model.inputDeviceUID,
                       !inputDevices.contains(where: { $0.uid == uid }) {
                        Text("Chosen microphone (not connected)").tag(String?.some(uid))
                    }
                }
                Picker("Language", selection: $model.language) {
                    ForEach(Self.languages, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                // The shortcut itself is recorded under Shortcuts; here only
                // how a press behaves.
                LabeledContent("Start dictation") {
                    HStack(spacing: VeloraSpacing.m) {
                        KeycapsLabel(hotkey: model.hotkey)
                        Picker("Behaviour", selection: $model.hotkeyMode) {
                            Text("Hold").tag(HotkeyMode.hold)
                            Text("Toggle").tag(HotkeyMode.toggle)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } header: {
                Text("Input")
            } footer: {
                SettingsFooter("Velora keeps recording from this microphone even when macOS switches its default input (for example when AirPods connect).")
            }
            Section("Writing") {
                Toggle("Automatic punctuation", isOn: $model.autoPunctuation)
                Toggle(isOn: $model.voiceCommands) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice commands")
                        Text("\u{201C}Scratch that\u{201D} undoes, \u{201C}new line\u{201D} presses Return.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $model.romanizeOutput) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write other languages in English letters")
                        Text("\u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947} becomes \u{201C}namaste\u{201D}. The words stay yours.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle("Keep audio recordings", isOn: $model.saveAudio)
            } header: {
                Text("Recordings")
            } footer: {
                SettingsFooter(recordingsFooter)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: model.saveAudio) { archiveSize = await Self.archiveSizeDescription() }
        .onAppear {
            AudioInputDevices.beginObserving()
            inputDevices = AudioInputDevices.displayList()
        }
        .onReceive(NotificationCenter.default.publisher(for: .veloraAudioInputDevicesChanged)) { _ in
            inputDevices = AudioInputDevices.displayList()
        }
    }

    /// "1.2 GB on disk · kept for 180 days. Your voice never leaves this Mac."
    private var recordingsFooter: String {
        let days = Int(model.audioRetentionDays)
        let retention = "kept for \(days) days"
        return "\(archiveSize) on disk · \(retention). Your voice never leaves this Mac."
    }

    /// Sums the archived-clip directory size off the main thread.
    private static func archiveSizeDescription() async -> String {
        let path = AppConfig.audioDirectory.path
        return await Task.detached(priority: .utility) { () -> String in
            let fm = FileManager.default
            guard fm.fileExists(atPath: path),
                  let files = fm.enumerator(atPath: path)
            else { return "Nothing" }
            var total: Int64 = 0
            while let file = files.nextObject() as? String {
                let attrs = try? fm.attributesOfItem(atPath: path + "/" + file)
                total += (attrs?[.size] as? Int64) ?? 0
            }
            return total == 0 ? "Nothing"
                : ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }.value
    }
}

// MARK: - Models

/// Models: the two models in use, each with a "Change…" that unfolds the
/// choices in place, and the storage they occupy.
///
///     ON THIS MAC
///     Speech to text                                   [Change…]
///       whisper-large-v3-turbo · On-device · 1.6 GB
///       ○ parakeet-tdt-0.6b-v3 … (only while unfolded)
///     Cleanup                                          [Change…]
///       Qwen 2.5 3B · Recommended for this Mac · 1.9 GB
struct ModelSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var storageUsed: String = "…"
    @State private var unusedSize: String = "…"
    @State private var cachedModels: [ModelStorage.CachedModel] = []
    @State private var confirmRemoveUnused = false
    @State private var changing: Slot?

    /// Which "Change…" is unfolded (at most one at a time).
    private enum Slot { case speech, cleanup }

    /// One row in the picker / catalog. Prefers the engine's advertised models
    /// (so newly-shipped models appear without an app update); falls back to the
    /// static catalog before the first `status` reply lands.
    private struct Choice: Identifiable {
        let id: String
        let name: String
        let detail: String
        let size: String
    }

    private var speechChoices: [Choice] {
        let engine = model.sttEngineModels
        if !engine.isEmpty {
            return engine.map {
                Choice(id: $0.id, name: $0.displayName,
                       detail: $0.backend.isEmpty ? "On-device" : $0.backend, size: $0.size)
            }
        }
        return STTModel.all.map {
            Choice(id: $0.id, name: $0.displayName, detail: $0.languages, size: $0.size)
        }
    }

    /// Cleanup models the engine advertises (smallest first).
    private var cleanupChoices: [Choice] {
        model.cleanupEngineModels.map {
            Choice(
                id: $0.id, name: $0.displayName,
                detail: $0.id == model.recommendedCleanupModel ? "Recommended for this Mac" : "On-device",
                size: $0.size)
        }
    }

    /// The set of currently-active model ids (never offered for deletion).
    private var activeModelIDs: Set<String> {
        [model.sttModel, model.cleanupModel].filter { !$0.isEmpty }.reduce(into: Set()) { $0.insert($1) }
    }

    private var unusedModels: [ModelStorage.CachedModel] {
        cachedModels.filter { !activeModelIDs.contains($0.id) }
    }

    var body: some View {
        Form {
            Section {
                slotRow(
                    title: "Speech to text", slot: .speech, choices: speechChoices,
                    selection: $model.sttModel)
                if !cleanupChoices.isEmpty {
                    slotRow(
                        title: "Cleanup", slot: .cleanup, choices: cleanupChoices,
                        selection: cleanupBinding)
                }
            } header: {
                Text("On this Mac")
            } footer: {
                SettingsFooter("Models download once and run on this Mac. Nothing is sent anywhere.")
            }
            Section("Storage") {
                LabeledContent("On disk") {
                    HStack(spacing: VeloraSpacing.m) {
                        Text(storageUsed)
                            .foregroundStyle(.secondary)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([ModelStorage.hubURL])
                        }
                    }
                }
                LabeledContent("Unused downloads") {
                    HStack(spacing: VeloraSpacing.m) {
                        Text(unusedSize)
                            .foregroundStyle(.secondary)
                        Button("Remove…") { confirmRemoveUnused = true }
                            .disabled(unusedModels.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await refreshStorage() }
        .onAppear { model.requestStatus() }
        .alert("Remove unused models?", isPresented: $confirmRemoveUnused) {
            Button("Remove", role: .destructive) {
                Task { await removeUnused() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(unusedSize) from the on-device model cache. Velora re-downloads a model automatically if you select it again.")
        }
    }

    // MARK: Slot rows

    /// Title, the active model's caption, and "Change…"; while unfolded,
    /// every choice as a selectable row beneath.
    @ViewBuilder
    private func slotRow(
        title: String, slot: Slot, choices: [Choice], selection: Binding<String>
    ) -> some View {
        let active = choices.first { $0.id == selection.wrappedValue }
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption(for: active, fallback: selection.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(changing == slot ? "Done" : "Change…") {
                changing = changing == slot ? nil : slot
            }
        }
        if changing == slot {
            ForEach(choices) { choice in
                Button {
                    selection.wrappedValue = choice.id
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: choice.id == selection.wrappedValue
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(choice.id == selection.wrappedValue
                                             ? AnyShapeStyle(VeloraBrand.accent)
                                             : AnyShapeStyle(.tertiary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.name)
                            Text(choice.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !choice.size.isEmpty {
                            Text(choice.size)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, VeloraSpacing.l)
            }
        }
    }

    /// "whisper-large-v3-turbo · On-device · 1.6 GB".
    private func caption(for choice: Choice?, fallback id: String) -> String {
        guard let choice else { return id.isEmpty ? "Not chosen" : shortName(id) }
        return [choice.name, choice.detail, choice.size]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var cleanupBinding: Binding<String> {
        Binding(get: { model.cleanupModel }, set: { model.setCleanupModel($0) })
    }

    // MARK: Storage

    private func shortName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    private func refreshStorage() async {
        let scanned = await ModelStorage.scan()
        cachedModels = scanned
        storageUsed = Self.sizeLabel(scanned, empty: "No models downloaded")
        unusedSize = Self.sizeLabel(unusedModels, empty: "None")
    }

    private static func sizeLabel(_ models: [ModelStorage.CachedModel], empty: String) -> String {
        let total = models.reduce(Int64(0)) { $0 + $1.bytes }
        if total == 0 { return empty }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func removeUnused() async {
        for cached in unusedModels {
            _ = await ModelStorage.delete(cached)
        }
        await refreshStorage()
    }
}

// MARK: - Advanced

/// Advanced: meeting preferences, terminal cleanup, the update installer,
/// and the tools a power user reaches for (settings file, CLI, logs, the
/// Setup Assistant). Every row here used to live somewhere more prominent.
struct AdvancedSettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var coordinator: MeetingCoordinator
    let openSetupAssistant: () -> Void

    @State private var editingNotesPrompt = false

    var body: some View {
        Form {
            Section {
                MeetingPreferenceRows(model: model, coordinator: coordinator)
                LabeledContent("Notes prompt") {
                    HStack(spacing: VeloraSpacing.m) {
                        Text(model.meetingNotesPrompt.isEmpty ? "Default" : "Custom")
                            .foregroundStyle(.secondary)
                        Button("Edit…") { editingNotesPrompt = true }
                    }
                }
            } header: {
                Text("Meetings")
            } footer: {
                SettingsFooter(MeetingPreferenceRows.footer)
            }
            Section("Terminals") {
                Toggle(isOn: $model.smartTerminal) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smart cleanup in terminals")
                        Text("Prose is cleaned up. Short commands land exactly as heard.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle("Download and install updates automatically", isOn: $model.autoInstallUpdates)
                    .disabled(!model.updateChecks)
                Button("View Release History…") { model.openReleaseHistory() }
            } header: {
                Text("Updates")
            } footer: {
                SettingsFooter("Updates download from GitHub only when you choose — or automatically with the toggle on — and are verified against Velora's Developer ID signature and Apple's notarization before they replace Velora.")
            }
            Section {
                settingsFileRow
                Toggle("Allow local CLI and agents", isOn: $model.localAgentAccess)
                if model.localAgentAccess {
                    agentIntegrationRow(
                        title: "Command-line tool",
                        detail: model.cliInstallPath
                            ?? "Puts a “velora” command on your PATH.",
                        buttonTitle: model.cliInstallPath == nil ? "Install" : "Reinstall"
                    ) { model.installCLITool() }
                    agentIntegrationRow(
                        title: "Agent skill",
                        detail: model.agentSkillInstalled
                            ? "Installed — Claude Code knows what it can ask Velora."
                            : "Teaches local agents (Claude Code) where to look and what they can ask.",
                        buttonTitle: model.agentSkillInstalled ? "Reinstall" : "Install"
                    ) { model.installAgentSkill() }
                    if let error = model.agentIntegrationError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(VeloraStatus.warning)
                    }
                }
                LabeledContent("Engine logs") {
                    Button("Show in Finder") { Self.revealEngineLog() }
                }
                Button("Run Setup Assistant…", action: openSetupAssistant)
            } header: {
                Text("Tools")
            } footer: {
                SettingsFooter("The settings file carries portable preferences, shortcuts, the speech model, and advanced engine settings. History, recordings, dictionary, custom modes, macOS permissions, microphone choice, Calendar access, and local-agent access stay on this Mac. Local agents run as your user and open no network server.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { model.refreshAgentIntegration() }
        .sheet(isPresented: $editingNotesPrompt) {
            MeetingNotesPromptEditor(model: model)
        }
    }

    /// Export/Import plus the last result and the file's path.
    private var settingsFileRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Settings file")
                Spacer()
                Button("Export…") { model.exportSettings() }
                Button("Import…") { model.importSettings() }
            }
            HStack(spacing: VeloraSpacing.s) {
                Text("~/.velora/settings.json")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if let result = model.settingsTransferResult {
                    if result.hasPrefix("Import failed") || result.hasPrefix("Export failed") {
                        Label(result, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(VeloraStatus.warning)
                    } else {
                        Label(result, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Title + status caption on the left, install action on the right.
    private func agentIntegrationRow(
        title: String, detail: String, buttonTitle: String, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(buttonTitle, action: action)
        }
    }

    /// Selects the engine log in Finder (falls back to the ~/.velora folder
    /// before the engine has written one).
    private static func revealEngineLog() {
        let log = AppConfig.veloraDirectory.appendingPathComponent("engine.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([AppConfig.veloraDirectory])
    }
}

// MARK: - Shortcuts

/// Card-per-feature Shortcuts pane: each voice feature gets one card with a
/// colored icon tile, its master toggle, and a keycap-styled recorder. The
/// Music permission row appears only while the user can actually act on it —
/// a permanently "Allowed" status row is dead weight.
struct ShortcutsSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var musicPermission: NativeMediaPermission?
    @State private var requestingMusicPermission = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VeloraSpacing.l) {
                dictationCard
                streamTypingCard
                proofreadCard
                voiceEditCard
                voiceActionsCard
            }
            .padding(VeloraSpacing.xl)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: refreshMusicPermission)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            refreshMusicPermission()
        }
    }

    // MARK: Dictation

    private var dictationCard: some View {
        SettingsCard {
            CardHeader(
                symbol: "mic.fill", color: VeloraBrand.sky.color,
                title: "Dictation",
                subtitle: "Press your shortcut and speak — anywhere you can type. Esc cancels.")
            CardDivider()
            shortcutRow(title: "Start dictation", hotkey: $model.hotkey)
            HStack {
                Text("When pressed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("When pressed", selection: $model.hotkeyMode) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if model.hotkeyMode == .hold {
                Text("A quick tap locks recording on; tap again to finish.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Stream typing

    private var streamTypingCard: some View {
        SettingsCard {
            CardHeader(
                symbol: "keyboard.fill", color: .blue,
                title: "Stream Typing",
                subtitle: "See your words appear at the cursor while you speak. The live draft is replaced with the polished final when you finish."
            ) {
                Toggle("Stream Typing", isOn: $model.streamTypingEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Group {
                CardDivider()
                shortcutRow(title: "Type as you speak", hotkey: $model.streamTypingHotkey)
                if model.streamTypingHotkeyConflict {
                    conflictLabel("Stream Typing needs a shortcut of its own.")
                }
                Text("If you type or move the cursor mid-stream, Velora stops rewriting and copies the final instead.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .disabled(!model.streamTypingEnabled)
            .opacity(model.streamTypingEnabled ? 1 : 0.5)
        }
    }

    // MARK: Proofread

    private var proofreadCard: some View {
        SettingsCard {
            CardHeader(
                symbol: "text.badge.checkmark", color: .green,
                title: "Proofread",
                subtitle: "Fix spelling and grammar in selected text, no microphone needed."
            ) {
                Toggle("Proofread", isOn: $model.proofreadEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Group {
                CardDivider()
                shortcutRow(title: "Proofread", hotkey: $model.proofreadHotkey)
                if model.proofreadHotkeyConflict {
                    conflictLabel("Proofread needs a shortcut of its own.")
                }
            }
            .disabled(!model.proofreadEnabled)
            .opacity(model.proofreadEnabled ? 1 : 0.5)
        }
    }

    // MARK: Voice edit

    private var voiceEditCard: some View {
        SettingsCard {
            CardHeader(
                symbol: "wand.and.stars", color: .teal,
                title: "Voice Edit",
                subtitle: "Select text anywhere, press the shortcut, and speak an edit — \u{201C}fix the grammar\u{201D}, \u{201C}make this more formal\u{201D}, \u{201C}turn this into bullet points\u{201D}. \u{2318}Z undoes it."
            ) {
                Toggle("Voice Edit", isOn: $model.voiceEdit)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Group {
                CardDivider()
                shortcutRow(title: "Voice Edit", hotkey: $model.editHotkey)
                if model.editHotkeyConflict {
                    conflictLabel("Dictation and Voice Edit need different shortcuts.")
                }
            }
            .disabled(!model.voiceEdit)
            .opacity(model.voiceEdit ? 1 : 0.5)
        }
    }

    // MARK: Voice actions

    private var voiceActionsCard: some View {
        SettingsCard {
            CardHeader(
                symbol: "sparkles", color: .orange,
                title: "Action Mode",
                subtitle: "Hold the shortcut and say what you want done — \u{201C}message Priya on Slack that I\u{2019}m running late\u{201D}. Velora carries it out in the app you’re in, or in another app’s window with the Cua Driver. Say \u{201C}draft\u{201D} to stop before sending."
            ) {
                VStack(alignment: .trailing, spacing: 4) {
                    Toggle("Action Mode", isOn: $model.actionsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    ExperimentalBadge()
                }
            }
            Group {
                CardDivider()
                shortcutRow(title: "Action Mode", hotkey: $model.actionHotkey)
                if model.actionHotkeyConflict {
                    conflictLabel("Action Mode needs a shortcut of its own.")
                }
                if CuaDriver.isInstalled {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Work in the background")
                                .font(.system(size: 12))
                            Text("Velora drives an exact target through Cua while your current app stays in front.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Toggle("Work in the background", isOn: $model.backgroundActions)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                musicPermissionRow
                Text("Action Mode needs Accessibility permission, and runs entirely on this Mac.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .disabled(!model.actionsEnabled)
            .opacity(model.actionsEnabled ? 1 : 0.5)
        }
    }

    /// Shown only while there is something to do: grant consent, fix a denial
    /// in System Settings, or open Music so consent becomes requestable (this
    /// pane is the only interactive Automation prompt — actions fail closed).
    /// Granted state renders nothing — a permanent "Allowed" row is dead weight.
    @ViewBuilder
    private var musicPermissionRow: some View {
        let actionable: [NativeMediaPermission?] = [.needsConsent, .denied, .unavailable]
        if actionable.contains(musicPermission) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Music control")
                        .font(.system(size: 12))
                    Text("Allow once to play or pause Music without bringing it forward.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                switch musicPermission {
                case .needsConsent:
                    Button(requestingMusicPermission ? "Waiting…" : "Allow…",
                           action: requestMusicPermission)
                        .disabled(requestingMusicPermission)
                case .denied:
                    Button("Open Settings") {
                        Permissions.openAutomationSettings()
                    }
                default:
                    Text("Open Music, then return here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Shared rows

    private func shortcutRow(title: String, hotkey: Binding<Hotkey>) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer(minLength: VeloraSpacing.l)
            HotkeyRecorderView(hotkey: hotkey, showsQuickPicks: false)
        }
    }

    private func conflictLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(VeloraStatus.warning)
    }

    private func refreshMusicPermission() {
        NativeMediaAutomation.shared.readMusicPermission { permission in
            musicPermission = permission
        }
    }

    private func requestMusicPermission() {
        requestingMusicPermission = true
        NativeMediaAutomation.shared.requestMusicPermission { permission in
            musicPermission = permission
            requestingMusicPermission = false
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @ObservedObject var model: SettingsModel

    private var version: String { VeloraAppInfo.shortVersion }

    private var build: String? { VeloraAppInfo.buildNumber }

    /// The real bundled app icon — the About pane must show exactly what sits
    /// in the Dock/Finder, not an SF Symbol stand-in.
    private var appIcon: NSImage { VeloraAppInfo.icon }

    var body: some View {
        VStack(spacing: VeloraSpacing.m) {
            Spacer(minLength: VeloraSpacing.xl)
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 108, height: 108)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            Text("Velora")
                .font(.title2.weight(.semibold))
            Text(build.map { "Version \(version) (\($0))" } ?? "Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Open-source, local-first dictation.\nYour voice never leaves this Mac.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            UpdateActionRow(model: model, checkLabel: "Check for Updates")
                .padding(.top, VeloraSpacing.xs)

            if let supportURL = VeloraLinks.supportEmailURL {
                Link(destination: supportURL) {
                    Label("Email Support", systemImage: "envelope.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Opens a new support email to \(VeloraLinks.supportEmailAddress)")
                .padding(.top, VeloraSpacing.xs)
            }

            HStack(spacing: VeloraSpacing.l) {
                link("Website", VeloraLinks.websiteURL)
                link("GitHub", VeloraLinks.repositoryURL)
                link("Star Velora", VeloraLinks.starURL)
                link("Report an Issue", VeloraLinks.issuesURL)
            }
            .padding(.top, VeloraSpacing.xs)

            Spacer()

            Text("Built with parakeet-mlx, mlx-whisper, and mlx-lm.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, VeloraSpacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Link that quietly renders nothing if a destination cannot be formed.
    @ViewBuilder
    private func link(_ title: String, _ url: URL?) -> some View {
        if let url {
            Link(title, destination: url)
        }
    }
}
