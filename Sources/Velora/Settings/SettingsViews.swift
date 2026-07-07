import SwiftUI

/// Settings tabs (design brief §4.1): grouped forms, fixed 580 pt width,
/// height hugging content. No custom chrome, one accent color.
enum SettingsTab: CaseIterable {
    case general, dictation, model, modes, history, shortcuts, about

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .model: return "Model"
        case .modes: return "Modes"
        case .history: return "History"
        case .shortcuts: return "Shortcuts"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "mic"
        case .model: return "cpu"
        case .modes: return "slider.horizontal.3"
        case .history: return "clock.arrow.circlepath"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }

    var preferredHeight: CGFloat {
        switch self {
        case .general: return 230
        case .dictation: return 430
        case .model: return 400
        case .modes: return 600
        case .history: return 560
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
                    ForEach(HUDPosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                Picker("Appearance", selection: $model.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
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

    /// The cleanup model the engine advertises, if any (falls back to the
    /// shipped default label).
    private var cleanupModelName: String {
        model.engineModels.first { $0.kind == "cleanup" }?.displayName
            ?? "Qwen3-4B Instruct (4-bit)"
    }

    var body: some View {
        Form {
            Section {
                Picker("Speech model", selection: $model.sttModel) {
                    ForEach(choices) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
            } footer: {
                Text("Models download on first use and run entirely on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Available models") {
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
            Section {
                LabeledContent("Cleanup model", value: cleanupModelName)
                LabeledContent("Model storage", value: storageUsed)
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: SettingsTab.model.preferredHeight)
        .task { storageUsed = await Self.modelStorageDescription() }
        .onAppear { model.requestStatus() }
    }

    /// Sums the HuggingFace hub cache size off the main thread.
    private static func modelStorageDescription() async -> String {
        let path = NSHomeDirectory() + "/.cache/huggingface/hub"
        return await Task.detached(priority: .utility) { () -> String in
            let fm = FileManager.default
            guard fm.fileExists(atPath: path),
                  let files = fm.enumerator(atPath: path)
            else { return "No models downloaded" }
            var total: Int64 = 0
            while let file = files.nextObject() as? String {
                let attrs = try? fm.attributesOfItem(atPath: path + "/" + file)
                total += (attrs?[.size] as? Int64) ?? 0
            }
            return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }.value
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
