import AppKit
import SwiftUI

struct DictionaryDraft: Equatable {
    var writeAs: String
    var heardAs: String?

    func validated() throws -> DictionaryDraft {
        let written = try DictionaryValue(writeAs)
        let trimmedHeard = heardAs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let heard = trimmedHeard.isEmpty ? nil : try DictionaryValue(trimmedHeard).text
        return DictionaryDraft(writeAs: written.text, heardAs: heard)
    }

    var riskWarning: String? {
        let output = writeAs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let heard = try? heardAs.map(DictionaryValue.init),
              !output.isEmpty,
              heard.text.split(separator: " ").count == 1,
              LearningStore.isRealWord(heard.text.lowercased()) else { return nil }
        return "“\(heard.text)” is a common word. Velora will replace every exact occurrence with “\(output)”."
    }
}

enum DictionarySettingsLogic {
    static func filtered(_ rows: [DictionaryRow], query: String) -> [DictionaryRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            row.writeAs.localizedCaseInsensitiveContains(needle)
                || (row.heardAs?.localizedCaseInsensitiveContains(needle) ?? false)
                || row.source.rawValue.localizedCaseInsensitiveContains(needle)
                || sourceLabel(row).localizedCaseInsensitiveContains(needle)
        }
    }

    /// What a key does on the list's selection, as in a native entry list
    /// such as Keyboard › Text Replacements: ⌫ or ⌦ asks to remove the row
    /// (the row menu's Remove or Forget, confirmation included); ↑ and ↓
    /// select the neighbouring row, Home and End the first and last, Page
    /// Up and Page Down the row a page away; Return opens it, as a
    /// double-click does.
    enum RowCommand: Equatable {
        case confirmDelete(DictionaryRow)
        case select(DictionaryRow.ID)
        case open(DictionaryRow)
    }

    /// The keys the list's key handler takes, held keys repeating; every
    /// other key passes through. ⌫ isn't one: AppKit turns it into the
    /// Delete command first, so it arrives through `onDeleteCommand` as
    /// `.delete`.
    static let rowKeys: Set<KeyEquivalent> = [
        .deleteForward, .upArrow, .downArrow, .home, .end, .pageUp, .pageDown,
    ]

    /// The key that opens the selection, taken on its first press only: a
    /// held Return opens the row once, not once per autorepeat.
    static let openKeys: Set<KeyEquivalent> = [.return]

    /// Page Up and Page Down move `page` rows, the rows in view. At an end
    /// of the list, the keys that move toward it pass through, as the
    /// arrows do.
    ///
    ///     page 3:  r0 [r1] r2 r3 r4 r5 r6
    ///     Page Down → r4 · Page Up → r0 · Home → r0 · End → r6
    static func rowCommand(
        for key: KeyEquivalent, on id: DictionaryRow.ID?, in rows: [DictionaryRow], page: Int
    ) -> RowCommand? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else {
            // Nothing listed is selected: End selects the last row, the
            // arrows and the other page keys the first.
            switch key {
            case .end:
                return rows.last.map { .select($0.id) }
            case .upArrow, .downArrow, .home, .pageUp, .pageDown:
                return rows.first.map { .select($0.id) }
            default:
                return nil
            }
        }
        let last = rows.count - 1
        switch key {
        case .delete, .deleteForward:
            return .confirmDelete(rows[index])
        case .upArrow:
            return index > 0 ? .select(rows[index - 1].id) : nil
        case .downArrow:
            return index < last ? .select(rows[index + 1].id) : nil
        case .home:
            return index > 0 ? .select(rows[0].id) : nil
        case .end:
            return index < last ? .select(rows[last].id) : nil
        case .pageUp:
            return index > 0 ? .select(rows[max(index - page, 0)].id) : nil
        case .pageDown:
            return index < last ? .select(rows[min(index + page, last)].id) : nil
        case .return:
            return .open(rows[index])
        default:
            return nil
        }
    }

    /// How far Page Up and Page Down move until the list knows its height.
    static let defaultPageRows = 10

    /// The rows that fit in the scroll view's `viewport` height, at least
    /// one, from the list's (estimated) height over its `count` rows. Nil
    /// until the list has been measured.
    ///
    ///     viewport 260, rows 50 pt tall  →  5
    static func pageRows(viewport: CGFloat, listHeight: CGFloat, count: Int) -> Int? {
        guard viewport > 0, listHeight > 0, count > 0 else {
            return nil
        }
        let rowHeight = listHeight / CGFloat(count)
        return max(1, Int(viewport / rowHeight))
    }

    /// The row the list selects as it takes focus: the selection while it
    /// is still listed, else the first row, so focus always shows on a row.
    static func selectionOnFocus(_ selected: DictionaryRow.ID?, in rows: [DictionaryRow]) -> DictionaryRow.ID? {
        if let selected, rows.contains(where: { $0.id == selected }) {
            return selected
        }
        return rows.first?.id
    }

    /// Whether the list shows focus: it has focus and its window is key,
    /// as the sidebar's `SidebarFocus`. A list keeps SwiftUI focus while
    /// its window resigns key; a native one then shows its selection
    /// unfocused, in grey, and doesn't scroll.
    enum ListFocus {
        case unfocused
        case focused

        init(listFocused: Bool, window: ControlActiveState) {
            self = listFocused && window == .key ? .focused : .unfocused
        }
    }

    /// Mouse events, during which focus reaching the list comes from a
    /// click on it: a press, a release, a drag or a Force Touch press.
    private static let pointerEvents: Set<NSEvent.EventType> = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .pressure,
    ]

    /// Whether focus reaching the list during `event`, with `buttons`
    /// (`NSEvent.pressedMouseButtons`) held, came from a click. The list
    /// takes focus on mouse-down, before the click's tap selects the row
    /// under the pointer; selecting on focus then would select the old row
    /// and scroll it into view, moving the clicked row away. A held button
    /// counts whatever the event, so one AppKit sends mid-click does too.
    static func isPointerFocus(_ event: NSEvent.EventType?, buttons: Int) -> Bool {
        if buttons != 0 {
            return true
        }
        return event.map(pointerEvents.contains) ?? false
    }

    /// Where the selection goes when the rows change, by any path (⌫, the
    /// ⋯ menu, a context menu, Make Permanent, sync, a search): it stays
    /// on its row while that row is listed, else moves to the nearest row
    /// still listed, next first. When none of its old neighbours is left
    /// (a sync that replaced every row), a focused list falls back to the
    /// first row, so it never loses its selection; a list without focus
    /// selects nothing, so a search from "a" to "z" picks no row the user
    /// didn't. Nil once nothing is left, or when nothing was selected.
    ///
    ///     old  a [b] c  d        new  a  d      →  d  (c left too)
    ///     old  a [b] c           new  x  y      →  x  focused, else nil
    static func selectionAfterChange(
        _ id: DictionaryRow.ID?, from old: [DictionaryRow], to new: [DictionaryRow], focus: ListFocus
    ) -> DictionaryRow.ID? {
        guard let id else {
            return nil
        }
        let kept = Set(new.map(\.id))
        if kept.contains(id) {
            return id
        }
        if let index = old.firstIndex(where: { $0.id == id }) {
            let next = old[(index + 1)...].first { kept.contains($0.id) }
            let previous = old[..<index].last { kept.contains($0.id) }
            if let neighbour = next ?? previous {
                return neighbour.id
            }
        }
        return focus == .focused ? new.first?.id : nil
    }

    /// The row a saved editor selects: the entry new to the rows (an add,
    /// an edit that changed the entry's key, Make Permanent…), else the
    /// edited entry, which kept its id and moved to the top. Not the edited
    /// row's old neighbour, where `selectionAfterChange` alone would go.
    static func savedRowID(
        editing: DictionaryRow.ID?, before: [DictionaryRow], after: [DictionaryRow]
    ) -> DictionaryRow.ID? {
        let existing = Set(before.map(\.id))
        if let saved = after.first(where: { !existing.contains($0.id) }) {
            return saved.id
        }
        return after.contains { $0.id == editing } ? editing : nil
    }

    /// The added entry that Make Permanent leaves for an auto-learned word
    /// promoted as `draft`: the same spelling and heard-as rule (or none),
    /// ignoring case. The one it adds, or one already there, which the
    /// promotion keeps as is.
    static func promotedRowID(_ draft: DictionaryDraft, in rows: [DictionaryRow]) -> DictionaryRow.ID? {
        rows.first {
            $0.source == .added
                && $0.writeAs.caseInsensitiveCompare(draft.writeAs) == .orderedSame
                && $0.heardAs?.lowercased() == draft.heardAs?.lowercased()
        }?.id
    }

    /// What a row's default action does: Return, a double-click, VoiceOver's
    /// press or Voice Control's "Click <word>". Each opens the editor, so
    /// none changes the dictionary without a confirm step: an added word
    /// to edit, a learned correction or an auto-learned word to confirm in
    /// Make Permanent. Promoting an auto-learned word forgets its auto copy,
    /// which bans the miner from it; a stray Return mustn't do that.
    enum OpenAction: Equatable {
        case edit
        case confirmPromotion
    }

    static func openAction(for row: DictionaryRow) -> OpenAction {
        row.source == .added ? .edit : .confirmPromotion
    }

    /// `filtered(_:query:)` for the pane, run again only when the rows or
    /// the query change. The pane's body runs on every selection change,
    /// so on every arrow key, and with a query set each run makes up to
    /// four localized searches per row, 8,000 at the 2,000-row cap. The
    /// memo also hands back the same array while nothing changed, so the
    /// list's `onChange(of: rows)` compares two arrays that share storage,
    /// which is O(1), instead of walking 2,000 rows. The memo's own check
    /// is O(1) for the same reason: the model hands out the same array
    /// until it publishes new rows.
    final class FilterMemo {
        private var input: (rows: [DictionaryRow], query: String)?
        private var output: [DictionaryRow] = []

        func rows(_ rows: [DictionaryRow], query: String) -> [DictionaryRow] {
            if let input, input.query == query, input.rows == rows {
                return output
            }
            output = DictionarySettingsLogic.filtered(rows, query: query)
            input = (rows, query)
            return output
        }
    }

    /// Where a row came from, as its caption says it. Search matches this
    /// text too, so what the row reads is what finds it.
    ///
    ///     Kubectl        Found in your dictations   (the idle miner)
    ///     Sushil Kumar   From your edit             (a correction you made)
    static func sourceLabel(_ row: DictionaryRow) -> String {
        switch row.source {
        case .added:
            return row.source.rawValue
        case .learned:
            return row.isSoftCorrection ? "From your edit · Context-aware" : "From your edit"
        case .automatic:
            return "Found in your dictations"
        }
    }

    /// What the ⋯ menu forgets in bulk: the words Velora learned. Added
    /// words are removed one at a time, so they have no bulk item.
    enum BulkForget: CaseIterable {
        case learned
        case automatic

        var source: DictionarySource {
            switch self {
            case .learned: return .learned
            case .automatic: return .automatic
            }
        }
    }

    /// The ⋯ menu's bulk forget item and its confirmation, named in the
    /// rows' own terms so the menu says what the captions say.
    ///
    ///     Forget Words Found in Dictations…  →  Forget all words found in your dictations?
    ///     Forget Corrections from Edits…     →  Forget all corrections from your edits?
    static func bulkForgetItem(_ kind: BulkForget) -> String {
        switch kind {
        case .learned: return "Forget Corrections from Edits…"
        case .automatic: return "Forget Words Found in Dictations…"
        }
    }

    static func bulkForgetTitle(_ kind: BulkForget) -> String {
        switch kind {
        case .learned: return "Forget all corrections from your edits?"
        case .automatic: return "Forget all words found in your dictations?"
        }
    }

    static func bulkForgetMessage(_ kind: BulkForget) -> String {
        switch kind {
        case .learned: return "Velora will remove these corrections from every synced Mac."
        case .automatic: return "Velora will remove these words from your dictionary."
        }
    }

    /// "Make Permanent" on an auto-learned word: add `draft` as the user's
    /// own entry (the word as found, from a menu; as confirmed, from the
    /// editor), then forget the auto copy, which also bans the miner from
    /// learning it again. Adding first means a failed step never loses the
    /// word; an identical added entry already there is kept as is.
    static func promoteAutomatic(
        _ row: DictionaryRow, as draft: DictionaryDraft, rows: [DictionaryRow],
        add: (DictionaryDraft) throws -> Void, remove: (DictionaryRow) throws -> Void
    ) throws {
        guard row.source == .automatic else {
            return
        }
        let alreadyAdded = promotedRowID(draft, in: rows) != nil
        if !alreadyAdded {
            try add(draft)
        }
        try remove(row)
    }
}

