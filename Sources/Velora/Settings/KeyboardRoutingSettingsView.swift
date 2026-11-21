import SwiftUI

/// Rules are edited in place; recording snapshots the current rule once.
struct KeyboardRoutingSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var source = KeyboardLanguageRouting.currentInputSource()
    @State private var cachedModels: Set<String> = []

    var body: some View {
        SettingsCard(
            title: "Keyboard language rules",
            symbol: "globe",
            tint: VeloraBrand.accent,
            footer: "Add a rule for each keyboard you use. Your selected speech model remains the manual fallback. Rules take effect on the next recording and never start a download; install a model in Models first. Turn this off to use the language above."
        ) {
            SettingsToggleRow(
                title: "Follow keyboard language",
                isOn: $model.followKeyboardLanguage)
            if model.followKeyboardLanguage {
                if let source {
                    GroupDivider()
                    SettingsRow(title: "Current keyboard", subtitle: source.name) {
                        if model.keyboardSpeechRoutes[source.id] == nil {
                            Button("Add rule") {
                                let language = KeyboardLanguageRouting.languages.contains(where: { $0.0 == source.language })
                                    ? source.language : "auto"
                                model.keyboardSpeechRoutes[source.id] = KeyboardSpeechRoute(
                                    language: language, model: model.sttModel)
                            }
                            .buttonStyle(.settingsChip)
                        } else {
                            SettingsStatusPill(text: "Configured", tint: VeloraStatus.success)
                        }
                    }
                }
                ForEach(model.keyboardSpeechRoutes.keys.sorted(), id: \.self) { id in
                    GroupDivider()
                    VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                        HStack {
                            Text(source?.id == id ? (source?.name ?? id) : id)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(2)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                model.keyboardSpeechRoutes.removeValue(forKey: id)
                            }
                            .buttonStyle(.settingsChip)
                        }
                        HStack(spacing: VeloraSpacing.m) {
                            Text("Language").font(.system(size: 12.5)).foregroundStyle(.secondary)
                            Spacer()
                            Picker("Language", selection: languageBinding(id)) {
                                ForEach(KeyboardLanguageRouting.languages, id: \.0) { Text($0.1).tag($0.0) }
                                if let selected = model.keyboardSpeechRoutes[id]?.language,
                                   !KeyboardLanguageRouting.languages.contains(where: { $0.0 == selected }) {
                                    Text(selected).tag(selected)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 200)
                        }
                        HStack(spacing: VeloraSpacing.m) {
                            Text("Speech model").font(.system(size: 12.5)).foregroundStyle(.secondary)
                            Spacer()
                            Picker("Speech model", selection: modelBinding(id)) {
                                ForEach(speechModels, id: \.id) { Text($0.name).tag($0.id) }
                                if let selected = model.keyboardSpeechRoutes[id]?.model,
                                   !speechModels.contains(where: { $0.id == selected }) {
                                    Text(selected + " (not installed)").tag(selected)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                GroupDivider()
                HStack {
                    Button("Refresh keyboards and installed models") {
                        source = KeyboardLanguageRouting.currentInputSource()
                        Task { cachedModels = Set(await ModelStorage.scan().map(\.id)) }
                    }
                    .buttonStyle(.settingsChip)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .task { cachedModels = Set(await ModelStorage.scan().map(\.id)) }
    }

    private var speechModels: [(id: String, name: String)] {
        let installed = cachedModels.union([model.sttModel]).union(
            model.downloads.downloads.filter { $0.kind == .stt && $0.state == .ready }.map(\.model))
        if !model.sttEngineModels.isEmpty {
            return model.sttEngineModels.filter { installed.contains($0.id) }.map { ($0.id, $0.displayName) }
        }
        return STTModel.all.filter { installed.contains($0.id) }.map { ($0.id, $0.displayName) }
    }

    private func languageBinding(_ id: String) -> Binding<String> {
        Binding(get: { model.keyboardSpeechRoutes[id]?.language ?? "auto" }, set: { value in
            guard var route = model.keyboardSpeechRoutes[id] else { return }
            route.language = value
            model.keyboardSpeechRoutes[id] = route
        })
    }
    private func modelBinding(_ id: String) -> Binding<String> {
        Binding(get: { model.keyboardSpeechRoutes[id]?.model ?? model.sttModel }, set: { value in
            guard var route = model.keyboardSpeechRoutes[id] else { return }
            route.model = value
            model.keyboardSpeechRoutes[id] = route
        })
    }
}
