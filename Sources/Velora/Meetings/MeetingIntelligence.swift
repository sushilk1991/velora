import Combine
import Foundation
import SwiftUI

extension MeetingSegment {
    /// Stable within a committed transcript revision; never a staging row ID.
    var sourceKey: String { "\(speaker.rawValue):\(chunkIndex)" }
}

struct MeetingSourceReference: Equatable, Identifiable {
    let meetingID: String
    let revision: Int64
    let key: String
    let text: String
    let startMs: Int
    let endMs: Int
    var id: String { "\(meetingID):\(revision):\(key)" }

    init(segment: MeetingSegment, revision: Int64) {
        meetingID = segment.meetingID
        self.revision = revision
        key = segment.sourceKey
        text = segment.text
        startMs = segment.startMs
        endMs = segment.endMs
    }
}

/// The local notes model proposes semantic topics. Boundaries are exact
/// transcript blocks; the engine and app both reject invented source keys.
struct MeetingChapter: Codable, Equatable {
    let title: String
    let startKey: String
    let endKey: String
    let startText: String
    let endText: String

    static func parse(_ object: Any?) -> [MeetingChapter] {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              data.count <= 2_000_000,
              let result = try? JSONDecoder().decode([MeetingChapter].self, from: data)
        else { return [] }
        return Array(result.prefix(80)).filter { !$0.title.isEmpty && $0.title.count <= 160 }
    }

    static func decode(_ text: String?) -> [MeetingChapter] {
        guard let text, let data = text.data(using: .utf8), data.count <= 2_000_000,
              let result = try? JSONDecoder().decode([MeetingChapter].self, from: data)
        else { return [] }
        return Array(result.prefix(80))
    }

    static func encode(_ chapters: [MeetingChapter]) -> String {
        guard let data = try? JSONEncoder().encode(Array(chapters.prefix(80))) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct MeetingChapterRange: Identifiable {
    let title: String
    let sources: [MeetingSourceReference]
    var id: String { sources.first?.id ?? title }
    var startMs: Int { sources.first?.startMs ?? 0 }
    var endMs: Int { sources.map(\.endMs).max() ?? startMs }
}

/// Search answers are exact excerpts, never a generated claim. Matching is
/// deliberately conservative; no matching passage means an explicit no-answer.
enum MeetingPassageSearch {
    private static let ignored: Set<String> = Set("a an the and or but to of for from in on at by with is are was were be been being it its this that these those i we you they he she me them our their my your what which who whom whose when where why how do does did can could would should will shall have has had about please tell said say us as any there here happened discussed discuss meeting".split(separator: " ").map(String.init))

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !ignored.contains($0) }.map { word in
                if word.count > 5 && word.hasSuffix("ing") { return String(word.dropLast(3)) }
                if word.count > 4 && word.hasSuffix("ed") { return String(word.dropLast(2)) }
                if word.count > 4 && word.hasSuffix("s") { return String(word.dropLast()) }
                return word
            })
    }

    static func matches(question: String, record: MeetingRecord, limit: Int = 3) -> [MeetingSourceReference] {
        let terms = words(String(question.prefix(2_000)))
        guard !terms.isEmpty else { return [] }
        let required = terms.count == 1 ? 1 : max(2, Int(ceil(Double(terms.count) * 0.6)))
        return record.segments.compactMap { segment -> (MeetingSegment, Int, Double)? in
            let available = words(segment.text)
            let overlap = available.intersection(terms).count
            guard overlap >= required else { return nil }
            return (segment, overlap, Double(overlap) / Double(max(1, available.count)))
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            return ($0.0.startMs, $0.0.sourceKey) < ($1.0.startMs, $1.0.sourceKey)
        }.prefix(max(0, min(limit, 8))).map { MeetingSourceReference(segment: $0.0, revision: record.transcriptRevision) }
    }

    /// These are related-source links, not a claim that lexical overlap
    /// proves every generated note. The linked text stays visible for review.
    static func related(to note: String, record: MeetingRecord) -> MeetingSourceReference? {
        guard words(note).count >= 2 else { return nil }
        return matches(question: note, record: record, limit: 1).first
    }

    static func chapters(in record: MeetingRecord) -> [MeetingChapterRange] {
        let ordered = record.segments.sorted {
            ($0.startMs, $0.speaker.rawValue, $0.chunkIndex) < ($1.startMs, $1.speaker.rawValue, $1.chunkIndex)
        }
        var lastEnd = -1
        return record.notes.chapters.compactMap { chapter in
            guard let start = ordered.firstIndex(where: { $0.sourceKey == chapter.startKey && $0.text == chapter.startText }),
                  let end = ordered.firstIndex(where: { $0.sourceKey == chapter.endKey && $0.text == chapter.endText }),
                  start <= end, start > lastEnd else { return nil }
            lastEnd = end
            return MeetingChapterRange(title: chapter.title, sources: ordered[start...end].map {
                MeetingSourceReference(segment: $0, revision: record.transcriptRevision)
            })
        }
    }
}

