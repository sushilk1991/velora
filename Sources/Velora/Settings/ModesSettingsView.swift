import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A dictation mode: the per-context instruction set the engine applies. Mirror
/// of the JSON at `~/.velora/modes/<Name>.json`
/// (`{name, prompt, formatting, apps, vocabulary, replacements}`).
struct Mode: Identifiable, Equatable {
    /// A saved mode is its file, so two files that name the same mode
    /// stay two rows; an unsaved one goes by `unsavedID` until saved.
    var id: String { stem ?? unsavedID ?? name }
    var name: String
    var prompt: String
    var formatting: String  // "off" | "light" | "full"
    var apps: [String]
    var vocabulary: [String]
    var replacements: [Replacement]
    /// Built-ins (Default, Raw) are protected from deletion.
    var isProtected: Bool = false
    /// The file this mode lives in ("a" for a.json, "Work" for Work.json),
    /// whatever its name says; nil until it's saved. Delete, Save, rename
    /// and Reset go by it. Compare it lowercased: the disk ignores case.
    var stem: String?
    /// A New Mode or Duplicate row's id ("unsaved:" + UUID) until its
    /// save picks a stem: a name could match a hand-made file's stem
    /// ("New Mode.json" named "Foo").
    var unsavedID: String?

    struct Replacement: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    /// File stems of the built-ins marked protected (the list's lock).
    private static let protectedStems: Set<String> = ["default", "raw"]

    static let formattingOptions = ["off", "light", "full"]

    /// The mode a dictation with no stored mode ran in.
    static let defaultName = "Default"

    /// The mode's list glyph: quiet and monochrome, one per known name.
    var symbol: String {
        switch name.lowercased() {
        case "message": return "bubble.left"
        case "email": return "envelope"
        case "note": return "note.text"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "terminal": return "terminal"
        case "raw": return "textformat"
        case "default": return "star"
        default: return "slider.horizontal.3"
        }
    }

    /// The list row's sub-caption: formatting strength, then how many apps
    /// switch to this mode ("Light formatting · 2 apps"). Default runs
    /// wherever no other mode claims the app, so it says that instead.
    var listSummary: String {
        let strength = formatting == "off" ? "No formatting" : "\(formatting.capitalized) formatting"
        if name.caseInsensitiveCompare(Self.defaultName) == .orderedSame {
            return "\(strength) · Used when no other mode matches"
        }

        let applications: String
        switch apps.count {
        case 0: applications = "No apps"
        case 1: applications = "1 app"
        default: applications = "\(apps.count) apps"
        }
        return "\(strength) · \(applications)"
    }

    /// Every `*.json` in `directory`, plus each mode Velora ships (the
    /// engine's `modes_builtin`) that has no file yet, as the engine
    /// installs them on its next load; default.json and raw.json marked
    /// protected, sorted by name. The Modes pane and History's Reprocess
    /// menu share it.
    static func loadAll(from directory: URL, packaged packagedDirectory: URL? = packagedDirectory) -> [Mode] {
        loadStamped(from: directory, packaged: packagedDirectory).modes
    }

    /// `loadAll`, with the identity of each file it read from `directory`,
    /// by stem: what Save and Reset check before they touch that file. A
    /// packaged mode has none, since no file of the user's was read for it.
    fileprivate static func loadStamped(
        from directory: URL, packaged packagedDirectory: URL?
    ) -> (modes: [Mode], stamps: [String: FileStamp]) {
        let saved = decodeAll(in: directory)
        var loaded = saved.map(\.mode)

        // The engine installs by file stem; rows are keyed by name. Skip a
        // packaged mode that matches either, so no name lists twice.
        let taken = Set(saved.map { $0.stem.lowercased() } + loaded.map { ModesViewModel.slug($0.name) })
        for stock in decodeAll(in: packagedDirectory)
        where !taken.contains(stock.stem.lowercased()) && !taken.contains(ModesViewModel.slug(stock.mode.name)) {
            loaded.append(stock.mode)
        }

        let modes = loaded
            .map { mode in
                // The file, not the name, as Reset and Delete go by it.
                var marked = mode
                if let stem = mode.stem, protectedStems.contains(stem.lowercased()) {
                    marked.isProtected = true
                }
                return marked
            }
            .sorted(by: byName)

        var stamps: [String: FileStamp] = [:]
        for file in saved {
            stamps[file.stem] = file.stamp
        }
        return (modes, stamps)
    }

    /// A to Z by name. Modes that share a name go by file stem, so their
    /// order never depends on how the disk lists them.
    fileprivate static func byName(_ lhs: Mode, _ rhs: Mode) -> Bool {
        switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return (lhs.stem ?? "") < (rhs.stem ?? "")
        }
    }

    /// Where the engine's packaged modes live, found in
    /// `ResourceLocator.locateEngine()`'s order but read in place: that
    /// call syncs a bundled engine into Application Support, under the
    /// engine already running from there.
    ///
    ///     VELORA_ENGINE_DIR ─▶ (only that)
    ///     else  Resources/engine ─▶ VeloraEngineDir ─▶ <repo>/engine
    ///     each + src/velora_engine/modes_builtin, first that exists
    static func findPackagedModes(
        environment: [String: String], resources: URL?, bakedEngine: String?, repoRoot: URL?
    ) -> URL? {
        let engines: [URL?]
        if let override = environment["VELORA_ENGINE_DIR"], !override.isEmpty {
            engines = [URL(fileURLWithPath: override, isDirectory: true)]
        } else {
            engines = [
                resources?.appendingPathComponent("engine", isDirectory: true),
                bakedEngine.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) },
                repoRoot?.appendingPathComponent("engine", isDirectory: true),
            ]
        }
        return engines
            .compactMap { $0?.appendingPathComponent(packagedModesPath, isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static let packagedModesPath = "src/velora_engine/modes_builtin"

    /// This launch's packaged modes, looked up once.
    fileprivate static let packagedDirectory = findPackagedModes(
        environment: ProcessInfo.processInfo.environment,
        resources: Bundle.main.resourceURL,
        bakedEngine: Bundle.main.object(forInfoDictionaryKey: "VeloraEngineDir") as? String,
        repoRoot: ResourceLocator.repoRoot)

    /// Every mode file in `folder` with its filename stem, case as on disk,
    /// and its identity, taken before the read so a change after it shows.
    fileprivate static func decodeAll(in folder: URL?) -> [(stem: String, mode: Mode, stamp: FileStamp?)] {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)
        else {
            return []
        }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            let stamp = FileStamp(url)
            guard var mode = decode(url) else {
                return nil
            }
            let stem = url.deletingPathExtension().lastPathComponent
            mode.stem = stem
            return (stem, mode, stamp)
        }
    }

    fileprivate static func decode(_ url: URL) -> Mode? {
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

    /// Comma-separated list-field text -> trimmed, non-empty items. The
    /// editor buffers field text locally and parses through this on change.
    static func parseList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A person-facing name for an assigned app, so no row shows a bundle
    /// ID: the installed app's own name, else a known name, else the ID's
    /// last part as words ("com.example.my-tool" → "My Tool").
    static func applicationName(for bundleID: String, installedName: String?) -> String {
        if let installedName, !installedName.isEmpty {
            return installedName
        }
        if let known = knownApplicationNames[bundleID.lowercased()] {
            return known
        }
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Names for the apps Velora's modes ship with and the browsers it
    /// recognises (`ModeCategory.byBundleID`), keyed by lowercased bundle ID.
    /// They title an app's row when it is not installed on this Mac.
    private static let knownApplicationNames: [String: String] = [
        "app.zen-browser.zen": "Zen",
        "com.agiletortoise.drafts-osx": "Drafts",
        "com.apple.dt.xcode": "Xcode",
        "com.apple.iwork.pages": "Pages",
        "com.apple.mail": "Mail",
        "com.apple.mobilesms": "Messages",
        "com.apple.notes": "Notes",
        "com.apple.safari": "Safari",
        "com.apple.terminal": "Terminal",
        "com.apple.textedit": "TextEdit",
        "com.brave.browser": "Brave Browser",
        "com.cmuxterm.app": "cmux",
        "com.culturedcode.thingsmac": "Things",
        "com.exafunction.windsurf": "Windsurf",
        "com.facebook.archon": "Messenger",
        "com.github.wez.wezterm": "WezTerm",
        "com.google.chrome": "Google Chrome",
        "com.googlecode.iterm2": "iTerm",
        "com.hnc.discord": "Discord",
        "com.jetbrains.clion": "CLion",
        "com.jetbrains.datagrip": "DataGrip",
        "com.jetbrains.goland": "GoLand",
        "com.jetbrains.intellij": "IntelliJ IDEA",
        "com.jetbrains.intellij.ce": "IntelliJ IDEA CE",
        "com.jetbrains.phpstorm": "PhpStorm",
        "com.jetbrains.pycharm": "PyCharm",
        "com.jetbrains.pycharm.ce": "PyCharm CE",
        "com.jetbrains.rider": "Rider",
        "com.jetbrains.rubymine": "RubyMine",
        "com.jetbrains.webstorm": "WebStorm",
        "com.kagi.kagimacos": "Orion",
        "com.lukilabs.lukiapp": "Craft",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.microsoft.outlook": "Microsoft Outlook",
        "com.microsoft.teams": "Microsoft Teams classic",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.vscode": "Visual Studio Code",
        "com.microsoft.word": "Microsoft Word",
        "com.mimestream.mimestream": "Mimestream",
        "com.mitchellh.ghostty": "Ghostty",
        "com.operasoftware.opera": "Opera",
        "com.readdle.smartemail-mac": "Spark Classic",
        "com.readdle.sparkdesktop": "Spark",
        "com.sublimetext.3": "Sublime Text 3",
        "com.sublimetext.4": "Sublime Text",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.vivaldi.vivaldi": "Vivaldi",
        "company.thebrowser.browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "dev.warp.warp-stable": "Warp",
        "dev.zed.zed": "Zed",
        "md.obsidian": "Obsidian",
        "net.kovidgoyal.kitty": "kitty",
        "net.shinyfrog.bear": "Bear",
        "net.whatsapp.whatsapp": "WhatsApp",
        "notion.id": "Notion",
        "org.alacritty": "Alacritty",
        "org.mozilla.firefox": "Firefox",
        "org.telegram.desktop": "Telegram Desktop",
        "org.whispersystems.signal-desktop": "Signal",
        "ru.keepcoder.telegram": "Telegram",
    ]

    /// Keeps the first spelling/order of each bundle identifier. Bundle IDs are
    /// compared case-insensitively end to end, including hand-edited JSON.
    static func normalizedApplicationIDs(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }

    /// A picker result is authoritative: replace any manually entered casing
    /// of the same identifier without moving its row, then append new apps.
    static func mergingApplicationIDs(existing: [String], selected: [String]) -> [String] {
        let canonical = normalizedApplicationIDs(selected)
        let selectedByKey = Dictionary(
            canonical.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first })
        var emitted: Set<String> = []
        var merged = normalizedApplicationIDs(existing).compactMap { identifier -> String? in
            let key = identifier.lowercased()
            guard let replacement = selectedByKey[key] else { return identifier }
            guard emitted.insert(key).inserted else { return nil }
            return replacement
        }
        for identifier in canonical where emitted.insert(identifier.lowercased()).inserted {
            merged.append(identifier)
        }
        return normalizedApplicationIDs(merged)
    }

    static func firstAssignmentConflict(
        applications: [String], modes: [Mode], excluding selectedID: String?
    ) -> (bundleID: String, modeName: String)? {
        let requested = Set(applications.map { $0.lowercased() })
        guard !requested.isEmpty else { return nil }
        for mode in modes where mode.id != selectedID {
            if let bundleID = mode.apps.first(where: { requested.contains($0.lowercased()) }) {
                return (bundleID, mode.name)
            }
        }
        return nil
    }
}