struct DictionarySyncPresentation: Equatable {
    let title: String
    let symbol: String
    let isWarning: Bool
    let isWorking: Bool
    let canRetry: Bool
    let needsAccountDecision: Bool
    let privacyDetail: String

    init(_ status: DictionarySyncStatus) {
        switch status {
        case .idle:
            title = "Saved on this Mac"
            symbol = "icloud"
            isWarning = false
            isWorking = false
            canRetry = false
            needsAccountDecision = false
            privacyDetail = "Syncs through iCloud Drive when it’s available. No audio, transcripts, or history are included."
        case .syncing:
            title = "Syncing…"
            symbol = "icloud"
            isWarning = false
            isWorking = true
            canRetry = false
            needsAccountDecision = false
            privacyDetail = "Sync uses your iCloud Drive. No audio, transcripts, or history are included."
        case .synced:
            title = "Synced with iCloud"
            symbol = "checkmark.icloud"
            isWarning = false
            isWorking = false
            canRetry = false
            needsAccountDecision = false
            privacyDetail = "Synced privately through your iCloud Drive. No audio, transcripts, or history are included."
        case .localOnly:
            title = "Saved on this Mac. iCloud Drive is unavailable"
            symbol = "icloud.slash"
            isWarning = true
            isWorking = false
            canRetry = true
            needsAccountDecision = false
            privacyDetail = "Your local dictionary remains active. No audio, transcripts, or history are included."
        case .waitingForDownload:
            title = "Waiting for iCloud download…"
            symbol = "icloud.and.arrow.down"
            isWarning = false
            isWorking = true
            canRetry = false
            needsAccountDecision = false
            privacyDetail = "Waiting for your iCloud Drive copy. Your local dictionary remains active."
        case .accountChanged:
            title = "Apple Account changed. Choose what to keep"
            symbol = "person.crop.circle.badge.exclamationmark"
            isWarning = true
            isWorking = false
            canRetry = false
            needsAccountDecision = true
            privacyDetail = "Sync is paused. No dictionary data crosses Apple Accounts until you choose."
        case .error(let message):
            title = message
            symbol = "exclamationmark.icloud"
            isWarning = true
            isWorking = false
            canRetry = true
            needsAccountDecision = false
            privacyDetail = "Your local dictionary remains active. No audio, transcripts, or history are included."
        }
    }
}

