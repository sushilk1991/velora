import AppKit
import SwiftUI

/// A dictation mode: the per-context instruction set the engine applies. Mirror
/// of the JSON at `~/.velora/modes/<Name>.json`
/// (`{name, prompt, formatting, apps, vocabulary, replacements}`).
struct Mode: Identifiable, Equatable {
    /// Name doubles as identity and filename stem.
    var id: String { name }
    var name: String
    var prompt: String
    var formatting: String  // "off" | "light" | "full"
    var apps: [String]
    var vocabulary: [String]
    var replacements: [Replacement]
    /// Built-ins (Default, Raw) are protected from deletion.
    var isProtected: Bool = false

    struct Replacement: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    /// The six built-in modes, used as editable templates when no file exists.
    static let builtInTemplates: [Mode] = [
        Mode(name: "Default", prompt: "Clean up the transcript into clear, well-punctuated text. Keep the speaker's wording and intent.",
             formatting: "light", apps: [], vocabulary: [], replacements: [], isProtected: true),
        Mode(name: "Message", prompt: "Format as a casual chat message. Keep it short and conversational; no greeting or signature.",
             formatting: "light", apps: [], vocabulary: [], replacements: []),
        Mode(name: "Email", prompt: "Format as a professional email body with proper paragraphs and punctuation. Do not invent a subject or signature.",
             formatting: "full", apps: [], vocabulary: [], replacements: []),
        Mode(name: "Note", prompt: "Format as tidy notes. Use short paragraphs or bullet points where the speaker lists items.",
             formatting: "full", apps: [], vocabulary: [], replacements: []),
        Mode(name: "Code", prompt: "The speaker is dictating in a code editor. Keep identifiers and symbols verbatim; apply minimal formatting.",
             formatting: "light", apps: [], vocabulary: [], replacements: []),
        Mode(name: "Raw", prompt: "Return the transcript verbatim with no cleanup.",
             formatting: "off", apps: [], vocabulary: [], replacements: [], isProtected: true),
    ]

    static let formattingOptions = ["off", "light", "full"]
}

/// Loads, edits, and persists modes to `~/.velora/modes/`. After any write it
/// nudges the running engine with `reload_config`.
final class ModesViewModel: ObservableObject {
    @Published var modes: [Mode] = []
    @Published var selectedID: String?
    /// Editable copy of the selected mode (bound by the detail form).
    @Published var draft = Mode(name: "", prompt: "", formatting: "light",
                                apps: [], vocabulary: [], replacements: [])
    /// Non-nil when the last `save()` was blocked (e.g. a name collision).
    @Published var saveError: String?

    private weak var supervisor: EngineSupervisor?

    init(supervisor: EngineSupervisor?) {
        self.supervisor = supervisor
        load()
    }

    var hasSelection: Bool { selectedID != nil }

    // MARK: - Loading

    /// Reads every `*.json` from the modes directory, then folds in any built-in
    /// template that has no file yet so all six always appear.
    func load() {
        let dir = AppConfig.modesDirectory
        let fm = FileManager.default
        var loaded: [Mode] = []
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "json" {
                if let mode = Self.decode(url) { loaded.append(mode) }
            }
        }
        let loadedNames = Set(loaded.map { $0.name.lowercased() })
        for template in Mode.builtInTemplates where !loadedNames.contains(template.name.lowercased()) {
            loaded.append(template)
        }
        // Mark protected built-ins even if they were loaded from disk.
        let protectedNames = Set(Mode.builtInTemplates.filter { $0.isProtected }.map { $0.name.lowercased() })
        modes = loaded
            .map { mode in
                var m = mode
                if protectedNames.contains(m.name.lowercased()) { m.isProtected = true }
                return m
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if selectedID == nil || !modes.contains(where: { $0.id == selectedID }) {
            select(modes.first?.id)
        }
    }

    func select(_ id: String?) {
        selectedID = id
        if let id, let mode = modes.first(where: { $0.id == id }) {
            draft = mode
        }
    }

    // MARK: - Mutations

    func newMode() {
        let name = uniqueName("New Mode")
        let mode = Mode(name: name, prompt: "", formatting: "light",
                        apps: [], vocabulary: [], replacements: [])
        modes.append(mode)
        modes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        select(name)
    }

    func duplicate() {
        guard hasSelection else { return }
        var copy = draft
        copy.name = uniqueName("\(draft.name) Copy")
        copy.isProtected = false
        modes.append(copy)
        modes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        select(copy.name)
    }

