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

    /// Comma-separated list-field text -> trimmed, non-empty items. The
    /// editor buffers field text locally and parses through this on change.
    static func parseList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sidebar

    /// Mode list: quiet monochrome glyphs (the selection highlight is the only
    /// color), so the list reads as one calm column instead of a hue lottery.
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { vm.selectedID },
                set: { vm.select($0) }
            )) {
                ForEach(vm.modes) { mode in
                    HStack(spacing: VeloraSpacing.s) {
                        Image(systemName: Self.symbol(for: mode))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(mode.name)
                            .lineLimit(1)
                        Spacer()
                        if mode.isProtected {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help("Built-in mode")
                        }
                    }
                    .padding(.vertical, 2)
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
        .frame(width: 180)
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
    /// Local text buffers for the comma-separated list fields. Binding the
    /// field straight to the parsed array re-joins it on every keystroke,
    /// which eats the ", " you just typed before the next item can exist.
    @State private var appsText = ""
    @State private var vocabularyText = ""

    var body: some View {
        // Grouped form + bottom action bar — the pre-0.9 editor was a bare
        // stack of labeled fields that read as a different app from every
        // other card-grouped pane.
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $vm.draft.name)
                    Picker("Formatting strength", selection: $vm.draft.formatting) {
                        ForEach(Mode.formattingOptions, id: \.self) { option in
                            Text(option.capitalized).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    // A visibly editable text area — borderless looked like a
                    // caption, and the owner read the whole pane as unclear.
                    TextEditor(text: $vm.draft.prompt)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                        .padding(VeloraSpacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(.textBackgroundColor)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(.separatorColor)))
                        .padding(.vertical, VeloraSpacing.xs)
                } header: {
                    Text("AI instructions")
                } footer: {
                    SettingsFooter("Tell the model how to format text in this mode.")
                }

                Section {
                    // Long comma lists get label-above, wrapping fields — the
                    // labeled-row idiom truncated them into an unreadable
                    // right-aligned sliver in this column.
                    stackedField(
                        "Apps", text: $appsText,
                        prompt: "com.tinyspeck.slackmacgap, com.apple.MobileSMS")
                        .onChange(of: appsText) { _, text in
                            vm.draft.apps = Mode.parseList(text)
                        }
                    stackedField(
                        "Vocabulary", text: $vocabularyText,
                        prompt: "Velora, Anthropic, Kubernetes")
                        .onChange(of: vocabularyText) { _, text in
                            vm.draft.vocabulary = Mode.parseList(text)
                        }
                } footer: {
                    SettingsFooter("Apps lists the bundle identifiers this mode auto-activates for; Vocabulary adds words and proper nouns it should recognize. Both are comma separated. Modes also activate from the menubar's Mode menu.")
                }

                Section {
                    replacementsTable
                } header: {
                    Text("Replacements")
                } footer: {
                    SettingsFooter("Rewrite dictated phrases (heard → written).")
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .onAppear { syncListBuffers() }
        .onChange(of: vm.selectedID) { _, _ in syncListBuffers() }
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

    /// Re-seeds the list-field buffers from the (newly selected) draft.
    private func syncListBuffers() {
        appsText = vm.draft.apps.joined(separator: ", ")
        vocabularyText = vm.draft.vocabulary.joined(separator: ", ")
    }

    /// Label-above bordered field that wraps long values across lines.
    private func stackedField(
        _ label: String, text: Binding<String>, prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            Text(label)
            TextField(label, text: text, prompt: Text(prompt), axis: .vertical)
                .labelsHidden()
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, VeloraSpacing.xs)
    }

    private var replacementsTable: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            ForEach($vm.draft.replacements) { $pair in
                HStack(spacing: VeloraSpacing.s) {
                    TextField("heard", text: $pair.key).textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    TextField("written", text: $pair.value).textFieldStyle(.roundedBorder)
                        .padding(.vertical, 0)
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

    /// Bottom action bar: destructive on the left, primary on the right, the
    /// standard macOS bottom-button arrangement.
    private var footer: some View {
        HStack(spacing: VeloraSpacing.s) {
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

            Button("Save") {
                vm.save()
                // Show the normalized lists ("a,,b " → "a, b") after a save.
                syncListBuffers()
            }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(vm.draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, VeloraSpacing.m)
        .padding(.vertical, 10)
        .background(.bar)
    }

}