/// A mode file as it was when read: which file it is (a replace makes a
/// new one) and when its bytes last changed. Save and Reset compare it
/// again before they replace or remove the file.
fileprivate struct FileStamp: Equatable {
    let identifier: NSObject?
    let modified: Date?

    /// nil when there's no file at `url`.
    init?(_ url: URL) {
        // A URL keeps the values it read once; a fresh one reads the disk.
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(
            forKeys: [.fileResourceIdentifierKey, .contentModificationDateKey])
        else {
            return nil
        }
        identifier = values.fileResourceIdentifier as? NSObject
        modified = values.contentModificationDate
    }
}

/// Loads, edits, and persists modes to `~/.velora/modes/`. After any write it
/// nudges the running engine with `reload_config`.
final class ModesViewModel: ObservableObject {
    @Published var modes: [Mode] = []
    /// The mode whose editor is open; nil shows the list.
    @Published var selectedID: String?
    /// Editable copy of the selected mode (bound by the detail form).
    @Published var draft = Mode(name: "", prompt: "", formatting: "light",
                                apps: [], vocabulary: [], replacements: [])
    /// Non-nil when the last `save()` was blocked (e.g. a name collision).
    @Published var saveError: String?
    /// A selection change held back while the draft has unsaved edits; the
    /// pane asks Save / Don't Save / Cancel.
    @Published var pendingChange: PendingChange?

    enum PendingChange: Equatable {
        case select(String?)
        case newMode
        case duplicate
        case leave
    }

    /// The answer to "Save changes before quitting?".
    enum QuitAnswer {
        case save
        case dontSave
        case cancel
    }

    /// Whether Velora may quit once unsaved mode edits are settled.
    enum QuitCheck: Equatable {
        case quit
        case stay
        /// The save failed; the message says why.
        case failed(String)
    }

    /// The title of the alert that shows `saveError`: a failed Reset
    /// isn't a failed save.
    @Published private(set) var saveErrorTitle = ModesViewModel.saveFailedTitle

    private static let saveFailedTitle = "Can't save mode"
    private static let resetFailedTitle = "Couldn't update mode"
    private static let deleteFailedTitle = "Couldn't delete mode"

    /// Set while the quit prompt, or its failed-save report, is up.
    private static var quitPromptOpen = false
    /// The mode that prompt is about. Its draft is off the books while the
    /// prompt is up: a parked one moved into the prompt's own model.
    private static var quitPromptMode: String?

    /// Mode edits that aren't on disk. An update relaunch waits on them:
    /// its helper hard-exits after quit starts, past any Cancel.
    static func hasUnsavedEdits(open: ModesViewModel?) -> Bool {
        unsavedModeName(open: open) != nil
    }

    /// The mode whose edits aren't on disk, by its saved name: the one the
    /// quit prompt is asking about, else the open pane's dirty draft, else
    /// (no pane open) one parked when the pane closed. nil when all's saved.
    static func unsavedModeName(open: ModesViewModel?) -> String? {
        if quitPromptOpen, let asking = quitPromptMode {
            return asking
        }
        if let open {
            return open.isDirty ? open.unsavedName : nil
        }
        return parked?.name
    }

    /// Velora's answer to Quit; true lets it quit. Unsaved edits go to
    /// `ask`, a failed save to `report`. A quit that arrives while either
    /// is up is cancelled instead of stacking a second prompt.
    static func confirmQuit(
        open: ModesViewModel?, ask: (String) -> QuitAnswer, report: (String) -> Void
    ) -> Bool {
        guard !quitPromptOpen else {
            return false
        }
        quitPromptMode = unsavedModeName(open: open)
        quitPromptOpen = true
        defer {
            quitPromptOpen = false
            quitPromptMode = nil
        }

        switch settleBeforeQuit(open: open, ask: ask) {
        case .quit:
            return true
        case .stay:
            return false
        case .failed(let reason):
            report(reason)
            return false
        }
    }

    private weak var supervisor: EngineSupervisor?
    private let directory: URL
    private let packagedDirectory: URL?
    /// Velora's own modes by lowercased filename stem ("code"): what Reset to
    /// Default restores. Empty when the engine project can't be found.
    private let packaged: [String: Mode]
    /// New or duplicated modes that exist only in the list, not on disk.
    private var unsavedIDs: Set<String> = []
    /// Each mode file the list read from `directory`, by stem, as it was
    /// then. Save and Reset replace or remove no file that has changed.
    private var stamps: [String: FileStamp] = [:]
    /// The pane switch a Save / Don't Save answer completes.
    private var pendingLeave: (() -> Void)?
    // Test seam: Selftest passes a writer that fails partway, as a full
    // disk does, or races another app, and a rename a volume without
    // RENAME_EXCL refuses; Velora passes `diskWriter` and `diskRenameExcl`.
    private let writeBytes: ByteWriter
    private let renameExclusive: ExclusiveRename
    // Test seam: Selftest fails the identity check's read of a file, as a
    // stat error does; Velora always reads it.
    private let canReadStamp: (URL) -> Bool

    /// An unsaved draft left behind when the pane closed. The shell rebuilds
    /// this model on every visit, so the draft waits here, one-shot, for the
    /// next model on the same directory.
    private struct ParkedDraft {
        let directory: URL
        let packagedDirectory: URL?
        let selectedID: String?
        /// The mode's saved name, for the update hold and the quit prompt.
        let name: String
        let draft: Mode
        let unsaved: [Mode]
        /// The draft's file as the list read it; nil when it had none.
        let stamp: FileStamp?
    }

    private static var parked: ParkedDraft?

    /// A mode the next model opens straight into its editor, one-shot
    /// (the window-snapshot harness captures the editor this way).
    private static var pendingOpen: String?

    /// Stems of the modes the engine ships (`modes_builtin`), so a shipped
    /// mode still never deletes or renames, and no other mode takes its
    /// name, when those files can't be found.
    private static let shippedStems: Set<String> = [
        "code", "default", "email", "message", "note", "raw", "terminal",
    ]

    init(
        supervisor: EngineSupervisor?, directory: URL = AppConfig.modesDirectory,
        packagedDirectory: URL? = Mode.packagedDirectory,
        writeBytes: @escaping ByteWriter = ModesViewModel.diskWriter,
        renameExclusive: @escaping ExclusiveRename = ModesViewModel.diskRenameExcl,
        canReadStamp: @escaping (URL) -> Bool = { _ in true }
    ) {
        self.supervisor = supervisor
        self.directory = directory
        self.packagedDirectory = packagedDirectory
        self.writeBytes = writeBytes
        self.renameExclusive = renameExclusive
        self.canReadStamp = canReadStamp
        self.packaged = Dictionary(
            Mode.decodeAll(in: packagedDirectory).map { ($0.stem.lowercased(), $0.mode) },
            uniquingKeysWith: { first, _ in first })
        load()
        restoreParked()
        openPending()
    }

    static func requestOpen(_ name: String) {
        pendingOpen = name
    }