struct DictionarySettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var query = ""
    @State private var editor: EditorContext?
    @State private var pendingDelete: DictionaryRow?
    @State private var confirmation: ConfirmationRoute?
    @State private var operationError: String?
    /// The selected entry: clicked, arrowed to, or just saved in the
    /// editor. The list keeps it as a native table does.
    @State private var selectedRowID: DictionaryRow.ID?
    /// Set with `selectedRowID` when a save selects its entry, so the list
    /// scrolls to it once whether or not it has focus.
    @State private var revealsSelection = false
    /// Keeps `filteredRows` between bodies (see `FilterMemo`).
    @State private var filterMemo = DictionarySettingsLogic.FilterMemo()

    private struct EditorContext: Identifiable {
        let id = UUID()
        let row: DictionaryRow?
        let promotesLearned: Bool
    }

    private enum ConfirmationRoute: Equatable {
        case bulkDelete(DictionarySettingsLogic.BulkForget)
        case accountReview
        case accountOverwrite(DictionaryAccountDecision)
    }

    private var filteredRows: [DictionaryRow] {
        filterMemo.rows(model.dictionaryRows, query: query)
    }

    /// The header search box, as wide as History's.
    private static let searchWidth: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            // Search, Add and the actions menu sit in the title row, like
            // every other pane's controls.
            PaneHeader(title: MainPane.dictionary.title) {
                SettingsSearchBox(
                    prompt: "Search names and terms", query: $query,
                    accessibilityLabel: "Search Dictionary")
                    .frame(width: Self.searchWidth)
                Button {
                    editor = EditorContext(row: nil, promotesLearned: false)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.primaryCapsule)
                .keyboardShortcut("n", modifiers: .command)
                .help("Add a word or heard-as correction")
                dictionaryMenu
            }
            .padding(.bottom, VeloraSpacing.m)

            // A failed add, promote or forget stays in view however far the
            // list is scrolled.
            if let operationError {
                operationErrorBanner(operationError)
                    .padding(.bottom, VeloraSpacing.s)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DictionaryMetrics.sectionSpacing) {
                    learningCard
                    entriesCard
                }
                .padding(.bottom, VeloraSpacing.xl)
            }

            // Sync state, the Apple Account review and the last import or
            // export result stay in view however far the list is scrolled.
            syncFooter
                .padding(.horizontal, DictionaryMetrics.rowInset)
                .padding(.top, VeloraSpacing.s)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editor) { context in
            DictionaryEditorSheet(
                model: model,
                editing: context.row,
                promotesLearned: context.promotesLearned
            ) { saved in
                select(saved)
            }
        }
        .modifier(DictionaryDeleteConfirmation(row: $pendingDelete) { row in
            do {
                try model.removeDictionaryEntry(row)
                operationError = nil
            } catch {
                operationError = error.localizedDescription
            }
        })
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible
        ) {
            confirmationActions
        } message: {
            Text(confirmationMessage)
        }
    }

    /// The shared header actions menu beside Add, like Meetings'; it
    /// brings its own ellipsis capsule, tooltip and VoiceOver label.
    private var dictionaryMenu: some View {
        HeaderMenu(actions: "Dictionary actions") {
            if model.dictionaryFolderIsAvailable {
                Button("Show in Finder", systemImage: "folder") {
                    model.openDictionaryFolder()
                }
                Divider()
            }
            Button("Import Dictionary…", systemImage: "square.and.arrow.down") {
                model.importDictionary()
            }
            Button("Export Dictionary…", systemImage: "square.and.arrow.up") {
                model.exportDictionary()
            }
            .disabled(model.dictionaryRows.isEmpty)

            if model.dictionaryRows.contains(where: { $0.source != .added }) {
                Divider()
                Button(DictionarySettingsLogic.bulkForgetItem(.learned), systemImage: "trash") {
                    confirmation = .bulkDelete(.learned)
                }
                .disabled(!model.dictionaryRows.contains { $0.source == .learned })
                Button(DictionarySettingsLogic.bulkForgetItem(.automatic), systemImage: "trash") {
                    confirmation = .bulkDelete(.automatic)
                }
                .disabled(!model.dictionaryRows.contains { $0.source == .automatic })
            }
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .bulkDelete(let kind): return DictionarySettingsLogic.bulkForgetTitle(kind)
        case .accountReview: return "Your Apple Account changed"
        case .accountOverwrite(.keepLocal): return "Replace the iCloud dictionary?"
        case .accountOverwrite(.useCloud): return "Replace this Mac’s dictionary?"
        case .accountOverwrite(.merge): return "Merge both dictionaries?"
        case nil: return ""
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .bulkDelete(let kind):
            return DictionarySettingsLogic.bulkForgetMessage(kind)
        case .accountReview:
            return "Merge keeps both dictionaries. Choosing either single copy replaces the other; nothing crosses Apple Accounts until you confirm."
        case .accountOverwrite(.keepLocal):
            return "The dictionary already stored in the new Apple Account’s iCloud Drive will be replaced by this Mac’s copy."
        case .accountOverwrite(.useCloud):
            return "This Mac’s dictionary from the previous Apple Account will be replaced by the new account’s iCloud copy."
        case .accountOverwrite(.merge):
            return "Velora will preserve terms from both copies."
        case nil: return ""
        }
    }

    @ViewBuilder private var confirmationActions: some View {
        switch confirmation {
        case .bulkDelete(let kind):
            Button("Forget All", role: .destructive) {
                do {
                    try model.clearDictionaryEntries(kind.source)
                    operationError = nil
                } catch {
                    operationError = error.localizedDescription
                }
                confirmation = nil
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        case .accountReview:
            Button("Merge both dictionaries") {
                model.resolveDictionaryAccountChange(.merge)
                confirmation = nil
            }
            Button("Replace iCloud with This Mac…", role: .destructive) {
                showAccountOverwrite(.keepLocal)
            }
            Button("Replace This Mac with iCloud…", role: .destructive) {
                showAccountOverwrite(.useCloud)
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        case .accountOverwrite(let decision):
            Button("Replace", role: .destructive) {
                model.resolveDictionaryAccountChange(decision)
                confirmation = nil
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        case nil:
            EmptyView()
        }
    }

    private func showAccountOverwrite(_ decision: DictionaryAccountDecision) {
        confirmation = nil
        DispatchQueue.main.async { confirmation = .accountOverwrite(decision) }
    }

    // MARK: Cards

    /// The two switches that grow this dictionary, each with what it does
    /// spelled out beneath it rather than in a tooltip.
    ///
    ///     Learning
    ///     ┌─────────────────────────────────────────────┐
    ///     │ Learn from your edits                  [on] │
    ///     │ When you correct a misheard word …          │
    ///     │   ├─────────────────────────────────────┤   │
    ///     │ Discover new words while idle          [on] │
    ///     │ Velora spots recurring names and jargon …   │
    ///     └─────────────────────────────────────────────┘
    private var learningCard: some View {
        GroupCard(header: "Learning") {
            learningRow(
                "Learn from your edits",
                sub: "When you correct a misheard word right after Velora inserts it, the fix is saved here.",
                isOn: $model.learnFromEdits)
            GroupDivider()
            learningRow(
                "Discover new words while idle",
                sub: "Velora spots recurring names and jargon in your dictations and adds confirmed terms here.",
                isOn: $model.vocabMining)
        }
    }

    private func learningRow(_ title: String, sub: String, isOn: Binding<Bool>) -> some View {
        GroupRow(label: title, sub: sub) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    /// The Entries card's title, which also names the list for VoiceOver.
    private static let entriesTitle = "Entries"

    /// Every word and correction as a row. The sync status sits under the
    /// scroll view instead (`syncFooter`), so it never scrolls away.
    private var entriesCard: some View {
        // The title as `GroupCard(header:)` draws it, but hidden from
        // VoiceOver: the list carries the same name, and hearing "Entries"
        // twice in a row says nothing more.
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            // Copied from GroupCard's header style (SettingsDesign.swift).
            Text(Self.entriesTitle)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, DictionaryMetrics.rowInset)
                .accessibilityHidden(true)
            GroupCard {
                entries
            }
        }
    }

    @ViewBuilder private var entries: some View {
        let rows = filteredRows
        if model.dictionaryRows.isEmpty {
            // The Dictionary symbol (DESIGN.md §7), and a glass capsule:
            // the header's Add stays the pane's one primary.
            ContentUnavailableView {
                Label("Teach Velora your words", systemImage: "character.book.closed")
            } description: {
                Text("Add names, product terms, acronyms, or a phrase Velora often mishears.")
            } actions: {
                Button("Add Word") {
                    editor = EditorContext(row: nil, promotesLearned: false)
                }
                .buttonStyle(.capsule)
            }
            .padding(.vertical, VeloraSpacing.xl)
        } else if rows.isEmpty {
            ContentUnavailableView.search(text: query)
                .padding(.vertical, VeloraSpacing.xl)
        } else {
            DictionaryEntryList(
                label: Self.entriesTitle, rows: rows,
                selection: $selectedRowID, reveal: $revealsSelection,
                onOpen: open,
                onEdit: { editor = EditorContext(row: $0, promotesLearned: false) },
                onPromote: promote,
                onDelete: { pendingDelete = $0 })
        }
    }

    /// Sync state with its one action as a link, then what sync carries
    /// and the last import or export result.
    ///
    ///     ☁ Saved on this Mac. iCloud Drive is unavailable  Retry
    ///     Your local dictionary remains active. No audio, …
    private var syncFooter: some View {
        let presentation = DictionarySyncPresentation(model.dictionarySyncStatus)
        return VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            HStack(spacing: VeloraSpacing.xs) {
                if presentation.isWorking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: presentation.symbol)
                        .foregroundStyle(presentation.isWarning ? AnyShapeStyle(VeloraStatus.warning) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }
                Text(presentation.title)
                    .foregroundStyle(presentation.isWarning ? .primary : .secondary)
                    .lineLimit(2)
                if presentation.needsAccountDecision {
                    footerLink("Review…") { confirmation = .accountReview }
                } else if presentation.canRetry {
                    footerLink("Retry") { model.retryDictionarySync() }
                }
            }
            .font(.caption)
            SettingsFooter(presentation.privacyDetail)
            if let result = model.dictionaryTransferResult {
                SettingsFooter(result)
            }
        }
    }

    /// An action inside the footer's sentence, drawn as a link like
    /// History's "Delete All…".
    private func footerLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(VeloraBrand.link)
    }

    /// A failed add, promote or forget, with a dismiss button.
    private func operationErrorBanner(_ message: String) -> some View {
        HStack(spacing: VeloraSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(VeloraStatus.danger)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: VeloraSpacing.s)
            Button {
                operationError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss dictionary error")
        }
        .font(.caption)
        .padding(.horizontal, DictionaryMetrics.rowInset)
    }

    /// A row's default action, for Return, a double-click and VoiceOver's
    /// or Voice Control's press: edit an added word, confirm a learned or
    /// auto-learned one in Make Permanent (see `openAction`).
    private func open(_ row: DictionaryRow) {
        switch DictionarySettingsLogic.openAction(for: row) {
        case .edit:
            editor = EditorContext(row: row, promotesLearned: false)
        case .confirmPromotion:
            editor = EditorContext(row: row, promotesLearned: true)
        }
    }

    /// Selects an entry just saved and scrolls it into view, as the editor
    /// and Make Permanent do.
    private func select(_ id: DictionaryRow.ID) {
        selectedRowID = id
        revealsSelection = true
    }

    /// Make Permanent from a row's menus or VoiceOver's actions: a learned
    /// correction opens the editor to confirm its spelling; an auto-learned
    /// word, whose item says what it does, moves straight to the added
    /// words.
    private func promote(_ row: DictionaryRow) {
        guard row.source == .automatic else {
            editor = EditorContext(row: row, promotesLearned: true)
            return
        }
        let draft = DictionaryDraft(writeAs: row.writeAs, heardAs: nil)
        do {
            try DictionarySettingsLogic.promoteAutomatic(
                row, as: draft, rows: model.dictionaryRows,
                add: { try model.addDictionaryEntry(writeAs: $0.writeAs, heardAs: $0.heardAs) },
                remove: { try model.removeDictionaryEntry($0) })
            // Select the added word, as the editor's Make Permanent does:
            // the one just added, or the one already there.
            if let promoted = DictionarySettingsLogic.promotedRowID(draft, in: model.dictionaryRows) {
                select(promoted)
            }
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
    }
}

