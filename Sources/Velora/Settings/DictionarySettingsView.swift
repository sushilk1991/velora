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
        }
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
            privacyDetail = "Stored only on this Mac until iCloud Drive is available. No audio, transcripts, or history are included."
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
            title = "Saved on this Mac — iCloud Drive is unavailable"
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
            title = "Apple Account changed — choose what to keep"
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
    @State private var selectedRowID: DictionaryRow.ID?
    @State private var editor: EditorContext?
    @State private var pendingDelete: DictionaryRow?
    @State private var confirmation: ConfirmationRoute?
    @State private var operationError: String?

    private struct EditorContext: Identifiable {
        let id = UUID()
        let row: DictionaryRow?
        let promotesLearned: Bool
    }

    private enum ConfirmationRoute: Equatable {
        case bulkDelete(DictionarySource)
        case accountReview
        case accountOverwrite(DictionaryAccountDecision)
    }

    private var filteredRows: [DictionaryRow] {
        DictionarySettingsLogic.filtered(model.dictionaryRows, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: VeloraSpacing.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search names and terms", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search personal dictionary")
                Button {
                    editor = EditorContext(row: nil, promotesLearned: false)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
                .help("Add a word or heard-as correction")
                dictionaryMenu
            }
            .padding(.horizontal, VeloraSpacing.m)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            Group {
                if model.dictionaryRows.isEmpty {
                    ContentUnavailableView {
                        Label("Teach Velora your words", systemImage: "text.book.closed")
                    } description: {
                        Text("Add names, product terms, acronyms, or a phrase Velora often mishears.")
                    } actions: {
                        Button("Add a word") {
                            editor = EditorContext(row: nil, promotesLearned: false)
                        }
                            .buttonStyle(.borderedProminent)
                    }
                } else if filteredRows.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(selection: $selectedRowID) {
                        ForEach(filteredRows) { row in
                            DictionarySettingsRow(row: row) {
                                editor = EditorContext(row: row, promotesLearned: false)
                            } onPromote: {
                                editor = EditorContext(row: row, promotesLearned: true)
                            } onDelete: {
                                pendingDelete = row
                            }
                            .tag(row.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .onDeleteCommand {
                        guard let selectedRowID,
                              let row = model.dictionaryRows.first(where: {
                                  $0.id == selectedRowID
                              }) else { return }
                        pendingDelete = row
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            syncFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editor) { context in
            DictionaryEditorSheet(
                model: model,
                editing: context.row,
                promotesLearned: context.promotesLearned)
        }
        .alert(item: $pendingDelete) { row in
            Alert(
                title: Text("Forget “\(row.writeAs)”?"),
                message: Text(deleteMessage(row)),
                primaryButton: .destructive(Text("Forget")) {
                    do {
                        try model.removeDictionaryEntry(row)
                        operationError = nil
                    } catch {
                        operationError = error.localizedDescription
                    }
                },
                secondaryButton: .cancel())
        }
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

    private var dictionaryMenu: some View {
        Menu {
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
                Button("Forget Learned Corrections…", systemImage: "trash") {
                    confirmation = .bulkDelete(.learned)
                }
                .disabled(!model.dictionaryRows.contains { $0.source == .learned })
                Button("Forget Auto-Learned Words…", systemImage: "trash") {
                    confirmation = .bulkDelete(.automatic)
                }
                .disabled(!model.dictionaryRows.contains { $0.source == .automatic })
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Dictionary actions")
        .accessibilityLabel("Dictionary actions")
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .bulkDelete(.learned): return "Forget all learned corrections?"
        case .bulkDelete(.automatic): return "Forget all auto-learned words?"
        case .bulkDelete(.added): return "Forget all added words?"
        case .accountReview: return "Your Apple Account changed"
        case .accountOverwrite(.keepLocal): return "Replace the iCloud dictionary?"
        case .accountOverwrite(.useCloud): return "Replace this Mac’s dictionary?"
        case .accountOverwrite(.merge): return "Merge both dictionaries?"
        case nil: return ""
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .bulkDelete(.learned):
            return "Velora will remove these corrections from every synced Mac."
        case .bulkDelete(.automatic):
            return "Velora will remove these words and prevent the local miner from relearning them."
        case .bulkDelete(.added):
            return "Velora will remove every word and rule you added."
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
        case .bulkDelete(let source):
            Button("Forget all", role: .destructive) {
                do {
                    try model.clearDictionaryEntries(source)
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

    private var syncFooter: some View {
        let presentation = DictionarySyncPresentation(model.dictionarySyncStatus)
        return VStack(spacing: 5) {
            HStack(spacing: VeloraSpacing.s) {
                if presentation.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: presentation.symbol)
                        .foregroundStyle(presentation.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }
                Text(presentation.title)
                    .font(.caption)
                    .foregroundStyle(presentation.isWarning ? .primary : .secondary)
                    .lineLimit(2)
                Spacer(minLength: VeloraSpacing.s)
                if presentation.needsAccountDecision {
                    Button("Review…") { confirmation = .accountReview }
                        .controlSize(.small)
                } else if presentation.canRetry {
                    Button("Retry") { model.retryDictionarySync() }
                        .controlSize(.small)
                }
            }
            if let operationError {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(operationError)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        self.operationError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss dictionary error")
                }
            }
            HStack {
                Text(presentation.privacyDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let result = model.dictionaryTransferResult {
                    Text(result)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, VeloraSpacing.m)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func deleteMessage(_ row: DictionaryRow) -> String {
        switch row.source {
        case .added: return "Velora will stop using this spelling and any heard-as rule."
        case .learned: return "Velora will forget this correction on all synced Macs."
        case .automatic: return "Velora will remove this word and prevent the local miner from relearning it."
        }
    }
}

private struct DictionarySettingsRow: View {
    let row: DictionaryRow
    let onEdit: () -> Void
    let onPromote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sourceSymbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(sourceColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.writeAs)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let heard = row.heardAs {
                        Text("When Velora hears “\(heard)”")
                            .lineLimit(1)
                        Text("·")
                    }
                    Text(sourceLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if row.source == .added {
                    Button("Edit…", systemImage: "pencil", action: onEdit)
                } else if row.source == .learned {
                    Button("Make Permanent…", systemImage: "pin", action: onPromote)
                }
                Button("Forget", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(row.writeAs)")
        }
        .padding(.vertical, 5)
        .contextMenu {
            if row.source == .added { Button("Edit…", action: onEdit) }
            if row.source == .learned { Button("Make Permanent…", action: onPromote) }
            Button("Forget", role: .destructive, action: onDelete)
        }
        .onTapGesture(count: 2) {
            if row.source == .added { onEdit() }
            if row.source == .learned { onPromote() }
        }
    }

    private var sourceSymbol: String {
        switch row.source {
        case .added: return "person.crop.circle.badge.plus"
        case .learned: return "wand.and.stars"
        case .automatic: return "sparkles"
        }
    }

    private var sourceColor: Color {
        switch row.source {
        case .added: return VeloraBrand.violet.color
        case .learned: return .blue
        case .automatic: return .secondary
        }
    }

    private var sourceLabel: String {
        guard row.source == .learned else { return row.source.rawValue }
        return row.isSoftCorrection ? "Learned · Context-aware" : "Learned correction"
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
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var writeAs: String
    @State private var heardAs: String
    @State private var includesHeardAs: Bool
    @State private var heardAsExpanded: Bool
    @State private var errorMessage: String?

    private enum Field { case writeAs, heardAs }

    init(model: SettingsModel, editing: DictionaryRow?, promotesLearned: Bool) {
        self.model = model
        self.editing = editing
        self.promotesLearned = promotesLearned
        _writeAs = State(initialValue: editing?.writeAs ?? "")
        _heardAs = State(initialValue: editing?.heardAs ?? "")
        _includesHeardAs = State(initialValue: editing?.heardAs != nil)
        _heardAsExpanded = State(initialValue: editing?.heardAs != nil)
    }

    private var draft: DictionaryDraft {
        DictionaryDraft(writeAs: writeAs, heardAs: includesHeardAs ? heardAs : nil)
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
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text(heardAsHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
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
        if promotesLearned { return "Make Correction Permanent" }
        return editing == nil ? "Add to Dictionary" : "Edit Dictionary Entry"
    }

    private var saveButtonTitle: String {
        if promotesLearned { return "Make Permanent" }
        return editing == nil ? "Add" : "Save"
    }

    private var heardAsHelp: String {
        if promotesLearned {
            return "This creates an explicit rule that replaces every exact word-boundary match and removes the learned version."
        }
        return "Optional. Use this only for a recurring mishearing; collapsing this section hides an existing rule but does not remove it."
    }

    private func save() {
        do {
            let valid = try draft.validated()
            if promotesLearned, let editing, let heardAs = valid.heardAs {
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
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
