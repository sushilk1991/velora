import SwiftUI

/// Settings sections, shown in a System Settings-style sidebar (the toolbar
/// tab strip overflowed into a "»" chevron once the app grew past eight tabs).
/// Grouped forms, one accent color, sidebar icons in the colored-tile idiom.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, dictation, dictionary, model, modes, history, intelligence, meetings, shortcuts, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .dictionary: return "Dictionary"
        case .model: return "Models"
        case .modes: return "Modes"
        case .history: return "History"
        case .intelligence: return "Stats"
        case .meetings: return "Meetings"
        case .shortcuts: return "Shortcuts"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .dictation: return "mic.fill"
        case .dictionary: return "character.book.closed.fill"
        case .model: return "cpu.fill"
        case .modes: return "slider.horizontal.3"
        case .history: return "clock.arrow.circlepath"
        case .intelligence: return "chart.bar.fill"
        case .meetings: return "person.2.wave.2.fill"
        case .shortcuts: return "keyboard.fill"
        case .about: return "info.circle.fill"
        }
    }

    /// Sidebar icon tile color — deliberate, System Settings-style palette
    /// (one hue per section, not per row).
    var tileColor: Color {
        switch self {
        case .general: return .gray
        case .dictation: return .red
        case .dictionary: return .brown
        case .model: return .purple
        case .modes: return .indigo
        case .history: return .blue
        case .intelligence: return .green
        case .meetings: return .teal
        case .shortcuts: return .orange
        case .about: return VeloraBrand.violet.color
        }
    }

    /// Sidebar layout: unlabeled groups separated by whitespace, the System
    /// Settings idiom — setup, dictation behavior, your activity, about.
    static let sidebarGroups: [[SettingsTab]] = [
        [.general, .shortcuts],
        [.dictation, .modes, .dictionary, .model],
        [.history, .meetings, .intelligence],
        [.about],
    ]

    /// What the sidebar search matches besides the pane title: the labels of
    /// the controls that actually live in the pane, so "volume" finds General
    /// and "speakers" finds Meetings the way System Settings search would.
    var searchKeywords: [String] {
        switch self {
        case .general:
            return [
                "launch at login", "appearance", "theme", "dark", "light",
                "pill", "hud", "position", "sounds", "volume",
                "updates", "install", "version", "cli", "agents", "advanced",
                "export", "import", "transfer", "settings file", "json", "backup",
            ]
        case .dictation:
            return [
                "microphone", "mic", "input device", "airpods",
                "language", "punctuation", "smart cleanup", "terminal",
                "voice commands", "scratch that", "new line", "recordings",
                "audio", "transliterate", "english letters", "hinglish",
            ]
        case .dictionary:
            return [
                "vocabulary", "words", "replacements", "learn from edits",
                "discover", "icloud", "sync", "spelling", "jargon", "names",
            ]
        case .model:
            return [
                "speech", "whisper", "parakeet", "qwen", "cleanup",
                "download", "storage", "remove", "stt", "llm", "streaming",
            ]
        case .modes:
            return ["apps", "prompt", "rules", "context", "code", "email", "notes"]
        case .history:
            return [
                "transcripts", "recordings", "replay", "retention",
                "delete", "search", "insert again", "copy",
            ]
        case .intelligence:
            return ["statistics", "usage", "streak", "daily activity", "words", "charts"]
        case .meetings:
            return [
                "record", "speakers", "diarization", "summary", "action items",
                "decisions", "calendar", "calls", "transcript",
            ]
        case .shortcuts:
            return [
                "hotkey", "keyboard", "key combo", "hold to talk", "toggle",
                "voice edit", "selection", "escape", "cancel",
            ]
        case .about:
            return [
                "version", "updates", "check for updates", "website", "github", "star",
                "support", "email", "license", "issue", "acknowledgments", "credits",
            ]
        }
    }

    /// True when every whitespace-separated token of `query` occurs in the
    /// pane's title or keywords (case-insensitive). An empty query matches
    /// everything — the sidebar shows the full list.
    func matches(query: String) -> Bool {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        let haystack = ([title] + searchKeywords).joined(separator: " ").lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }

    /// `sidebarGroups` with non-matching panes removed and emptied groups
    /// dropped, preserving group order — what a filtering sidebar renders.
    static func filteredGroups(query: String) -> [[SettingsTab]] {
        sidebarGroups
            .map { $0.filter { $0.matches(query: query) } }
            .filter { !$0.isEmpty }
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
            .foregroundStyle(.orange)
            .background(
                Capsule().fill(Color.orange.opacity(0.15))
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
        .background(RoundedRectangle(cornerRadius: 8).fill(VeloraPanel.card))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separatorColor)))
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch Velora at login", isOn: $model.launchAtLogin)
                Picker("Appearance", selection: $model.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            Section {
                Toggle(isOn: $model.hudAlwaysVisible) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show the pill when idle")
                        Text("Click the pill to start dictating. Right-click it for recent transcripts and quick actions. Turn this off to hide the HUD until dictation is active.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Position", selection: $model.hudPosition) {
                    ForEach(HUDPosition.presets) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                    if model.hudPosition == .custom {
                        Text(HUDPosition.custom.displayName).tag(HUDPosition.custom)
                    }
                }
            } header: {
                Text("Dictation pill")
            } footer: {
                SettingsFooter("Drag the pill anywhere on screen to set your own position.")
            }
            Section("Sounds") {
                Toggle("Play sound effects", isOn: $model.soundsEnabled)
                HStack {
                    Text("Volume")
                    Slider(value: $model.soundVolume, in: 0...100)
                        .disabled(!model.soundsEnabled)
                    Text("\(Int(model.soundVolume))")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
            Section {
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
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Advanced")
            } footer: {
                SettingsFooter("Lets command-line tools running as your user read dictation history and stats. Everything stays on this Mac — no network server is opened.")
            }
            Section {
                HStack {
                    Button("Export Settings…") { model.exportSettings() }
                    Button("Import Settings…") { model.importSettings() }
                    Spacer()
                    if let result = model.settingsTransferResult {
                        if result.hasPrefix("Import failed") || result.hasPrefix("Export failed") {
                            Label(result, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Label(result, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Config file") {
                    Text("~/.velora/settings.json")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Settings transfer")
            } footer: {
                SettingsFooter("Exports portable preferences, shortcuts, the speech model, and advanced engine settings as JSON. History, recordings, dictionary, custom modes, the hardware-selected cleanup model, macOS permissions, microphone choice, Calendar access, and local-agent access stay on this Mac.")
            }
            Section {
                Toggle("Check for updates automatically", isOn: $model.updateChecks)
                Toggle("Download and install updates automatically", isOn: $model.autoInstallUpdates)
                    .disabled(!model.updateChecks)
                updateStatusRow
                Button("View Release History…") { model.openReleaseHistory() }
            } header: {
                Text("Updates")
            } footer: {
                SettingsFooter("Asks GitHub once a day whether a newer release exists. The request carries nothing about you or your dictations. Updates download from GitHub only when you choose — or automatically with the toggle on — and are verified against Velora's Developer ID signature and Apple's notarization before they replace the app.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { model.refreshAgentIntegration() }
    }

    private var updateStatusRow: some View {
        UpdateActionRow(model: model)
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
}

/// Update controls mirroring the updater's state: check → download progress →
/// verify → restart. Failures show the reason and fall back to the releases
/// page. Shared by Settings → General → Updates and the About pane.
struct UpdateActionRow: View {
    @ObservedObject var model: SettingsModel
    /// The idle-state button title ("Check Now" in the Updates section,
    /// "Check for Updates" in About).
    var checkLabel = "Check Now"

    var body: some View {
        switch model.updateState {
        case .downloading(let version, let progress):
            HStack(spacing: 12) {
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
                Text("Downloading Velora \(version) — \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.cancelUpdateDownload() }
            }
        case .verifying(let version):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying Velora \(version)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready(let version):
            HStack {
                Button("Restart to Update") { model.installStagedUpdate() }
                if model.availableUpdate != nil {
                    Button("View Release Notes…") { model.startUpdateInstall() }
                }
                Text(model.autoInstallUpdates
                     ? "Velora \(version) is ready — it installs when the app restarts or quits."
                     : "Velora \(version) is downloaded and verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let reason):
            HStack {
                if model.canInstallUpdateInPlace {
                    Button("Retry Update…") { model.startUpdateInstall() }
                } else {
                    Button("Open Releases Page") { model.openReleasesPage() }
                }
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .idle:
            HStack {
                Button(checkLabel) { model.checkForUpdatesNow() }
                if let update = model.availableUpdate {
                    if model.canInstallUpdateInPlace {
                        Button("Install Velora \(update.version)…") {
                            model.startUpdateInstall()
                        }
                    } else {
                        Button("Open Releases Page") { model.openReleasesPage() }
                    }
                }
                if let status = model.updateCheckStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Dictation

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
            } footer: {
                SettingsFooter("Velora records from this microphone even when macOS switches its default input (for example when AirPods connect). System default follows macOS.")
            }
            Section {
                Picker("Language", selection: $model.language) {
                    ForEach(Self.languages, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                Toggle("Automatic punctuation", isOn: $model.autoPunctuation)
                Toggle(isOn: $model.romanizeOutput) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write output in English letters")
                        Text("Transliterate non-English speech to the Latin alphabet — e.g. Hindi becomes Hinglish (\u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947} \u{2192} \u{201C}namaste\u{201D}). Keeps the words, not a translation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $model.smartTerminal) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smart cleanup in terminals")
                        Text("Long prose dictated into a terminal (AI chats) gets cleaned up; short commands are inserted exactly as heard.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $model.voiceCommands) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice commands")
                        Text("Say \u{201C}scratch that\u{201D} to undo the last dictation, or \u{201C}new line\u{201D} to press Return.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle(isOn: $model.saveAudio) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep audio recordings")
                        Text("Replay or re-transcribe past dictations, and recover one interrupted by a crash or restart. Recordings stay on this Mac and are deleted after \(Int(model.audioRetentionDays / 30)) months.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Storage used", value: archiveSize)
            } header: {
                Text("Recordings")
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

    /// Sums the archived-clip directory size off the main thread.
    private static func archiveSizeDescription() async -> String {
        let path = AppConfig.audioDirectory.path
        return await Task.detached(priority: .utility) { () -> String in
            let fm = FileManager.default
            guard fm.fileExists(atPath: path),
                  let files = fm.enumerator(atPath: path)
            else { return "Empty" }
            var total: Int64 = 0
            while let file = files.nextObject() as? String {
                let attrs = try? fm.attributesOfItem(atPath: path + "/" + file)
                total += (attrs?[.size] as? Int64) ?? 0
            }
            return total == 0 ? "Empty"
                : ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }.value
    }
}

// MARK: - Model

struct ModelSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var storageUsed: String = "…"
    @State private var cachedModels: [ModelStorage.CachedModel] = []
    @State private var pendingDelete: ModelStorage.CachedModel?

    /// One row in the picker / catalog. Prefers the engine's advertised models
    /// (so newly-shipped models appear without an app update); falls back to the
    /// static catalog before the first `status` reply lands.
    private struct Choice: Identifiable {
        let id: String
        let name: String
        let detail: String
        let size: String
    }

    private var choices: [Choice] {
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
    private var cleanupChoices: [EngineModel] { model.cleanupEngineModels }

    /// The set of currently-active model ids (never offered for deletion).
    private var activeModelIDs: Set<String> {
        [model.sttModel, model.cleanupModel].filter { !$0.isEmpty }.reduce(into: Set()) { $0.insert($1) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Speech model", selection: $model.sttModel) {
                    ForEach(choices) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                if !cleanupChoices.isEmpty {
                    Picker("Cleanup model", selection: cleanupBinding) {
                        ForEach(cleanupChoices) { m in
                            Text(cleanupLabel(m)).tag(m.id)
                        }
                    }
                }
            } footer: {
                SettingsFooter(cleanupFooter)
            }
            Section("Available speech models") {
                ForEach(choices) { choice in
                    HStack(alignment: .firstTextBaseline) {
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
                                .frame(width: 72, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, VeloraSpacing.xs)
                }
            }
            storageSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await refreshStorage() }
        .onAppear { model.requestStatus() }
        .alert(item: $pendingDelete) { target in
            Alert(
                title: Text("Remove “\(shortName(target.id))”?"),
                message: Text("Frees \(target.sizeLabel) from the on-device model cache. Velora re-downloads it automatically if you select it again."),
                primaryButton: .destructive(Text("Remove")) {
                    Task { await ModelStorage.delete(target); await refreshStorage() }
                },
                secondaryButton: .cancel())
        }
    }

    // MARK: Cleanup model picker

    private var cleanupBinding: Binding<String> {
        Binding(get: { model.cleanupModel }, set: { model.setCleanupModel($0) })
    }

    private func cleanupLabel(_ m: EngineModel) -> String {
        m.id == model.recommendedCleanupModel ? "\(m.displayName)  ·  Recommended" : m.displayName
    }

    private var cleanupFooter: String {
        let base = "Models download on first use and run entirely on this Mac."
        guard !model.recommendedCleanupModel.isEmpty,
              let rec = cleanupChoices.first(where: { $0.id == model.recommendedCleanupModel })
        else { return base }
        return base + " “\(rec.displayName)” is recommended for your Mac's memory."
    }

    // MARK: Storage section

    @ViewBuilder
    private var storageSection: some View {
        Section {
            LabeledContent("Total on disk", value: storageUsed)
            ForEach(cachedModels) { m in
                HStack(alignment: .firstTextBaseline, spacing: VeloraSpacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shortName(m.id))
                        if activeModelIDs.contains(m.id) {
                            Text("In use")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(VeloraBrand.violet.color)
                        }
                    }
                    Spacer()
                    Text(m.sizeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if activeModelIDs.contains(m.id) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 22)
                    } else {
                        Button {
                            pendingDelete = m
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this cached model to reclaim space")
                        .frame(width: 22)
                    }
                }
                .padding(.vertical, 1)
            }
        } header: {
            Text("Model storage")
        } footer: {
            SettingsFooter("Reclaim space by removing models you no longer use. The two in-use models can't be removed.")
        }
    }

    private func shortName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    private func refreshStorage() async {
        let scanned = await ModelStorage.scan()
        cachedModels = scanned
        let total = scanned.reduce(Int64(0)) { $0 + $1.bytes }
        storageUsed = scanned.isEmpty
            ? "No models downloaded"
            : ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
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
        .background(VeloraPanel.canvas)
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
                symbol: "mic.fill", color: VeloraBrand.violet.color,
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
                title: "Stream typing",
                subtitle: "See your words appear at the cursor while you speak. The live draft is replaced with the polished final when you finish."
            ) {
                Toggle("Stream typing", isOn: $model.streamTypingEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Group {
                CardDivider()
                shortcutRow(title: "Type as you speak", hotkey: $model.streamTypingHotkey)
                if model.streamTypingHotkeyConflict {
                    conflictLabel("Stream typing needs a shortcut of its own.")
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
                title: "Fix spelling and grammar",
                subtitle: "Select text and press the shortcut. Velora replaces editable selections; for read-only text, it copies the result. No microphone or speech model is used."
            ) {
                Toggle("Fix spelling and grammar", isOn: $model.proofreadEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Group {
                CardDivider()
                shortcutRow(title: "Proofread selection", hotkey: $model.proofreadHotkey)
                if model.proofreadHotkeyConflict {
                    conflictLabel("Proofread selection needs a shortcut of its own.")
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
                title: "Voice edit selection",
                subtitle: "Select text anywhere, press the shortcut, and speak an edit — \u{201C}fix the grammar\u{201D}, \u{201C}make this more formal\u{201D}, \u{201C}turn this into bullet points\u{201D}. \u{2318}Z undoes it."
            ) {
                Toggle("Voice edit selection", isOn: $model.voiceEdit)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Group {
                CardDivider()
                shortcutRow(title: "Edit selection", hotkey: $model.editHotkey)
                if model.editHotkeyConflict {
                    conflictLabel("Dictation and Edit selection need different shortcuts.")
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
                title: "Voice actions",
                subtitle: "Hold the shortcut and say what you want done — \u{201C}message Priya on Slack that I\u{2019}m running late\u{201D}. Velora opens the app and carries it out. Say \u{201C}draft\u{201D} to stop before sending."
            ) {
                VStack(alignment: .trailing, spacing: 4) {
                    Toggle("Voice actions", isOn: $model.actionsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    ExperimentalBadge()
                }
            }
            Group {
                CardDivider()
                shortcutRow(title: "Run an action", hotkey: $model.actionHotkey)
                if model.actionHotkeyConflict {
                    conflictLabel("Voice actions need a shortcut of their own.")
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
                Text("Actions need Accessibility permission, and run entirely on this Mac.")
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
            .foregroundStyle(.orange)
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