// Test seam: internal so Selftest can confirm a remove the way the pane does.
/// The confirmation before a row is removed, from ⌫, ⌦, the ⋯ menu or a
/// context menu: "Remove" for entries the user added, "Forget" for learned
/// ones. `remove` runs on the destructive button only.
struct DictionaryDeleteConfirmation: ViewModifier {
    @Binding var row: DictionaryRow?
    let remove: (DictionaryRow) -> Void

    func body(content: Content) -> some View {
        content.alert(item: $row) { row in
            Alert(
                title: Text("\(Self.verb(row)) “\(row.writeAs)”?"),
                message: Text(Self.message(row)),
                primaryButton: .destructive(Text(Self.verb(row))) {
                    remove(row)
                },
                secondaryButton: .cancel())
        }
    }

    private static func verb(_ row: DictionaryRow) -> String {
        row.source == .added ? "Remove" : "Forget"
    }

    private static func message(_ row: DictionaryRow) -> String {
        switch row.source {
        case .added: return "Velora will stop using this spelling and any heard-as rule."
        case .learned: return "Velora will forget this correction on all synced Macs."
        case .automatic: return "Velora will remove this word from your dictionary."
        }
    }
}

/// Card geometry, matched to Home's and Modes' rows.
private enum DictionaryMetrics {
    /// Body spacing between cards, as on Home and Stats.
    static let sectionSpacing: CGFloat = 18
    /// Leading and trailing inset of a row inside a `GroupCard` (`GroupRow`'s),
    /// which is also where the card's footer text starts.
    static let rowInset: CGFloat = 14
    /// Width of the leading symbol well on a row.
    static let iconWell: CGFloat = 22
    /// A focused row's accent tint, inset from the card's edges like a
    /// selected row in an inset list.
    static let focusTint: Double = 0.14
    static let focusStroke: CGFloat = 2
    static let focusInset: CGFloat = 4
    /// The selection while the list doesn't have focus: the grey a native
    /// list keeps on its selection while another control has focus.
    static let selectedFill = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    /// Side of the ⋯ button, and of the slot it keeps in the row.
    static let actionsSize: CGFloat = 24
    /// The ⋯ symbol's size: SwiftUI's default body size on macOS.
    static let actionsSymbolSize: CGFloat = 13
}

