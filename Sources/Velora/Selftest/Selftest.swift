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
        testDictionaryPrivacyAndPerformanceBoundary()
        testDictionaryTransportIsolation()
        testLearningStoreProjection()
        testAutoVocabProjection()
        testManualConfigProjection()
        testDictionaryRepositoryMigration()
        testDictionaryRepositoryCRUD()
        testDictionaryRepositoryRemoteMerge()
        testDictionaryRepositoryCapturesLearning()
        testDictionarySyncAvailabilityAndPublish()
        testDictionarySyncMergeAndCorruption()
        testDictionarySyncAccountBoundary()
        testDictionarySyncDebouncesChanges()
        testDictionarySettingsLogic()
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

    private static func testDictionaryPrivacyAndPerformanceBoundary() {
        let fixture = DictionaryRepositoryFixture()
        let sentinels = [
            "SECRET_TRANSCRIPT_SENTINEL", "SECRET_AUDIO_PATH_SENTINEL",
            "SECRET_SCREEN_CONTEXT_SENTINEL", "SECRET_PENDING_COUNT_SENTINEL",
            "SECRET_CANDIDATE_SENTINEL", "SECRET_CHECKPOINT_SENTINEL",
            "SECRET_MODEL_SENTINEL",
        ]
        try! JSONSerialization.data(withJSONObject: [
            "stt_model": sentinels[6],
            "transcript": sentinels[0],
            "audio_path": sentinels[1],
            "screen_context": sentinels[2],
            "vocabulary": ["PrivateBoundaryTerm"],
            "replacements": ["private boundary": "PrivateBoundaryTerm"],
        ]).write(to: fixture.config)
        try! JSONSerialization.data(withJSONObject: [
            "replacements": ["velor": "Velora"],
            "vocabulary": ["Velora"],
            "counts": [sentinels[3]: 1],
        ]).write(to: fixture.learned)
        try! JSONSerialization.data(withJSONObject: [
            "version": 1,
            "checkpoint_id": sentinels[5],
            "terms": ["ConfirmedAutoTerm"],
            "candidates": [sentinels[4]: ["count": 1]],
        ]).write(to: fixture.auto)

        let repository = DictionaryRepository(
            stateURL: fixture.state,
            configURL: fixture.config,
            learnedURL: fixture.learned,
            autoURL: fixture.auto,
            deviceID: "privacy-mac",
            now: { Date(timeIntervalSince1970: 100) })
        let exported = try! repository.exportData()
        let json = String(decoding: exported, as: UTF8.self)
        for sentinel in sentinels {
            expect(!json.contains(sentinel), "cloud payload excludes local sentinel \(sentinel)")
        }
        let root = try! JSONSerialization.jsonObject(with: exported) as! [String: Any]
        expect(Set(root.keys) == ["schema_version", "entries", "clear_generations"],
               "cloud payload root is an explicit allow-list")
        let allowedEntryKeys: Set<String> = [
            "logical_key", "kind", "write_as", "heard_as", "epoch", "revision",
            "generation", "modified_at", "device_id", "deleted",
        ]
        let entryKeys = (root["entries"] as? [[String: Any]] ?? [])
            .reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        expect(entryKeys.isSubset(of: allowedEntryKeys),
               "cloud dictionary entries contain only portable merge fields")

        for url in [fixture.state, fixture.config, fixture.learned, fixture.auto] {
            let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            expect(permissions == 0o600, "local dictionary file is owner-readable only: \(url.lastPathComponent)")
        }
        fixture.remove()

        let maximumFixture = DictionaryRepositoryFixture()
        let entries = (0..<DictionaryDocument.maximumEntries).map { index in
            try! DictionaryEntry.manual(
                writeAs: String(format: "Term%04d", index),
                deviceID: "benchmark-mac",
                at: Date(timeIntervalSince1970: Double(index)))
        }
        try! DictionaryDocument(entries: entries).encoded().write(to: maximumFixture.state)
        let launchStart = ProcessInfo.processInfo.systemUptime
        let maximumRepository = DictionaryRepository(
            stateURL: maximumFixture.state,
            configURL: maximumFixture.config,
            learnedURL: maximumFixture.learned,
            autoURL: maximumFixture.auto,
            deviceID: "benchmark-mac")
        let launchDuration = ProcessInfo.processInfo.systemUptime - launchStart
        let mutationStart = ProcessInfo.processInfo.systemUptime
        try! maximumRepository.update(id: entries[0].logicalKey, writeAs: "TERM0000")
        let mutationDuration = ProcessInfo.processInfo.systemUptime - mutationStart
        print(String(format: "dictionary benchmark — launch %.3fs, mutation %.3fs (%d entries)",
                     launchDuration, mutationDuration, DictionaryDocument.maximumEntries))
        expect(maximumRepository.rows.count == DictionaryDocument.maximumEntries,
               "maximum-size dictionary projects every active entry")
        expect(launchDuration < 5 && mutationDuration < 5,
               "maximum-size migration and mutation remain bounded")
        do {
            _ = try maximumRepository.add(writeAs: "OverflowTerm")
            expect(false, "repository refuses to persist a dictionary it cannot reload")
        } catch {
            expect(true, "repository refuses to persist a dictionary it cannot reload")
        }
        expect(maximumRepository.rows.count == DictionaryDocument.maximumEntries,
               "oversized mutation leaves the last valid dictionary active")
        maximumFixture.remove()
    }

    private static func testDictionaryTransportIsolation() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-transport-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var providerRanOnMain = true
        var callbackRanOnMain = false
        var completed = false
        let transport = ICloudDocumentsDictionaryTransport(
            containerURLProvider: {
                providerRanOnMain = Thread.isMainThread
                return directory
            },
            identityTokenProvider: { "test-account" })
        transport.write(Data("portable".utf8), resolvingConflicts: false) { result in
            if case .failure = result {
                expect(false, "fixture iCloud transport write succeeds")
            }
            callbackRanOnMain = Thread.isMainThread
            completed = true
        }
        let deadline = Date().addingTimeInterval(2)
        while !completed && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        expect(completed, "iCloud transport completes without blocking the caller")
        expect(!providerRanOnMain, "iCloud container lookup and file coordination run off-main")
        expect(callbackRanOnMain, "iCloud transport returns observable state to the main queue")
        let document = directory
            .appendingPathComponent("Documents/Personal Dictionary")
            .appendingPathComponent(ICloudDocumentsDictionaryTransport.fileName)
        let attributes = try! FileManager.default.attributesOfItem(atPath: document.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        expect(permissions == 0o600, "local iCloud document copy is owner-readable only")
        try? FileManager.default.removeItem(at: directory)
    }

    private static func testLearningStoreProjection() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-learned-projection-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("learned.json")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let seed: [String: Any] = [
            "replacements": ["valoraa": "Velora"],
            "soft_replacements": ["lung": "Airlearn"],
            "vocabulary": ["Velora", "Airlearn", "Standalone++"],
            "counts": ["pending→Pending": 1],
        ]
        try! JSONSerialization.data(withJSONObject: seed).write(to: url)
        let store = LearningStore(url: url)
        let portable = store.portableSnapshot()
        expect(portable.replacements["valoraa"] == "Velora", "learned snapshot keeps hard corrections")
        expect(portable.softReplacements["lung"] == "Airlearn", "learned snapshot keeps soft corrections")
        expect(portable.standaloneVocabulary == ["Standalone++"],
               "learned snapshot separates standalone vocabulary")
        let portableJSON = String(decoding: try! JSONEncoder().encode(portable), as: UTF8.self)
        expect(!portableJSON.contains("counts") && !portableJSON.contains("pending"),
               "portable learned snapshot excludes pending confirmation counts")

        let incoming = LearningStore.PortableSnapshot(
            replacements: ["velorra": "Velora AI"],
            softReplacements: ["cloud": "iCloud++"],
            standaloneVocabulary: ["node.js"])
        store.applyPortableSnapshot(incoming)
        let afterApply = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        expect((afterApply["counts"] as? [String: Int])?["pending→Pending"] == 1,
               "applying portable learning preserves local pending counts")
        expect(Set(afterApply["vocabulary"] as? [String] ?? []).isSuperset(of: ["Velora AI", "iCloud++", "node.js"]),
               "applying portable learning rebuilds correction and standalone vocabulary")

        store.clearCorrections()
        let afterClear = store.portableSnapshot()
        expect(afterClear.replacements.isEmpty && afterClear.softReplacements.isEmpty,
               "forget learned corrections clears both correction tiers")
        expect(afterClear.standaloneVocabulary == ["node.js"],
               "forget learned corrections preserves standalone vocabulary")

        expect((try? store.addStandaloneVocabulary("C++")) == true,
               "standalone vocabulary can be added directly")
        expect(store.exportData().map { String(decoding: $0, as: UTF8.self).contains("C++") } == true,
               "vocabulary-only dictionaries remain exportable")
        store.removeStandaloneVocabulary("C++")
        expect(!store.portableSnapshot().standaloneVocabulary.contains("C++"),
               "standalone vocabulary can be removed directly")

        let malformed: [String: Any] = [
            "replacements": ["bad\nkey": "Injected", "valid": String(repeating: "x", count: 61)],
            "vocabulary": ["also\nbad", String(repeating: "y", count: 61)],
        ]
        let result = store.importData(try! JSONSerialization.data(withJSONObject: malformed))
        expect(result == nil || (result?.corrections == 0 && result?.vocabulary == 0),
               "dictionary import rejects malformed prompt-active strings")
        expect(!String(decoding: store.exportData()!, as: UTF8.self).contains("Injected"),
               "malformed imported correction never reaches the prompt store")
        try? FileManager.default.removeItem(at: dir)
    }

    private static func testAutoVocabProjection() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-auto-projection-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("auto_learned.json")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let seed: [String: Any] = [
            "version": 1,
            "checkpoint_id": 42,
            "terms": ["Velora"],
            "banned": ["OldTerm"],
            "candidates": ["Candidate": ["count": 1]],
            "future_engine_key": "preserve-me",
        ]
        try! JSONSerialization.data(withJSONObject: seed).write(to: url)
        let store = AutoVocabStore(url: url)
        expect(store.portableSnapshot() == AutoVocabStore.PortableSnapshot(
            terms: ["Velora"], banned: ["OldTerm"]),
            "auto snapshot contains only promoted terms and bans")
        store.applyPortableSnapshot(.init(terms: ["RemoteTerm"], banned: ["OldTerm"]))
        let root = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        expect((root["checkpoint_id"] as? Int) == 42, "auto apply preserves miner checkpoint")
        expect((root["candidates"] as? [String: Any])?["Candidate"] != nil,
               "auto apply preserves miner candidates")
        expect((root["future_engine_key"] as? String) == "preserve-me",
               "auto apply preserves unknown engine keys")
        expect(Set(root["terms"] as? [String] ?? []) == ["Velora", "RemoteTerm"],
               "auto apply unions promoted terms without dropping a concurrent miner term")
        try? FileManager.default.removeItem(at: dir)
    }

    private static func testManualConfigProjection() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-config-projection-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("config.json")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let seed: [String: Any] = [
            "stt_model": "keep-model",
            "cleanup": false,
            "vocabulary": ["Old"],
            "replacements": ["old": "Old"],
            "future_engine_key": ["nested": true],
        ]
        try! JSONSerialization.data(withJSONObject: seed).write(to: url)
        let initial = AppConfig.manualDictionarySnapshot(at: url)
        expect(initial.vocabulary == ["Old"] && initial.replacements["old"] == "Old",
               "manual config snapshot reads only vocabulary and replacements")
        let applied = AppConfig.applyManualDictionary(
            .init(vocabulary: ["node.js"], replacements: ["node js": "node.js"]),
            at: url)
        expect(applied, "manual config projection writes atomically")
        let root = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        expect((root["stt_model"] as? String) == "keep-model" && (root["cleanup"] as? Bool) == false,
               "manual config projection preserves current engine settings")
        expect((root["future_engine_key"] as? [String: Bool])?["nested"] == true,
               "manual config projection preserves unknown nested keys")
        expect((root["vocabulary"] as? [String]) == ["node.js"],
               "manual config projection replaces only manual vocabulary")
        try? FileManager.default.removeItem(at: dir)
    }

    private struct DictionaryRepositoryFixture {
        let directory: URL
        let state: URL
        let config: URL
        let learned: URL
        let auto: URL

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("velora-repository-\(UUID().uuidString)")
            state = directory.appendingPathComponent("dictionary_sync.json")
            config = directory.appendingPathComponent("config.json")
            learned = directory.appendingPathComponent("learned.json")
            auto = directory.appendingPathComponent("auto_learned.json")
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private static func testDictionaryRepositoryMigration() {
        let fixture = DictionaryRepositoryFixture()
        try! JSONSerialization.data(withJSONObject: [
            "stt_model": "keep-me",
            "vocabulary": ["ManualLegacy"],
            "replacements": ["legacy heard": "LegacyName"],
        ]).write(to: fixture.config)
        try! JSONSerialization.data(withJSONObject: [
            "replacements": ["valoraa": "Velora"],
            "soft_replacements": ["lung": "Airlearn"],
            "vocabulary": ["Velora", "Airlearn", "ImportedName"],
            "counts": ["pending→Pending": 1],
        ]).write(to: fixture.learned)
        try! JSONSerialization.data(withJSONObject: [
            "version": 1,
            "checkpoint_id": 9,
            "terms": ["AutoName"],
            "banned": ["OldAutoName"],
            "candidates": ["Candidate": ["count": 1]],
        ]).write(to: fixture.auto)

        let repository = DictionaryRepository(
            stateURL: fixture.state,
            configURL: fixture.config,
            learnedURL: fixture.learned,
            autoURL: fixture.auto,
            deviceID: "mac-a",
            now: { Date(timeIntervalSince1970: 100) })
        expect(FileManager.default.fileExists(atPath: fixture.state.path),
               "first launch persists a canonical dictionary document")
        expect(Set(repository.rows.map(\.writeAs)).isSuperset(of: [
            "ManualLegacy", "LegacyName", "Velora", "Airlearn", "ImportedName", "AutoName",
        ]), "migration preserves manual, learned, imported, and promoted vocabulary")
        expect(repository.rows.first(where: { $0.writeAs == "ImportedName" })?.source == .added,
               "standalone imported vocabulary migrates as an explicit added term")
        expect(repository.rows.first(where: { $0.writeAs == "Velora" })?.source == .learned,
               "edit-learned correction keeps its learned source")
        expect(repository.rows.first(where: { $0.writeAs == "AutoName" })?.source == .automatic,
               "promoted miner vocabulary keeps its automatic source")

        let second = DictionaryRepository(
            stateURL: fixture.state,
            configURL: fixture.config,
            learnedURL: fixture.learned,
            autoURL: fixture.auto,
            deviceID: "mac-a",
            now: { Date(timeIntervalSince1970: 200) })
        expect(second.rows.count == repository.rows.count,
               "migration is idempotent after canonical state exists")
        let learnedRoot = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.learned)) as! [String: Any]
        expect((learnedRoot["counts"] as? [String: Int])?["pending→Pending"] == 1,
               "migration projection preserves local pending correction counts")
        let autoRoot = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.auto)) as! [String: Any]
        expect((autoRoot["checkpoint_id"] as? Int) == 9
               && (autoRoot["candidates"] as? [String: Any])?["Candidate"] != nil,
               "migration projection preserves device-local miner state")
        fixture.remove()
    }

    private static func testDictionaryRepositoryCRUD() {
        let fixture = DictionaryRepositoryFixture()
        var reloads = 0
        var stateExistedAtReload = false
        let repository = DictionaryRepository(
            stateURL: fixture.state,
            configURL: fixture.config,
            learnedURL: fixture.learned,
            autoURL: fixture.auto,
            deviceID: "mac-a",
            now: { Date(timeIntervalSince1970: Double(100 + reloads)) },
            reload: {
                reloads += 1
                stateExistedAtReload = FileManager.default.fileExists(atPath: fixture.state.path)
            })
        reloads = 0
        stateExistedAtReload = false

        let replacement = try! repository.add(writeAs: "Airlearn", heardAs: "air learn")
        expect(reloads == 1 && stateExistedAtReload,
               "repository persists and projects before requesting one engine reload")
        let config = AppConfig.manualDictionarySnapshot(at: fixture.config)
        expect(config.replacements["air learn"] == "Airlearn"
               && config.vocabulary.contains("Airlearn"),
               "heard-as entry immediately projects replacement and glossary term")

        try! repository.update(
            id: replacement.id, writeAs: "Airlearn AI", heardAs: "air learn")
        expect(repository.rows.first(where: { $0.id == replacement.id })?.writeAs == "Airlearn AI",
               "editing a manual rule updates the stable heard-as entry")
        do {
            _ = try repository.add(writeAs: "Airline", heardAs: "air learn")
            expect(false, "adding a conflicting heard-as rule requires an explicit decision")
        } catch {
            expect(error.localizedDescription.contains("Airlearn AI"),
                   "heard-as collision identifies the existing output")
        }
        do {
            _ = try repository.add(writeAs: "Airlearn AI", heardAs: "air learn")
            expect(false, "adding an exact duplicate reports that it already exists")
        } catch {
            expect(error.localizedDescription.localizedCaseInsensitiveContains("already"),
                   "exact duplicate has actionable messaging")
        }
        try! repository.remove(id: replacement.id)
        expect(repository.rows.first(where: { $0.id == replacement.id }) == nil,
               "deleting an entry removes it from the active dictionary")
        let persisted = try! DictionaryDocument.decode(Data(contentsOf: fixture.state))
        expect(persisted.entries.contains(where: { $0.logicalKey == replacement.id && $0.deleted }),
               "deleting an entry persists a tombstone")

        _ = try! repository.add(writeAs: "node.js")
        let firstTerm = try! repository.add(writeAs: "FirstTerm")
        let secondTerm = try! repository.add(writeAs: "SecondTerm")
        do {
            try repository.update(id: secondTerm.id, writeAs: "FirstTerm")
            expect(false, "editing into an existing logical key reports a collision")
        } catch {
            expect(error.localizedDescription.localizedCaseInsensitiveContains("already"),
                   "edit collision identifies the existing dictionary entry")
        }
        expect(repository.rows.contains(where: { $0.id == firstTerm.id })
               && repository.rows.contains(where: { $0.id == secondTerm.id }),
               "failed edit collision leaves both original entries active")
        let exported = try! repository.exportData()
        expect(String(decoding: exported, as: UTF8.self).contains("node.js"),
               "complete repository export includes vocabulary-only entries")
        fixture.remove()

        let failureFixture = DictionaryRepositoryFixture()
        let stateDirectory = failureFixture.directory.appendingPathComponent("sync")
        let failureState = stateDirectory.appendingPathComponent("dictionary.json")
        let failureRepository = DictionaryRepository(
            stateURL: failureState,
            configURL: failureFixture.config,
            learnedURL: failureFixture.learned,
            autoURL: failureFixture.auto,
            deviceID: "mac-failure")
        let retained = try! failureRepository.add(writeAs: "RetainedAfterFailure")
        try! FileManager.default.removeItem(at: stateDirectory)
        try! Data("not a directory".utf8).write(to: stateDirectory)
        do {
            try failureRepository.remove(id: retained.id)
            expect(false, "failed removal reports its persistence error")
        } catch {
            expect(error.localizedDescription.contains("could not save"),
                   "failed removal returns actionable persistence messaging")
        }
        expect(failureRepository.rows.contains(where: { $0.id == retained.id }),
               "failed removal leaves the in-memory entry active")
        failureFixture.remove()
    }

    private static func testDictionaryRepositoryRemoteMerge() {
        let fixture = DictionaryRepositoryFixture()
        let repository = DictionaryRepository(
            stateURL: fixture.state,
            configURL: fixture.config,
            learnedURL: fixture.learned,
            autoURL: fixture.auto,
            deviceID: "mac-a",
            now: { Date(timeIntervalSince1970: 100) })
        _ = try! repository.add(writeAs: "LocalTerm")
        let beforeCorrupt = try! Data(contentsOf: fixture.state)
        expect(!repository.applyRemote(Data("not json".utf8)),
               "corrupt remote document is refused")
        expect(try! Data(contentsOf: fixture.state) == beforeCorrupt,
               "corrupt remote document leaves valid local state untouched")

        let remoteEntry = try! DictionaryEntry.manual(
            writeAs: "RemoteTerm", deviceID: "mac-b", at: Date(timeIntervalSince1970: 200))
        let remote = try! DictionaryDocument(entries: [remoteEntry]).encoded()
        expect(repository.applyRemote(remote), "valid remote document merges")
        expect(Set(repository.rows.map(\.writeAs)) == ["LocalTerm", "RemoteTerm"],
               "remote merge preserves independent local and remote additions")

        let importedFixture = DictionaryRepositoryFixture()
        let imported = DictionaryRepository(
            stateURL: importedFixture.state,
            configURL: importedFixture.config,
            learnedURL: importedFixture.learned,
            autoURL: importedFixture.auto,
            deviceID: "mac-c",
            now: { Date(timeIntervalSince1970: 300) })
        _ = try! imported.add(writeAs: "KeepLocalOnImport")
        let firstImport = try! imported.importData(try! repository.exportData())
        expect(firstImport == DictionaryImportResult(added: 2, keptExisting: 0),
               "complete portable dictionary reports imported entry counts")
        expect(Set(imported.rows.map(\.writeAs)) == [
            "KeepLocalOnImport", "LocalTerm", "RemoteTerm",
        ], "import adds portable entries without deleting local entries")

        var clearedRemote = DictionaryDocument().clearing(
            .manual, deviceID: "remote", at: Date(timeIntervalSince1970: 400))
        clearedRemote = clearedRemote.upserting(try! DictionaryEntry.manual(
            writeAs: "AfterRemoteClear", deviceID: "remote",
            at: Date(timeIntervalSince1970: 401),
            generation: clearedRemote.generation(for: .manual)))
        let clearedImport = try! imported.importData(try! clearedRemote.encoded())
        expect(clearedImport == DictionaryImportResult(added: 1, keptExisting: 0),
               "explicit import accepts active entries without importing clear generations")
        expect(Set(imported.rows.map(\.writeAs)).isSuperset(of: [
            "KeepLocalOnImport", "LocalTerm", "RemoteTerm", "AfterRemoteClear",
        ]), "imported clear generations never erase existing local entries")
        fixture.remove()
        importedFixture.remove()
    }

    private static func testDictionaryRepositoryCapturesLearning() {
        let fixture = DictionaryRepositoryFixture()
        var reloads = 0
        let repository = DictionaryRepository(
            stateURL: fixture.state,
            configURL: fixture.config,
            learnedURL: fixture.learned,
            autoURL: fixture.auto,
            deviceID: "mac-a",
            now: { Date(timeIntervalSince1970: 100) },
            reload: { reloads += 1 })
        let committed = repository.observeCorrections([("velor", "Velora")])
        expect(committed.count == 1, "repository owns edit-learning observation")
        expect(repository.rows.contains(where: {
            $0.writeAs == "Velora" && $0.source == .learned
        }), "committed edit-learning is captured while Settings is closed")
        expect(reloads == 1, "captured edit-learning projects before one reload")

        let learned = repository.rows.first(where: { $0.source == .learned })!
        try! repository.promoteLearned(
            id: learned.id, writeAs: learned.writeAs, heardAs: learned.heardAs!)
        expect(repository.rows.contains(where: {
            $0.writeAs == "Velora" && $0.source == .added
        }) && !repository.rows.contains(where: { $0.source == .learned }),
        "making a learned correction permanent atomically replaces its source")

        AutoVocabStore(url: fixture.auto).applyPortableSnapshot(
            .init(terms: ["BackgroundTerm"], banned: []))
        repository.captureAutoVocabulary()
        expect(repository.rows.contains(where: {
            $0.writeAs == "BackgroundTerm" && $0.source == .automatic
        }), "background miner promotion is captured while Settings is closed")
        expect(reloads == 3, "learned promotion and miner capture each request one reload")
        fixture.remove()
    }

    private final class FakeDictionarySyncTransport: DictionarySyncTransport {
        var identityResult: Result<String, DictionarySyncTransportError> = .success("account-a")
        var versionsResult: Result<[Data], DictionarySyncTransportError> = .success([])
        var writes: [Data] = []
        var reads = 0
        var resolvedConflicts = 0
        var observer: (() -> Void)?
        var deferIdentity = false
        var pendingIdentityCompletion: ((Result<String, DictionarySyncTransportError>) -> Void)?

        func fetchAccountIdentity(
            completion: @escaping (Result<String, DictionarySyncTransportError>) -> Void
        ) {
            if deferIdentity {
                pendingIdentityCompletion = completion
            } else {
                completion(identityResult)
            }
        }

        func readVersions(
            completion: @escaping (Result<[Data], DictionarySyncTransportError>) -> Void
        ) {
            reads += 1
            completion(versionsResult)
        }

        func write(
            _ data: Data,
            resolvingConflicts: Bool,
            completion: @escaping (Result<Void, DictionarySyncTransportError>) -> Void
        ) {
            writes.append(data)
            if resolvingConflicts { resolvedConflicts += 1 }
            completion(.success(()))
        }

        func startObserving(_ onChange: @escaping () -> Void) { observer = onChange }
        func stopObserving() { observer = nil }
        var folderURL: URL? { nil }
    }

    private static func makeSyncRepository(
        _ fixture: DictionaryRepositoryFixture,
        deviceID: String = "mac-a"
    ) -> DictionaryRepository {
        DictionaryRepository(
            stateURL: fixture.state,
            configURL: fixture.config,
            learnedURL: fixture.learned,
            autoURL: fixture.auto,
            deviceID: deviceID,
            now: { Date(timeIntervalSince1970: 100) })
    }

    private static func testDictionarySyncAvailabilityAndPublish() {
        let fixture = DictionaryRepositoryFixture()
        let repository = makeSyncRepository(fixture)
        _ = try! repository.add(writeAs: "LocalTerm")
        let identityURL = fixture.directory.appendingPathComponent("icloud_identity")

        let unavailable = FakeDictionarySyncTransport()
        unavailable.identityResult = .failure(.unavailable)
        let localOnly = ICloudDictionarySync(
            repository: repository, transport: unavailable, identityURL: identityURL)
        localOnly.start()
        expect(localOnly.status == .localOnly,
               "iCloud unavailable keeps dictionary local and usable")
        expect(unavailable.reads == 0 && unavailable.writes.isEmpty,
               "unavailable iCloud never starts cloud I/O")
        localOnly.stop()

        let available = FakeDictionarySyncTransport()
        let sync = ICloudDictionarySync(
            repository: repository, transport: available, identityURL: identityURL)
        sync.start()
        expect(sync.status == .synced, "empty iCloud publishes the local dictionary")
        expect(available.writes.count == 1,
               "initial empty cloud receives exactly one canonical document")
        let published = try! DictionaryDocument.decode(available.writes[0])
        expect(published.activeEntries.contains(where: { $0.writeAs == "LocalTerm" }),
               "published cloud document contains confirmed local entry")
        sync.stop()

        let waiting = FakeDictionarySyncTransport()
        waiting.versionsResult = .failure(.waitingForDownload)
        let waitingSync = ICloudDictionarySync(
            repository: repository, transport: waiting,
            identityURL: fixture.directory.appendingPathComponent("waiting_identity"))
        waitingSync.start()
        expect(waitingSync.status == .waitingForDownload,
               "partially downloaded iCloud document reports waiting")
        waitingSync.stop()
        fixture.remove()
    }

    private static func testDictionarySyncMergeAndCorruption() {
        let fixture = DictionaryRepositoryFixture()
        let repository = makeSyncRepository(fixture)
        _ = try! repository.add(writeAs: "LocalTerm")
        let remoteA = try! DictionaryDocument(entries: [
            try! DictionaryEntry.manual(
                writeAs: "RemoteA", deviceID: "mac-b", at: Date(timeIntervalSince1970: 200)),
        ]).encoded()
        let remoteB = try! DictionaryDocument(entries: [
            try! DictionaryEntry.manual(
                writeAs: "RemoteB", deviceID: "mac-c", at: Date(timeIntervalSince1970: 300)),
        ]).encoded()
        let transport = FakeDictionarySyncTransport()
        transport.versionsResult = .success([remoteA, remoteB])
        let sync = ICloudDictionarySync(
            repository: repository,
            transport: transport,
            identityURL: fixture.directory.appendingPathComponent("identity"))
        sync.start()
        expect(Set(repository.rows.map(\.writeAs)) == ["LocalTerm", "RemoteA", "RemoteB"],
               "all current and conflict versions merge with local additions")
        expect(transport.resolvedConflicts == 1,
               "canonical write resolves stale iCloud conflict versions")
        sync.stop()

        let corruptFixture = DictionaryRepositoryFixture()
        let corruptRepository = makeSyncRepository(corruptFixture)
        _ = try! corruptRepository.add(writeAs: "KeepLocal")
        let corrupt = FakeDictionarySyncTransport()
        corrupt.versionsResult = .success([Data("not json".utf8)])
        let corruptSync = ICloudDictionarySync(
            repository: corruptRepository,
            transport: corrupt,
            identityURL: corruptFixture.directory.appendingPathComponent("identity"))
        corruptSync.start()
        if case .error = corruptSync.status {
            expect(true, "corrupt cloud document surfaces an actionable error")
        } else {
            expect(false, "corrupt cloud document surfaces an actionable error")
        }
        expect(corruptRepository.rows.map(\.writeAs) == ["KeepLocal"] && corrupt.writes.isEmpty,
               "corrupt cloud content never replaces or republishes valid local state")
        corruptSync.stop()
        fixture.remove()
        corruptFixture.remove()
    }

    private static func testDictionarySyncAccountBoundary() {
        let fixture = DictionaryRepositoryFixture()
        let repository = makeSyncRepository(fixture)
        _ = try! repository.add(writeAs: "OldAccountLocal")
        let identityURL = fixture.directory.appendingPathComponent("identity")
        try! Data("account-old".utf8).write(to: identityURL)
        let cloud = FakeDictionarySyncTransport()
        cloud.identityResult = .success("account-new")
        let remote = try! DictionaryDocument(entries: [
            try! DictionaryEntry.manual(
                writeAs: "NewAccountCloud", deviceID: "mac-new",
                at: Date(timeIntervalSince1970: 200)),
        ]).encoded()
        cloud.versionsResult = .success([remote])
        let sync = ICloudDictionarySync(
            repository: repository, transport: cloud, identityURL: identityURL,
            debounceDelay: 0.01)
        sync.start()
        expect(sync.status == .accountChanged,
               "Apple Account identity change pauses automatic sync")
        expect(cloud.reads == 0 && cloud.writes.isEmpty,
               "account boundary prevents silent read, merge, or upload")

        cloud.deferIdentity = true
        cloud.observer?()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        expect(sync.status == .accountChanged,
               "cloud notifications cannot displace a pending account decision")
        sync.resolveAccountChange(.useCloud)
        expect(repository.rows.map(\.writeAs) == ["NewAccountCloud"],
               "use-cloud decision explicitly replaces old-account local names")
        expect(String(decoding: try! Data(contentsOf: identityURL), as: UTF8.self) == "account-new",
               "resolved account decision advances the stored identity")
        sync.stop()
        fixture.remove()
    }

    private static func testDictionarySyncDebouncesChanges() {
        let fixture = DictionaryRepositoryFixture()
        let repository = makeSyncRepository(fixture)
        let transport = FakeDictionarySyncTransport()
        let sync = ICloudDictionarySync(
            repository: repository,
            transport: transport,
            identityURL: fixture.directory.appendingPathComponent("identity"),
            debounceDelay: 0.02)
        sync.start()
        transport.reads = 0
        transport.writes = []
        transport.observer?()
        transport.observer?()
        transport.observer?()
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline && transport.reads == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        expect(transport.reads == 1 && transport.writes.count == 1,
               "bursty cloud notifications coalesce into one reconciliation")
        sync.stop()
        fixture.remove()
    }

    private static func testDictionarySettingsLogic() {
        let rows = [
            DictionaryRow(
                id: "1", writeAs: "Airlearn", heardAs: "air learn",
                source: .added, isSoftCorrection: false),
            DictionaryRow(
                id: "2", writeAs: "Sushil Kumar", heardAs: "social kumar",
                source: .learned, isSoftCorrection: true),
            DictionaryRow(
                id: "3", writeAs: "node.js", heardAs: nil,
                source: .automatic, isSoftCorrection: false),
        ]
        expect(DictionarySettingsLogic.filtered(rows, query: "AIR").map(\.id) == ["1"],
               "dictionary search matches written and heard forms case-insensitively")
        expect(DictionarySettingsLogic.filtered(rows, query: "learned").map(\.id) == ["2"],
               "dictionary search matches source labels")
        expect(DictionarySettingsLogic.filtered(rows, query: "").count == 3,
               "empty dictionary search shows every entry")

        let simple = try! DictionaryDraft(writeAs: "  node.js ", heardAs: " ").validated()
        expect(simple.writeAs == "node.js" && simple.heardAs == nil,
               "dictionary form keeps heard-as optional")
        let rule = try! DictionaryDraft(
            writeAs: "Airlearn", heardAs: " air learn ").validated()
        expect(rule.heardAs == "air learn", "dictionary form normalizes an explicit heard-as rule")
        expect(DictionaryDraft(writeAs: "Airlearn", heardAs: "the").riskWarning != nil,
               "common-word heard forms warn before deterministic replacement")
        do {
            _ = try DictionaryDraft(
                writeAs: String(repeating: "x", count: 61), heardAs: nil).validated()
            expect(false, "dictionary form enforces prompt-safe length")
        } catch {
            expect(true, "dictionary form enforces prompt-safe length")
        }

        expect(DictionarySyncPresentation(.synced).title == "Synced with iCloud",
               "synced status has concise truthful copy")
        expect(DictionarySyncPresentation(.localOnly).title
               == "Saved on this Mac — iCloud Drive is unavailable",
               "local-only status makes offline safety clear")
        expect(DictionarySyncPresentation(.accountChanged).needsAccountDecision,
               "account-change status exposes an explicit privacy decision")
        expect(DictionarySyncPresentation(.syncing).isWorking,
               "syncing status exposes in-progress state")
        expect(DictionarySyncPresentation(.waitingForDownload).isWorking,
               "download wait status exposes in-progress state")
        expect(DictionarySyncPresentation(.error("Cloud failed")).canRetry,
               "sync errors expose a retry action")
        expect(DictionarySyncPresentation(.idle).title == "Saved on this Mac",
               "idle status does not overclaim cloud sync")
        expect(!DictionarySyncPresentation(.localOnly).privacyDetail.hasPrefix("Synced"),
               "offline privacy detail does not claim a completed iCloud sync")
        expect(DictionarySyncPresentation(.accountChanged).privacyDetail.contains("paused"),
               "account-boundary copy states that cloud sync is paused")
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

        if case .vocabularyPromoted(let count) = EngineEvent.parse([
            "event": "vocabulary_promoted", "count": 3,
        ]) {
            expect(count == 3, "vocabulary promotion event carries only a count")
        } else {
            expect(false, "vocabulary promotion event must parse")
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