    /// Opens the requested mode, by name, once. A parked draft wins; a
    /// request for a mode that no longer exists lapses.
    private func openPending() {
        guard let name = Self.pendingOpen else {
            return
        }
        Self.pendingOpen = nil
        guard selectedID == nil, let mode = modes.first(where: { $0.name == name }) else {
            return
        }
        select(mode.id)
    }

    var hasSelection: Bool { selectedID != nil }

    /// The open mode's saved name ("Work"), which titles its editor and
    /// alerts while the draft's name is edited.
    var selectedName: String? {
        modes.first { $0.id == selectedID }?.name
    }

    /// What the update hold, its caption and log, and the Save prompts
    /// call the open mode's unsaved edits. A saved mode goes by its saved
    /// name ("Work", not a half-typed "Wor"); a new or duplicated one by
    /// the name it's being given ("Client"), its row's name ("Work Copy")
    /// while that's blank.
    fileprivate var unsavedName: String {
        if selectedStem != nil, let selectedName {
            return selectedName
        }
        return draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            ? selectedName ?? Self.newModeName : draft.name
    }

    private static let newModeName = "New Mode"

    /// The open mode ships with Velora, so the editor offers Reset to
    /// Default in place of Delete (the engine reinstalls a deleted one)
    /// and keeps its name.
    var resetsToDefault: Bool {
        guard let stem = selectedStem else {
            return false
        }
        return packaged[stem.lowercased()] != nil || Self.shippedStems.contains(stem.lowercased())
    }

    /// Reset has a packaged file to restore and something to undo.
    var canReset: Bool {
        resetTarget != nil && !isAtDefault
    }

    /// The open mode, draft included, already matches what Reset writes.
    var isAtDefault: Bool {
        guard let target = resetTarget, let selectedID,
              let stored = modes.first(where: { $0.id == selectedID })
        else {
            return false
        }
        return !isDirty && Self.sameContent(stored, target)
    }

    /// Reset's help: what it puts back, or why it's off.
    var resetHelp: String {
        if canReset {
            return "Put back Velora's formatting, instructions, apps, vocabulary and replacements"
        }
        if packagedMode == nil {
            return "Velora's copy of this mode can't be found, so it can't be reset"
        }
        return "This mode matches Velora's default"
    }

    /// One line per packaged app Reset leaves with the mode that took it
    /// since, for the confirm alert: "Cursor stays in Work."
    var resetNotes: [String] {
        (packagedMode?.apps ?? []).compactMap { app in
            keeper(of: app).map { "\(Self.applicationTitle(app)) stays in \($0)." }
        }
    }

    /// What Reset writes: the packaged mode without the apps another mode
    /// has claimed since, so each app keeps one owner.
    private var resetTarget: Mode? {
        guard var stock = packagedMode else {
            return nil
        }
        stock.apps = stock.apps.filter { keeper(of: $0) == nil }
        return stock
    }

    /// The saved mode, other than the open one, that has `bundleID`. An
    /// unsaved new mode claims nothing yet.
    private func keeper(of bundleID: String) -> String? {
        Mode.firstAssignmentConflict(
            applications: [bundleID],
            modes: modes.filter { !unsavedIDs.contains($0.id) },
            excluding: selectedID)?.modeName
    }

    private var packagedMode: Mode? {
        selectedStem.flatMap { packaged[$0.lowercased()] }
    }

    /// The open mode's file stem, once it's on disk (or the engine is
    /// about to install it): the file it was read from, not its name's.
    private var selectedStem: String? {
        guard let selectedID, !unsavedIDs.contains(selectedID) else {
            return nil
        }
        return modes.first { $0.id == selectedID }?.stem
    }

    /// The draft differs from the saved mode, or the mode was never saved.
    /// App lists and vocabulary compare as the editor leaves them on
    /// appear, so opening a hand-edited mode isn't an edit.
    var isDirty: Bool {
        guard let selectedID else {
            return false
        }
        if unsavedIDs.contains(selectedID) {
            return true
        }
        guard let stored = modes.first(where: { $0.id == selectedID }) else {
            return false
        }
        return Self.comparable(draft) != Self.comparable(stored)
    }

    /// A mode Velora ships resets instead of deleting.
    var canDelete: Bool {
        selectedID != nil && !resetsToDefault
    }

    private static func comparable(_ mode: Mode) -> Mode {
        var copy = mode
        copy.apps = Mode.normalizedApplicationIDs(mode.apps)
        // The vocabulary field's round trip (`syncListBuffers`, then
        // `parseList`): [" Kubernetes ", ""] → ["Kubernetes"].
        copy.vocabulary = Mode.parseList(mode.vocabulary.joined(separator: ", "))
        return copy
    }

    /// Two modes hold the same settings. Replacement pairs compare by text,
    /// since their IDs are minted per load.
    private static func sameContent(_ lhs: Mode, _ rhs: Mode) -> Bool {
        lhs.name == rhs.name
            && lhs.prompt == rhs.prompt
            && lhs.formatting == rhs.formatting
            && Mode.normalizedApplicationIDs(lhs.apps) == Mode.normalizedApplicationIDs(rhs.apps)
            && lhs.vocabulary == rhs.vocabulary
            && lhs.replacements.map { [$0.key, $0.value] } == rhs.replacements.map { [$0.key, $0.value] }
    }

    /// List order: Default first, since every app without a mode uses it,
    /// then A to Z (modes that share a name by file).
    private static func listOrder(_ lhs: Mode, _ rhs: Mode) -> Bool {
        let lhsIsDefault = lhs.name.caseInsensitiveCompare(Mode.defaultName) == .orderedSame
        let rhsIsDefault = rhs.name.caseInsensitiveCompare(Mode.defaultName) == .orderedSame
        if lhsIsDefault != rhsIsDefault {
            return lhsIsDefault
        }
        return Mode.byName(lhs, rhs)
    }

    // MARK: - Guarded navigation

    /// Selects `id`, or holds the change while the draft is dirty.
    func requestSelect(_ id: String?) {
        guard id != selectedID else {
            return
        }
        guard !isDirty else {
            pendingChange = .select(id)
            return
        }
        select(id)
    }

    /// Adds a mode, or holds the change while the draft is dirty.
    func requestNewMode() {
        guard !isDirty else {
            pendingChange = .newMode
            return
        }
        newMode()
    }

    /// Copies the open mode, or holds the copy while the draft is dirty:
    /// Save copies the saved edit, Don't Save the stored mode.
    func requestDuplicate() {
        guard !isDirty else {
            pendingChange = .duplicate
            return
        }
        duplicate()
    }

    /// Saves the draft, then makes the held change. A blocked save keeps
    /// the draft and drops the change; its alert says why.
    func saveAndContinue() {
        guard let change = pendingChange else {
            return
        }
        pendingChange = nil
        save()
        guard saveError == nil else {
            return
        }
        apply(change)
    }

    /// Drops the draft (and an unsaved new mode), then makes the held change.
    func discardAndContinue() {
        guard let change = pendingChange else {
            return
        }
        pendingChange = nil
        discardDraft()
        apply(change)
    }

    func cancelPending() {
        pendingChange = nil
        pendingLeave = nil
    }

    /// Asked before any pane switch (`MainWindowSelection.request`). A
    /// clean draft lets the switch happen now (true); a dirty one holds it
    /// and asks, and `leave` runs after Save or Don't Save.
    func requestLeave(_ leave: @escaping () -> Void) -> Bool {
        guard isDirty else {
            return true
        }
        pendingLeave = leave
        pendingChange = .leave
        return false
    }

    private func apply(_ change: PendingChange) {
        switch change {
        case .select(let id):
            select(id)
        case .newMode:
            newMode()
        case .duplicate:
            duplicate()
        case .leave:
            let leave = pendingLeave
            pendingLeave = nil
            leave?()
        }
    }

    /// Drops the draft. An unsaved new mode goes with it, back to the list;
    /// a saved one is read from its file again, so a Save refused over
    /// another app's change works on that version next.
    private func discardDraft() {
        guard let selectedID else {
            return
        }
        if unsavedIDs.contains(selectedID) {
            unsavedIDs.remove(selectedID)
            modes.removeAll { $0.id == selectedID }
            select(nil)
            return
        }
        guard let stem = selectedStem else {
            select(selectedID)
            return
        }
        select(reloadRow(stem: stem))
    }

    /// Settles unsaved mode edits before Velora quits: the open pane's
    /// draft, else one parked when the pane closed. `ask` gets the mode's
    /// name and answers Save / Don't Save / Cancel.
    ///
    ///     open draft ──┐                  ┌ Save ─────── .quit, or .failed
    ///                  ├─ dirty? ask(name)┼ Don't Save ─ .quit
    ///     parked ──────┘  clean: .quit    └ Cancel ───── .stay (still parked)
    static func settleBeforeQuit(open: ModesViewModel?, ask: (String) -> QuitAnswer) -> QuitCheck {
        if let open {
            return open.settle(ask)
        }
        guard let parked = Self.parked else {
            return .quit
        }

        // A model on the parked folder takes the draft back as it loads.
        let model = ModesViewModel(
            supervisor: nil, directory: parked.directory,
            packagedDirectory: parked.packagedDirectory)
        let check = model.settle(ask)
        if check != .quit {
            model.park()
        }
        return check
    }