    /// Removes the selected mode's file and list entry. Protected built-ins are
    /// refused (the caller warns and offers rename instead).
    func delete() {
        guard hasSelection, !draft.isProtected else { return }
        let name = draft.name
        try? FileManager.default.removeItem(at: fileURL(for: name))
        modes.removeAll { $0.name == name }
        reloadEngine()
        select(modes.first?.id)
    }

    private static let protectedNames =
        Set(Mode.builtInTemplates.filter { $0.isProtected }.map { $0.name.lowercased() })

    /// Writes the draft to disk (renaming its file if the name changed) and
    /// reloads the engine. Renaming a protected built-in keeps the original and
    /// creates a new mode instead of replacing it.
    func save() {
        // Block a name that collides with a *different* existing mode: `Mode.id`
        // is the name, and SwiftUI `ForEach`/`.tag` require unique ids. The
        // check is case-insensitive so "Default" can't shadow "default" either.
        let target = draft.name.lowercased()
        if modes.contains(where: { $0.id != selectedID && $0.name.lowercased() == target }) {
            saveError = "A mode named “\(draft.name)” already exists. Choose a different name."
            return
        }
        saveError = nil

        AppConfig.shared.ensureVeloraDirectory()
        try? FileManager.default.createDirectory(
            at: AppConfig.modesDirectory, withIntermediateDirectories: true)

        let original = modes.first { $0.id == selectedID }
        let renamed = selectedID != nil && selectedID != draft.name
        let renamedProtected = renamed && original?.isProtected == true

        // A rename of a normal mode drops the old file; a protected rename keeps
        // the original built-in intact.
        if renamed, original?.isProtected == false, let id = selectedID {
            try? FileManager.default.removeItem(at: fileURL(for: id))
        }

        // Protection follows the name: only a built-in name is protected.
        draft.isProtected = Self.protectedNames.contains(draft.name.lowercased())
        writeFile(draft)

        if renamedProtected {
            if !modes.contains(where: { $0.id == draft.id }) { modes.append(draft) }
        } else if let index = modes.firstIndex(where: { $0.id == selectedID }) {
            modes[index] = draft
        } else {
            modes.append(draft)
        }
        modes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        selectedID = draft.id
        reloadEngine()
    }

    // MARK: - Persistence

    private func fileURL(for name: String) -> URL {
        AppConfig.modesDirectory.appendingPathComponent("\(Self.slug(name)).json")
    }

