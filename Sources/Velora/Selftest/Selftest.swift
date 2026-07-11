import AppKit
import Foundation

/// Headless pure-logic tests, run with `Velora --selftest` (CommandLineTools
/// ships no XCTest/swift-testing, so tests live in the binary). Covers the
/// learning loop's thresholds, the correction diff, and protocol parsing —
/// everything deterministic that doesn't need TCC grants or the engine.
enum Selftest {
    private static var failures = 0
    private static var checks = 0

    private static func expect(
        _ condition: Bool, _ message: String,
        file: String = #fileID, line: Int = #line
    ) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL \(file):\(line) — \(message)")
        }
    }

    static func run() -> Int32 {
        testEditDistance()
        testMishearingShapes()
        testLearningThresholds()
        testDictionaryValues()
        testDictionaryMerge()
        testDictionarySerializationBoundary()
        testCorrectionDiff()
        testEventParsing()
        testOnboardingSetup()
        testKeyboardShortcutMapping()
        testModeCategories()
        testVoiceCommands()
        testStreak()
        testHUDGeometry()
        testInsertionBoundary()
        testEmptyFinalFeedback()
        testClipboardStaging()
        print(failures == 0
            ? "selftest OK — \(checks) checks"
            : "selftest FAILED — \(failures)/\(checks) checks failed")
        return failures == 0 ? 0 : 1
    }

    private static func testKeyboardShortcutMapping() {
        let vKey = Hotkey.keyCode(for: "v")
        expect(vKey != nil, "active keyboard layout resolves the Paste shortcut")
        if let vKey {
            expect(
                Hotkey.keyName(for: Int64(vKey)) == "V",
                "Paste uses the semantic V key in the active keyboard layout")
        }

        let zKey = Hotkey.keyCode(for: "z")
        expect(zKey != nil, "active keyboard layout resolves the Undo shortcut")
        if let zKey {
            expect(
                Hotkey.keyName(for: Int64(zKey)) == "Z",
                "Undo uses the semantic Z key in the active keyboard layout")
        }
    }

    // MARK: - Onboarding setup gate

    private static func testOnboardingSetup() {
        let downloading = OnboardingSetupState(
            isComplete: false,
            status: "Downloading the speech model (1.6 GB) — 42%",
            fraction: 0.42)
        expect(!downloading.canTryIt, "model download keeps onboarding try-it locked")

        let staleDownload = OnboardingSetupState(
            isComplete: true,
            status: "Preparing the writing model…",
            fraction: nil)
        expect(!staleDownload.canTryIt, "visible model work wins over a stale completion signal")

        let ready = OnboardingSetupState(isComplete: true, status: nil, fraction: nil)
        expect(ready.canTryIt, "explicit setup completion unlocks onboarding try-it")

        let oversized = OnboardingSetupState(isComplete: false, status: "Downloading", fraction: 1.7)
        expect(oversized.progressFraction == 0.99, "onboarding progress reserves 100% for completion")
    }

    // MARK: - LearningStore: distance + mishearing shape

    private static func testEditDistance() {
        expect(LearningStore.editDistance("", "abc") == 3, "distance to empty")
        expect(LearningStore.editDistance("kitten", "sitting") == 3, "kitten→sitting is 3")
        expect(LearningStore.editDistance("same", "same") == 0, "identity is 0")
    }

    private static func testMishearingShapes() {
        expect(LearningStore.likelyMishearing("shubhi", "Shivangi"), "misheard name shape accepted")
        expect(LearningStore.likelyMishearing("velor", "Velora"), "near-miss accepted")
        expect(LearningStore.likelyMishearing("aircirclearn", "Airlearn"), "stutter blend accepted")
        expect(!LearningStore.likelyMishearing("vercel", "Netlify"), "brand swap rejected")
        // Tiny words: a 1-char diff is half the word — content, not mishearing.
        expect(!LearningStore.likelyMishearing("js", "TS"), "short-word swap rejected")
        expect(LearningStore.likelyMishearing("ts", "TS"), "case-only fix accepted")
    }

    // MARK: - LearningStore: commit thresholds + tiers

    private static func withStore(_ body: (LearningStore, URL) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-selftest-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("learned.json")
        body(LearningStore(url: url), url)
        try? FileManager.default.removeItem(at: dir)
    }

    private static func tiers(_ url: URL) -> (hard: [String: String], soft: [String: String]) {
        struct Learned: Decodable {
            var replacements: [String: String]?
            var soft_replacements: [String: String]?
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Learned.self, from: data)
        else { return ([:], [:]) }
        return (decoded.replacements ?? [:], decoded.soft_replacements ?? [:])
    }

    private static func testLearningThresholds() {
        withStore { store, url in
            // Close name-like fix: instant commit, hard tier (not a real word).
            expect(store.observe([("velor", "Velora")]).count == 1, "close name commits instantly")
            expect(tiers(url).hard["velor"] == "Velora", "close name lands in hard tier")
        }
        withStore { store, url in
            // Far content edit: no instant deterministic rewrite.
            expect(store.observe([("vercel", "Netlify")]).isEmpty, "far pair needs 2 sightings")
            expect(tiers(url).hard["vercel"] == nil, "far pair not committed on 1st")
            expect(store.observe([("vercel", "Netlify")]).count == 1, "far pair commits on 2nd")
        }
        withStore { store, url in
            // Real-word wrong: instant, but context-gated soft tier only.
            expect(store.observe([("lung", "Airlearn")]).count == 1, "real-word wrong commits instantly")
            let t = tiers(url)
            expect(t.hard["lung"] == nil, "real word never a hard rewrite")
            expect(t.soft["lung"] == "Airlearn", "real word lands in soft tier")
        }
        withStore { store, _ in
            expect(store.observe([("hello", "Howdy")]).isEmpty, "stopword refused (1st)")
            expect(store.observe([("hello", "Howdy")]).isEmpty, "stopword refused (2nd)")
            expect(store.count == 0, "stopword never persisted")
        }
        withStore { store, _ in
            expect(store.observe([("cat", "car")]).isEmpty, "ordinary word needs 2 sightings")
            expect(store.observe([("cat", "car")]).count == 1, "ordinary word commits on 2nd")
        }
        withStore { store, url in
            _ = store.observe([("lung", "Airlearn")])
            store.remove(wrong: "lung")
            expect(store.count == 0, "remove forgets the entry")
            expect(tiers(url).soft["lung"] == nil, "remove clears soft tier on disk")
        }
    }

    // MARK: - Portable personal dictionary

    private static func testDictionaryValues() {
        let spaced = try? DictionaryValue("  Sushil   Kumar  ")
        expect(spaced?.text == "Sushil Kumar", "dictionary collapses surrounding whitespace")
        expect(spaced?.normalized == "sushil kumar", "dictionary keys are case-insensitive")

        for technical in ["C++", "node.js", "auth_check", "Mary-Jane", "O'Connor"] {
            expect((try? DictionaryValue(technical))?.text == technical,
                   "dictionary preserves technical spelling: \(technical)")
        }

        for invalid in ["", "   ", "two\nlines", "bad\u{0007}value", String(repeating: "x", count: 61)] {
            do {
                _ = try DictionaryValue(invalid)
                expect(false, "dictionary rejects invalid value: \(invalid.debugDescription)")
            } catch {
                expect(true, "dictionary rejects invalid value: \(invalid.debugDescription)")
            }
        }

        let term = try? DictionaryEntry.manual(
            writeAs: "Airlearn", deviceID: "mac-a", at: Date(timeIntervalSince1970: 10))
        let replacement = try? DictionaryEntry.manual(
            writeAs: "Airlearn", heardAs: "air learn", deviceID: "mac-a",
            at: Date(timeIntervalSince1970: 10))
        expect(term?.kind == .manualTerm && term?.heardAs == nil,
               "write-as alone creates a vocabulary term")
        expect(replacement?.kind == .manualReplacement && replacement?.heardAs == "air learn",
               "optional heard-as creates an explicit replacement")
        expect(
            term?.logicalKey == (try? DictionaryEntry.manual(
                writeAs: "  airLEARN  ", deviceID: "mac-b",
                at: Date(timeIntervalSince1970: 20)))?.logicalKey,
            "manual term logical keys ignore case and repeated whitespace")
    }

    private static func testDictionaryMerge() {
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)
        let alpha = try! DictionaryEntry.manual(writeAs: "Alpha", deviceID: "mac-a", at: t0)
        let beta = try! DictionaryEntry.manual(writeAs: "Beta", deviceID: "mac-b", at: t0)
        let addAdd = DictionaryDocument(entries: [alpha]).merged(
            with: DictionaryDocument(entries: [beta]))
        expect(addAdd.activeEntries.count == 2, "independent additions merge as a union")

        let old = try! DictionaryEntry.manual(
            writeAs: "Velora", heardAs: "valora", deviceID: "mac-a", at: t0,
            revision: 1)
        let revised = try! DictionaryEntry.manual(
            writeAs: "Velora AI", heardAs: "valora", deviceID: "mac-b", at: t1,
            revision: 2)
        let updateWinner = DictionaryDocument(entries: [old]).merged(
            with: DictionaryDocument(entries: [revised]))
        expect(updateWinner.activeEntries.first?.writeAs == "Velora AI",
               "higher revision deterministically wins an update conflict")

        let deleted = old.deleting(deviceID: "mac-b", at: t1)
        let deleteWinner = DictionaryDocument(entries: [revised]).merged(
            with: DictionaryDocument(entries: [deleted]))
        expect(deleteWinner.activeEntries.isEmpty,
               "deletion wins over a concurrent same-epoch update")

        let readded = try! deleted.readding(writeAs: "Velora", deviceID: "mac-a", at: t1)
        let readdWinner = DictionaryDocument(entries: [deleted]).merged(
            with: DictionaryDocument(entries: [readded]))
        expect(readdWinner.activeEntries.count == 1 && readdWinner.activeEntries[0].writeAs == "Velora",
               "explicit re-add advances the epoch and survives an older tombstone")

        let learned = try! DictionaryEntry.learned(
            wrong: "valora", right: "Velora", soft: false,
            deviceID: "mac-a", at: t0)
        let manual = try! DictionaryEntry.manual(
            writeAs: "Velora Pro", heardAs: "valora", deviceID: "mac-b", at: t1)
        let precedence = DictionaryDocument(entries: [learned, manual]).effectiveProjection
        expect(precedence.replacements["valora"] == "Velora Pro",
               "manual replacement outranks learned correction")

        let cleared = DictionaryDocument(entries: [learned]).clearing(
            .learned, deviceID: "mac-b", at: t1)
        let longOfflineMerge = cleared.merged(with: DictionaryDocument(entries: [learned]))
        expect(longOfflineMerge.activeEntries.allSatisfy { $0.namespace != .learned },
               "clear generation blocks a long-offline learned entry from returning")
    }

    private static func testDictionarySerializationBoundary() {
        let entry = try! DictionaryEntry.manual(
            writeAs: "node.js", heardAs: "node js", deviceID: "mac-a",
            at: Date(timeIntervalSince1970: 100))
        let document = DictionaryDocument(entries: [entry])
        let data = try! document.encoded()
        let json = String(decoding: data, as: UTF8.self)
        for forbidden in [
            "transcript", "audio_path", "history", "counts", "candidates",
            "checkpoint_id", "model", "screen_context", "SECRET_TRANSCRIPT_SENTINEL",
        ] {
            expect(!json.contains(forbidden), "cloud dictionary excludes \(forbidden)")
        }
        expect((try? DictionaryDocument.decode(data))?.activeEntries.count == 1,
               "valid portable dictionary round-trips")

        let newer = json.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":999")
        do {
            _ = try DictionaryDocument.decode(Data(newer.utf8))
            expect(false, "newer dictionary schema is rejected")
        } catch {
            expect(true, "newer dictionary schema is rejected")
        }
        do {
            _ = try DictionaryDocument.decode(Data("not json".utf8))
            expect(false, "corrupt dictionary payload is rejected")
        } catch {
            expect(true, "corrupt dictionary payload is rejected")
        }
    }

    // MARK: - CorrectionDiff

    private static func testCorrectionDiff() {
        let nameFix = CorrectionDiff.corrections(
            baseline: "i met airline at the office today",
            edited: "i met Airlearn at the office today")
        expect(
            nameFix == [CorrectionDiff.Correction(wrong: "airline", right: "Airlearn")],
            "1:1 name fix detected")

        let insertion = CorrectionDiff.corrections(
            baseline: "hello world how are you",
            edited: "hello brave world how are you")
        expect(insertion.isEmpty, "pure insertion learns nothing")

        let unrelated = CorrectionDiff.corrections(
            baseline: "the quarterly numbers look strong this week",
            edited: "remember to buy milk and call the plumber")
        expect(unrelated.isEmpty, "wholesale replacement learns nothing")
    }

    // MARK: - EngineEvent parsing

    private static func testEventParsing() {
        let ready = EngineEvent.parse(["event": "ready", "setup_complete": true])
        if case .ready(let setupComplete) = ready {
            expect(setupComplete, "ready event carries cached setup completion")
        } else {
            expect(false, "expected .ready, got \(ready)")
        }

        let final = EngineEvent.parse([
            "event": "final", "session": "s1", "text": "Hello.", "cleanup_applied": true,
        ])
        if case .final(let session, let text, let raw, _, _, let applied, let audio) = final {
            expect(session == "s1" && text == "Hello." && raw == "Hello.", "final fields parse")
            expect(applied && audio == nil, "final flags parse")
        } else {
            expect(false, "expected .final, got \(final)")
        }

        let started = EngineEvent.parse(
            ["event": "transcribe_started", "id": "j", "duration_s": 62.5, "chunks": 2])
        if case .transcribeStarted(let id, let duration, let chunks) = started {
            expect(id == "j" && abs(duration - 62.5) < 0.01 && chunks == 2, "transcribe_started parses")
        } else {
            expect(false, "expected .transcribeStarted")
        }

        let done = EngineEvent.parse(
            ["event": "transcribed", "path": "/a/b.m4a", "text": "notes", "stt_ms": 1200])
        if case .transcribed(_, let path, let text, let ms) = done {
            expect(path == "/a/b.m4a" && text == "notes" && ms == 1200, "transcribed parses")
        } else {
            expect(false, "expected .transcribed")
        }

        if case .transcribeFailed(_, let error) = EngineEvent.parse(["event": "transcribe_failed"]) {
            expect(error == "transcription failed", "transcribe_failed default message")
        } else {
            expect(false, "expected .transcribeFailed")
        }

        if case .unknown = EngineEvent.parse(["event": "from_the_future"]) {
            // fine
        } else {
            expect(false, "unknown events must parse as .unknown")
        }

        if case .setupComplete = EngineEvent.parse(["event": "setup_complete"]) {
            // fine
        } else {
            expect(false, "setup_complete event must unlock onboarding")
        }

        let loading = EngineEvent.parse([
            "event": "loading", "phase": "Downloading the speech model", "fraction": 0.42,
        ])
        if case .loading(let phase, let fraction) = loading {
            expect(
                phase == "Downloading the speech model" && fraction == 0.42,
                "model download phase and typed fraction parse")
        } else {
            expect(false, "expected .loading, got \(loading)")
        }
    }

    // MARK: - Voice commands

    private static func testVoiceCommands() {
        expect(VoiceCommand.parse(text: "Scratch that.", raw: "scratch that") == .undoLastInsertion,
               "punctuated 'Scratch that.' parses as undo")
        expect(VoiceCommand.parse(text: "", raw: "scratch that") == .undoLastInsertion,
               "cleanup-emptied retraction still parses via raw")
        expect(VoiceCommand.parse(text: "New line", raw: "new line") == .pressReturn,
               "'New line' parses as return")
        expect(VoiceCommand.parse(text: "undo", raw: "undo") == nil,
               "bare 'undo' is dictation, not a command")
        expect(VoiceCommand.parse(
            text: "Please scratch that idea and start over.",
            raw: "please scratch that idea and start over") == nil,
            "command words inside a sentence never intercept")
        expect(VoiceCommand.parse(text: "Undo that", raw: "undo that") == .undoLastInsertion,
               "'Undo that' parses as undo")
        expect(VoiceCommand.parse(text: "New paragraph.", raw: "new paragraph") == .newParagraph,
               "'New paragraph' is its own command (two Returns)")
    }

    // MARK: - Stats streak

    private static func testStreak() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        func day(_ offset: Int) -> String {
            formatter.string(from: Calendar.current.date(
                byAdding: .day, value: -offset, to: Date())!)
        }
        expect(HistoryStore.streak(days: []) == 0, "no history → no streak")
        expect(HistoryStore.streak(days: [day(0)]) == 1, "today only → 1")
        expect(HistoryStore.streak(days: [day(1)]) == 1, "yesterday only → streak alive")
        expect(HistoryStore.streak(days: [day(0), day(1), day(2)]) == 3, "3 consecutive days")
        expect(HistoryStore.streak(days: [day(0), day(2), day(3)]) == 1, "gap breaks the streak")
        expect(HistoryStore.streak(days: [day(3), day(4)]) == 0, "stale history → no streak")
    }

    // MARK: - Mode categories

    private static func testModeCategories() {
        expect(ModeCategory.displayName(forBundleID: "com.tinyspeck.slackmacgap") == "Message",
               "Slack maps to Message")
        let terminals = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "org.alacritty",
            "net.kovidgoyal.kitty",
            "com.cmuxterm.app",
        ]
        for bundleID in terminals {
            expect(ModeCategory.displayName(forBundleID: bundleID) == "Terminal",
                   "\(bundleID) maps to Terminal")
        }
        let editors = [
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",
            "dev.zed.Zed",
        ]
        for bundleID in editors {
            expect(ModeCategory.displayName(forBundleID: bundleID) == "Code",
                   "\(bundleID) maps to Code")
        }
        expect(ModeCategory.displayName(forBundleID: "com.example.unknown") == "Text",
               "unknown app falls back to Text")
        expect(ModeCategory.displayName(forBundleID: nil) == "Text", "nil bundle falls back to Text")
    }

    // MARK: - HUD waveform-first geometry

    private static func testHUDGeometry() {
        expect(HUDGeometry.height == 56, "HUD stays a compact 56-point capsule")
        expect(HUDGeometry.minListeningWidth == 280, "HUD keeps the original minimum width")
        expect(HUDGeometry.maxListeningWidth == 420, "HUD has a bounded context-label width")
        expect(HUDGeometry.insertedDiameter == 56, "success morph ends as a circle")
        expect(
            HUDGeometry.waveformSize == CGSize(width: 120, height: 32),
            "HUD restores the original waveform footprint")
        expect(WaveformLevelStore.barCount == 24, "HUD renders 24 mirrored waveform bars")
        expect(WaveformLevelStore.halfCount == 12, "HUD uses all 12 spectrum bands")
        expect(
            HUDPanel.panelSize == NSSize(width: 480, height: 160),
            "HUD host contains every capsule state and its shadow")
        expect(
            HUDPanel.panelSize.height >= HUDGeometry.height + 40,
            "HUD host leaves vertical room for motion and shadow")
        expect(
            HUDPanel.panelSize.width >= HUDGeometry.errorWidth + 40,
            "HUD host leaves horizontal room for the error action")
    }

    // MARK: - Final-output clipboard staging

    private static func testInsertionBoundary() {
        expect(
            TextInsertionBoundary.adjusted("Next sentence.", previous: ".", next: nil)
                == " Next sentence.",
            "dictation after a completed sentence gets one leading space")
        expect(
            TextInsertionBoundary.adjusted("Next sentence.", previous: " ", next: nil)
                == "Next sentence.",
            "existing whitespace is never doubled")
        expect(
            TextInsertionBoundary.adjusted(", however", previous: "d", next: nil)
                == ", however",
            "leading punctuation stays attached to prior text")
        expect(
            TextInsertionBoundary.adjusted(".", previous: "d", next: nil) == ".",
            "a dictated full stop stays attached to prior text")
        expect(
            TextInsertionBoundary.adjusted("Users", previous: "/", next: nil) == "Users",
            "path components stay attached after a slash")
        expect(
            TextInsertionBoundary.adjusted("handle", previous: "@", next: nil) == "handle",
            "handles stay attached after an at sign")
        expect(
            TextInsertionBoundary.adjusted("tag", previous: "#", next: nil) == "tag",
            "tags stay attached after a hash")
        expect(
            TextInsertionBoundary.adjusted("based", previous: "-", next: nil) == "based",
            "hyphenated text stays attached")
        expect(
            TextInsertionBoundary.adjusted("Users", previous: nil, next: "/") == "Users",
            "text inserted before a path separator stays attached")
        expect(
            TextInsertionBoundary.adjusted("user", previous: nil, next: "@") == "user",
            "text inserted before an at sign stays attached")
        expect(
            TextInsertionBoundary.adjusted("inside", previous: "(", next: ")")
                == "inside",
            "text stays tight inside delimiters")
        expect(
            TextInsertionBoundary.adjusted("inserted", previous: " ", next: "w")
                == "inserted ",
            "dictation before existing prose gets one trailing separator")
        expect(
            TextInsertionBoundary.adjusted("standalone", previous: nil, next: nil)
                == "standalone",
            "unknown or empty surroundings do not create dangling spaces")
        expect(
            TextInsertionBoundary.adjusted(
                "member",
                boundary: TextSelectionBoundary(before: "object.", after: ""),
                mode: "Code") == "member",
            "code member access stays attached after a period")
        expect(
            TextInsertionBoundary.adjusted(
                "Next sentence.",
                boundary: TextSelectionBoundary(before: "object.", after: ""),
                mode: "Code") == " Next sentence.",
            "prose in Code mode still gets sentence spacing")
        expect(
            TextInsertionBoundary.adjusted(
                "Nested",
                boundary: TextSelectionBoundary(before: "Type.", after: ""),
                mode: "Code") == "Nested",
            "uppercase code member access stays attached after a period")
        expect(
            TextInsertionBoundary.adjusted("bar", previous: "_", next: nil) == "bar",
            "identifier fragments stay attached after underscores")
        expect(
            TextInsertionBoundary.adjusted("PATH", previous: "$", next: nil) == "PATH",
            "environment variables stay attached after dollar signs")
        expect(
            TextInsertionBoundary.adjusted("Users", previous: "\\", next: nil) == "Users",
            "backslash-delimited paths stay attached")
        expect(
            TextInsertionBoundary.adjusted(
                "hello",
                boundary: TextSelectionBoundary(before: "He said \"", after: "\"."),
                mode: nil) == "hello",
            "insertion inside straight quotes does not add inner spaces")
        expect(
            TextInsertionBoundary.adjusted(
                "Next",
                boundary: TextSelectionBoundary(before: "He said \"hello\"", after: ""),
                mode: nil) == " Next",
            "text after a closing straight quote gets a separator")
        expect(
            TextInsertionBoundary.adjusted(
                "requests",
                boundary: TextSelectionBoundary(before: "Users'", after: ""),
                mode: nil) == " requests",
            "text after a possessive apostrophe gets a separator")
        expect(
            TextInsertionBoundary.adjusted(
                "t worry.",
                boundary: TextSelectionBoundary(before: "don'", after: ""),
                mode: nil) == "t worry.",
            "recognized contraction suffix stays attached after an apostrophe")
        expect(
            TextInsertionBoundary.adjusted(
                "世界。",
                boundary: TextSelectionBoundary(before: "你好", after: ""),
                mode: nil) == "世界。",
            "Chinese text is not split by an ASCII space")
        expect(
            TextInsertionBoundary.adjusted(
                "世界",
                boundary: TextSelectionBoundary(before: "", after: "。次"),
                mode: nil) == "世界",
            "full-width punctuation stays attached")
        expect(
            TextInsertionBoundary.adjusted(
                "世界",
                boundary: TextSelectionBoundary(before: "こんにちは", after: ""),
                mode: nil) == "世界",
            "Japanese text is not split by an ASCII space")
        expect(
            TextInsertionBoundary.adjusted(
                "다음 문장입니다.",
                boundary: TextSelectionBoundary(before: "안녕하세요.", after: ""),
                mode: nil) == " 다음 문장입니다.",
            "Korean sentence chunks keep their normal word separator")

        let emojiBoundary = TextSelectionBoundary(
            text: "A🙂B", utf16Range: NSRange(location: 3, length: 0))
        expect(
            emojiBoundary?.previous == "🙂" && emojiBoundary?.next == "B",
            "AX UTF-16 caret ranges preserve composed characters")
        expect(
            TextSelectionBoundary(
                text: "A🙂B", utf16Range: NSRange(location: 2, length: 0)) == nil,
            "AX ranges that split a composed character are refused")
        let replacementBoundary = TextSelectionBoundary(
            text: "abXcd", utf16Range: NSRange(location: 2, length: 1))
        expect(
            replacementBoundary?.previous == "b" && replacementBoundary?.next == "c",
            "AX replacement ranges inspect text outside the selection")
    }

    private static func testEmptyFinalFeedback() {
        expect(
            DictationOutputFailure.message(for: "  \n") == "Couldn't transcribe that — try again",
            "an empty final produces actionable feedback")
        expect(
            DictationOutputFailure.message(for: "Recognized text.") == nil,
            "recognized output does not produce an error")
    }

    private static func testClipboardStaging() {
        let name = NSPasteboard.Name("com.velora.selftest.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        let inserter = TextInserter(pasteboard: pasteboard)
        inserter.stageFinalOutput("A final sentence.")
        expect(
            pasteboard.string(forType: .string) == "A final sentence.",
            "final output remains available for manual paste")
        pasteboard.clearContents()
    }
}
