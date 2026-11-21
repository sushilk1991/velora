import SwiftUI

/// Rules are edited in place; recording snapshots the current rule once.
struct KeyboardRoutingSettingsView: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    @ObservedObject var model: SettingsModel
    @State private var source = KeyboardLanguageRouting.currentInputSource()
    @State private var cachedModels: Set<String> = []

    var body: some View {
        GroupCard(
            header: L10n.text("Keyboard language rules"),
            footer: "Add a rule for each keyboard you use. Your selected speech model remains the manual fallback. Rules take effect on the next recording and never start a download; install a model in Models first. Turn this off to use the language above."
        ) {
            SettingsToggleRow(
                title: "Follow keyboard language",
                isOn: $model.followKeyboardLanguage)
            if model.followKeyboardLanguage {
                if let source {
                    GroupDivider()
                    GroupRow(label: L10n.text("Current keyboard"), sub: source.name) {
                        if model.keyboardSpeechRoutes[source.id] == nil {
                            Button(L10n.text("Add rule")) {
                                let language = KeyboardLanguageRouting.languages.contains(where: { $0.0 == source.language })
                                    ? source.language : "auto"
                                model.keyboardSpeechRoutes[source.id] = KeyboardSpeechRoute(
                                    language: language, model: model.sttModel)
                            }
                            .buttonStyle(.capsule)
                        } else {
                            Text(L10n.text("Configured"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(model.keyboardSpeechRoutes.keys.sorted(), id: \.self) { id in
                    GroupDivider()
                    VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                        HStack {
                            Text(source?.id == id ? (source?.name ?? id) : id)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(2)
                            Spacer()
                            Button(L10n.text("Remove"), role: .destructive) {
                                model.keyboardSpeechRoutes.removeValue(forKey: id)
                            }
                            .buttonStyle(.capsule)
                        }
                        HStack(spacing: VeloraSpacing.m) {
                            Text(L10n.text("Language"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            HeaderMenu(
                                L10n.text("Language"),
                                value: languageTitle(for: id),
                                selection: languageBinding(id)
                            ) {
                                ForEach(KeyboardLanguageRouting.languages, id: \.0) { Text($0.1).tag($0.0) }
                                if let selected = model.keyboardSpeechRoutes[id]?.language,
                                   !KeyboardLanguageRouting.languages.contains(where: { $0.0 == selected }) {
                                    Text(selected).tag(selected)
                                }
                            }
                        }
                        HStack(spacing: VeloraSpacing.m) {
                            Text(L10n.text("Speech model"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            HeaderMenu(
                                L10n.text("Speech model"),
                                value: modelTitle(for: id),
                                selection: modelBinding(id)
                            ) {
                                ForEach(speechModels, id: \.id) { Text($0.name).tag($0.id) }
                                if let selected = model.keyboardSpeechRoutes[id]?.model,
                                   !speechModels.contains(where: { $0.id == selected }) {
                                    Text(selected + " (not installed)").tag(selected)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, VeloraSpacing.m)
                }
                GroupDivider()
                GroupRow(label: L10n.text("Keyboards and installed models")) {
                    Button(L10n.text("Refresh")) {
                        source = KeyboardLanguageRouting.currentInputSource()
                        Task { cachedModels = Set(await ModelStorage.scan().map(\.id)) }
                    }
                    .buttonStyle(.capsule)
                }
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

    private func languageTitle(for id: String) -> String {
        let code = model.keyboardSpeechRoutes[id]?.language ?? "auto"
        return KeyboardLanguageRouting.languages.first(where: { $0.0 == code })?.1 ?? code
    }

    private func modelTitle(for id: String) -> String {
        let selected = model.keyboardSpeechRoutes[id]?.model ?? model.sttModel
        return speechModels.first(where: { $0.id == selected })?.name ?? selected
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
