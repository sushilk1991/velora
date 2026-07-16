import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit
import SQLite3

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

    @discardableResult
    private static func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
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
        testPreferencesDomainMigration()
        testDictionaryRepositoryMigration()
        testDictionaryRepositoryCRUD()
        testDictionaryRepositoryRemoteMerge()
        testDictionaryRepositoryCapturesLearning()
        testDictionaryRepositoryRelearnAfterClear()
        testDictionaryRepositoryProjectionFailure()
        testDictionaryAccountIdentityComparison()
        testDictionarySyncAvailabilityAndPublish()
        testDictionarySyncMergeAndCorruption()
        testDictionarySyncAccountBoundary()
        testDictionarySyncDebouncesChanges()
        testDictionarySyncSkipsSelfTriggeredRewrite()
        testDictionarySyncRequiresIdentityMarker()
        testDictionarySettingsLogic()
        testCorrectionDiff()
        testEventParsing()
        testOnboardingSetup()
        testKeyboardShortcutMapping()
        testModeCategories()
        testVoiceCommands()
        testStreak()
        testLongestStreak()
        testHistoryStoreMigration()
        testIntelligenceAggregates()
        if ProcessInfo.processInfo.environment["VELORA_PERF_SELFTEST"] == "1" {
            testIntelligencePerformance100K()
        }
        testQualityObservationMetrics()
        testMeetingStore()
        testMeetingAlertTokenSlot()
        testMeetingSystemAudioWarnings()
        testMeetingDetection()
        testMinutesSavedDefinition()
        testShareCardPrivacy()
        testControlProtocol()
        testControlRouter()
        testCLIParsing()
        testMCPProtocol()
        testLocalControlSocket()
        testHUDGeometry()
        testInsertionBoundary()
        testEmptyFinalFeedback()
        testClipboardStaging()
        print(failures == 0
            ? "selftest OK — \(checks) checks"
            : "selftest FAILED — \(failures)/\(checks) checks failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Bundle identifier migration

    private static func testPreferencesDomainMigration() {
        let suffix = UUID().uuidString
        let sourceDomain = "com.velora.selftest.legacy.\(suffix)"
        let destinationDomain = "com.velora.selftest.current.\(suffix)"
        let coordinatorDomain = "com.velora.selftest.coordinator.\(suffix)"
        let source = UserDefaults(suiteName: sourceDomain)!
        let destination = UserDefaults(suiteName: destinationDomain)!
        let coordinator = UserDefaults(suiteName: coordinatorDomain)!
        defer {
            source.removePersistentDomain(forName: sourceDomain)
            destination.removePersistentDomain(forName: destinationDomain)
            coordinator.removePersistentDomain(forName: coordinatorDomain)
        }

        source.set(true, forKey: "velora.onboardingComplete")
        source.set("legacy-device", forKey: "velora.dictionary.deviceID")
        source.set("must-not-migrate", forKey: "unrelated.setting")
        destination.set("current-device", forKey: "velora.dictionary.deviceID")

        let copied = PreferencesDomainMigration.run(
            sourceDomain: sourceDomain,
            destinationDomain: destinationDomain,
            destination: coordinator)
        expect(copied == 1, "bundle migration copies only missing Velora preferences")
        expect(destination.bool(forKey: "velora.onboardingComplete"),
               "bundle migration preserves onboarding completion")
        expect(destination.string(forKey: "velora.dictionary.deviceID") == "current-device",
               "bundle migration never overwrites current-domain preferences")
        expect(destination.object(forKey: "unrelated.setting") == nil,
               "bundle migration ignores keys outside the Velora namespace")

        source.set("late-change", forKey: "velora.hotkeyMode")
        expect(PreferencesDomainMigration.run(
            sourceDomain: sourceDomain,
            destinationDomain: destinationDomain,
            destination: coordinator) == 0,
               "bundle migration runs only once")
        expect(destination.string(forKey: "velora.hotkeyMode") == nil,
               "a completed migration does not replay stale legacy settings")
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

        let clearedAt = Date(timeIntervalSince1970: 300)
        let manualBeforeClear = try! DictionaryEntry.manual(
            writeAs: "BeforeClear", deviceID: "mac-a",
            at: Date(timeIntervalSince1970: 250))
        let manualAfterClear = try! DictionaryEntry.manual(
            writeAs: "OfflineAfterClear", deviceID: "mac-b",
            at: Date(timeIntervalSince1970: 350))
        let manualClear = DictionaryDocument(entries: [manualBeforeClear]).clearing(
            .manual, deviceID: "mac-a", at: clearedAt)
        let offlineIntentMerge = manualClear.merged(
            with: DictionaryDocument(entries: [manualBeforeClear, manualAfterClear]))
        expect(!offlineIntentMerge.activeEntries.contains(where: {
            $0.writeAs == "BeforeClear"
        }), "clear timestamp keeps the pre-clear offline snapshot deleted")
        expect(offlineIntentMerge.activeEntries.contains(where: {
            $0.writeAs == "OfflineAfterClear"
        }), "an explicit offline add made after clear survives reconciliation")
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
        expect(Set(root.keys) == [
            "schema_version", "entries", "clear_generations", "clear_modified_at",
        ],
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

        let blockedParent = dir.appendingPathComponent("blocked-learned")
        try! Data("not a directory".utf8).write(to: blockedParent)
        let blockedStore = LearningStore(url: blockedParent.appendingPathComponent("learned.json"))
        expect(!blockedStore.applyPortableSnapshot(.init(
            replacements: ["veloraa": "Velora"],
            softReplacements: [:],
            standaloneVocabulary: [])),
            "learning projection reports a persistence failure")
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

        let blockedParent = dir.appendingPathComponent("blocked-auto")
        try! Data("not a directory".utf8).write(to: blockedParent)
        let blockedStore = AutoVocabStore(
            url: blockedParent.appendingPathComponent("auto_learned.json"))
        expect(!blockedStore.applyPortableSnapshot(.init(
            terms: ["ShouldNotPersist"], banned: [])),
            "auto-vocabulary projection reports a lock or persistence failure")
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
        let userExport = try! repository.exportData()
        expect(!String(decoding: userExport, as: UTF8.self).contains("Airlearn AI"),
               "user export excludes deleted terms and corrections")
        expect(try! DictionaryDocument.decode(userExport).entries.allSatisfy { !$0.deleted },
               "user export contains active dictionary entries only")

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

        let offlineFixture = DictionaryRepositoryFixture()
        let offlineAfterClear = try! DictionaryEntry.manual(
            writeAs: "OfflineAfterClear",
            deviceID: "offline-mac",
            at: Date(timeIntervalSince1970: 350))
        let offlineDocument = DictionaryDocument().clearing(
            .manual,
            deviceID: "online-mac",
            at: Date(timeIntervalSince1970: 300))
            .upserting(offlineAfterClear)
        try! offlineDocument.encoded().write(to: offlineFixture.state)
        let offlineRepository = DictionaryRepository(
            stateURL: offlineFixture.state,
            configURL: offlineFixture.config,
            learnedURL: offlineFixture.learned,
            autoURL: offlineFixture.auto,
            deviceID: "online-mac",
            now: { Date(timeIntervalSince1970: 400) })
        expect(offlineRepository.rows.map(\.writeAs) == ["OfflineAfterClear"],
               "post-clear offline entry is manageable in repository UI")
        do {
            try offlineRepository.remove(id: offlineAfterClear.logicalKey)
            expect(offlineRepository.rows.isEmpty,
                   "post-clear offline entry can be removed normally")
        } catch {
            expect(false, "post-clear offline entry can be removed normally")
        }
        offlineFixture.remove()

        let legacyExport = try! JSONSerialization.data(withJSONObject: [
            "replacements": ["legacy heard": "LegacyName"],
            "soft_replacements": ["cloud": "iCloud++"],
            "vocabulary": ["LegacyStandalone"],
        ])
        do {
            let legacyResult = try imported.importData(legacyExport)
            expect(legacyResult.added == 3,
                   "pre-Personal-Dictionary exports remain importable")
            expect(Set(imported.rows.map(\.writeAs)).isSuperset(of: [
                "LegacyName", "iCloud++", "LegacyStandalone",
            ]), "legacy corrections and standalone vocabulary survive import")
        } catch {
            expect(false, "pre-Personal-Dictionary exports remain importable")
        }
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

    private static func testDictionaryRepositoryRelearnAfterClear() {
        let fixture = DictionaryRepositoryFixture()
        let repository = makeSyncRepository(fixture)
        expect(repository.observeCorrections([("velor", "Velora")]).count == 1,
               "fixture correction is learned")
        try! repository.clear(.learned)
        expect(!repository.rows.contains(where: { $0.source == .learned }),
               "forget all hides prior learned corrections")
        expect(repository.observeCorrections([("velor", "Velora")]).count == 1,
               "the same correction can be learned again after forget all")
        expect(repository.rows.contains(where: {
            $0.writeAs == "Velora" && $0.source == .learned
        }), "re-learned correction advances past the clear generation")
        let reloaded = makeSyncRepository(fixture, deviceID: "mac-reloaded")
        expect(reloaded.rows.contains(where: {
            $0.writeAs == "Velora" && $0.source == .learned
        }), "re-learned correction survives projection and relaunch")
        fixture.remove()
    }

    private static func testDictionaryRepositoryProjectionFailure() {
        let fixture = DictionaryRepositoryFixture()
        let blockedParent = fixture.directory.appendingPathComponent("blocked-config")
        try! Data("not a directory".utf8).write(to: blockedParent)
        let repository = DictionaryRepository(
            stateURL: fixture.state,
            configURL: blockedParent.appendingPathComponent("config.json"),
            learnedURL: fixture.learned,
            autoURL: fixture.auto,
            deviceID: "projection-failure")
        do {
            _ = try repository.add(writeAs: "SavedDespiteProjectionFailure")
            expect(false, "projection failure is surfaced to the caller")
        } catch {
            expect(error.localizedDescription.contains("speech engine"),
                   "projection failure explains that canonical state was saved")
        }
        expect(repository.rows.contains(where: { $0.writeAs == "SavedDespiteProjectionFailure" }),
               "UI state follows the canonical document after projection failure")
        let persisted = try! DictionaryDocument.decode(Data(contentsOf: fixture.state))
        expect(persisted.activeEntries.contains(where: {
            $0.writeAs == "SavedDespiteProjectionFailure"
        }), "projection failure keeps a valid canonical document on disk")
        fixture.remove()

        let syncFixture = DictionaryRepositoryFixture()
        let blockedSyncParent = syncFixture.directory.appendingPathComponent("blocked-config")
        try! Data("not a directory".utf8).write(to: blockedSyncParent)
        let syncRepository = DictionaryRepository(
            stateURL: syncFixture.state,
            configURL: blockedSyncParent.appendingPathComponent("config.json"),
            learnedURL: syncFixture.learned,
            autoURL: syncFixture.auto,
            deviceID: "sync-projection-failure")
        let remoteEntry = try! DictionaryEntry.manual(
            writeAs: "CloudTermSavedLocally",
            deviceID: "remote",
            at: Date(timeIntervalSince1970: 200))
        let transport = FakeDictionarySyncTransport()
        transport.versionsResult = .success([
            try! DictionaryDocument(entries: [remoteEntry]).encoded(),
        ])
        let sync = ICloudDictionarySync(
            repository: syncRepository,
            transport: transport,
            identityURL: syncFixture.directory.appendingPathComponent("identity"))
        sync.start()
        _ = waitUntil {
            if case .error = sync.status { return true }
            return false
        }
        if case .error(let message) = sync.status {
            expect(message.contains("speech engine") && !message.contains("unreadable"),
                   "sync reports projection failure instead of blaming valid cloud data")
        } else {
            expect(false, "sync surfaces a projection failure")
        }
        let syncedState = try! DictionaryDocument.decode(Data(contentsOf: syncFixture.state))
        expect(syncedState.activeEntries.contains(where: {
            $0.writeAs == "CloudTermSavedLocally"
        }), "sync projection failure still preserves the merged canonical state")
        expect(transport.writes.isEmpty,
               "sync does not publish until the local speech-engine projection succeeds")

        try! FileManager.default.removeItem(at: blockedSyncParent)
        try! FileManager.default.createDirectory(
            at: blockedSyncParent, withIntermediateDirectories: true)
        sync.syncNow()
        _ = waitUntil { sync.status == .synced }
        let projected = AppConfig.manualDictionarySnapshot(
            at: blockedSyncParent.appendingPathComponent("config.json"))
        expect(sync.status == .synced && projected.vocabulary.contains("CloudTermSavedLocally"),
               "retry reprojects durable canonical state before reporting synced")
        sync.stop()
        syncFixture.remove()
    }

    private final class FakeDictionarySyncTransport: DictionarySyncTransport {
        var identityResult: Result<DictionaryAccountIdentity, DictionarySyncTransportError> =
            .success(DictionaryAccountIdentity.fixture("account-a"))
        var versionsResult: Result<[Data], DictionarySyncTransportError> = .success([])
        var writes: [Data] = []
        var reads = 0
        var resolvedConflicts = 0
        var observer: (() -> Void)?
        var deferIdentity = false
        var pendingIdentityCompletion:
            ((Result<DictionaryAccountIdentity, DictionarySyncTransportError>) -> Void)?
        var persistWritesAsVersion = false
        var notifyAfterWrite = false

        func fetchAccountIdentity(
            completion: @escaping (
                Result<DictionaryAccountIdentity, DictionarySyncTransportError>
            ) -> Void
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
            if persistWritesAsVersion { versionsResult = .success([data]) }
            completion(.success(()))
            if notifyAfterWrite { observer?() }
        }

        func startObserving(_ onChange: @escaping () -> Void) { observer = onChange }
        func stopObserving() { observer = nil }
        var folderURL: URL? { nil }
    }

    private static func testDictionaryAccountIdentityComparison() {
        let binary = DictionaryAccountIdentity.fixture("same-account", format: .binary)
        let xml = DictionaryAccountIdentity.fixture("same-account", format: .xml)
        expect(binary.archivedToken != xml.archivedToken,
               "identity fixture proves archive bytes can differ for the same account token")
        expect(binary.matches(storedData: xml.archivedToken),
               "iCloud identity compares unarchived tokens rather than archive bytes")
        let legacyBase64 = Data(xml.archivedToken.base64EncodedString().utf8)
        expect(binary.matches(storedData: legacyBase64),
               "existing base64 identity markers migrate without a false account change")
        let other = DictionaryAccountIdentity.fixture("different-account")
        expect(!binary.matches(storedData: other.archivedToken),
               "different iCloud identity tokens remain isolated")
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
        _ = waitUntil { available.writes.count == 1 && sync.status == .synced }
        expect(sync.status == .synced, "empty iCloud publishes the local dictionary")
        expect(available.writes.count == 1,
               "initial empty cloud receives exactly one canonical document")
        if let payload = available.writes.first {
            let published = try! DictionaryDocument.decode(payload)
            expect(published.activeEntries.contains(where: { $0.writeAs == "LocalTerm" }),
                   "published cloud document contains confirmed local entry")
        } else {
            expect(false, "published cloud document contains confirmed local entry")
        }
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
        _ = waitUntil { transport.resolvedConflicts == 1 && sync.status == .synced }
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
        _ = waitUntil {
            if case .error = corruptSync.status { return true }
            return false
        }
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
        try! JSONSerialization.data(withJSONObject: [
            "counts": ["old pending→Old Pending": 1],
        ]).write(to: fixture.learned)
        try! JSONSerialization.data(withJSONObject: [
            "version": 1,
            "checkpoint_id": 7,
            "terms": ["OldAccountAutoTerm"],
            "candidates": ["OldAccountCandidate": ["count": 1]],
        ]).write(to: fixture.auto)
        let repository = makeSyncRepository(fixture)
        _ = try! repository.add(writeAs: "OldAccountLocal")
        let identityURL = fixture.directory.appendingPathComponent("identity")
        try! DictionaryAccountIdentity.fixture("account-old").archivedToken.write(to: identityURL)
        let cloud = FakeDictionarySyncTransport()
        let newIdentity = DictionaryAccountIdentity.fixture("account-new")
        cloud.identityResult = .success(newIdentity)
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
        _ = waitUntil { sync.status == .synced }
        expect(repository.rows.map(\.writeAs) == ["NewAccountCloud"],
               "use-cloud decision explicitly replaces old-account local names")
        let learnedRoot = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.learned)) as! [String: Any]
        expect((learnedRoot["counts"] as? [String: Int])?.isEmpty == true,
               "account replacement clears old-account pending corrections")
        let autoRoot = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.auto)) as! [String: Any]
        expect((autoRoot["terms"] as? [String])?.contains("OldAccountAutoTerm") == false,
               "account replacement removes old-account auto vocabulary")
        expect((autoRoot["candidates"] as? [String: Any])?.isEmpty == true,
               "account replacement clears old-account miner candidates")
        expect(newIdentity.matches(storedData: try! Data(contentsOf: identityURL)),
               "resolved account decision advances the stored identity")
        sync.stop()
        fixture.remove()

        let failureFixture = DictionaryRepositoryFixture()
        let learnedParent = failureFixture.directory.appendingPathComponent("account-learning")
        let learnedURL = learnedParent.appendingPathComponent("learned.json")
        try! FileManager.default.createDirectory(
            at: learnedParent, withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: [
            "counts": ["prior pending→Prior Pending": 1],
        ]).write(to: learnedURL)
        let failureRepository = DictionaryRepository(
            stateURL: failureFixture.state,
            configURL: failureFixture.config,
            learnedURL: learnedURL,
            autoURL: failureFixture.auto,
            deviceID: "account-write-failure")
        let failureIdentityURL = failureFixture.directory.appendingPathComponent("identity")
        let oldIdentity = DictionaryAccountIdentity.fixture("failure-account-old")
        try! oldIdentity.archivedToken.write(to: failureIdentityURL)
        let failureCloud = FakeDictionarySyncTransport()
        failureCloud.identityResult = .success(
            DictionaryAccountIdentity.fixture("failure-account-new"))
        failureCloud.versionsResult = .success([remote])
        let failureSync = ICloudDictionarySync(
            repository: failureRepository,
            transport: failureCloud,
            identityURL: failureIdentityURL)
        failureSync.start()
        expect(failureSync.status == .accountChanged,
               "account cleanup failure fixture reaches the explicit boundary")
        try! FileManager.default.removeItem(at: learnedParent)
        try! Data("not a directory".utf8).write(to: learnedParent)
        failureSync.resolveAccountChange(.useCloud)
        _ = waitUntil {
            if case .error = failureSync.status { return true }
            return failureSync.status == .synced
        }
        if case .error(let message) = failureSync.status {
            expect(message.contains("pending learning"),
                   "account switch explains why prior-account state could not be cleared")
        } else {
            expect(false, "account switch pauses when prior-account state is not durable")
        }
        expect(failureCloud.reads == 0 && failureCloud.writes.isEmpty,
               "failed prior-account cleanup prevents all new-account dictionary I/O")
        expect(oldIdentity.matches(storedData: try! Data(contentsOf: failureIdentityURL)),
               "failed prior-account cleanup does not advance the account marker")
        failureSync.stop()
        failureFixture.remove()
    }

    private static func testDictionarySyncSkipsSelfTriggeredRewrite() {
        let fixture = DictionaryRepositoryFixture()
        let repository = makeSyncRepository(fixture)
        _ = try! repository.add(writeAs: "LoopSafeTerm")
        let transport = FakeDictionarySyncTransport()
        transport.persistWritesAsVersion = true
        transport.notifyAfterWrite = true
        let sync = ICloudDictionarySync(
            repository: repository,
            transport: transport,
            identityURL: fixture.directory.appendingPathComponent("identity"),
            debounceDelay: 0.01)
        sync.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        expect(transport.writes.count == 1,
               "metadata notification from Velora's own write does not rewrite forever (writes: \(transport.writes.count))")
        expect(sync.status == .synced, "self-notification settles back to synced")
        sync.stop()
        fixture.remove()
    }

    private static func testDictionarySyncRequiresIdentityMarker() {
        let fixture = DictionaryRepositoryFixture()
        let repository = makeSyncRepository(fixture)
        _ = try! repository.add(writeAs: "LocalOnlyUntilIdentityIsSafe")
        let blockedParent = fixture.directory.appendingPathComponent("blocked-identity")
        try! Data("not a directory".utf8).write(to: blockedParent)
        let transport = FakeDictionarySyncTransport()
        let sync = ICloudDictionarySync(
            repository: repository,
            transport: transport,
            identityURL: blockedParent.appendingPathComponent("identity"))
        sync.start()
        if case .error = sync.status {
            expect(true, "unwritable identity marker pauses iCloud sync")
        } else {
            expect(false, "unwritable identity marker pauses iCloud sync")
        }
        expect(transport.reads == 0 && transport.writes.isEmpty,
               "iCloud is untouched until the account boundary is durable")
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
        _ = waitUntil { sync.status == .synced && transport.writes.count == 1 }
        transport.reads = 0
        transport.writes = []
        transport.observer?()
        transport.observer?()
        transport.observer?()
        _ = waitUntil { transport.reads == 1 && transport.writes.count == 1 }
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

        let done = EngineEvent.parse([
            "event": "transcribed", "path": "/a/b.m4a", "text": "notes",
            "mode": "Note", "duration_s": 12.3, "stt_ms": 1200,
        ])
        if case .transcribed(_, let path, let text, let mode, let duration, let ms) = done {
            expect(path == "/a/b.m4a" && text == "notes" && ms == 1200,
                   "transcribed parses")
            expect(mode == "Note" && abs(duration - 12.3) < 0.01,
                   "transcribed mode and duration parse")
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

    // MARK: - History store: migration, aggregates, quality, share card

    private static func withHistoryStore(_ body: (HistoryStore, URL) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-history-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.sqlite3")
        body(HistoryStore(url: url), url)
        try? FileManager.default.removeItem(at: dir)
    }

    /// A synthetic dictation `daysAgo` calendar days back. `final` defaults to
    /// `words` repeated tokens so SQL word counts are exact.
    private static func dictation(
        daysAgo: Int, words: Int, durationMs: Int = 5_000,
        app: String? = "TestApp", bundle: String? = "com.test.app",
        mode: String? = "Default", raw: String? = nil, final: String? = nil,
        session: String? = nil, sttMs: Int? = nil, cleanupMs: Int? = nil,
        cleanupApplied: Bool? = nil
    ) -> DictationRecord {
        let text = final ?? Array(repeating: "word", count: words).joined(separator: " ")
        return DictationRecord(
            timestamp: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!,
            bundleID: bundle, appName: app, raw: raw ?? text, final: text,
            mode: mode, durationMs: durationMs, cleanupMs: cleanupMs,
            audioPath: nil, sessionID: session, sttMs: sttMs,
            cleanupApplied: cleanupApplied)
    }

    private static func testLongestStreak() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        func day(_ offset: Int) -> String {
            formatter.string(from: Calendar.current.date(
                byAdding: .day, value: -offset, to: Date())!)
        }
        expect(HistoryStore.longestStreak(days: []) == 0, "no history → no longest streak")
        expect(HistoryStore.longestStreak(days: [day(0)]) == 1, "single day → 1")
        expect(HistoryStore.longestStreak(days: [day(0), day(1), day(3), day(4), day(5)]) == 3,
               "longest run wins over the current run")
        expect(HistoryStore.longestStreak(days: [day(5), day(6), day(7)]) == 3,
               "longest streak doesn't have to reach today")
        expect(HistoryStore.longestStreak(days: [day(0), day(2), day(4)]) == 1,
               "gaps everywhere → longest is 1")
    }

    private static func testHistoryStoreMigration() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-history-migration-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.sqlite3")

        // A database exactly as the oldest shipping build created it — before
        // audio_path and every Intelligence column existed.
        var handle: OpaquePointer?
        expect(sqlite3_open(url.path, &handle) == SQLITE_OK, "legacy fixture database opens")
        sqlite3_exec(handle, """
            CREATE TABLE dictations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                bundle_id TEXT,
                app_name TEXT,
                raw TEXT NOT NULL,
                final TEXT NOT NULL,
                mode TEXT,
                duration_ms INTEGER NOT NULL,
                cleanup_ms INTEGER
            );
            INSERT INTO dictations (ts, bundle_id, app_name, raw, final, mode, duration_ms, cleanup_ms)
            VALUES (strftime('%s', 'now') - 60, 'com.legacy.app', 'Legacy',
                    'legacy raw', 'legacy final words', 'Default', 4000, NULL);
            """, nil, nil, nil)
        sqlite3_close(handle)

        let store = HistoryStore(url: url)
        let migrated = store.recent(limit: 10)
        expect(migrated.count == 1, "legacy row survives the additive migration")
        expect(migrated.first?.final == "legacy final words",
               "legacy transcript is intact after migration")
        expect(migrated.first?.sessionID == nil && migrated.first?.sttMs == nil
               && migrated.first?.cleanupApplied == nil,
               "legacy row's new columns decode as unknown, not fabricated values")

        store.insert(dictation(
            daysAgo: 0, words: 5, session: "migrated-session",
            sttMs: 250, cleanupMs: 120, cleanupApplied: true))
        let rows = store.recent(limit: 10)
        expect(rows.count == 2, "a migrated store accepts new inserts")
        let fresh = rows.first(where: { $0.sessionID == "migrated-session" })
        expect(fresh?.sttMs == 250 && fresh?.cleanupApplied == true,
               "session id, stt latency, and cleanup state round-trip")

        // Reopen: re-running the migration on an already-migrated store must
        // be harmless.
        let reopened = HistoryStore(url: url)
        expect(reopened.recent(limit: 10).count == 2, "migration is idempotent on reopen")
        let window = reopened.insights().allTime
        expect(window.count == 2, "aggregates run over a migrated store")
        expect(window.sttSamples == 1, "legacy rows never fake latency samples")
        expect(window.cleanupKnown == 1, "legacy rows never fake a cleanup state")

        // The schema real installs are on today: audio_path exists, none of
        // the Intelligence columns do (its audio_path ALTER must fail-and-skip
        // while the new ALTERs apply).
        let currentURL = dir.appendingPathComponent("history-current.sqlite3")
        var current: OpaquePointer?
        expect(sqlite3_open(currentURL.path, &current) == SQLITE_OK,
               "current-schema fixture database opens")
        sqlite3_exec(current, """
            CREATE TABLE dictations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                bundle_id TEXT,
                app_name TEXT,
                raw TEXT NOT NULL,
                final TEXT NOT NULL,
                mode TEXT,
                duration_ms INTEGER NOT NULL,
                cleanup_ms INTEGER,
                audio_path TEXT
            );
            INSERT INTO dictations (ts, bundle_id, app_name, raw, final, mode, duration_ms, cleanup_ms, audio_path)
            VALUES (strftime('%s', 'now') - 60, 'com.current.app', 'Current',
                    'raw', 'shipped final', 'Default', 3000, 250, 'clip.wav');
            """, nil, nil, nil)
        sqlite3_close(current)
        let currentStore = HistoryStore(url: currentURL)
        let currentRows = currentStore.recent(limit: 10)
        expect(currentRows.count == 1 && currentRows.first?.audioPath == "clip.wav",
               "audio_path-era rows survive with their clip reference")
        currentStore.markQualityObservation(session: "no-such-session", state: .edited)
        expect(currentStore.insights().allTime.count == 1,
               "audio_path-era store gains the Intelligence columns")
    }

    private static func testIntelligenceAggregates() {
        withHistoryStore { store, _ in
            store.insert(dictation(
                daysAgo: 0, words: 10, durationMs: 60_000, app: "Slack",
                bundle: "com.slack", mode: "Message", raw: "different raw",
                session: "a", sttMs: 200, cleanupMs: 100, cleanupApplied: true))
            store.insert(dictation(
                daysAgo: 0, words: 20, durationMs: 30_000, app: "Notes",
                bundle: "com.notes", mode: "Note",
                session: "b", sttMs: 400, cleanupMs: 300, cleanupApplied: true))
            store.insert(dictation(
                daysAgo: 3, words: 30, app: "Slack", bundle: "com.slack",
                mode: "Message", session: "c", cleanupApplied: false))
            store.insert(dictation(
                daysAgo: 10, words: 40, app: "Notes", bundle: "com.notes", mode: "Note"))
            store.insert(dictation(
                daysAgo: 40, words: 50, app: "Terminal", bundle: "com.term", mode: "Terminal"))
            // Empty-final rows (kept only for reprocessing) never enter stats.
            store.insert(dictation(daysAgo: 0, words: 0, raw: "audio only", final: ""))

            let insights = store.insights()
            expect(insights.today.count == 2 && insights.today.words == 30,
                   "today window counts only today's non-empty rows")
            expect(insights.week.count == 3 && insights.week.words == 60,
                   "7-day window spans the last 7 calendar days")
            expect(insights.month.count == 4 && insights.month.words == 100,
                   "30-day window spans the last 30 calendar days")
            expect(insights.allTime.count == 5 && insights.allTime.words == 150,
                   "all-time window covers every non-empty row")

            expect(insights.today.averageSttMs == 300,
                   "stt latency averages only rows that carry it")
            expect(insights.week.sttSamples == 2 && insights.week.averageSttMs == 300,
                   "rows without stt_ms don't drag the latency average")
            expect(insights.allTime.averageCleanupMs == 200,
                   "cleanup latency averages only cleanup-timed rows")

            expect(insights.week.cleanupKnown == 3 && insights.week.cleanupApplied == 2,
                   "cleanup-applied rate uses only state-known rows")
            expect(insights.week.cleanupAppliedRate.map { abs($0 - 2.0 / 3.0) < 0.0001 } == true,
                   "cleanup-applied rate = applied / known")
            expect(insights.today.cleanupChanged == 1,
                   "raw≠final delta counts only cleanup-applied rows that changed the text")
            expect(insights.today.cleanupChangedRate == 0.5,
                   "cleanup-changed rate = changed / applied")
            expect(insights.allTime.zeroEditRate == nil,
                   "no quality observations → no zero-edit claim")

            expect(insights.daily.last?.words == 30,
                   "daily series ends with today's word total")
            expect(insights.daily.count <= 30 && insights.daily.allSatisfy { $0.count > 0 },
                   "daily series is bounded to active days in the last 30")
            expect(insights.apps.first?.name == "Notes" && insights.apps.first?.words == 60,
                   "app breakdown ranks by words over the last 30 days")
            expect(!insights.apps.contains(where: { $0.name == "Terminal" }),
                   "app breakdown excludes rows older than 30 days")
            expect(insights.modes.first?.name == "Note",
                   "mode breakdown ranks by words over the last 30 days")
        }

        withHistoryStore { store, _ in
            for daysAgo in [0, 1, 5, 6, 7] {
                store.insert(dictation(daysAgo: daysAgo, words: 3))
            }
            let insights = store.insights()
            expect(insights.currentStreak == 2, "current streak from stored rows")
            expect(insights.longestStreak == 3, "longest streak from stored rows")
            expect(store.stats().streakDays == insights.currentStreak,
                   "History and Intelligence use the same non-empty streak definition")
        }

        withHistoryStore { store, _ in
            store.insert(dictation(daysAgo: 0, words: 0, raw: "audio only", final: ""))
            store.insert(dictation(daysAgo: 2, words: 3))
            expect(store.stats().streakDays == 0 && store.insights().currentStreak == 0,
                   "an empty failed dictation cannot keep either streak alive")
        }
    }

    private static func testQualityObservationMetrics() {
        withHistoryStore { store, _ in
            store.insert(dictation(daysAgo: 0, words: 4, session: "kept"))
            store.insert(dictation(daysAgo: 0, words: 4, session: "fixed"))
            store.insert(dictation(daysAgo: 0, words: 4, session: "unwatched"))
            store.insert(dictation(daysAgo: 0, words: 0, final: "", session: "empty"))

            store.markQualityObservation(session: "kept", state: .unchanged)
            store.markQualityObservation(session: "fixed", state: .edited)
            // A later conflicting trigger for an already-observed session and
            // an unknown session must both be no-ops.
            store.markQualityObservation(session: "fixed", state: .unchanged)
            store.markQualityObservation(session: "never-existed", state: .unchanged)

            let window = store.insights().allTime
            expect(window.qualityUnchanged == 1 && window.qualityEdited == 1,
                   "observations persist keyed by session id")
            expect(window.zeroEditRate == 0.5,
                   "zero-edit rate = unchanged / observed — first observation wins")
            expect(window.observationCoverage.map { abs($0 - 2.0 / 3.0) < 0.0001 } == true,
                   "unobserved rows lower coverage instead of inflating the rate")
            expect(window.count == 3,
                   "empty-final rows stay out of the coverage denominator")

            let fixedID = store.recent(limit: 10).first { $0.sessionID == "fixed" }!.id
            store.updateAfterReprocess(
                id: fixedID, raw: "new raw", final: "new final",
                mode: "Note", sttMs: 77, cleanupMs: 33, cleanupApplied: true)
            let reprocessed = store.recent(limit: 10).first { $0.id == fixedID }
            expect(
                reprocessed?.sttMs == 77 && reprocessed?.cleanupMs == 33
                    && reprocessed?.cleanupApplied == true,
                "reprocess replaces the run's performance measurements")
            let afterReprocess = store.insights().allTime
            expect(afterReprocess.qualityObserved == 1,
                   "reprocess clears the old text's quality observation")
        }

        withHistoryStore { store, _ in
            store.insert(dictation(daysAgo: 0, words: 4, session: "only-unobserved"))
            let window = store.insights().allTime
            expect(window.zeroEditRate == nil,
                   "zero observations → nil rate, never a fabricated 100%")
            expect(window.observationCoverage == 0, "coverage reports 0% honestly")
        }
    }

    private static func testMinutesSavedDefinition() {
        expect(HistoryStore.minutesSaved(words: 400, spokenMs: 120_000, typingWPM: 40) == 8,
               "time saved = typing minutes at the configured wpm minus speaking minutes")
        expect(HistoryStore.minutesSaved(words: 400, spokenMs: 120_000, typingWPM: 80) == 3,
               "a faster typist saves less")
        expect(HistoryStore.minutesSaved(words: 40, spokenMs: 600_000, typingWPM: 40) == 0,
               "time saved floors at zero — speaking slower than typing never goes negative")
        expect(HistoryStore.minutesSaved(words: 400, spokenMs: 0, typingWPM: 0) == 0,
               "a zero wpm preference cannot divide by zero")
    }

    /// Opt-in release benchmark: exercise the exact Swift aggregate path over
    /// a realistically large history without making every developer selftest
    /// seed 100k rows. Run with VELORA_PERF_SELFTEST=1.
    private static func testIntelligencePerformance100K() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-intelligence-perf-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.sqlite3")
        autoreleasepool { _ = HistoryStore(url: url) }

        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            expect(false, "100k intelligence fixture opens")
            return
        }
        let seed = """
            WITH RECURSIVE rows(x) AS (
                SELECT 1 UNION ALL SELECT x + 1 FROM rows WHERE x < 100000
            )
            INSERT INTO dictations
                (ts, bundle_id, app_name, raw, final, mode, duration_ms,
                 cleanup_ms, session_id, stt_ms, cleanup_applied, quality_state)
            SELECT
                strftime('%s', 'now') - (x % 365) * 86400,
                'com.perf.app' || (x % 8), 'Perf App ' || (x % 8),
                'one two three four five six seven eight nine ten',
                'one two three four five six seven eight nine ten',
                CASE WHEN x % 2 = 0 THEN 'Message' ELSE 'Note' END,
                5000, 120, 'perf-' || x, 250, 1,
                CASE WHEN x % 3 = 0 THEN 2 ELSE 1 END
            FROM rows;
            """
        let seeded = sqlite3_exec(handle, seed, nil, nil, nil) == SQLITE_OK
        sqlite3_close(handle)
        expect(seeded, "100k intelligence fixture seeds")
        guard seeded else { return }

        let store = HistoryStore(url: url)
        let started = Date()
        let insights = store.insights()
        let firstPage = store.page(limit: 50, offset: 0, search: nil)
        let elapsed = -started.timeIntervalSinceNow
        expect(insights.allTime.count == 100_000 && firstPage.count == 50,
               "100k intelligence aggregates and first page are complete")
        expect(elapsed < 5,
               "100k intelligence query stays under the five-second release ceiling")
        print(String(format: "intelligence benchmark — 100k rows %.3fs", elapsed))
    }

    private static func testShareCardPrivacy() {
        withHistoryStore { store, _ in
            store.insert(dictation(
                daysAgo: 0, words: 0, durationMs: 90_000,
                app: "SENTINEL_APP_NAME", bundle: "com.sentinel.contact",
                mode: "Message",
                raw: "SECRET_TRANSCRIPT_SENTINEL raw",
                final: "SECRET_TRANSCRIPT_SENTINEL wrote to ContactAlice today",
                session: "share-1"))
            store.insert(dictation(
                daysAgo: 1, words: 12, app: "SENTINEL_APP_NAME",
                bundle: "com.sentinel.contact", session: "share-2"))

            let insights = store.insights()
            let card = IntelligenceShareCard(
                period: .allTime,
                words: insights.allTime.words,
                dictations: insights.allTime.count,
                minutesSaved: insights.allTime.minutesSaved(typingWPM: 40),
                currentStreakDays: insights.currentStreak)
            let rendered = card.renderedStrings.joined(separator: "\n")
            for sentinel in [
                "SECRET_TRANSCRIPT_SENTINEL", "SENTINEL_APP_NAME",
                "com.sentinel.contact", "ContactAlice",
            ] {
                expect(!rendered.contains(sentinel),
                       "share card never renders \(sentinel)")
            }
            expect(card.metrics.count >= 3, "share card carries its aggregate metrics")
        }

        expect(IntelligenceShareCard.compact(12_345) == "12.3k",
               "share card numbers use the compact format")
        expect(IntelligenceShareCard.duration(minutes: 95) == "1h 35m",
               "share card durations format as h/m")
        let noStreak = IntelligenceShareCard(
            period: .today, words: 10, dictations: 1,
            minutesSaved: 0, currentStreakDays: 1)
        expect(!noStreak.metrics.contains(where: { $0.label == "current streak" }),
               "a 1-day streak isn't bragged about")
        let image = MainActor.assumeIsolated {
            IntelligenceShareCardRenderer.image(for: noStreak)
        }
        expect(image != nil && image!.size.width >= 460 && image!.size.height > 100,
               "the real aggregate-only share card renders to a non-empty image")
        expect((image?.tiffRepresentation?.count ?? 0) > 1_000,
               "the rendered share card has exportable image data")
    }

    // MARK: - Private meeting memory

    private static func testMeetingStore() {
        expect(AppConfig.archivedAudioURL(name: "session-1.flac") != nil
               && AppConfig.archivedAudioURL(name: "../outside.wav") == nil
               && AppConfig.archivedAudioURL(name: "session-1.m4a") == nil,
               "dictation archive paths accept only engine-owned FLAC/WAV basenames")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-meetings-\(UUID().uuidString)", isDirectory: true)
        let db = root.appendingPathComponent("meetings.sqlite3")
        let store = MeetingStore(url: db, filesRoot: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID().uuidString
        let audioDir = root.appendingPathComponent(id, isDirectory: true)
        MeetingStore.ensurePrivateDirectory(audioDir)
        let mic = audioDir.appendingPathComponent("me.caf")
        FileManager.default.createFile(atPath: mic.path, contents: Data("audio".utf8))
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        store.insertProcessing(MeetingRecord(
            id: id, title: "Launch review", startedAt: started,
            endedAt: started.addingTimeInterval(125), sourceApp: "Google Meet",
            status: .processing, micPath: "\(id)/me.caf"))
        store.appendSegment(MeetingSegment(
            meetingID: id, speaker: .them, chunkIndex: 0,
            startMs: 0, endMs: 60_000, text: "We approved the launch plan."))
        store.appendSegment(MeetingSegment(
            meetingID: id, speaker: .me, chunkIndex: 0,
            startMs: 0, endMs: 60_000, text: "I will ship the release."))
        // INSERT OR REPLACE makes a replayed chunk idempotent.
        store.appendSegment(MeetingSegment(
            meetingID: id, speaker: .me, chunkIndex: 0,
            startMs: 0, endMs: 60_000, text: "I will ship the release tomorrow."))
        expect(store.nextChunk(meetingID: id, speaker: .me) == 1,
               "meeting segment cursor resumes after the last committed chunk")
        store.complete(meetingID: id, notes: MeetingNotes(
            summary: "The team approved launch.",
            decisions: ["Launch on Friday"],
            actionItems: ["Me: ship the release"]))

        let loaded = store.record(id: id)
        expect(loaded?.status == .ready && loaded?.segments.count == 2,
               "meeting store persists status, notes, and idempotent segments")
        expect(loaded?.formattedTranscript.contains("Me: I will ship") == true
               && loaded?.formattedTranscript.contains("Them: We approved") == true,
               "separate audio tracks render with honest Me/Them labels")
        expect(loaded?.exportText.contains("## Decisions") == true
               && loaded?.exportText.contains("[00:00]") == true,
               "meeting export includes structured notes and cited timestamps")
        let hits = store.search("approved launch", limit: 10)
        expect(hits.first?.meetingID == id && hits.first?.title == "Launch review",
               "meeting FTS recalls the local source meeting")
        expect(store.search("", limit: 10).first?.meetingID == id,
               "empty meeting search returns recent ready meetings without deadlock")
        let metadata = store.recentMetadata(limit: 10)
        expect(metadata.first?.id == id && metadata.first?.segments.isEmpty == true,
               "meeting picker rows never load full transcripts")
        expect(store.audioURL(relativePath: "../outside.wav") == nil
               && store.audioURL(relativePath: "/tmp/outside.wav") == nil
               && store.audioURL(relativePath: "\(id)/../outside.wav") == nil
               && store.audioURL(relativePath: "\(id)/unexpected.aiff") == nil,
               "meeting audio lookup cannot escape its private root")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-outside-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: outside) }
        FileManager.default.createFile(atPath: outside.path, contents: Data("outside".utf8))
        let linkedID = UUID().uuidString
        let linkedDirectory = root.appendingPathComponent(linkedID, isDirectory: true)
        MeetingStore.ensurePrivateDirectory(linkedDirectory)
        try? FileManager.default.createSymbolicLink(
            at: linkedDirectory.appendingPathComponent("me.caf"), withDestinationURL: outside)
        expect(store.audioURL(relativePath: "\(linkedID)/me.caf") == nil,
               "meeting audio lookup rejects symlinks that leave its private root")

        let rootMode = (try? FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
                        as? NSNumber)?.intValue ?? -1
        let dbMode = (try? FileManager.default.attributesOfItem(atPath: db.path)[.posixPermissions]
                      as? NSNumber)?.intValue ?? -1
        expect(rootMode & 0o777 == 0o700, "meeting directory is owner-only")
        expect(dbMode & 0o777 == 0o600, "meeting transcript database is owner-only")

        store.markFailed(meetingID: id, error: "engine restarted")
        expect(store.recoverable().first?.id == id
               && store.recoverable().first?.segments.isEmpty == true,
               "recovery queue uses bounded metadata rows")
        expect(store.resumable().isEmpty,
               "permanently failed meetings never auto-retry on engine ready")
        expect(store.record(id: id)?.segments.count == 2,
               "failed meeting processing preserves committed chunks for resume")
        store.markProcessing(meetingID: id)
        expect(store.resumable().first?.id == id,
               "interrupted processing remains eligible for automatic resume")
        expect(store.record(id: id)?.segments.count == 2,
               "resuming processing never replaces or deletes prior chunks")
        store.pruneAudio(olderThanDays: 7)
        expect(FileManager.default.fileExists(atPath: mic.path)
               && store.record(id: id)?.micPath != nil,
               "retention never removes audio from queued or processing work")
        store.delete(meetingID: id)
        expect(store.record(id: id) == nil && !FileManager.default.fileExists(atPath: audioDir.path),
               "complete meeting deletion removes database rows and retained audio")

        let recoveryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-meeting-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: recoveryRoot) }
        let recoveryDB = recoveryRoot.appendingPathComponent("meetings.sqlite3")
        let recoveredID = UUID().uuidString
        let emptyID = UUID().uuidString
        var interrupted: MeetingStore? = MeetingStore(url: recoveryDB, filesRoot: recoveryRoot)
        let recoveredDirectory = recoveryRoot.appendingPathComponent(recoveredID, isDirectory: true)
        MeetingStore.ensurePrivateDirectory(recoveredDirectory)
        let recoveredMic = recoveredDirectory.appendingPathComponent("me.caf")
        if let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) {
            autoreleasepool {
                _ = try? AVAudioFile(forWriting: recoveredMic, settings: format.settings)
            }
            if let handle = try? FileHandle(forWritingTo: recoveredMic) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(repeating: 1, count: 4_096))
                try? handle.close()
            }
        }
        let recoveredSystem = recoveredDirectory.appendingPathComponent("them.m4a")
        FileManager.default.createFile(
            atPath: recoveredSystem.path, contents: Data(repeating: 0xA5, count: 8_192))
        let recoveredSize = (try? recoveredMic.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let recoveredProbe = try? AVAudioFile(forReading: recoveredMic)
        expect((recoveredProbe?.length ?? 0) > 0 && recoveredSize > 4_096,
               "flushed CAF audio stays readable without a final container rewrite")
        let interruptedAt = Date(timeIntervalSince1970: 1_700_001_000)
        interrupted?.insertRecording(MeetingRecord(
            id: recoveredID, title: "Interrupted meeting",
            startedAt: interruptedAt, endedAt: interruptedAt,
            status: .recording, micPath: "\(recoveredID)/me.caf",
            systemPath: "\(recoveredID)/them.m4a"))
        interrupted?.insertRecording(MeetingRecord(
            id: emptyID, title: "Empty preparation",
            startedAt: interruptedAt, endedAt: interruptedAt,
            status: .recording, micPath: "\(emptyID)/me.caf"))
        interrupted = nil
        let reopened = MeetingStore(url: recoveryDB, filesRoot: recoveryRoot)
        let recoveredRecord = reopened.record(id: recoveredID)
        expect(recoveredRecord?.status == .failed
               && recoveredRecord?.micPath == "\(recoveredID)/me.caf"
               && FileManager.default.fileExists(atPath: recoveredMic.path),
               "relaunch retains interrupted microphone audio as recoverable work")
        expect(recoveredRecord?.systemPath == nil
               && !FileManager.default.fileExists(atPath: recoveredSystem.path),
               "relaunch drops an unfinalized system track so mic-only retry can succeed")
        expect(reopened.record(id: emptyID) == nil,
               "relaunch removes an interrupted preparation that captured no audio")
    }

    private static func testMeetingDetection() {
        let slackOnly = MeetingDetectionInput(
            runningBundleIDs: ["com.tinyspeck.slackmacgap"],
            windowTitles: ["com.tinyspeck.slackmacgap": ["Velora team — Slack"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false)
        expect(MeetingDetector.candidate(from: slackOnly) == nil,
               "Slack merely running never triggers a meeting suggestion")

        let huddle = MeetingDetectionInput(
            runningBundleIDs: ["com.tinyspeck.slackmacgap"],
            windowTitles: ["com.tinyspeck.slackmacgap": ["Huddle with Product"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false)
        expect(MeetingDetector.candidate(from: huddle)?.sourceApp == "Slack Huddle",
               "an explicit Slack Huddle window produces a high-confidence candidate")

        let zoomCalendar = MeetingDetectionInput(
            runningBundleIDs: ["us.zoom.xos"], windowTitles: [:],
            calendarTitle: "Weekly planning", calendarEventID: "event-1",
            calendarHasConferenceLink: true)
        let combined = MeetingDetector.candidate(from: zoomCalendar)
        expect(combined?.title == "Weekly planning" && combined?.confidence == 85,
               "calendar plus a running Zoom process crosses the suggestion threshold")

        let browserMeet = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome"],
            windowTitles: ["com.google.Chrome": ["Roadmap – Google Meet"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false)
        expect(MeetingDetector.candidate(from: browserMeet)?.sourceApp == "Google Meet",
               "Google Meet is detected from bounded browser window metadata")

        let segmentEvent = EngineEvent.parse([
            "event": "meeting_segment", "id": "job", "meeting_id": "m1",
            "speaker": "me", "chunk_index": 2, "start_ms": 60_000,
            "end_ms": 120_000, "text": "status update",
        ])
        if case .meetingSegment(let job, let segment) = segmentEvent {
            expect(job == "job" && segment.speaker == .me && segment.chunkIndex == 2,
                   "meeting segment engine events preserve resumable cursor and channel")
        } else { expect(false, "expected meeting segment event") }

        let notesEvent = EngineEvent.parse([
            "event": "meeting_notes_ready", "meeting_id": "m1",
            "summary": "Summary", "decisions": ["Ship"],
            "action_items": ["Me: test"],
        ])
        if case .meetingNotesReady(_, let meetingID, let notes) = notesEvent {
            expect(meetingID == "m1" && notes.decisions == ["Ship"]
                   && notes.actionItems == ["Me: test"],
                   "structured meeting notes parse without lossy string encoding")
        } else { expect(false, "expected meeting notes event") }

        let busyEvent = EngineEvent.parse([
            "event": "meeting_transcribe_failed", "id": "job", "meeting_id": "m1",
            "speaker": "me", "error": "localized text may change", "code": "busy",
        ])
        if case .meetingTranscribeFailed(_, _, _, _, let code) = busyEvent {
            expect(code == "busy", "meeting retry policy parses a stable machine error code")
        } else { expect(false, "expected meeting transcription failure event") }

        let reprocessFailure = EngineEvent.parse([
            "event": "reprocess_failed", "id": 42,
            "error": "audio unavailable", "code": "invalid_file",
        ])
        if case .reprocessFailed(let id, _, let code) = reprocessFailure {
            expect(id == 42 && code == "invalid_file",
                   "history reprocess failures preserve row id and stable code")
        } else { expect(false, "expected reprocess failure event") }
    }

    private static func testMeetingAlertTokenSlot() {
        var slot = MeetingAlertTokenSlot()
        let first = UUID()
        let replacement = UUID()
        slot.track(first)
        slot.completed(replacement)
        expect(slot.token == first,
               "an unrelated alert completion cannot clear the active meeting warning")
        expect(slot.take() == first && slot.token == nil,
               "stopping a meeting takes and clears its visible warning token")
        slot.track(replacement)
        slot.completed(replacement)
        expect(slot.token == nil,
               "responding to a meeting warning clears only that warning token")
    }

    private static func testMeetingSystemAudioWarnings() {
        let denied = MeetingAudioCapture.systemAudioWarning(for: NSError(
            domain: SCStreamErrorDomain, code: -3801,
            userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs"]
        ))
        expect(denied.contains("Screen & System Audio Recording")
               && !denied.contains("TCC"),
               "a computer-audio denial gives a useful recovery path without TCC jargon")

        let encoder = MeetingAudioCapture.systemAudioWarning(for: NSError(
            domain: "VeloraMeetingCapture", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "audio encoder is unavailable"]
        ))
        expect(encoder.contains("audio encoder is unavailable"),
               "non-permission computer-audio failures retain their actionable detail")
    }

    // MARK: - Local CLI / MCP control plane

    private static func testControlProtocol() {
        let valid: [String: Any] = [
            "version": 1, "id": "request-1", "command": "recent",
            "arguments": ["limit": 5],
        ]
        let data = try! JSONSerialization.data(withJSONObject: valid)
        let parsed = try? ControlRequest.parse(data)
        expect(parsed?.id == "request-1" && parsed?.command == "recent",
               "control protocol parses a versioned request")
        expect((parsed?.arguments["limit"] as? NSNumber)?.intValue == 5,
               "control protocol preserves bounded arguments")

        var invalid = valid
        invalid["version"] = 99
        expect((try? ControlRequest.parse(
            try! JSONSerialization.data(withJSONObject: invalid))) == nil,
               "control protocol rejects unknown versions")
        invalid = valid
        invalid["command"] = "recent; rm"
        expect((try? ControlRequest.parse(
            try! JSONSerialization.data(withJSONObject: invalid))) == nil,
               "control protocol command is an identifier, never shell text")
        expect((try? ControlRequest.parse(Data(repeating: 0x20,
                                               count: ControlRequest.maxBytes + 1))) == nil,
               "control protocol rejects inputs over 1 MiB")

        let encoded = ControlResponse.success(
            id: "r", result: ["value": true]).encodedLine()
        expect(encoded?.last == 0x0A, "control responses are newline-delimited JSON")
    }

    private static func testControlRouter() {
        withHistoryStore { store, _ in
            store.insert(DictationRecord(
                timestamp: Date(), bundleID: "SECRET_BUNDLE", appName: "Notes",
                raw: "SECRET_RAW_TRANSCRIPT", final: "Budget is 100% approved",
                mode: "Note", durationMs: 2_000, cleanupMs: 20,
                audioPath: "SECRET_AUDIO.wav", sessionID: "SECRET_SESSION",
                sttMs: 100, cleanupApplied: true))
            var enabled = false
            let router = LocalControlRouter(
                history: store, accessEnabled: { enabled },
                engineReady: { true }, typingWPM: { 50 })

            let status = router.handle(ControlRequest(
                id: "s", command: "status", arguments: [:]))
            expect(status.failure == nil
                   && (status.result?["access_enabled"] as? Bool) == false,
                   "status remains available while local agent access is off")
            let denied = router.handle(ControlRequest(
                id: "r", command: "recent", arguments: [:]))
            expect(denied.failure == .disabled,
                   "history is deny-by-default until the user enables access")

            enabled = true
            let recent = router.handle(ControlRequest(
                id: "r", command: "recent", arguments: ["limit": 500]))
            let records = recent.result?["records"] as? [[String: Any]]
            expect(records?.count == 1, "recent returns the allow-listed projection")
            let serialized = VeloraCLI.json(recent.result ?? [:], pretty: false)
            for secret in ["SECRET_RAW_TRANSCRIPT", "SECRET_BUNDLE",
                           "SECRET_AUDIO.wav", "SECRET_SESSION"] {
                expect(!serialized.contains(secret),
                       "public control response omits \(secret)")
            }
            expect(serialized.contains("Budget is 100% approved")
                   && serialized.contains("Notes"),
                   "public control response includes requested final text and app label")
            expect(records?.first?["id"] == nil,
                   "public control response omits internal history row ids")

            let escaped = router.handle(ControlRequest(
                id: "q", command: "search", arguments: ["query": "100%", "limit": 1]))
            expect((escaped.result?["records"] as? [[String: Any]])?.count == 1,
                   "control search preserves literal LIKE metacharacters")
            let stats = router.handle(ControlRequest(
                id: "t", command: "stats", arguments: [:]))
            expect(stats.result?["typing_wpm"] as? Int == 50,
                   "control stats use the configured typing speed")
            expect(stats.result?["apps"] == nil && stats.result?["modes"] == nil,
                   "control stats expose aggregates, not app/mode labels")

            var receivedArguments: [String: Any]?
            let actionRouter = LocalControlRouter(
                history: store, accessEnabled: { enabled },
                engineReady: { true }, typingWPM: { 50 },
                transcribeFile: { arguments, completion in
                    receivedArguments = arguments
                    completion(.success(["text": "agent transcript"]))
                    return {}
                },
                listen: { arguments, completion in
                    receivedArguments = arguments
                    completion(.success(["text": "voice answer"]))
                    return {}
                })
            var actionResponse: ControlResponse?
            actionRouter.handle(ControlRequest(
                id: "file", command: "transcribe",
                arguments: ["path": "/tmp/../tmp/memo.wav", "mode": " Note "]
            )) { actionResponse = $0 }
            expect(actionResponse?.failure == nil
                   && actionResponse?.result?["text"] as? String == "agent transcript",
                   "control router completes an enabled file transcription capability")
            expect(receivedArguments?["path"] as? String == "/tmp/memo.wav"
                   && receivedArguments?["mode"] as? String == "Note",
                   "control router normalizes bounded path and mode arguments")

            actionResponse = nil
            actionRouter.handle(ControlRequest(
                id: "bad", command: "transcribe", arguments: ["path": "relative.wav"]
            )) { actionResponse = $0 }
            expect(actionResponse?.failure?.code == "invalid_arguments",
                   "control router rejects relative file paths")

            actionResponse = nil
            actionRouter.handle(ControlRequest(
                id: "listen", command: "listen", arguments: ["mode": "Raw"]
            )) { actionResponse = $0 }
            expect(actionResponse?.result?["text"] as? String == "voice answer"
                   && receivedArguments?["mode"] as? String == "Raw",
                   "control router exposes the consent-owned listening capability")

            var cancelled = false
            let cancellableRouter = LocalControlRouter(
                history: store, accessEnabled: { true },
                engineReady: { true }, typingWPM: { 50 },
                listen: { _, _ in { cancelled = true } })
            let cancel = cancellableRouter.handle(ControlRequest(
                id: "cancel", command: "listen", arguments: [:]
            )) { _ in }
            cancel?()
            expect(cancelled,
                   "long-running control capabilities return a timeout cancellation hook")
        }
    }

    private static func testCLIParsing() {
        let recent = try? CLIInvocation.parse(["recent", "--limit", "500", "--json"])
        expect(recent == CLIInvocation(command: .recent(limit: 100), json: true),
               "CLI clamps recent limits and accepts JSON mode")
        let search = try? CLIInvocation.parse(
            ["search", "quarterly", "plan", "--limit", "7"])
        expect(search == CLIInvocation(
            command: .search(query: "quarterly plan", limit: 7), json: false),
               "CLI parses multi-word searches and limits")
        expect((try? CLIInvocation.parse(["search"])) == nil,
               "CLI rejects a missing search query")
        expect((try? CLIInvocation.parse(["recent", "--wat"])) == nil,
               "CLI rejects unknown options")
        let transcribe = try? CLIInvocation.parse([
            "transcribe", "voice memo.m4a", "--mode", "Note", "--json",
        ])
        expect(transcribe == CLIInvocation(
            command: .transcribe(path: "voice memo.m4a", mode: "Note"), json: true),
               "CLI parses file transcription path, mode, and JSON output")
        expect((try? CLIInvocation.parse(["listen", "--mode", "Raw"]))
               == CLIInvocation(command: .listen(mode: "Raw"), json: false),
               "CLI parses an explicitly formatted listening request")
        expect((try? CLIInvocation.parse(["transcribe"])) == nil,
               "CLI rejects file transcription without a path")
        expect(VeloraCLI.shouldRun(arguments: ["/Applications/Velora.app/Contents/Resources/bin/velora", "status"]),
               "lowercase bundled symlink selects CLI mode")
        expect(!VeloraCLI.shouldRun(arguments: ["/Applications/Velora.app/Contents/MacOS/Velora"]),
               "normal app executable never enters CLI mode")
    }

    private static func testMCPProtocol() {
        var called: (String, [String: Any])?
        let caller: MCPStdioServer.Caller = { command, arguments in
            called = (command, arguments)
            return .success(["records": []])
        }
        let initialized = MCPStdioServer.process([
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:],
        ], caller: caller)
        let initResult = initialized?["result"] as? [String: Any]
        expect(initResult?["protocolVersion"] as? String == "2025-06-18",
               "MCP initialize negotiates the supported stable protocol")
        expect(MCPStdioServer.process([
            "jsonrpc": "2.0", "method": "notifications/initialized",
        ], caller: caller) == nil,
               "MCP notifications produce no stdout response")

        let listed = MCPStdioServer.process([
            "jsonrpc": "2.0", "id": "tools", "method": "tools/list",
        ], caller: caller)
        let tools = (listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        expect(tools?.count == 6,
               "MCP lists the read-only tools plus file and consented voice input")

        let calledTool = MCPStdioServer.process([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": [
                "name": "search_dictations",
                "arguments": ["query": "roadmap", "limit": 3],
            ],
        ], caller: caller)
        expect(called?.0 == "search"
               && (called?.1["query"] as? String) == "roadmap",
               "MCP search tool maps to the bounded app broker command")
        let toolResult = calledTool?["result"] as? [String: Any]
        expect(toolResult?["isError"] as? Bool == false,
               "MCP tool success uses a protocol-level successful result")

        _ = MCPStdioServer.process([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "request_voice_input", "arguments": ["mode": "Raw"]],
        ], caller: caller)
        expect(called?.0 == "listen" && called?.1["mode"] as? String == "Raw",
               "MCP voice input maps to the app's consent-requiring command")

        let invalidArguments = MCPStdioServer.process([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "velora_status", "arguments": "wrong"],
        ], caller: caller)
        let invalidError = invalidArguments?["error"] as? [String: Any]
        expect((invalidError?["code"] as? NSNumber)?.intValue == -32602,
               "MCP rejects present non-object tool arguments")
    }

    private static func testLocalControlSocket() {
        var pair = [Int32](repeating: -1, count: 2)
        if socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 {
            expect(!UnixSocket.peerDisconnected(pair[0]),
                   "control peer liveness keeps a connected caller active")
            close(pair[1])
            expect(UnixSocket.peerDisconnected(pair[0]),
                   "control peer liveness detects a disconnected caller")
            close(pair[0])
        } else {
            expect(false, "socketpair fixture opens")
            expect(false, "socketpair fixture reports disconnect")
        }
        withHistoryStore { store, _ in
            // sockaddr_un.sun_path is only 104 bytes on Darwin; use a short
            // explicit fixture path so the test exercises the socket, not the
            // randomized macOS temporary-directory prefix.
            let dir = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("vc-\(UUID().uuidString.prefix(8))")
            let path = dir.appendingPathComponent("control.sock").path
            let longRequestStarted = DispatchSemaphore(value: 0)
            let longRequestCancelled = DispatchSemaphore(value: 0)
            let router = LocalControlRouter(
                history: store, accessEnabled: { true },
                engineReady: { true }, typingWPM: { 40 },
                listen: { _, _ in
                    longRequestStarted.signal()
                    return { longRequestCancelled.signal() }
                })
            let server = LocalControlServer(path: path, router: router)
            expect(server.start(), "local control socket binds")
            defer {
                server.stop()
                try? FileManager.default.removeItem(at: dir)
            }

            var info = stat()
            let statOK = lstat(path, &info) == 0
            expect(statOK && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
                   "control endpoint is a Unix socket, never TCP")
            expect(statOK && (info.st_mode & 0o777) == 0o600,
                   "control socket is owner-readable/writable only")
            let parentMode = (try? FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions]
                              as? NSNumber)?.intValue ?? -1
            expect(parentMode & 0o777 == 0o700,
                   "control socket directory is owner-only")

            let result = try? LocalControlClient.send(
                command: "status", path: path, timeoutSeconds: 2)
            expect((result?["engine_ready"] as? Bool) == true,
                   "same-UID client completes the real socket round-trip")

            let competing = LocalControlServer(path: path, router: router)
            expect(!competing.start(),
                   "a second app instance cannot steal a live control socket")
            let afterCompetition = try? LocalControlClient.send(
                command: "status", path: path, timeoutSeconds: 2)
            expect((afterCompetition?["app_running"] as? Bool) == true,
                   "failed second-instance startup leaves the first socket reachable")
            competing.stop()
            expect(FileManager.default.fileExists(atPath: path),
                   "a server that never owned the socket cannot unlink it")

            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? LocalControlClient.send(
                    command: "listen", path: path, timeoutSeconds: 3)
            }
            expect(longRequestStarted.wait(timeout: .now() + 2) == .success,
                   "control server begins a real long-running request")
            server.stop()
            expect(longRequestCancelled.wait(timeout: .now() + 2) == .success,
                   "stopping control server cancels active client work")
            expect(!FileManager.default.fileExists(atPath: path),
                   "stopping the server removes the stale socket")
        }
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