/// Token checks discard old reads after navigation, deletion, or recreation.
/// Source activation revalidates the exact revision through the store again.
final class MeetingIntelligenceModel: ObservableObject {
    @Published private(set) var chapters: [MeetingChapterRange] = []
    @Published private(set) var noteSources: [String: MeetingSourceReference] = [:]
    @Published private(set) var answer: [MeetingSourceReference] = []
    @Published private(set) var asked = false
    @Published private(set) var searching = false
    @Published private(set) var loading = false
    @Published private(set) var selectedSources: [MeetingSourceReference] = []
    @Published private(set) var sourceError: String?
    private let store: MeetingStore
    private var current: MeetingRecord?
    private var snapshot: MeetingRecord?
    private var loadToken = UUID()
    private var questionToken = UUID()
    private var sourceToken = UUID()

    init(store: MeetingStore) { self.store = store }

    func load(_ record: MeetingRecord) {
        guard current?.id != record.id || current?.transcriptRevision != record.transcriptRevision
                || current?.notes != record.notes || snapshot == nil else { current = record; return }
        let changed = current?.id != record.id || current?.transcriptRevision != record.transcriptRevision
        current = record
        let token = UUID()
        loadToken = token
        loading = true
        if changed { clearQuestion(); selectedSources = []; sourceError = nil; chapters = []; noteSources = [:]; snapshot = nil }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fresh = self.store.record(id: record.id)
            let chapters = fresh.map(MeetingPassageSearch.chapters) ?? []
            var sources: [String: MeetingSourceReference] = [:]
            if let fresh {
                for note in [fresh.notes.summary] + fresh.notes.decisions + fresh.notes.actionItems {
                    sources[note] = MeetingPassageSearch.related(to: note, record: fresh)
                }
            }
            DispatchQueue.main.async {
                guard self.loadToken == token, self.current?.id == record.id,
                      self.current?.transcriptRevision == record.transcriptRevision else { return }
                self.loading = false
                guard let fresh, fresh.transcriptRevision == record.transcriptRevision,
                      self.isCurrent(fresh) else {
                    self.snapshot = nil; self.chapters = []; self.noteSources = [:]
                    return
                }
                self.snapshot = fresh
                self.chapters = chapters
                self.noteSources = sources
                self.loading = false
            }
        }
    }

    func ask(_ question: String) {
        clearQuestion()
        asked = true
        guard let snapshot, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = UUID()
        questionToken = token
        searching = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let matches = MeetingPassageSearch.matches(question: question, record: snapshot)
            DispatchQueue.main.async {
                guard let self, self.questionToken == token, self.isCurrent(snapshot) else { return }
                self.answer = matches
                self.searching = false
            }
        }
    }

    func clearQuestion() {
        questionToken = UUID()
        answer = []
        asked = false
        searching = false
    }

    func open(_ references: [MeetingSourceReference], play: ((MeetingSegment) -> Void)? = nil) {
        let token = UUID()
        sourceToken = token
        sourceError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let resolved = self.store.resolve(references)
            DispatchQueue.main.async {
                guard self.sourceToken == token, let current = self.current,
                      references.first?.meetingID == current.id else { return }
                guard let resolved, resolved.count == references.count, self.isCurrent(current) else {
                    self.selectedSources = []
                    self.sourceError = "This transcript changed or was deleted. Open the meeting again to use current sources."
                    return
                }
                self.selectedSources = references
                if let first = resolved.first { play?(first) }
            }
        }
    }

    func cancel() {
        loadToken = UUID(); questionToken = UUID(); sourceToken = UUID()
        loading = false; searching = false
    }

    private func isCurrent(_ record: MeetingRecord) -> Bool {
        guard current?.id == record.id, current?.transcriptRevision == record.transcriptRevision,
              let metadata = store.recordMetadata(id: record.id) else { return false }
        return metadata.transcriptRevision == record.transcriptRevision
    }
}

/// Shared by the existing Meetings detail and focused notes window.
struct MeetingIntelligenceCards: View {
    let record: MeetingRecord
    let store: MeetingStore
    @ObservedObject var playback: MeetingAudioPlayback
    var onToggleAction: ((String, Bool, @escaping (Bool) -> Void) -> Void)? = nil
    var showTranscript: () -> Void = {}
    @StateObject private var intelligence: MeetingIntelligenceModel
    @State private var question = ""

    init(record: MeetingRecord, store: MeetingStore, playback: MeetingAudioPlayback,
         onToggleAction: ((String, Bool, @escaping (Bool) -> Void) -> Void)? = nil,
         showTranscript: @escaping () -> Void = {}) {
        self.record = record; self.store = store; self.playback = playback
        self.onToggleAction = onToggleAction; self.showTranscript = showTranscript
        _intelligence = StateObject(wrappedValue: MeetingIntelligenceModel(store: store))
    }

