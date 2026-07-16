import SwiftUI

/// Settings tabs (design brief §4.1): grouped forms, fixed 580 pt width,
/// height hugging content. No custom chrome, one accent color.
enum SettingsTab: CaseIterable {
    case general, dictation, dictionary, model, modes, history, intelligence, meetings, shortcuts, about

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .dictionary: return "Dictionary"
        case .model: return "Model"
        case .modes: return "Modes"
        case .history: return "History"
        case .intelligence: return "Intelligence"
        case .meetings: return "Meetings"
        case .shortcuts: return "Shortcuts"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "mic"
        case .dictionary: return "text.book.closed"
        case .model: return "cpu"
        case .modes: return "slider.horizontal.3"
        case .history: return "clock.arrow.circlepath"
        case .intelligence: return "chart.bar.xaxis"
        case .meetings: return "person.2.wave.2"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }

    var preferredHeight: CGFloat {
        switch self {
        case .general: return 350
        case .dictation: return 500
        case .dictionary: return 440
        case .model: return 480
        case .modes: return 600
        case .history: return 560
        case .intelligence: return 620
        case .meetings: return 720
        case .shortcuts: return 320
        case .about: return 320
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch Velora at login", isOn: $model.launchAtLogin)
            }
            Section {
                Picker("HUD position", selection: $model.hudPosition) {
                    Text("Bottom center").tag(HUDPosition.bottomCenter)
                    Text("Top center").tag(HUDPosition.topCenter)
                    if model.hudPosition == .custom {
                        Text("Custom (dragged)").tag(HUDPosition.custom)
                    }
                }
                Picker("Appearance", selection: $model.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            } footer: {
                Text("Tip: while the HUD is on screen, drag the pill to place it anywhere — that switches it to Custom.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Allow local CLI and agents", isOn: $model.localAgentAccess)
            } footer: {
                Text("Off by default. When enabled, processes running as your macOS user can read allow-listed local history and aggregate stats through an owner-only Unix socket. No network server is opened.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: SettingsTab.general.preferredHeight)
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
                Picker("Hotkey behavior", selection: $model.hotkeyMode) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("With Hold to talk, a quick tap locks recording on; tap again to finish. Esc always cancels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                        Text("Clean up long prose dictated into a terminal (AI chats); short commands stay verbatim.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $model.voiceCommands) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice commands")
                        Text("Say just \u{201C}scratch that\u{201D} to undo the last dictation, or \u{201C}new line\u{201D} to press Return.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $model.learnFromEdits) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Learn from my edits")
                        Text("When you fix a misheard word, Velora adds the confirmed correction to your Personal Dictionary.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $model.vocabMining) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Learn new words automatically")
                        Text("While idle, Velora spots recurring names and jargon and adds confirmed terms to your Personal Dictionary.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle(isOn: $model.saveAudio) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save audio for reprocessing")
                        Text("Clips are stored locally at ~/.velora/audio for \(Int(model.audioRetentionDays / 30)) months and used by History → Reprocess.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Archive size", value: archiveSize)
            } header: {
                Text("Audio archive")
            }
            Section {
                Toggle("Play sounds", isOn: $model.soundsEnabled)
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
        }
        .formStyle(.grouped)
        .frame(width: 580, height: SettingsTab.dictation.preferredHeight)
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
        .frame(width: 580, height: SettingsTab.model.preferredHeight)
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
                LabeledContent("Dictation hotkey") {
                    HotkeyRecorderView(hotkey: $model.hotkey)
                }
            } footer: {
                Text("Click the shortcut, then press any key combo — or press and release a bare modifier like Right Option. Esc cancels recording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Cancel recording", value: "Esc")
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: SettingsTab.shortcuts.preferredHeight)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "0.1.0"
    }

    var body: some View {
        VStack(spacing: VeloraSpacing.m) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(VeloraBrand.iconGradient)
                .padding(.top, VeloraSpacing.xl)
            Text("Velora")
                .font(.title2.weight(.semibold))
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open-source, local-first dictation.\nYour voice never leaves this Mac.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: VeloraSpacing.l) {
                link("GitHub", "https://github.com/velora-app/velora")
                link("Report an Issue", "https://github.com/velora-app/velora/issues")
            }
            .padding(.top, VeloraSpacing.xs)

            Spacer()

            Text("Built with parakeet-mlx, mlx-whisper, and mlx-lm.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, VeloraSpacing.l)
        }
        .frame(width: 580, height: SettingsTab.about.preferredHeight)
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
