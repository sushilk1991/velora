import SwiftUI

struct MeetingSubtitleSheet: View {
    let record: MeetingRecord
    @StateObject private var service: MeetingSubtitleService
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    @Environment(\.dismiss) private var dismiss

    init(record: MeetingRecord, store: MeetingStore,
         isReady: @escaping () -> Bool, send: @escaping ([String: Any]) -> Void) {
        self.record = record
        _service = StateObject(wrappedValue: MeetingSubtitleService(record: record, store: store, isReady: isReady, send: send))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            Text(L10n.text("Generate subtitles")).font(.headline)
            Text(L10n.text("Recognize the retained audio again with word timing on this Mac. These source-language words may differ from the saved transcript. Timing is estimated; review the preview before export."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text(service.working ? "Generating…" : "Generate preview")) { service.generate() }
                    .disabled(service.working || service.exporting)
                if service.working {
                    ProgressView(value: service.fraction).frame(width: 160)
                    Button(L10n.text(service.cancelling ? "Cancelling…" : "Cancel generation")) { service.cancel() }
                        .disabled(service.cancelling)
                }
                Spacer()
            }
            if let result = service.result, !result.cues.isEmpty {
                Text(L10n.text("Generated from audio • estimated word timing")).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: VeloraSpacing.m) {
                        ForEach(Array(result.cues.enumerated()), id: \.offset) { _, cue in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(MeetingRecord.cueTime(cue.startMs, format: .vtt))–\(MeetingRecord.cueTime(cue.endMs, format: .vtt)) · \(speaker(cue.speaker))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(cue.text).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(VeloraSpacing.m)
                }
                .background(VeloraPanel.card)
                .clipShape(RoundedRectangle(cornerRadius: VeloraRadius.tile))
            } else {
                Text(L10n.text(service.working ? "Listening to the saved audio… Dictation takes priority between audio windows." : "Generate a preview to review the words and timing before saving an SRT or WebVTT file."))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = service.message {
                Text(message).font(.caption).foregroundStyle(VeloraStatus.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Picker(L10n.text("Format"), selection: $service.format) {
                    Text("SRT").tag(MeetingExportFormat.srt)
                    Text("WebVTT").tag(MeetingExportFormat.vtt)
                }.frame(width: 170).disabled(service.exporting)
                Spacer()
                Button(L10n.text("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text(service.exporting ? "Checking audio…" : "Export subtitles…")) { service.export(format: service.format) }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.working || service.exporting || service.result?.cues.isEmpty != false)
            }
        }
        .padding(VeloraSpacing.xl).frame(width: 650, height: 590)
        .interactiveDismissDisabled(service.exporting)
        .onDisappear { service.disappear() }
    }

    private func speaker(_ value: MeetingSpeaker) -> String {
        switch value {
        case .me: return L10n.text("Me")
        case .them: return L10n.text("Them")
        default: return L10n.text("Recording")
        }
    }
}