    /// A safe, lowercased filename stem for a mode name. Lowercasing matches the
    /// engine's convention (its built-ins are `default.json` etc.) so editing a
    /// built-in overwrites the same file; sanitizing prevents a name with `/` or
    /// `..` from escaping the modes directory.
    static func slug(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        var result = String(name.lowercased().map { allowed.contains($0) ? $0 : "-" })
        // Collapse any "." runs (blocks "..") and trim leading/trailing separators.
        while result.contains("..") { result = result.replacingOccurrences(of: "..", with: ".") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return result.isEmpty ? "mode" : result
    }

    private func writeFile(_ mode: Mode) {
        var replacements: [String: String] = [:]
        for pair in mode.replacements where !pair.key.isEmpty {
            replacements[pair.key] = pair.value
        }
        let payload: [String: Any] = [
            "name": mode.name,
            "prompt": mode.prompt,
            "formatting": mode.formatting,
            "apps": mode.apps,
            "vocabulary": mode.vocabulary,
            "replacements": replacements,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: fileURL(for: mode.name), options: .atomic)
    }

    private static func decode(_ url: URL) -> Mode? {
        guard let data = try? Data(contentsOf: url),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let name = dict["name"] as? String ?? url.deletingPathExtension().lastPathComponent
        let replacements = (dict["replacements"] as? [String: String] ?? [:])
            .map { Mode.Replacement(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
        return Mode(
            name: name,
            prompt: dict["prompt"] as? String ?? "",
            formatting: dict["formatting"] as? String ?? "light",
            apps: dict["apps"] as? [String] ?? [],
            vocabulary: dict["vocabulary"] as? [String] ?? [],
            replacements: replacements)
    }

    private func reloadEngine() {
        supervisor?.send(["cmd": "reload_config"])
    }

    private func uniqueName(_ base: String) -> String {
        var name = base
        var n = 2
        let existing = Set(modes.map { $0.name.lowercased() })
        while existing.contains(name.lowercased()) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }
}

// MARK: - View

struct ModesSettingsView: View {
    @StateObject private var vm: ModesViewModel

    init(supervisor: EngineSupervisor?) {
        _vm = StateObject(wrappedValue: ModesViewModel(supervisor: supervisor))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: 580, height: SettingsTab.modes.preferredHeight)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { vm.selectedID },
                set: { vm.select($0) }
            )) {
                ForEach(vm.modes) { mode in
                    HStack(spacing: VeloraSpacing.s) {
                        Image(systemName: Self.symbol(for: mode))
                            .foregroundStyle(VeloraBrand.violet.color)
                            .frame(width: 16)
                        Text(mode.name)
                        Spacer()
                        if mode.isProtected {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(mode.id)
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: VeloraSpacing.s) {
                Button { vm.newMode() } label: { Image(systemName: "plus") }
                    .help("New mode")
                Button { vm.duplicate() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate")
                    .disabled(!vm.hasSelection)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(VeloraSpacing.s)
        }
        .frame(width: 190)
    }

    private static func symbol(for mode: Mode) -> String {
        switch mode.name.lowercased() {
        case "message": return "bubble.left"
        case "email": return "envelope"
        case "note": return "note.text"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "raw": return "textformat"
        case "default": return "star"
        default: return "slider.horizontal.3"
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if vm.hasSelection {
            ModeEditor(vm: vm)
        } else {
            VStack(spacing: VeloraSpacing.s) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 40))
                    .foregroundStyle(VeloraBrand.iconGradient)
                Text("No mode selected")
                    .font(.title3.weight(.semibold))
                Text("Create a mode to steer how Velora formats your dictation per app.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(VeloraSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Mode editor

private struct ModeEditor: View {
    @ObservedObject var vm: ModesViewModel
    @State private var showProtectedAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VeloraSpacing.l) {
                field("Name") {
                    TextField("Mode name", text: $vm.draft.name)
                        .textFieldStyle(.roundedBorder)
                }

                field("AI instructions") {
                    VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                        Text("Tell the model how to format text in this mode.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $vm.draft.prompt)
                            .font(.body)
                            .frame(height: 96)
                            .padding(VeloraSpacing.xs)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(.separatorColor)))
                    }
                }

                field("Formatting strength") {
                    Picker("", selection: $vm.draft.formatting) {
                        ForEach(Mode.formattingOptions, id: \.self) { option in
                            Text(option.capitalized).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                field("Apps") {
                    VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                        Text("Bundle identifiers this mode auto-activates for (comma separated).")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("com.tinyspeck.slackmacgap, com.apple.MobileSMS",
                                  text: listBinding(\.apps))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                field("Vocabulary") {
                    VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                        Text("Custom words and proper nouns (comma separated).")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Velora, Anthropic, Kubernetes",
                                  text: listBinding(\.vocabulary))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                field("Replacements") {
                    replacementsTable
                }

                Divider()
                footer
            }
            .padding(VeloraSpacing.l)
        }
        .alert(
            "Can't save mode",
            isPresented: Binding(get: { vm.saveError != nil },
                                 set: { if !$0 { vm.saveError = nil } })
        ) {
            Button("OK", role: .cancel) { vm.saveError = nil }
        } message: {
            Text(vm.saveError ?? "")
        }
    }

    private var replacementsTable: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            Text("Rewrite dictated phrases (heard → written).")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($vm.draft.replacements) { $pair in
                HStack(spacing: VeloraSpacing.s) {
                    TextField("heard", text: $pair.key).textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    TextField("written", text: $pair.value).textFieldStyle(.roundedBorder)
                    Button {
                        vm.draft.replacements.removeAll { $0.id == pair.id }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                vm.draft.replacements.append(Mode.Replacement(key: "", value: ""))
            } label: {
                Label("Add replacement", systemImage: "plus")
            }
            .buttonStyle(.link)
        }
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                if vm.draft.isProtected { showProtectedAlert = true } else { vm.delete() }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!vm.hasSelection)
            .alert("Built-in mode", isPresented: $showProtectedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("“\(vm.draft.name)” is a built-in mode and can't be deleted. Rename it to create a new mode instead.")
            }

            Spacer()

            Text("Modes activate automatically per app — or force one from the menubar.")
                .font(.caption).foregroundStyle(.tertiary)

            Button("Save") { vm.save() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func field<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            Text(title).font(.callout.weight(.semibold))
            content()
        }
    }

    /// Two-way binding between a `[String]` mode field and a comma-joined
    /// editable string.
    private func listBinding(_ keyPath: WritableKeyPath<Mode, [String]>) -> Binding<String> {
        Binding(
            get: { vm.draft[keyPath: keyPath].joined(separator: ", ") },
            set: { newValue in
                vm.draft[keyPath: keyPath] = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            })
    }
}