    private func settle(_ ask: (String) -> QuitAnswer) -> QuitCheck {
        guard isDirty else {
            return .quit
        }
        switch ask(unsavedName) {
        case .cancel:
            return .stay
        case .dontSave:
            discardDraft()
            return .quit
        case .save:
            save()
            guard let error = saveError else {
                return .quit
            }
            // The quit alert reports it, so the editor's alert doesn't too.
            saveError = nil
            return .failed(error)
        }
    }

    /// Keeps a dirty draft for the next visit (called as the pane closes).
    func park() {
        guard isDirty else {
            Self.parked = nil
            return
        }
        Self.parked = ParkedDraft(
            directory: directory, packagedDirectory: packagedDirectory,
            selectedID: selectedID, name: unsavedName, draft: draft,
            unsaved: modes.filter { unsavedIDs.contains($0.id) },
            stamp: selectedStem.flatMap { stamps[$0] })
    }

    private func restoreParked() {
        guard let parked = Self.parked else {
            return
        }
        Self.parked = nil
        guard parked.directory == directory else {
            return
        }

        for mode in parked.unsaved where !modes.contains(where: { $0.id == mode.id }) {
            modes.append(mode)
            unsavedIDs.insert(mode.id)
        }
        modes.sort(by: Self.listOrder)
        guard let id = parked.selectedID else {
            return
        }
        guard modes.contains(where: { $0.id == id }) else {
            restoreOrphan(parked)
            return
        }
        selectedID = id
        draft = parked.draft
        // Save checks the draft against the file it came from: one replaced
        // while the pane was closed is refused, not overwritten.
        if let stem = selectedStem {
            stamps[stem] = parked.stamp
        }
    }

    /// A parked draft whose file went while the pane was closed (deleted,
    /// or no longer a mode Velora can read) comes back as a new, unsaved
    /// mode with its edits, so it still holds Quit and the update. The row
    /// keeps the name Quit asked about ("B"); the draft keeps its fields.
    private func restoreOrphan(_ parked: ParkedDraft) {
        var orphan = parked.draft
        orphan.stem = nil
        orphan.isProtected = false
        orphan.unsavedID = Self.unsavedRowID()
        var row = orphan
        row.name = parked.name
        modes.append(row)
        unsavedIDs.insert(row.id)
        modes.sort(by: Self.listOrder)
        selectedID = row.id
        draft = orphan
    }

    // MARK: - Loading

    /// Reads every `*.json` from the modes directory, then folds in each
    /// packaged mode that has no file yet. The pane opens on the list (no
    /// selection); a mode that vanished closes its editor.
    func load() {
        removeStaleTemps()
        let loaded = Mode.loadStamped(from: directory, packaged: packagedDirectory)
        modes = loaded.modes.sorted(by: Self.listOrder)
        stamps = loaded.stamps

        if !modes.contains(where: { $0.id == selectedID }) {
            selectedID = nil
        }
    }

    func select(_ id: String?) {
        // A saved mode left with nothing unsaved is read from its file
        // again, so a Delete or Reset refused over another app's change
        // works once you go back to All Modes.
        if selectedID != id, !isDirty, let stem = selectedStem {
            reloadRow(stem: stem)
        }
        selectedID = id
        if let id, let mode = modes.first(where: { $0.id == id }) {
            draft = mode
        }
    }

    // MARK: - Mutations

    func newMode() {
        let name = uniqueName(Self.newModeName)
        var mode = Mode(name: name, prompt: "", formatting: "light",
                        apps: [], vocabulary: [], replacements: [])
        mode.unsavedID = Self.unsavedRowID()
        modes.append(mode)
        unsavedIDs.insert(mode.id)
        modes.sort(by: Self.listOrder)
        select(mode.id)
    }

    /// Copies how the open mode writes (formatting, instructions,
    /// vocabulary, replacements) into a new unsaved mode. The apps stay
    /// with the original: each app activates one mode, so a copy that kept
    /// them could never be saved.
    func duplicate() {
        guard hasSelection else { return }
        var copy = draft
        copy.name = uniqueName("\(draft.name) Copy")
        copy.isProtected = false
        copy.stem = nil
        copy.unsavedID = Self.unsavedRowID()
        copy.apps = []
        modes.append(copy)
        unsavedIDs.insert(copy.id)
        modes.sort(by: Self.listOrder)
        select(copy.id)
    }

    /// Removes the selected mode's file and list entry, then returns to the
    /// list. Modes Velora ships and Default are refused: the engine would
    /// reinstall them, so they offer Reset to Default instead.
    /// Goes by the selected ID, its file: another file may hold the same
    /// name, and the draft's name may already be edited to another mode's.
    /// The list and the engine change only once the file is gone; a file
    /// another app already deleted is a finished Delete.
    func delete() {
        guard canDelete, let id = selectedID else { return }
        if let stem = selectedStem {
            if let refusal = removeModeFile(stem: stem) {
                saveErrorTitle = Self.deleteFailedTitle
                saveError = refusal
                return
            }
            stamps[stem] = nil
        }
        modes.removeAll { $0.id == id }
        unsavedIDs.remove(id)
        reloadEngine()
        select(nil)
    }

    /// Removes the file for `stem`, if it's still the one the list read.
    /// Only a file the folder shows missing counts as removed; a folder
    /// Velora can't list refuses. nil once it's gone, else why not.
    private func removeModeFile(stem: String) -> String? {
        let name = selectedName ?? stem
        switch fileInFolder(stem: stem) {
        case .missing:
            return nil
        case .lookupError(let error):
            return "Couldn't delete “\(name)”. \(error.localizedDescription)"
        case .found:
            break
        }

        // Only the file the list read goes, as with Save and Reset.
        if let changed = changedOnDisk(stem: stem) {
            return changed
        }
        do {
            try FileManager.default.removeItem(at: fileURL(stem: stem))
        } catch {
            // Gone anyway (another app removed it meanwhile): done.
            guard case .missing = fileInFolder(stem: stem) else {
                return "Couldn't delete “\(name)”. \(error.localizedDescription)"
            }
        }
        return nil
    }

    /// Writes the mode Velora ships over the open one, dropping the user's
    /// edits but leaving each app another mode took since where it is
    /// (`resetNotes`), and keeps its editor open on the restored mode.
    func resetToDefault() {
        guard let name = selectedName, let stem = selectedStem, let target = resetTarget else {
            return
        }
        if let changed = changedOnDisk(stem: stem) {
            saveErrorTitle = Self.resetFailedTitle
            saveError = changed
            return
        }
        do {
            try writeFile(target, to: fileURL(stem: stem), existing: stamps[stem] != nil ? .replace : .refuse)
        } catch {
            saveErrorTitle = Self.resetFailedTitle
            saveError = "Couldn't reset “\(name)”. \(error.localizedDescription)"
            return
        }
        load()
        select(modes.first { $0.stem == stem }?.id)
        reloadEngine()
    }

    /// Writes the draft to its file and reloads the engine; a rename
    /// writes the new file, then removes the old one. Refused before any
    /// write, with `saveError` saying why: a blank name, renaming a mode
    /// Velora ships, a name another mode has (in any case), a file another
    /// mode or a shipped mode uses, an app another mode has, a file already
    /// in the folder that isn't the mode's own, or a failed write.
    func save() {
        saveErrorTitle = Self.saveFailedTitle
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            saveError = "Give the mode a name."
            return
        }

        // A mode Velora ships keeps its name. A rename wrote a second file
        // while the engine reinstalled the shipped one on reload, and both
        // claimed the same apps. Duplicate makes your own version instead.
        if resetsToDefault, let savedName = selectedName, draft.name != savedName {
            saveError = "“\(savedName)” comes with Velora, so it keeps its name. Duplicate it to make your own version."
            return
        }

        // A mode keeps its file through a rename that file still fits: a
        // hand-edited a.json named "B" stays a.json as "B", "b" or "A". A
        // name its file doesn't fit gets a file of its own. Modes collide
        // by file as well as by name: “Email!” is email.json too.
        let stem: String
        if let current = selectedStem,
           selectedName?.caseInsensitiveCompare(draft.name) == .orderedSame
               || current.lowercased() == Self.slug(draft.name) {
            stem = current
        } else {
            stem = Self.slug(draft.name)
        }
        if let other = modes.first(where: {
            $0.id != selectedID
                && (($0.stem?.lowercased() ?? Self.slug($0.name)) == stem.lowercased()
                    || $0.name.caseInsensitiveCompare(draft.name) == .orderedSame)
        }) {
            saveError = "A mode named “\(other.name)” already exists. Choose a different name."
            // A hand-edited file can hold another name: b.json named "C".
            if Self.slug(other.name) != stem.lowercased(), other.name.caseInsensitiveCompare(draft.name) != .orderedSame {
                saveError = "“\(other.name)” is saved as \(stem).json, the file “\(draft.name)” would use. Choose a different name."
            }
            // A mode Velora ships can't change its name, so the other
            // file is what has to go: x.json also named "Email".
            if resetsToDefault, let otherStem = other.stem {
                saveError = "\(otherStem).json is another mode named “\(other.name)”. “\(draft.name)” comes with Velora and keeps its name, so delete \(otherStem).json, then save."
            }
            return
        }

        // A shipped mode's stem stays Velora's even without its file: the
        // engine would install its own file over this one.
        if Self.shippedStems.union(packaged.keys).contains(stem.lowercased()),
           selectedStem?.lowercased() != stem.lowercased() {
            saveError = "“\(draft.name)” is the name of a mode Velora comes with. Choose a different name."
            return
        }

