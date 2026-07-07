import SwiftUI

/// Settings tabs (design brief §4.1): grouped forms, fixed 580 pt width,
/// height hugging content. No custom chrome, one accent color.
enum SettingsTab: CaseIterable {
    case general, dictation, model, shortcuts, about

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .model: return "Model"
        case .shortcuts: return "Shortcuts"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "mic"
        case .model: return "cpu"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }

    var preferredHeight: CGFloat {
        switch self {
        case .general: return 230
        case .dictation: return 330
        case .model: return 400
        case .shortcuts: return 240
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

    private static let languages: [(String, String)] = [
        ("auto", "Automatic"), ("en", "English"), ("es", "Spanish"),
        ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("ja", "Japanese"), ("zh", "Chinese"),
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
                Text("With Hold to talk, double-tap the hotkey to lock recording on. Esc always cancels.")
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
    }
}

// MARK: - Model

struct ModelSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var storageUsed: String = "…"

    var body: some View {
        Form {
            Section {
                Picker("Speech model", selection: $model.sttModel) {
                    ForEach(STTModel.all) { sttModel in
                        Text(sttModel.displayName).tag(sttModel.id)
                    }
                }
            } footer: {
                Text("Models download on first use and run entirely on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Available models") {
                ForEach(STTModel.all) { sttModel in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sttModel.displayName)
                            Text(sttModel.languages)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(sttModel.speed)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(sttModel.size)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                LabeledContent("Cleanup model", value: "Qwen3-4B Instruct (4-bit)")
                LabeledContent("Model storage", value: storageUsed)
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: SettingsTab.model.preferredHeight)
        .task { storageUsed = await Self.modelStorageDescription() }
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
                Picker("Dictation hotkey", selection: $model.hotkey) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
            } footer: {
                Text("Hold to dictate, double-tap to lock recording on. A fully custom shortcut recorder is coming in a future release.")
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
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 24)
            Text("Velora")
                .font(.title2.weight(.semibold))
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open-source, local-first dictation.\nYour voice never leaves this Mac.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/velora-app/velora")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/velora-app/velora/issues")!)
            }
            .padding(.top, 4)

            Spacer()

            Text("Built with parakeet-mlx, mlx-whisper, and mlx-lm.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(width: 580, height: SettingsTab.about.preferredHeight)
    }
}
