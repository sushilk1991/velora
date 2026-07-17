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
                        Text("Click the pill to start dictating. Right-click it for recent transcripts and quick actions.")
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
                Text("Drag the pill anywhere on screen to set your own position.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
            } header: {
                Text("Advanced")
            } footer: {
                Text("Lets command-line tools running as your user read dictation history and stats. Everything stays on this Mac — no network server is opened.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Check for updates automatically", isOn: $model.updateChecks)
                Toggle("Download and install updates automatically", isOn: $model.autoInstallUpdates)
                    .disabled(!model.updateChecks)
                updateStatusRow
            } header: {
                Text("Updates")
            } footer: {
                Text("Asks GitHub once a day whether a newer release exists. The request carries nothing about you or your dictations. Updates download from GitHub only when you choose — or automatically with the toggle on — and are verified against Velora's Developer ID signature and Apple's notarization before they replace the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The Updates section's action row, mirroring the updater's state:
    /// check → download progress → verify → restart. Failures show the
    /// reason and fall back to the releases page.
    @ViewBuilder
    private var updateStatusRow: some View {
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
                Button("Discard") { model.discardStagedUpdate() }
                Text(model.autoInstallUpdates
                     ? "Velora \(version) is ready — it installs when the app restarts or quits."
                     : "Velora \(version) is downloaded and verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let reason):
            HStack {
                if model.canInstallUpdateInPlace {
                    Button("Try Again") { model.startUpdateInstall() }
                } else {
                    Button("Open Releases Page") { model.openReleasesPage() }
                }
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .idle:
            HStack {
                Button("Check Now") { model.checkForUpdatesNow() }
                if let update = model.availableUpdate {
                    if model.canInstallUpdateInPlace {
                        Button("Install Velora \(update.version)") { model.startUpdateInstall() }
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
                        Text("Replay or re-transcribe past dictations from History. Recordings stay on this Mac and are deleted after \(Int(model.audioRetentionDays / 30)) months.")
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
        .task(id: model.saveAudio) { archiveSize = await Self.archiveSizeDescription() }
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
                Text(cleanupFooter)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
            Text("Reclaim space by removing models you no longer use. The two in-use models can't be removed.")
                .font(.callout)
                .foregroundStyle(.secondary)
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

struct ShortcutsSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Start dictation") {
                    HotkeyRecorderView(hotkey: $model.hotkey)
                }
                LabeledContent("Cancel dictation", value: "Esc")
            } footer: {
                Text("Click the shortcut, then press a new key combo — a bare modifier like Right Option works too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $model.voiceEdit) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice edit selection")
                        Text("Select text anywhere, press the shortcut, and speak an edit — \u{201C}make this more formal\u{201D}, \u{201C}fix the grammar\u{201D}, \u{201C}turn this into bullet points\u{201D}. \u{2318}Z undoes it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Edit selection") {
                    HotkeyRecorderView(hotkey: $model.editHotkey)
                }
                .disabled(!model.voiceEdit)
                if model.editHotkeyConflict {
                    Text("That's already the dictation shortcut — pick a different one.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Voice edit")
            }
            Section {
                Picker("When pressed", selection: $model.hotkeyMode) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Hotkey behavior")
            } footer: {
                Text("With Hold to talk, a quick tap locks recording on; tap again to finish.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "0.1.0"
    }

    private var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// The real bundled app icon — the About pane must show exactly what sits
    /// in the Dock/Finder, not an SF Symbol stand-in.
    private var appIcon: NSImage {
        if let bundled = Bundle.main.image(forResource: "AppIcon") { return bundled }
        return NSApp.applicationIconImage ?? NSImage()
    }

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

            HStack(spacing: VeloraSpacing.l) {
                link("GitHub", "https://github.com/\(UpdateChecker.repoSlug)")
                link("Report an Issue", "https://github.com/\(UpdateChecker.repoSlug)/issues")
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

    /// Link that quietly renders nothing if the URL literal is malformed
    /// (keeps the view force-unwrap free).
    @ViewBuilder
    private func link(_ title: String, _ urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(title, destination: url)
        }
    }
}