        if let conflict = Mode.firstAssignmentConflict(
            applications: draft.apps, modes: modes, excluding: selectedID
        ) {
            saveError = "\(Self.applicationTitle(conflict.bundleID)) is already assigned to “\(conflict.modeName)”. Each app can activate only one mode."
            return
        }

        // Only the mode's own file is overwritten. The list can miss a
        // file in the folder (one that isn't valid JSON, one added since
        // it loaded, or D.json that a disk ignoring case opens as d.json),
        // so the folder is read again here, and any other target is
        // created fresh: a file that appears after this check fails the
        // write instead of being replaced.
        let ownsTarget = selectedStem?.lowercased() == stem.lowercased()
        if !ownsTarget {
            switch fileInFolder(stem: stem) {
            case .found(let existing):
                saveError = folderHas(existing, stem: stem)
                return
            case .lookupError(let error):
                saveError = "Couldn't save “\(draft.name)”. \(error.localizedDescription)"
                return
            case .missing:
                break
            }
        }

        // The mode's own file, which this save replaces or a rename
        // removes, must still be the one the list read. A change in the
        // microseconds between a check and the write goes unseen; that
        // window is accepted.
        if let current = selectedStem, let changed = changedOnDisk(stem: current) {
            saveError = changed
            return
        }

        AppConfig.shared.ensureVeloraDirectory()
        let target = fileURL(stem: stem)
        do {
            try writeFile(draft, to: target, existing: ownsTarget && stamps[stem] != nil ? .replace : .refuse)
        } catch CocoaError.fileWriteFileExists {
            // Another app made the file after the check above.
            var existing = "\(stem).json"
            if case .found(let name) = fileInFolder(stem: stem) {
                existing = name
            }
            saveError = folderHas(existing, stem: stem)
            return
        } catch {
            saveError = "Couldn't save “\(draft.name)”. \(error.localizedDescription)"
            return
        }
        let written = FileStamp(target)

        // A renamed mode's old file goes once the new one is written. If
        // it won't go, the new one goes instead and nothing changes: two
        // files would both claim the mode's apps. The new one is always
        // this save's own creation (`.refuse` above), never a file it
        // found.
        //
        //     create d.json ─▶ remove a.json ─ ok ─▶ commit
        //                          └─ fails ─▶ remove d.json, saveError
        if let oldStem = selectedStem, !ownsTarget {
            let old = fileURL(stem: oldStem)
            let stopped: String?
            if let changed = changedOnDisk(stem: oldStem) {
                // Checked again: it may have changed while the new file was written.
                stopped = changed
            } else {
                do {
                    if FileManager.default.fileExists(atPath: old.path) {
                        try FileManager.default.removeItem(at: old)
                    }
                    stopped = nil
                } catch {
                    stopped = "Couldn't rename “\(selectedName ?? oldStem)”: its file couldn't be removed. \(error.localizedDescription)"
                }
            }
            if let stopped {
                saveError = stopped
                if !removeCreated(target, as: written) {
                    saveError? += " A copy named “\(draft.name)” is left in the modes folder."
                }
                return
            }
            stamps[oldStem] = nil
        }
        saveError = nil
        stamps[stem] = written
        draft.stem = stem
        draft.unsavedID = nil