/// How a row shows the list's selection: the focus mark while the list
/// has focus; unfocused, a grey tint, as in a native list.
enum DictionaryRowState {
    case plain
    case selected
    case focused
}

// Test seam: internal so Selftest can drive the real list in a window.
/// The Entries list, keyed like a native table. Focus sits on the list,
/// not on a row, and the selection is plain state, so it outlives the lazy
/// stack dropping rows scrolled out of view, and nothing ever moves focus
/// in from elsewhere (the search box, a sheet).
///
///     Tab ──▶ ┌ Kubectl       ┐ ◀─ the selection while listed, else the first row
///             │▐Sushil Kumar ▌│  ↑ ↓ Home End Page Up/Down select, scroll into view,
///             │               │  move VoiceOver
///             └ Velora        ┘  ⌫ ⌦ remove, confirmed · ⏎ open
struct DictionaryEntryList: View {
    /// The list's name for VoiceOver: the card's title, which VoiceOver
    /// skips so it isn't read twice.
    let label: String
    let rows: [DictionaryRow]
    @Binding var selection: DictionaryRow.ID?
    /// Set to scroll the selection into view once, with or without focus,
    /// as after a save in the editor. The list clears it.
    @Binding var reveal: Bool
    let onOpen: (DictionaryRow) -> Void
    let onEdit: (DictionaryRow) -> Void
    let onPromote: (DictionaryRow) -> Void
    let onDelete: (DictionaryRow) -> Void
    /// Test seam: each built row's window frame, and nil once the lazy
    /// stack drops the row. The app passes none, so its rows carry no
    /// geometry observer.
    var rowFrame: ((DictionaryRow.ID, CGRect?) -> Void)?

    @FocusState private var listFocused: Bool
    @Environment(\.controlActiveState) private var windowState
    /// The row VoiceOver is on. The arrows move it with the selection, and
    /// VoiceOver moving it moves the selection, so ⌫ removes the row
    /// VoiceOver just read.
    @AccessibilityFocusState private var spokenRow: DictionaryRow.ID?
    /// How far Page Up and Page Down move: the rows in view, nil until
    /// measured.
    @State private var pageRows: Int?

    /// Focus as the list shows it: only in the key window. The selection's
    /// accent mark, scrolling to it and VoiceOver following it all need it.
    private var focus: DictionarySettingsLogic.ListFocus {
        DictionarySettingsLogic.ListFocus(listFocused: listFocused, window: windowState)
    }