    var body: some View {
        Group {
            if !intelligence.chapters.isEmpty {
                GroupCard(header: "Chapters") {
                    VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                        ForEach(intelligence.chapters) { chapter in
                            Button { intelligence.open(chapter.sources) } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(chapter.title).multilineTextAlignment(.leading)
                                    Spacer()
                                    Text(clock(chapter.startMs) + "–" + clock(chapter.endMs))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain).help("Open this topic's source passages")
                        }
                        Text("Chapter times follow transcript audio blocks; they are approximate topic boundaries.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(14)
                }
            }
            MeetingNotesCards(notes: record.notes, onToggleAction: onToggleAction,
                sourceFor: { intelligence.noteSources[$0] },
                onShowSource: { intelligence.open([$0]) })
            MeetingPersonalNotesCard(record: record, store: store)
            if record.status == .ready || record.status == .failed {
                GroupCard(header: "Ask this meeting") {
                    VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                        HStack {
                            TextField("What would you like to find?", text: $question)
                                .textFieldStyle(.roundedBorder).onSubmit { intelligence.ask(question) }
                                .onChange(of: question) { _, _ in intelligence.clearQuestion() }
                            Button("Find passages") { intelligence.ask(question) }
                                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || intelligence.loading)
                        }
                        Text("Searches this meeting on your Mac and returns exact transcript excerpts.")
                            .font(.caption).foregroundStyle(.secondary)
                        if intelligence.searching { ProgressView("Finding passages…").controlSize(.small) }
                        else if intelligence.asked {
                            if intelligence.answer.isEmpty {
                                Text("No supporting passage was found in this meeting. Try different words or check the transcript.")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else {
                                Text("Matching transcript passages").font(.caption).foregroundStyle(.secondary)
                                ForEach(intelligence.answer) { reference in sourceRow(reference) }
                            }
                        }
                    }.padding(14)
                }
            }
            if let error = intelligence.sourceError {
                Text(error).font(.caption).foregroundStyle(VeloraStatus.warningText)
            }
            if !intelligence.selectedSources.isEmpty {
                GroupCard(header: "Source passages") {
                    VStack(alignment: .leading, spacing: VeloraSpacing.m) {
                        ForEach(intelligence.selectedSources) { reference in sourceRow(reference) }
                        Button("Show full transcript", action: showTranscript)
                    }.padding(14)
                }
            }
        }
        .onAppear { intelligence.load(record) }
        .onChange(of: record) { _, fresh in intelligence.load(fresh) }
        .onDisappear { intelligence.cancel() }
    }

    private func clock(_ ms: Int) -> String { MeetingAudioPlayback.clock(Double(ms) / 1_000) }
    private func sourceRow(_ reference: MeetingSourceReference) -> some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            Text(reference.text).font(.callout).textSelection(.enabled)
            Button("Play at " + clock(reference.startMs)) {
                intelligence.open([reference], play: { playback.play($0) })
            }.font(.caption)
        }
    }
}

struct MeetingPersonalNotesCard: View {
    let record: MeetingRecord
    let store: MeetingStore
    @State private var draft = ""
    @State private var savedText = ""
    @State private var revision: Int64 = 0
    @State private var saving = false
    @State private var error: String?
    @State private var token = UUID()

    var body: some View {
        GroupCard(header: "Personal notes") {
            VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                TextEditor(text: $draft).font(.body).frame(minHeight: 90)
                    .accessibilityLabel("Personal meeting notes")
                HStack {
                    Text("Kept when generated notes are recreated.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(saving ? "Saving…" : "Save") { save() }.disabled(saving || draft == savedText)
                }
                if let error { Text(error).font(.caption).foregroundStyle(VeloraStatus.warningText) }
            }.padding(14)
        }
        .onAppear { reset(record) }
        .onChange(of: record) { old, fresh in
            if old.id != fresh.id { reset(fresh) }
            else if draft == savedText && !saving { reset(fresh) }
        }
        .onDisappear { token = UUID() }
    }

    private func reset(_ record: MeetingRecord) {
        token = UUID(); draft = record.personalNotes; savedText = draft
        revision = record.personalNotesRevision; error = nil; saving = false
    }

    private func save() {
        let text = draft, id = record.id, expected = revision, request = UUID()
        token = request; saving = true; error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = store.savePersonalNotes(meetingID: id, text: text, expectedRevision: expected)
            DispatchQueue.main.async {
                guard token == request, record.id == id else { return }
                saving = false
                if saved { savedText = text; revision = expected + 1 }
                else { error = "These notes changed in another window or could not be saved. Your draft is still here; copy it before reopening the meeting." }
            }
        }
    }
}