        if let index = modes.firstIndex(where: { $0.id == selectedID }) {
            modes[index] = draft
        } else {
            modes.append(draft)
        }
        modes.sort(by: Self.listOrder)
        if let selectedID {
            unsavedIDs.remove(selectedID)
        }
        selectedID = draft.id
        reloadEngine()
    }

    // MARK: - Persistence

    private func fileURL(stem: String) -> URL {
        directory.appendingPathComponent("\(stem).json")
    }

    /// What the modes folder holds for a stem, read from the disk now.
    private enum FolderLookup {
        /// The file, by its name on disk: "D.json" for "d".
        case found(String)
        /// No such file, or no folder yet.
        case missing
        /// The folder couldn't be listed, so nothing is known.
        case lookupError(Error)
    }

    /// The file in the modes folder that `stem` would write, read from the
    /// disk now and matched ignoring case, as the disk does: "D.json" for
    /// "d". A folder that can't be listed is a `.lookupError`, never empty.
    private func fileInFolder(stem: String) -> FolderLookup {
        let target = "\(stem).json".lowercased()
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            return .lookupError(error)
        }
        guard let name = names.first(where: { $0.lowercased() == target }) else {
            return .missing
        }
        return .found(name)
    }

    /// Why the file for `stem` can't be replaced or removed: it isn't the
    /// file the list read. A mode read from the folder compares its
    /// `FileStamp`. One the folder had no file for (Velora's, not yet
    /// installed) finds any file there now new, unless it's the copy of
    /// Velora's own that the engine installs on reload
    /// (`_ensure_builtin_modes`): that one is stamped as read. nil when
    /// the file is as read.
    ///
    ///     stamped ─── same stamp ──────────▶ nil
    ///             ├── can't stat, then the folder:
    ///             │     missing ───────────▶ unstamped, nil (Save creates it)
    ///             │     found ─────────────▶ "couldn't check", stamp kept
    ///             │     unlistable ────────▶ folderMessage, stamp kept
    ///             ├── unreadable ──────────▶ unreadableMessage
    ///             └── other ───────────────▶ changedMessage
    ///     unstamped ─ no file ─────────────▶ nil
    ///             ├── folder unlistable ───▶ folderMessage
    ///             ├── unreadable ──────────▶ unreadableMessage
    ///             ├── equals packaged[stem] ▶ stamped, nil
    ///             └── anything else ───────▶ changedMessage
    private func changedOnDisk(stem: String) -> String? {
        if let read = stamps[stem] {
            let url = fileURL(stem: stem)
            guard canReadStamp(url), let now = FileStamp(url) else {
                // A stat can fail with the file still there; only the
                // folder showing it missing makes it gone.
                switch fileInFolder(stem: stem) {
                case .missing:
                    // Nothing of anyone's to replace: the stamp goes, so
                    // Save creates the file afresh and exclusively (`.refuse`).
                    stamps[stem] = nil
                    return nil
                case .found(let name):
                    return "Velora couldn't check \(name) for changes. Try again."
                case .lookupError(let error):
                    return Self.folderMessage(error)
                }
            }
            if now == read {
                return nil
            }
            let file = "\(stem).json"
            return Mode.decode(url) == nil ? Self.unreadableMessage(file) : Self.changedMessage(file)
        }

        let file: String
        switch fileInFolder(stem: stem) {
        case .missing:
            return nil
        case .lookupError(let error):
            return Self.folderMessage(error)
        case .found(let name):
            file = name
        }

        // Stamped before the read, as `decodeAll` does, so a change after
        // it still shows.
        let url = directory.appendingPathComponent(file)
        let stamp = FileStamp(url)
        guard let found = Mode.decode(url) else {
            return Self.unreadableMessage(file)
        }
        if let stamp, let shipped = packaged[stem.lowercased()], Self.sameContent(found, shipped) {
            stamps[stem] = stamp
            return nil
        }
        return Self.changedMessage(file)
    }

    /// Every refusal over a file another app changed (Save, Reset,
    /// Delete, a rename's cleanup, a restored draft) says this. Going back
    /// to All Modes rereads the file (`reloadRow`); Don't Save drops an
    /// edit made on the old one.
    private static func changedMessage(_ file: String) -> String {
        "\(file) was changed by another app. To load that version, go back to All Modes and choose Don't Save if asked."
    }

    private static func folderMessage(_ error: Error) -> String {
        "Velora couldn't read the modes folder. \(error.localizedDescription)"
    }

    private static func unreadableMessage(_ file: String) -> String {
        "\(file) isn't a mode Velora can read. Fix or remove it, then save."
    }

    /// Save's refusal of a target that's already a file in the folder. A
    /// mode Velora ships can't take another name; its file is most likely
    /// the engine's own install, which the next Save takes as read.
    private func folderHas(_ existing: String, stem: String) -> String {
        let next = resetsToDefault ? "Try saving again." : "Choose a different name."
        return "“\(draft.name)” would be saved as \(stem).json, but the modes folder already has \(existing). \(next)"
    }

    /// Reads the mode at `stem` again as `load()` does, with its stamp, so
    /// its row is the file as it is now: another app's version, Velora's
    /// own once the file is gone, or no row. Returns the row's id, if any.
    ///
    ///     another app replaces a.json ─▶ Save refused
    ///     All Modes ─▶ Don't Save ─▶ reloadRow("a") ─▶ row + stamp = a.json now
    ///                                                  └─▶ next Save writes
    @discardableResult
    private func reloadRow(stem: String) -> String? {
        let loaded = Mode.loadStamped(from: directory, packaged: packagedDirectory)
        let fresh = loaded.modes.first { $0.stem == stem }
            ?? loaded.modes.first { $0.stem?.lowercased() == stem.lowercased() }
        modes.removeAll { $0.stem == stem }
        stamps[stem] = nil
        guard let fresh, let freshStem = fresh.stem else {
            return nil
        }

        modes.removeAll { $0.id == fresh.id }
        modes.append(fresh)
        modes.sort(by: Self.listOrder)
        stamps[freshStem] = loaded.stamps[freshStem]
        return fresh.id
    }

    /// Removes `url`, which this save created, unless it has changed since
    /// (`written`). A rollback never deletes a file it didn't make. True
    /// when the file is gone.
    private func removeCreated(_ url: URL, as written: FileStamp?) -> Bool {
        guard let written, FileStamp(url) == written else {
            return false
        }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// A fresh id for a row that isn't on disk yet.
    private static func unsavedRowID() -> String {
        "unsaved:" + UUID().uuidString
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

    /// An app's name for an alert: the installed app's, else a known one.
    private static func applicationTitle(_ bundleID: String) -> String {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return Mode.applicationName(
            for: bundleID, installedName: installed?.deletingPathExtension().lastPathComponent)
    }

    /// What `writeFile` does with a file already at its target.
    private enum ExistingFile {
        /// Replace it, atomically: it's the mode's own file.
        case replace
        /// Fail the write: the target must be a new file.
        case refuse
    }

    /// Writes a mode file's bytes to a new file at the URL.
    typealias ByteWriter = (Data, URL) throws -> Void

    /// Velora's writer: creates the file, and fails if one is already there.
    static let diskWriter: ByteWriter = { data, url in
        try data.write(to: url, options: .withoutOverwriting)
    }

    /// Renames a file onto a path that must be free: 0, or the errno.
    typealias ExclusiveRename = (URL, URL) -> Int32

    /// Velora's exclusive rename: EEXIST when the target is taken.
    static let diskRenameExcl: ExclusiveRename = { from, to in
        renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }

    /// Temp files `writeFile` writes: `.velora-<UUID>.partial`, one length
    /// whatever the mode's name, and never *.json, so neither the engine
    /// nor `decodeAll` reads one.
    private static let tempPrefix = ".velora-"
    private static let tempSuffix = ".partial"
    /// A temp file this old was left by a save that crashed; a younger one
    /// may be another Velora's save still running.
    private static let staleTempAge: TimeInterval = 60 * 60

    /// Removes the temp files a crashed save left in the modes folder:
    /// regular files named exactly `.velora-<UUID>.partial`, an hour old.
    /// A look-alike name, a directory or a symlink is someone else's.
    private func removeStaleTemps() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-Self.staleTempAge).timeIntervalSince1970
        for name in names where Self.isTempName(name) {
            // lstat: the entry itself, never what a symlink points to.
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  TimeInterval(info.st_mtimespec.tv_sec) < cutoff
            else {
                continue
            }
            // unlink never removes a directory, even one swapped in since.
            unlink(path)
        }
    }

    /// `.velora-<UUID>.partial`, with a UUID that parses.
    private static func isTempName(_ name: String) -> Bool {
        guard name.hasPrefix(tempPrefix), name.hasSuffix(tempSuffix) else {
            return false
        }
        let middle = name.dropFirst(tempPrefix.count).dropLast(tempSuffix.count)
        return UUID(uuidString: String(middle)) != nil
    }

    /// Writes `mode` to a temp file beside `url`, then renames it into
    /// place, so `url` is never half written and a failure never touches
    /// it.
    ///
    ///     write .velora-<UUID>.partial ─▶ onto work.json
    ///                  │                    .replace: rename over the file
    ///                  │                    .refuse: `installExclusive`, EEXIST if taken
    ///                  └─── any failure ──▶ remove the temp file only
    private func writeFile(_ mode: Mode, to url: URL, existing: ExistingFile) throws {
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
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString)\(Self.tempSuffix)")
        do {
            try writeBytes(data, temp)
            if existing == .replace {
                guard rename(temp.path, url.path) == 0 else {
                    throw Self.renameError(errno, url)
                }
            } else {
                try installExclusive(temp, at: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Moves `temp` onto `url`, failing with EEXIST if `url` is taken. A
    /// volume without RENAME_EXCL (ENOTSUP, EINVAL) gets a hard link, which
    /// fails the same way, then the temp name goes.
    private func installExclusive(_ temp: URL, at url: URL) throws {
        let code = renameExclusive(temp, url)
        if code == 0 {
            return
        }
        guard code == ENOTSUP || code == EINVAL else {
            throw Self.renameError(code, url)
        }
        guard link(temp.path, url.path) == 0 else {
            throw Self.renameError(errno, url)
        }
        unlink(temp.path)
    }

    /// A failed rename or link onto `url` as Foundation reports a failed write:
    /// EEXIST is `.fileWriteFileExists`, which Save turns into its
    /// "already has" refusal.
    private static func renameError(_ code: Int32, _ url: URL) -> CocoaError {
        let posix = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        let userInfo: [String: Any] = [NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: posix]
        return CocoaError(code == EEXIST ? .fileWriteFileExists : .fileWriteUnknown, userInfo: userInfo)
    }

    private func reloadEngine() {
        ModeApplicationIndex.shared.reload()
        supervisor?.send(["cmd": "reload_config"])
    }

    /// `base`, numbered past any mode whose file stem it would share.
    private func uniqueName(_ base: String) -> String {
        var name = base
        var n = 2
        let existing = Set(modes.flatMap { [$0.stem?.lowercased(), Self.slug($0.name)].compactMap { $0 } })
        while existing.contains(Self.slug(name)) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }
}

// MARK: - View

/// The Modes pane: every mode as a row in one card, opening a mode's
/// editor in place, the way Meetings opens a meeting's notes. Both pages
/// draw the shared `PaneHeader` and stack `GroupCard`s in one scroller.
///
///     Modes                                         [+ New Mode]
///     ┌──────────────────────────────────────────────────────┐
///     │ </>  Code        Light formatting · 4 apps         › │
///     │ ☆    Default     Light formatting · No apps     🔒 › │
///     └──────────────────────────────────────────────────────┘
///                          click a row ▼
///     [‹] Code         [Duplicate] [Reset to Default…] [Save]
///     Name · Formatting / Instructions / Automatic activation
///     / Vocabulary / Replacements cards
///
/// Leaving a mode with unsaved edits (‹, ⌘[, Duplicate, any pane switch)
/// asks Save / Don't Save / Cancel first; Quit asks the same.
struct ModesSettingsView: View {
    @StateObject private var vm: ModesViewModel
    private let selection: MainWindowSelection
    /// The mode whose editor just closed, for the list to focus as it
    /// comes back. Here, not in the list, since the list is rebuilt.
    @State private var returnFocusID: String?
    /// Test seam: each list row's window frame (`.global`) as it moves, so
    /// Selftest sees what scrolled into view without the accessibility tree.
    private let rowFrames: ((String, CGRect) -> Void)?

    init(
        supervisor: EngineSupervisor?, selection: MainWindowSelection,
        directory: URL = AppConfig.modesDirectory,
        rowFrames: ((String, CGRect) -> Void)? = nil
    ) {
        _vm = StateObject(wrappedValue: ModesViewModel(supervisor: supervisor, directory: directory))
        self.selection = selection
        self.rowFrames = rowFrames
    }

    var body: some View {
        Group {
            if vm.hasSelection {
                ModeEditor(vm: vm)
            } else {
                ModeList(vm: vm, returnFocus: $returnFocusID, rowFrames: rowFrames)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: vm.selectedID) { closed, opened in
            if opened == nil {
                returnFocusID = closed
            }
        }
        .confirmationDialog(
            "Save changes to “\(vm.unsavedName)”?",
            isPresented: Binding(get: { vm.pendingChange != nil },
                                 set: { if !$0 { vm.cancelPending() } })
        ) {
            Button("Save") { vm.saveAndContinue() }
            Button("Don't Save", role: .destructive) { vm.discardAndContinue() }
            Button("Cancel", role: .cancel) { vm.cancelPending() }
        } message: {
            Text("Your edits to this mode aren't saved yet.")
        }
        // Every pane switch asks the model first; a dirty draft holds it
        // until the dialog above is answered.
        .onAppear {
            selection.openModes = vm
        }
        // Leaving the pane rebuilds the model. A draft still dirty (the
        // window closed) is parked for the next visit, and Quit asks.
        .onDisappear {
            if selection.openModes === vm {
                selection.openModes = nil
            }
            vm.park()
        }
    }
}

/// Geometry the list and the editor share, matched to Home's cards.
private enum ModesMetrics {
    /// Body spacing between cards, as on Home and Stats.
    static let sectionSpacing: CGFloat = 18
    /// Leading and trailing inset of a row inside a `GroupCard` (`GroupRow`'s).
    static let rowInset: CGFloat = 14
    /// A `GroupRow`'s minimum height, for rows drawn without one.
    static let rowMinHeight: CGFloat = 42
    /// Width of the leading symbol well on a row.
    static let iconWell: CGFloat = 22
    /// Dictionary's keyboard focus mark: tint, edge, and inset from the card.
    static let focusTint: Double = 0.14
    static let focusStroke: CGFloat = 2
    static let focusInset: CGFloat = 4
}

/// Reports a list row's window frame to the `rowFrames` test seam. With
/// no seam (the app) the row carries no geometry observer at all.
private struct RowFrameReport: ViewModifier {
    let id: String
    let report: ((String, CGRect) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let report {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                report(id, frame)
            }
        } else {
            content
        }
    }
}

// MARK: - Mode list

/// Every mode as a `GroupRow` with its symbol, a formatting and app-count
/// sub-caption, and a disclosure chevron. Monochrome glyphs, so the list
/// reads as one calm column instead of a hue lottery.
///
/// Rows are not Buttons, so the card is one Tab stop the arrows move
/// within, as in Dictionary and Meetings (`MeetingListKeys`): ↑ ↓ move,
/// Return or Space opens, and Tab comes back to the last focused row.
/// The focused row scrolls into view, and Back focuses the mode it closed.
private struct ModeList: View {
    @ObservedObject var vm: ModesViewModel
    /// The mode to focus as the list appears (the one just closed), read
    /// once and cleared.
    @Binding var returnFocus: String?
    /// Test seam: see `ModesSettingsView.rowFrames`.
    let rowFrames: ((String, CGRect) -> Void)?
    @FocusState private var focusedID: String?
    /// The last row that had focus, which Tab returns to.
    @State private var lastFocusedID: String?

    var body: some View {
        let ids = vm.modes.map(\.id)
        let tabStop = MeetingListKeys.tabStop(lastFocusedID, in: ids)
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: MainPane.modes.title) {
                Button {
                    vm.requestNewMode()
                } label: {
                    Label("New Mode", systemImage: "plus")
                }
                .buttonStyle(.primaryCapsule)
                .keyboardShortcut("n", modifiers: .command)
                .help("Add a mode")
            }
            .padding(.bottom, VeloraSpacing.m)

            ScrollViewReader { proxy in
                ScrollView {
                    card(ids: ids, tabStop: tabStop)
                        .padding(.bottom, VeloraSpacing.xl)
                }
                // Keep the focused row on screen as Tab and the arrows
                // move, and remember it as the list's Tab stop.
                .onChange(of: focusedID) { _, id in
                    guard let id else {
                        return
                    }
                    lastFocusedID = id
                    proxy.scrollTo(id)
                }
            }
        }
        .onAppear { focusReturningRow(ids: ids) }
    }

    private func card(ids: [String], tabStop: String?) -> some View {
        GroupCard(footer: "A mode tells Velora how to clean up your dictation. It activates automatically in the apps assigned to it.") {
            // The ForEach ID is each row's scroll ID. The divider sits in the
            // row's stack: as a sibling it was what `scrollTo` revealed,
            // leaving the row itself just out of view (as in Meetings).
            ForEach(vm.modes) { mode in
                VStack(alignment: .leading, spacing: 0) {
                    if mode.id != vm.modes.first?.id {
                        GroupDivider()
                    }
                    row(mode)
                        .background(focusMark(mode.id == focusedID))
                        .onTapGesture { vm.requestSelect(mode.id) }
                        // Only the Tab stop row is focusable, so Tab lands
                        // on one row and the arrows walk the rest.
                        .focusable(mode.id == tabStop, interactions: .edit)
                        .focused($focusedID, equals: mode.id)
                        .focusEffectDisabled()
                        .onKeyPress(keys: MeetingListKeys.keys) { press in
                            handle(press.key, on: mode.id, ids: ids)
                        }
                        // Each row still reads and acts as one button.
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Opens this mode")
                        .accessibilityAction { vm.requestSelect(mode.id) }
                        .modifier(RowFrameReport(id: mode.id, report: rowFrames))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Modes")
    }

    /// Back from a mode, focus lands on its row. The row becomes the Tab
    /// stop first, so it is focusable when focus arrives.
    private func focusReturningRow(ids: [String]) {
        guard let id = returnFocus else {
            return
        }
        returnFocus = nil
        guard ids.contains(id) else {
            return
        }
        lastFocusedID = id
        focusedID = id
    }

    private func handle(_ key: KeyEquivalent, on id: String, ids: [String]) -> KeyPress.Result {
        guard let command = MeetingListKeys.command(for: key, on: id, in: ids) else {
            return .ignored
        }
        switch command {
        case .focus(let next):
            // Move the Tab stop first so the row is focusable when focus lands.
            lastFocusedID = next
            focusedID = next
        case .open(let open):
            vm.requestSelect(open)
        }
        return .handled
    }

    /// Keyboard focus: an accent tint with a 2 pt accent edge, which gives
    /// the 3:1 contrast a focus indicator needs.
    @ViewBuilder private func focusMark(_ focused: Bool) -> some View {
        if focused {
            let shape = RoundedRectangle(cornerRadius: VeloraRadius.row, style: .continuous)
            shape
                .fill(VeloraBrand.accent.opacity(ModesMetrics.focusTint))
                .overlay(shape.strokeBorder(VeloraBrand.accent, lineWidth: ModesMetrics.focusStroke))
                .padding(.horizontal, ModesMetrics.focusInset)
        }
    }

    private func row(_ mode: Mode) -> some View {
        HStack(spacing: VeloraSpacing.m) {
            Image(systemName: mode.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: ModesMetrics.iconWell)
                .accessibilityHidden(true)
            GroupRow(label: mode.name, sub: mode.listSummary) {
                if mode.isProtected {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Built-in mode")
                        .accessibilityLabel("Built-in")
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            // The symbol takes the row's leading inset.
            .padding(.leading, -ModesMetrics.rowInset)
        }
        .padding(.leading, ModesMetrics.rowInset)
        .contentShape(Rectangle())
    }
}

// MARK: - Mode editor

/// One assigned bundle ID and where it's installed, if anywhere. Looked
/// up once per render, then shared by the row and the installed split.
private struct AssignedApp: Identifiable {
    let bundleID: String
    let url: URL?

    var id: String { bundleID }
}

private struct ModeEditor: View {
    @ObservedObject var vm: ModesViewModel
    /// Local text buffer for the comma-separated vocabulary. Binding the
    /// field straight to the parsed array re-joins it on every keystroke,
    /// which eats the ", " you just typed before the next item can exist.
    @State private var vocabularyText = ""
    /// Bundle IDs typed into Add by Bundle ID, cleared once they're added.
    @State private var bundleIDText = ""
    @State private var showsMissingApps = false
    @State private var showsBundleIDField = false
    @State private var applicationPickerError: String?
    @State private var confirmsDelete = false
    @State private var confirmsReset = false

    /// The Name field grows to this width, then the row's label keeps the rest.
    private static let nameFieldWidth: CGFloat = 260
    /// The instructions well: about seven lines before it scrolls.
    private static let promptHeight: CGFloat = 140
    /// An assigned app's icon; full-colour icons need a little more than
    /// the 22 pt symbol well to read.
    private static let appIconSide: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back, then the open mode's saved name, then its actions: one
            // row, as Meetings draws a meeting.
            HStack(spacing: VeloraSpacing.s) {
                Button {
                    vm.requestSelect(nil)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.capsule)
                .keyboardShortcut("[", modifiers: .command)
                .help("All Modes (⌘[)")
                .accessibilityLabel("All Modes")
                PaneHeader(title: vm.unsavedName) {
                    headerControls
                }
            }
            .padding(.bottom, VeloraSpacing.m)

            ScrollView {
                VStack(alignment: .leading, spacing: ModesMetrics.sectionSpacing) {
                    generalCard
                    instructionsCard
                    activationCard
                    vocabularyCard
                    replacementsCard
                }
                .padding(.bottom, VeloraSpacing.xl)
            }
        }
        .onAppear { syncListBuffers() }
        .onChange(of: vm.selectedID) { _, _ in syncListBuffers() }
        .alert(
            vm.saveErrorTitle,
            isPresented: Binding(get: { vm.saveError != nil },
                                 set: { if !$0 { vm.saveError = nil } })
        ) {
            Button("OK", role: .cancel) { vm.saveError = nil }
        } message: {
            Text(vm.saveError ?? "")
        }
        .alert(
            "Can't add application",
            isPresented: Binding(get: { applicationPickerError != nil },
                                 set: { if !$0 { applicationPickerError = nil } })
        ) {
            Button("OK", role: .cancel) { applicationPickerError = nil }
        } message: {
            Text(applicationPickerError ?? "")
        }
        .alert("Delete “\(vm.unsavedName)”?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { vm.delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the mode and its app assignments.")
        }
        .alert("Reset “\(vm.selectedName ?? vm.draft.name)” to its default?", isPresented: $confirmsReset) {
            Button("Reset", role: .destructive) {
                vm.resetToDefault()
                syncListBuffers()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Apps another mode took since stay there: "Cursor stays in Work."
            Text((["Its formatting, instructions, apps, vocabulary and replacements go back to Velora's defaults."]
                  + vm.resetNotes).joined(separator: " "))
        }
    }

    // MARK: Header

    /// Duplicate and Delete (or Reset, for a mode Velora ships) as glass
    /// capsules, Save as the pane's one primary, in the title row like
    /// every other pane's controls. Save waits for an edit.
    @ViewBuilder
    private var headerControls: some View {
        Button {
            vm.requestDuplicate()
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        .buttonStyle(.capsule)
        .help("Make an editable copy of this mode")

        if vm.resetsToDefault {
            Button(role: .destructive) {
                confirmsReset = true
            } label: {
                Label("Reset to Default…", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.capsule)
            .disabled(!vm.canReset)
            .help(vm.resetHelp)
        } else {
            Button(role: .destructive) {
                confirmsDelete = true
            } label: {
                Label("Delete…", systemImage: "trash")
            }
            .buttonStyle(.capsule)
            .disabled(!vm.canDelete)
            .help("Delete this mode")
        }

        Button("Save") {
            vm.save()
            // Show the normalized vocabulary ("a,,b " → "a, b") after a save.
            syncListBuffers()
        }
        .buttonStyle(.primaryCapsule)
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!vm.isDirty)
    }

    // MARK: Cards

    /// Name and formatting strength. A mode Velora ships keeps its name,
    /// shown as a read-only value; Duplicate makes an editable copy.
    private var generalCard: some View {
        GroupCard {
            GroupRow(
                label: "Name",
                sub: vm.resetsToDefault ? "Built-in. Duplicate it to make your own version." : nil
            ) {
                if vm.resetsToDefault {
                    Text(vm.draft.name)
                        .foregroundStyle(.secondary)
                } else {
                    // System Settings' inline field: plain text that edits
                    // in place, trailing-aligned with the segmented control.
                    TextField("Name", text: $vm.draft.name)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: Self.nameFieldWidth)
                }
            }
            GroupDivider()
            GroupRow(label: "Formatting strength") {
                Picker("Formatting strength", selection: $vm.draft.formatting) {
                    ForEach(Mode.formattingOptions, id: \.self) { option in
                        Text(option.capitalized).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// A visibly editable text area: borderless read as a caption, and the
    /// owner read the whole pane as unclear. The well is concentric with
    /// the card (12 pt card − 4 pt padding = 8 pt tile).
    private var instructionsCard: some View {
        GroupCard(
            header: "Instructions",
            footer: "How Velora rewrites text in this mode."
        ) {
            TextEditor(text: $vm.draft.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(VeloraSpacing.xs)
                .frame(height: Self.promptHeight)
                .background(
                    RoundedRectangle(cornerRadius: VeloraRadius.tile, style: .continuous)
                        .fill(VeloraPanel.card))
                .overlay(
                    RoundedRectangle(cornerRadius: VeloraRadius.tile, style: .continuous)
                        .strokeBorder(VeloraPanel.hairline))
                .padding(VeloraSpacing.xs)
                .accessibilityLabel("Instructions")
        }
    }

    /// Assigned apps by name: installed ones with their icons, then one
    /// row that folds away the apps not on this Mac. The picker sits in the
    /// header; adding by bundle ID hides behind the last row.
    ///
    ///     Automatic activation                 Choose Applications…
    ///     [icon] Cursor                                          ⊖
    ///     [ ⋯ ]  11 apps not on this Mac                         ›
    ///     [ ⌘ ]  Add by Bundle ID                                ›
    private var activationCard: some View {
        let assigned = vm.draft.apps.map { bundleID in
            AssignedApp(
                bundleID: bundleID,
                url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID))
        }
        let installed = assigned.filter { $0.url != nil }
        let missing = assigned.filter { $0.url == nil }
        return GroupCard(
            header: "Automatic activation",
            headerLink: ("Choose Applications…", { chooseApplications() }),
            footer: "A browser assigned here uses this mode on every site, instead of each site's own mode."
        ) {
            if assigned.isEmpty {
                placeholderRow("No apps assigned", symbol: "app.dashed")
                GroupDivider()
            }
            ForEach(installed) { app in
                applicationRow(app)
                GroupDivider()
            }
            if !missing.isEmpty {
                disclosureRow(
                    missing.count == 1 ? "1 app not on this Mac" : "\(missing.count) apps not on this Mac",
                    sub: "This mode applies once they're installed.",
                    symbol: "app.dashed", isExpanded: $showsMissingApps)
                if showsMissingApps {
                    ForEach(missing) { app in
                        GroupDivider()
                        applicationRow(app)
                    }
                }
                GroupDivider()
            }
            disclosureRow(
                "Add by Bundle ID", sub: nil,
                symbol: "plus.circle", isExpanded: $showsBundleIDField)
            if showsBundleIDField {
                bundleIDField
            }
        }
    }

    /// For apps the picker can't reach: one or more comma-separated bundle
    /// IDs, added on Return or Add.
    private var bundleIDField: some View {
        HStack(spacing: VeloraSpacing.s) {
            TextField("Bundle ID", text: $bundleIDText, prompt: Text("com.example.app"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTypedBundleIDs)
            Button("Add", action: addTypedBundleIDs)
                .buttonStyle(.capsule)
                .disabled(Mode.parseList(bundleIDText).isEmpty)
        }
        .padding(.horizontal, ModesMetrics.rowInset)
        .padding(.bottom, VeloraSpacing.s)
    }

    private var vocabularyCard: some View {
        GroupCard(
            header: "Vocabulary",
            footer: "Add words and proper nouns this mode should recognize. Separate entries with commas."
        ) {
            fieldRow {
                TextField(
                    "Vocabulary", text: $vocabularyText,
                    prompt: Text("Velora, Anthropic, Kubernetes"),
                    axis: .vertical)
                    .onChange(of: vocabularyText) { _, text in
                        vm.draft.vocabulary = Mode.parseList(text)
                    }
            }
        }
    }

    private var replacementsCard: some View {
        GroupCard(
            header: "Replacements",
            headerLink: ("Add Replacement", {
                vm.draft.replacements.append(Mode.Replacement(key: "", value: ""))
            }),
            footer: "Rewrite dictated phrases (heard → written)."
        ) {
            if vm.draft.replacements.isEmpty {
                placeholderRow("No replacements", symbol: "arrow.right")
            }
            ForEach($vm.draft.replacements) { $pair in
                if pair.id != vm.draft.replacements.first?.id {
                    GroupDivider()
                }
                HStack(spacing: VeloraSpacing.s) {
                    TextField("Heard", text: $pair.key, prompt: Text("heard"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    TextField("Written", text: $pair.value, prompt: Text("written"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    removeButton(label: "Remove replacement") {
                        vm.draft.replacements.removeAll { $0.id == pair.id }
                    }
                }
                .padding(.horizontal, ModesMetrics.rowInset)
                .padding(.vertical, VeloraSpacing.s)
            }
        }
    }

    // MARK: Rows

    /// A quiet stand-in row for an empty list inside a card.
    private func placeholderRow(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, ModesMetrics.rowInset)
            .padding(.vertical, VeloraSpacing.s)
            .frame(maxWidth: .infinity, minHeight: ModesMetrics.rowMinHeight, alignment: .leading)
    }

    /// A bordered field that wraps long values over up to four lines; the
    /// card's header names it.
    private func fieldRow<Field: View>(@ViewBuilder field: () -> Field) -> some View {
        field()
            .labelsHidden()
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, ModesMetrics.rowInset)
            .padding(.vertical, VeloraSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func removeButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: ModesMetrics.iconWell, height: ModesMetrics.iconWell)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    /// An assigned app by name, never by bundle ID (that shows on hover).
    /// One that isn't installed is dimmed, with a placeholder icon.
    private func applicationRow(_ app: AssignedApp) -> some View {
        let name = Mode.applicationName(
            for: app.bundleID,
            installedName: app.url?.deletingPathExtension().lastPathComponent)
        let icon = app.url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        return HStack(spacing: VeloraSpacing.m) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: Self.appIconSide, height: Self.appIconSide)
            .accessibilityHidden(true)

            GroupRow(label: name) {
                removeButton(label: "Remove \(name)") {
                    setApplications(vm.draft.apps.filter {
                        $0.caseInsensitiveCompare(app.bundleID) != .orderedSame
                    })
                }
            }
            .padding(.leading, -ModesMetrics.rowInset)
        }
        .padding(.leading, ModesMetrics.rowInset)
        .foregroundStyle(app.url == nil ? HierarchicalShapeStyle.secondary : .primary)
        .help(app.bundleID)
    }

    /// A row that opens more rows under it, its chevron turning down.
    private func disclosureRow(
        _ label: String, sub: String?, symbol: String, isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(VeloraMotion.quick) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: VeloraSpacing.m) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.appIconSide)
                    .accessibilityHidden(true)
                GroupRow(label: label, sub: sub) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.leading, -ModesMetrics.rowInset)
            }
            .padding(.leading, ModesMetrics.rowInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
    }

    // MARK: Actions

    /// Normalizes the draft's apps and re-seeds the vocabulary buffer from
    /// the (newly selected) draft.
    private func syncListBuffers() {
        vm.draft.apps = Mode.normalizedApplicationIDs(vm.draft.apps)
        vocabularyText = vm.draft.vocabulary.joined(separator: ", ")
    }

    private func setApplications(_ values: [String]) {
        vm.draft.apps = Mode.normalizedApplicationIDs(values)
    }

    private func addTypedBundleIDs() {
        let typed = Mode.normalizedApplicationIDs(Mode.parseList(bundleIDText))
        guard !typed.isEmpty, addApplications(typed) else {
            return
        }
        bundleIDText = ""
    }

    /// Adds apps from the picker or the bundle-ID field, refusing any app
    /// another mode already has. Returns whether they were added.
    private func addApplications(_ selected: [String]) -> Bool {
        if let conflict = Mode.firstAssignmentConflict(
            applications: selected, modes: vm.modes, excluding: vm.selectedID
        ) {
            applicationPickerError = "That app is already assigned to “\(conflict.modeName)”. Remove it there before assigning it to this mode."
            return false
        }
        setApplications(Mode.mergingApplicationIDs(existing: vm.draft.apps, selected: selected))
        return true
    }

    private func chooseApplications() {
        let panel = NSOpenPanel()
        panel.title = "Choose Applications"
        panel.message = "Select the apps where \(vm.draft.name) should activate automatically."
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else { return }
        let ownBundleID = Bundle.main.bundleIdentifier
        let selected = panel.urls.compactMap { url -> String? in
            guard let identifier = Bundle(url: url)?.bundleIdentifier,
                  !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ownBundleID.map({ identifier.caseInsensitiveCompare($0) != .orderedSame }) ?? true
            else { return nil }
            return identifier
        }
        guard !selected.isEmpty else {
            applicationPickerError = "Select a macOS app with a bundle identifier. Velora itself cannot activate a dictation mode."
            return
        }
        _ = addApplications(selected)
    }
}