    var body: some View {
        ScrollViewReader { proxy in
            // Lazy: an import can bring DictionaryDocument.maximumEntries
            // (2,000) rows, each with an AppKit menu, and only rows near the
            // visible ones are built.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    // The ForEach ID is the row's scroll ID. The divider sits
                    // inside the row's stack, as in MeetingRowList: as a
                    // sibling it was what `scrollTo` revealed.
                    VStack(alignment: .leading, spacing: 0) {
                        if index > 0 {
                            GroupDivider()
                        }
                        DictionarySettingsRow(
                            row: item, state: state(of: item.id), spokenRow: $spokenRow,
                            onOpen: { onOpen(item) },
                            onEdit: { onEdit(item) },
                            onPromote: { onPromote(item) },
                            onDelete: { onDelete(item) })
                            // A click selects the row and focuses the list
                            // at once, without waiting out a double-click.
                            .simultaneousGesture(TapGesture().onEnded {
                                selection = item.id
                                listFocused = true
                            })
                    }
                    .modifier(DictionaryRowFrameReport(id: item.id, report: rowFrame))
                }
            }
            // A page for Page Up and Page Down: the rows that fit in the
            // scroll view, from the stack's estimated height.
            .onGeometryChange(for: Int?.self) { geometry in
                DictionarySettingsLogic.pageRows(
                    viewport: geometry.bounds(of: .scrollView)?.height ?? 0,
                    listHeight: geometry.size.height, count: rows.count)
            } action: { page in
                pageRows = page
            }
            // One named group for VoiceOver, holding two elements per row:
            // the row and its ⋯ button.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            // The list is one Tab stop. AppKit turns ⌫ into the Delete
            // command before any key handler sees it. Return opens on its
            // first press only, so a held Return opens the row once.
            .focusable(interactions: .edit)
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: DictionarySettingsLogic.rowKeys) { press in
                handle(press.key)
            }
            .onKeyPress(keys: DictionarySettingsLogic.openKeys, phases: .down) { press in
                handle(press.key)
            }
            .onDeleteCommand {
                _ = handle(.delete)
            }
            // Keep the selection in view as the keys move it. Only with
            // focus in the key window: a sync or a search that moves the
            // selection leaves the view where the user scrolled it.
            .onChange(of: selection) { _, id in
                guard focus == .focused, let id else {
                    return
                }
                proxy.scrollTo(id)
            }
            // A save in the editor scrolls to its entry, focus or not. The
            // list may appear with a reveal already set (the first add, or
            // one under a search with no results), so it answers that too;
            // left set, the next save's reveal would change nothing.
            .onChange(of: reveal, initial: true) { _, revealing in
                guard revealing else {
                    return
                }
                reveal = false
                if let selection {
                    proxy.scrollTo(selection)
                }
            }
            // Tabbing in shows focus on a row: the selection, else the first
            // row. A click focuses the list too, on mouse-down, before its
            // tap selects the row under the pointer; selecting here then
            // would pick the old row and scroll the clicked one away.
            .onChange(of: listFocused) { _, focused in
                let isPointer = DictionarySettingsLogic.isPointerFocus(
                    NSApp?.currentEvent?.type, buttons: NSEvent.pressedMouseButtons)
                guard focused, !isPointer,
                      let target = DictionarySettingsLogic.selectionOnFocus(selection, in: rows) else {
                    return
                }
                selection = target
                spokenRow = target
                proxy.scrollTo(target)
            }
            .onChange(of: spokenRow) { _, id in
                guard focus == .focused, let id else {
                    return
                }
                selection = id
            }
        }
        // A selected row that leaves by any path (⌫, a menu, Make Permanent,
        // sync, a search) hands the selection to its nearest listed
        // neighbour, and VoiceOver goes with it. Focus stays where it is.
        .onChange(of: rows) { old, new in
            let next = DictionarySettingsLogic.selectionAfterChange(
                selection, from: old, to: new, focus: focus)
            guard next != selection else {
                return
            }
            selection = next
            if focus == .focused {
                spokenRow = next
            }
        }
        // ⌫'s confirmation is a sheet, so the window isn't key when its
        // Remove moves the selection; VoiceOver catches up as the window
        // takes key back with the list still focused.
        .onChange(of: windowState) { _, state in
            guard state == .key, listFocused, let selection else {
                return
            }
            spokenRow = selection
        }
    }

    private func state(of id: DictionaryRow.ID) -> DictionaryRowState {
        guard id == selection else {
            return .plain
        }
        return focus == .focused ? .focused : .selected
    }

    /// Runs a key pressed on the focused list: ⌫ or ⌦ opens the same
    /// confirmation as the row menu's Remove or Forget, an arrow or a page
    /// key moves the selection and VoiceOver with it, and Return opens the
    /// selected row.
    private func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        let page = pageRows ?? DictionarySettingsLogic.defaultPageRows
        guard let command = DictionarySettingsLogic.rowCommand(for: key, on: selection, in: rows, page: page) else {
            return .ignored
        }
        switch command {
        case .confirmDelete(let target):
            onDelete(target)
        case .select(let id):
            selection = id
            spokenRow = id
        case .open(let target):
            onOpen(target)
        }
        return .handled
    }
}

/// Reports a row's window frame to `DictionaryEntryList.rowFrame`, and nil
/// once the lazy stack drops the row. With no seam (the app) the row
/// carries no geometry observer at all, as with Modes' `RowFrameReport`.
private struct DictionaryRowFrameReport: ViewModifier {
    let id: DictionaryRow.ID
    let report: ((DictionaryRow.ID, CGRect?) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let report {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    report(id, frame)
                }
                .onDisappear {
                    report(id, nil)
                }
        } else {
            content
        }
    }
}

/// One entry. VoiceOver and Voice Control see exactly two elements:
///
///     ┌───────────────────────────────────────────────┐
///     │ ◎  Kubectl                                 ⋯  │
///     │    Found in your dictations                   │
///     └───────────────────────────────────────────────┘
///      └─ the row: a button named for the word, its  └─ "Actions for Kubectl"
///         caption as value, every ⋯ action on it
private struct DictionarySettingsRow: View {
    let row: DictionaryRow
    let state: DictionaryRowState
    /// The list's VoiceOver focus, which lands on this row at its id.
    let spokenRow: AccessibilityFocusState<DictionaryRow.ID?>.Binding
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onPromote: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    /// The ⋯ button shows on the hovered or focused row only, so a long
    /// list isn't a column of identical buttons; right-click and the row's
    /// accessibility actions have the same actions.
    private var showsMenu: Bool {
        isHovered || state == .focused
    }

