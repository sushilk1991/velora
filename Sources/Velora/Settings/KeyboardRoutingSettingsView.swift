import SwiftUI

/// Rules are edited in place; recording snapshots the current rule once.
struct KeyboardRoutingSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var source = KeyboardLanguageRouting.currentInputSource()
    @State private var cachedModels: Set<String> = []

    var body: some View {
        Section {
            Toggle("Follow keyboard language", isOn: $model.followKeyboardLanguage)
            if model.followKeyboardLanguage {
                if let source {
                    HStack {
                        Text("Current keyboard: \(source.name)")
                        Spacer()
                        if model.keyboardSpeechRoutes[source.id] == nil {
                            Button("Add rule") {
                                let language = KeyboardLanguageRouting.languages.contains(where: { $0.0 == source.language })
                                    ? source.language : "auto"
                                model.keyboardSpeechRoutes[source.id] = KeyboardSpeechRoute(
                                    language: language, model: model.sttModel)
                            }
                        }
                    }
                }
                ForEach(model.keyboardSpeechRoutes.keys.sorted(), id: \.self) { id in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(source?.id == id ? (source?.name ?? id) : id).font(.caption).lineLimit(2)
                            Spacer()
                            Button("Remove", role: .destructive) { model.keyboardSpeechRoutes.removeValue(forKey: id) }
                        }
                        Picker("Language", selection: languageBinding(id)) {
                            ForEach(KeyboardLanguageRouting.languages, id: \.0) { Text($0.1).tag($0.0) }
                            if let selected = model.keyboardSpeechRoutes[id]?.language,
                               !KeyboardLanguageRouting.languages.contains(where: { $0.0 == selected }) {
                                Text(selected).tag(selected)
                            }
                        }
                        Picker("Speech model", selection: modelBinding(id)) {
                            ForEach(speechModels, id: \.id) { Text($0.name).tag($0.id) }
                            if let selected = model.keyboardSpeechRoutes[id]?.model,
                               !speechModels.contains(where: { $0.id == selected }) {
                                Text(selected + " (not installed)").tag(selected)
                            }
                        }
                    }
                }
                Button("Refresh keyboards and installed models") {
                    source = KeyboardLanguageRouting.currentInputSource()
                    Task { cachedModels = Set(await ModelStorage.scan().map(\.id)) }
                }
            }
        } header: {
            Text("Keyboard language rules")
        } footer: {
            Text("Add a rule for each keyboard you use. Your selected speech model remains the manual fallback. Rules take effect on the next recording and never start a download; install a model in Models first. Turn this off to use the language above.")
                .font(.caption).foregroundStyle(.secondary)
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
