import AppKit
import SwiftUI

/// Previewing never rewrites the stored record. Save is a separate guarded edit.
struct HistoryReformatSheet: View {
    let record: DictationRecord
    let modeNames: [String]
    let format: (DictationRecord, String, @escaping (Result<TextFormattingResult, TextFormattingFailure>) -> Void) -> String?
    let cancel: (String) -> Void
    let save: (DictationRecord, String, @escaping (Bool) -> Void) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: String
    @State private var result: TextFormattingResult?
    @State private var requestID: String?
    @State private var draft = ""
    @State private var generation = 0
    @State private var working = false
    @State private var saving = false
    @State private var message: String?

    init(
        record: DictationRecord, modeNames: [String], initialMode: String? = nil,
        format: @escaping (DictationRecord, String, @escaping (Result<TextFormattingResult, TextFormattingFailure>) -> Void) -> String?,
        cancel: @escaping (String) -> Void,
        save: @escaping (DictationRecord, String, @escaping (Bool) -> Void) -> Void
    ) {
        self.record = record
        self.modeNames = modeNames.isEmpty ? [Mode.defaultName] : modeNames
        self.format = format
        self.cancel = cancel
        self.save = save
        let preferred = initialMode ?? record.mode ?? Mode.defaultName
        _selectedMode = State(initialValue: modeNames.contains(preferred) ? preferred : Mode.defaultName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            Text("Reformat saved text").font(.headline)
            Text("Try another mode using the saved words. Audio is not needed. Nothing changes until you save.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Mode", selection: $selectedMode) {
                    ForEach(modeNames, id: \.self) { Text($0).tag($0) }
                }
                .disabled(working || saving)
                Button(working ? "Formatting…" : "Preview") { preview() }
                    .disabled(working || saving)
            }
            DisclosureGroup("Original words") {
                ScrollView {
                    Text(record.raw.isEmpty ? record.final : record.raw)
                        .font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 100)
            }
            if let result {
                Text(result.explanation).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft)
                    .font(.body)
                    .disabled(saving)
                    .frame(minHeight: 170)
                    .padding(VeloraSpacing.s)
                    .background(VeloraPanel.card)
                    .clipShape(RoundedRectangle(cornerRadius: VeloraRadius.tile))
            } else {
                VStack(spacing: VeloraSpacing.s) {
                    if working { ProgressView().controlSize(.small) }
                    Text(working ? "Formatting on this Mac…" : "Choose a mode, then preview the result.")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 180)
            }
            if let message { Text(message).font(.caption).foregroundStyle(VeloraStatus.warningText) }
            HStack {
                if result != nil {
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(draft, forType: .string)
                    }.disabled(saving)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "Saving…" : "Save correction") {
                    saving = true
                    save(record, draft) { saved in
                        saving = false
                        if saved { dismiss() }
                        else { message = "The saved result changed or was deleted. Copy this preview or reopen the latest result." }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(result == nil || working || saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(VeloraSpacing.xl)
        .frame(width: 580, height: 540)
        .interactiveDismissDisabled(saving)
        .onChange(of: selectedMode) { _ in result = nil; message = nil }
        .onDisappear {
            generation += 1
            if let requestID { cancel(requestID) }
        }
    }

    private func preview() {
        generation += 1
        let expected = generation
        working = true
        result = nil
        message = nil
        requestID = format(record, selectedMode) { outcome in
            guard generation == expected else { return }
            working = false
            requestID = nil
            switch outcome {
            case .success(let value): result = value; draft = value.text
            case .failure(let error): message = error.localizedDescription
            }
        }
    }
}