    var body: some View {
        // A `GroupRow` behind a symbol well, as on Home and Modes: the
        // symbol takes the row's leading inset. The trailing slot keeps the
        // ⋯ button's room; the button sits over it (below), outside the
        // row's accessibility element.
        HStack(spacing: VeloraSpacing.m) {
            Image(systemName: sourceSymbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(sourceColor)
                .frame(width: DictionaryMetrics.iconWell)
                .accessibilityHidden(true)
            GroupRow(label: row.writeAs, sub: caption) {
                Color.clear
                    .frame(width: DictionaryMetrics.actionsSize, height: DictionaryMetrics.actionsSize)
            }
            .padding(.leading, -DictionaryMetrics.rowInset)
        }
        .padding(.leading, DictionaryMetrics.rowInset)
        // One button per row for VoiceOver and Voice Control: the word,
        // then its caption, pressed as Return opens it, with every ⋯
        // action, so none hides behind the hover-only button. Its texts
        // are read through it, never on their own.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.writeAs)
        .accessibilityValue(caption)
        .accessibilityAddTraits(state == .plain ? .isButton : [.isButton, .isSelected])
        .accessibilityAction(.default, onOpen)
        .accessibilityActions {
            if row.source == .added { Button("Edit", action: onEdit) }
            if promoteTitle != nil { Button("Make Permanent", action: onPromote) }
            Button(deleteTitle, action: onDelete)
        }
        .accessibilityFocused(spokenRow, equals: row.id)
        // Hidden, the ⋯ button keeps its slot but takes no clicks (they
        // reach the row). It is never a Tab stop, since the list is one,
        // but stays enabled for VoiceOver and Voice Control. SwiftUI drops
        // a transparent view from the accessibility tree unless it is
        // marked not hidden.
        .overlay(alignment: .trailing) {
            DictionaryRowActions(label: "Actions for \(row.writeAs)", items: menuItems)
                .frame(width: DictionaryMetrics.actionsSize, height: DictionaryMetrics.actionsSize)
                .opacity(showsMenu ? 1 : 0)
                .allowsHitTesting(showsMenu)
                .accessibilityHidden(false)
                .padding(.trailing, DictionaryMetrics.rowInset)
        }
        .background(focusMark)
        // The whole row takes the double-click, blank space included.
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            if row.source == .added { Button("Edit…", action: onEdit) }
            if let promoteTitle { Button(promoteTitle, action: onPromote) }
            Button(deleteTitle, role: .destructive, action: onDelete)
        }
        .onTapGesture(count: 2, perform: onOpen)
    }

    /// The selection, inset from the card like a selected row in an inset
    /// list. With focus, an accent tint with a 2 pt accent edge: the edge
    /// gives the 3:1 contrast a focus indicator needs; the tint alone falls
    /// short. Without focus, a grey tint.
    @ViewBuilder private var focusMark: some View {
        let shape = RoundedRectangle(cornerRadius: VeloraRadius.row, style: .continuous)
        switch state {
        case .focused:
            shape
                .fill(VeloraBrand.accent.opacity(DictionaryMetrics.focusTint))
                .overlay(shape.strokeBorder(VeloraBrand.accent, lineWidth: DictionaryMetrics.focusStroke))
                .padding(.horizontal, DictionaryMetrics.focusInset)
        case .selected:
            shape
                .fill(DictionaryMetrics.selectedFill)
                .padding(.horizontal, DictionaryMetrics.focusInset)
        case .plain:
            EmptyView()
        }
    }

    /// The ⋯ menu: Edit… or Make Permanent, then Remove or Forget.
    private var menuItems: [DictionaryRowActions.Item] {
        var items: [DictionaryRowActions.Item] = []
        if row.source == .added {
            items.append(.init(title: "Edit…", symbol: "pencil", action: onEdit))
        } else if let promoteTitle {
            items.append(.init(title: promoteTitle, symbol: "pin", action: onPromote))
        }
        items.append(.init(title: deleteTitle, symbol: "trash", action: onDelete))
        return items
    }

    /// "Remove" for entries the user added, "Forget" for learned ones.
    private var deleteTitle: String {
        row.source == .added ? "Remove" : "Forget"
    }

    /// A learned correction opens the editor ("…"); an auto-learned word
    /// becomes an added word at once.
    private var promoteTitle: String? {
        switch row.source {
        case .added: return nil
        case .learned: return "Make Permanent…"
        case .automatic: return "Make Permanent"
        }
    }

    private var sourceSymbol: String {
        switch row.source {
        case .added: return "person.crop.circle.badge.plus"
        // Not Voice Edit's wand or Action Mode's sparkles (DESIGN.md §7).
        case .learned: return "pencil.line"
        case .automatic: return "text.magnifyingglass"
        }
    }

    private var sourceColor: Color {
        switch row.source {
        case .added: return VeloraBrand.accent
        // Apricot is kept for "learned" moments (DESIGN.md, Brand v2).
        case .learned: return VeloraBrand.warm
        case .automatic: return .secondary
        }
    }

    /// "When Velora hears “social kumar” · From your edit", or just the
    /// origin for a word with no heard-as rule.
    private var caption: String {
        let origin = DictionarySettingsLogic.sourceLabel(row)
        guard let heard = row.heardAs else {
            return origin
        }
        return "When Velora hears “\(heard)” · \(origin)"
    }
}

/// A row's ⋯ button: an AppKit pull-down rather than SwiftUI's `Menu`,
/// which VoiceOver names for its symbol ("More") whatever label it gets,
/// and which stays a Full Keyboard Access Tab stop while hidden. This one
/// is named "Actions for <word>" and refuses first responder, so the list
/// stays the one Tab stop, yet stays enabled for VoiceOver and Voice
/// Control to press.
private struct DictionaryRowActions: NSViewRepresentable {
    struct Item {
        let title: String
        let symbol: String
        let action: () -> Void
    }

    let label: String
    let items: [Item]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.refusesFirstResponder = true
        button.imagePosition = .imageOnly
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.items = items

        // Rebuild the menu only when what it shows changes: SwiftUI updates
        // the button on every hover, and the menu may be open then.
        let shown = [label] + items.map(\.title)
        guard coordinator.shown != shown else {
            return
        }
        coordinator.shown = shown
        button.menu = menu(target: coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: DictionaryMetrics.actionsSize, height: DictionaryMetrics.actionsSize)
    }

    /// A pull-down shows its first item as the button's face: here the ⋯
    /// symbol, whose description is the name VoiceOver reads for the button.
    private func menu(target: Coordinator) -> NSMenu {
        let menu = NSMenu()
        let symbolSize = NSImage.SymbolConfiguration(pointSize: DictionaryMetrics.actionsSymbolSize, weight: .regular)
        let face = NSMenuItem()
        face.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: label)?
            .withSymbolConfiguration(symbolSize)
        menu.addItem(face)
        for (index, item) in items.enumerated() {
            let entry = NSMenuItem(title: item.title, action: #selector(Coordinator.run(_:)), keyEquivalent: "")
            entry.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            entry.target = target
            entry.tag = index
            menu.addItem(entry)
        }
        return menu
    }

    /// Runs a menu item's action. The actions are refreshed on every update
    /// while the menu is kept, so an item always acts on the current row.
    final class Coordinator: NSObject {
        fileprivate var items: [Item] = []
        fileprivate var shown: [String] = []

        @objc fileprivate func run(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag) else {
                return
            }
            items[sender.tag].action()
        }
    }
}

private enum DictionaryEditorError: LocalizedError {
    case missingHeardAs

    var errorDescription: String? {
        "Enter what Velora currently hears before making this correction permanent."
    }
}

private struct DictionaryEditorSheet: View {
    @ObservedObject var model: SettingsModel
    let editing: DictionaryRow?
    let promotesLearned: Bool
    /// Selects the saved entry in the list.
    let onSave: (DictionaryRow.ID) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var writeAs: String
    @State private var heardAs: String
    @State private var includesHeardAs: Bool
    @State private var heardAsExpanded: Bool
    @State private var errorMessage: String?

    private enum Field { case writeAs, heardAs }

    init(
        model: SettingsModel, editing: DictionaryRow?, promotesLearned: Bool,
        onSave: @escaping (DictionaryRow.ID) -> Void
    ) {
        self.model = model
        self.editing = editing
        self.promotesLearned = promotesLearned
        self.onSave = onSave
        _writeAs = State(initialValue: editing?.writeAs ?? "")
        _heardAs = State(initialValue: editing?.heardAs ?? "")
        _includesHeardAs = State(initialValue: editing?.heardAs != nil)
        _heardAsExpanded = State(initialValue: editing?.heardAs != nil)
    }

    private var draft: DictionaryDraft {
        DictionaryDraft(writeAs: writeAs, heardAs: includesHeardAs ? heardAs : nil)
    }

    /// Make Permanent on an auto-learned word, opened from its row: the
    /// word has no heard-as rule to require, and saving it forgets the
    /// auto copy (see `promoteAutomatic`).
    private var promotesAutomatic: Bool {
        promotesLearned && editing?.source == .automatic
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sheetTitle)
                    .font(.headline)
                Spacer()
            }
            .padding(VeloraSpacing.m)

            Divider()

            Form {
                Section {
                    TextField("Write as", text: $writeAs, prompt: Text("Sushil Kumar"))
                        .focused($focusedField, equals: .writeAs)
                        .onSubmit(save)
                } footer: {
                    Text("The exact spelling Velora should type.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup(isExpanded: $heardAsExpanded) {
                        TextField(
                            "When Velora hears", text: $heardAs,
                            prompt: Text("social kumar"))
                            .focused($focusedField, equals: .heardAs)
                            .padding(.top, 6)
                        if editing?.heardAs != nil && !promotesLearned && includesHeardAs {
                            Button("Remove heard-as correction", role: .destructive) {
                                includesHeardAs = false
                                heardAs = ""
                                heardAsExpanded = false
                            }
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                    } label: {
                        Text(includesHeardAs
                             ? "Heard-as correction"
                             : "Add a heard-as correction")
                    }
                    if let warning = draft.riskWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(VeloraStatus.warningText)
                    }
                } footer: {
                    Text(heardAsHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    // Only the symbol is red, as in the pane's error banner:
                    // systemRed text is under 4.5:1 on a light sheet.
                    Section {
                        Label {
                            Text(errorMessage)
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(VeloraStatus.danger)
                        }
                        .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveButtonTitle) { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(writeAs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(VeloraSpacing.m)
        }
        .frame(width: 440, height: heardAsExpanded ? 410 : 330)
        .onAppear { focusedField = .writeAs }
        .onChange(of: heardAsExpanded) { _, expanded in
            guard expanded else { return }
            includesHeardAs = true
            DispatchQueue.main.async { focusedField = .heardAs }
        }
        .onChange(of: writeAs) { _, _ in errorMessage = nil }
        .onChange(of: heardAs) { _, _ in errorMessage = nil }
    }

    private var sheetTitle: String {
        if promotesAutomatic { return "Make Word Permanent" }
        if promotesLearned { return "Make Correction Permanent" }
        return editing == nil ? "Add to Dictionary" : "Edit Dictionary Entry"
    }

    private var saveButtonTitle: String {
        if promotesLearned { return "Make Permanent" }
        return editing == nil ? "Add" : "Save"
    }

    private var heardAsHelp: String {
        if promotesAutomatic {
            return "Optional. The word becomes one you added, and Velora stops listing it as found in your dictations."
        }
        if promotesLearned {
            return "This creates an explicit rule that replaces every exact word-boundary match and removes the learned version."
        }
        return "Optional. Use this only for a recurring mishearing; collapsing this section hides an existing rule but does not remove it."
    }

    private func save() {
        do {
            let valid = try draft.validated()
            let before = model.dictionaryRows
            if promotesAutomatic, let editing {
                try DictionarySettingsLogic.promoteAutomatic(
                    editing, as: valid, rows: before,
                    add: { try model.addDictionaryEntry(writeAs: $0.writeAs, heardAs: $0.heardAs) },
                    remove: { try model.removeDictionaryEntry($0) })
            } else if promotesLearned, let editing, let heardAs = valid.heardAs {
                try model.promoteLearnedEntry(
                    editing, writeAs: valid.writeAs, heardAs: heardAs)
            } else if promotesLearned {
                throw DictionaryEditorError.missingHeardAs
            } else if let editing {
                try model.updateDictionaryEntry(
                    editing, writeAs: valid.writeAs, heardAs: valid.heardAs)
            } else {
                try model.addDictionaryEntry(writeAs: valid.writeAs, heardAs: valid.heardAs)
            }
            // The model's rows are already updated. Select the saved entry:
            // new (an add, a changed key, a promotion) or moved to the top;
            // for an auto-learned word already added, the one kept.
            let after = model.dictionaryRows
            let saved = DictionarySettingsLogic.savedRowID(editing: editing?.id, before: before, after: after)
                ?? DictionarySettingsLogic.promotedRowID(valid, in: after)
            if let saved {
                onSave(saved)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
