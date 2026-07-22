import AppKit
import AVFoundation
import CoreAudio
import Foundation
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
        testSettingsDocument()
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
        testHistoryEdit()
        testIntelligenceAggregates()
        if ProcessInfo.processInfo.environment["VELORA_PERF_SELFTEST"] == "1" {
            testIntelligencePerformance100K()
        }
        testQualityObservationMetrics()
        testMeetingStore()
        testMeetingCaptureReadiness()
        testMeetingSystemAudioBackendPolicy()
        testMeetingSystemAudioFrameMath()
        testMeetingSystemAudioWarnings()
        testMeetingDetection()
        testMinutesSavedDefinition()
        testShareCardPrivacy()
        testControlProtocol()
        testControlRouter()
        testLocalAgentAccessRevocationSignal()
        testCLIParsing()
        testMCPProtocol()
        testLocalControlSocket()
        testHUDGeometry()
        testHUDPerformance()
        testSettingsSidebar()
        testAudioInputDeviceResolution()
        testMicrophoneCaptureDeviceSelection()
        testAudioCaptureRapidRestart()
        testMediaPlaybackNoop()
        testMediaPlaybackUnknownStateFailsClosed()
        testMediaPlaybackPauseResume()
        testMediaPlaybackEarlyStop()
        testMediaPlaybackFailedPause()
        testMediaPlaybackUserOverride()
        testMediaPlaybackAmbiguousPlayers()
        testMediaPlaybackMisdirectedToggleRollsBack()
        testMediaPlaybackUnsupportedOutput()
        testMediaPlaybackActiveInput()
        testMediaPlaybackUnrelatedSystemInput()
        testMediaPlaybackUnsupportedOutputOnRestore()
        testMediaPlaybackTerminationRestore()
        testMediaPlaybackTerminationDuringVerification()
        testMediaPlaybackRapidRestart()
        testMediaPlaybackMisdirectedRestoreRollsBack()
        testMediaPlaybackBrowserStreamDrain()
        testMediaPlaybackSupportedPlayers()
        testInsertionBoundary()
        testInsertionContinuation()
        testEngineRestartDelay()
        testEmptyFinalFeedback()
        testClipboardStaging()
        testUpdateChecker()
        if ProcessInfo.processInfo.environment["VELORA_LIVE_AUDIO_SELFTEST"] == "1" {
            testLiveMicrophoneCapture()
            testLiveSystemAudioCapture()
            testLiveMeetingCapture()
        }
        print(failures == 0
            ? "selftest OK — \(checks) checks"
            : "selftest FAILED — \(failures)/\(checks) checks failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Update checker

    private static func testUpdateChecker() {
        expect(UpdateChecker.isNewer("0.8.0", than: "0.7.2"), "minor bump is newer")
        expect(UpdateChecker.isNewer("0.10.0", than: "0.9.9"), "numeric not lexicographic")
        expect(UpdateChecker.isNewer("1.0.0", than: "0.99.99"), "major bump is newer")
        expect(!UpdateChecker.isNewer("0.7.2", than: "0.7.2"), "same version is not newer")
        expect(!UpdateChecker.isNewer("0.7.1", than: "0.7.2"), "older is not newer")
        expect(UpdateChecker.isNewer("0.7.2.1", than: "0.7.2"), "extra component is newer")
        expect(!UpdateChecker.isNewer("0.7", than: "0.7.0"), "missing component counts as zero")
        expect(UpdateChecker.isNewer("0.8.0-beta", than: "0.7.9"),
               "junk suffix compares by numeric prefix")

        let ok = """
        {"tag_name": "v9.9.9", "html_url": "https://github.com/x/y/releases/tag/v9.9.9",
         "assets": [
           {"name": "Velora-9.9.9.zip", "size": 5,
            "browser_download_url": "https://github.com/x/y/releases/download/v9.9.9/Velora-9.9.9.zip"},
           {"name": "Other.dmg", "size": 7,
            "browser_download_url": "https://github.com/x/y/releases/download/v9.9.9/Other.dmg"},
           {"name": "Velora-9.9.9.dmg", "size": 42,
            "browser_download_url": "https://github.com/x/y/releases/download/v9.9.9/Velora-9.9.9.dmg"}
         ]}
        """.data(using: .utf8)
        let http = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!, statusCode: 200,
            httpVersion: nil, headerFields: nil)
        if case .updateAvailable(let update) = UpdateChecker.parse(
            current: "0.7.2", data: ok, response: http, error: nil) {
            expect(update.version == "9.9.9", "parses and strips the v prefix")
            expect(update.page.absoluteString.hasSuffix("v9.9.9"), "uses the release html_url")
            expect(update.asset?.name == "Velora-9.9.9.dmg",
                   "prefers the canonical versioned DMG over other assets")
            expect(update.asset?.size == 42, "carries the asset size")
        } else {
            expect(false, "release feed with newer tag parses as updateAvailable")
        }
        let noAssets = """
        {"tag_name": "v9.9.9", "html_url": "https://github.com/x/y/releases/tag/v9.9.9"}
        """.data(using: .utf8)
        if case .updateAvailable(let update) = UpdateChecker.parse(
            current: "0.7.2", data: noAssets, response: http, error: nil) {
            expect(update.asset == nil, "release without a DMG still surfaces, without an asset")
        } else {
            expect(false, "release without assets parses as updateAvailable")
        }
        expect(UpdateChecker.pickAsset(version: "1.0.0", assets: [
            ["name": "Other.dmg", "size": 1,
             "browser_download_url": "https://github.com/x/y/releases/download/v1/Other.dmg"]
        ])?.name == "Other.dmg", "falls back to any DMG when the canonical name is absent")
        expect(UpdateChecker.pickAsset(version: "1.0.0", assets: [
            ["name": "Velora.zip", "size": 1,
             "browser_download_url": "https://github.com/x/y/releases/download/v1/Velora.zip"]
        ]) == nil, "non-DMG assets are never picked")
        // Downloads are pinned to GitHub over HTTPS (the feed URL override is
        // absent in selftest runs, so the pin is active).
        expect(UpdateChecker.pickAsset(version: "1.0.0", assets: [
            ["name": "Velora-1.0.0.dmg", "size": 1,
             "browser_download_url": "https://evil.example.com/Velora-1.0.0.dmg"]
        ]) == nil, "assets hosted off GitHub are rejected")
        expect(UpdateChecker.pickAsset(version: "1.0.0", assets: [
            ["name": "Velora-1.0.0.dmg", "size": 1,
             "browser_download_url": "http://github.com/x/y/Velora-1.0.0.dmg"]
        ]) == nil, "plain-HTTP assets are rejected")
        expect(UpdateChecker.assetURLAllowed(
            URL(string: "https://objects.githubusercontent.com/x")!),
            "the release-asset CDN host is allowed")
        if case .upToDate = UpdateChecker.parse(
            current: "9.9.9", data: ok, response: http, error: nil) {} else {
            expect(false, "same-version feed parses as upToDate")
        }
        let rateLimited = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!, statusCode: 403,
            httpVersion: nil, headerFields: nil)
        if case .failed = UpdateChecker.parse(
            current: "0.7.2", data: ok, response: rateLimited, error: nil) {} else {
            expect(false, "non-200 parses as failed, never as an update")
        }
        if case .failed = UpdateChecker.parse(
            current: "0.7.2", data: "not json".data(using: .utf8),
            response: http, error: nil) {} else {
            expect(false, "garbage body parses as failed")
        }

        testUpdateInstaller()
    }

    private static func testUpdateInstaller() {
        // hdiutil `attach -plist` output → first mount point.
        let hdiutilPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>system-entities</key>
          <array>
            <dict><key>content-hint</key><string>GUID_partition_scheme</string></dict>
            <dict>
              <key>content-hint</key><string>Apple_HFS</string>
              <key>mount-point</key><string>/Volumes/Velora</string>
            </dict>
          </array>
        </dict></plist>
        """.data(using: .utf8)!
        expect(UpdateInstaller.mountPoint(fromHdiutilPlist: hdiutilPlist) == "/Volumes/Velora",
               "extracts the mount point from hdiutil plist output")
        expect(UpdateInstaller.mountPoint(fromHdiutilPlist: Data("junk".utf8)) == nil,
               "garbage hdiutil output yields no mount point")

        // The swap helper takes paths as positional arguments (no
        // interpolation → no quoting bugs) and restores the old bundle when
        // the swap fails.
        let script = UpdateInstaller.helperScript
        expect(script.hasPrefix("#!/bin/sh"), "helper script is a shell script")
        expect(script.contains("PID=\"$1\""), "helper takes the pid as an argument")
        expect(script.contains("mv \"$OLD\" \"$TARGET\""),
               "helper restores the previous app when the swap fails")
        expect(script.contains("/usr/bin/open \"$TARGET\""),
               "helper can relaunch the swapped-in app")
        expect(script.contains("codesign --verify --deep --strict"),
               "helper re-validates the signature of the bytes it installs")
        expect(!script.contains("/Applications"),
               "helper hard-codes no paths — everything arrives as arguments")

        testHelperScriptDryRun(script)

        // A bare `swift build` binary (what runs this selftest) must never
        // think it can swap itself.
        expect(UpdateInstaller.installBlocker() != nil,
               "bare binaries are blocked from in-place installs")

        // The verify gate rejects an unsigned bundle outright.
        let fake = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-selftest-\(UUID().uuidString).app")
        try? FileManager.default.createDirectory(
            at: fake.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fake) }
        expect(UpdateInstaller.verifyStagedApp(at: fake, expectedVersion: "9.9.9") != nil,
               "an unsigned bundle never passes the verify gate")
    }

    /// Actually executes the swap helper in a temp sandbox (both HIGH-severity
    /// review findings lived in the helper's failure paths, so string checks
    /// alone are not enough). The empty team argument skips the codesign
    /// re-check — these are marker directories, not signed bundles. The dead
    /// pid makes the wait loop exit immediately.
    private static func testHelperScriptDryRun(_ script: String) {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .appendingPathComponent("velora-helper-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: sandbox) }
        let scriptFile = sandbox.appendingPathComponent("install.sh")
        let log = sandbox.appendingPathComponent("log.txt")
        let target = sandbox.appendingPathComponent("target.app")
        let staged = sandbox.appendingPathComponent("staged.app")
        let deadPID = "999999999"

        func runHelper(stagedPath: String, pathPrefix: String? = nil) -> Int32 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = [scriptFile.path, deadPID, stagedPath, target.path,
                              "0", log.path, ""]
            if let pathPrefix {
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = pathPrefix + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
                proc.environment = environment
            }
            do { try proc.run() } catch { return -1 }
            proc.waitUntilExit()
            return proc.terminationStatus
        }
        func marker(_ dir: URL) -> String? {
            try? String(contentsOf: dir.appendingPathComponent("marker"), encoding: .utf8)
        }

        do {
            try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
            try script.write(to: scriptFile, atomically: true, encoding: .utf8)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            try "old".write(to: target.appendingPathComponent("marker"),
                            atomically: true, encoding: .utf8)
            try "new".write(to: staged.appendingPathComponent("marker"),
                            atomically: true, encoding: .utf8)
        } catch {
            expect(false, "helper dry-run sandbox setup failed: \(error)")
            return
        }

        expect(runHelper(stagedPath: staged.path) == 0, "helper swap succeeds")
        expect(marker(target) == "new", "helper installed the staged app")
        expect(!fm.fileExists(atPath: staged.path), "helper cleans up the staging copy")

        // Real rollback path: first rename succeeds, installing the new app
        // fails, and the third rename must put the old app back. A PATH-local
        // mv shim deterministically fails only the second invocation.
        let shimDirectory = sandbox.appendingPathComponent("shim")
        let mvShim = shimDirectory.appendingPathComponent("mv")
        let mvCount = sandbox.appendingPathComponent("mv-count")
        do {
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            try "newer".write(to: staged.appendingPathComponent("marker"),
                              atomically: true, encoding: .utf8)
            try "old".write(to: target.appendingPathComponent("marker"),
                            atomically: true, encoding: .utf8)
            try fm.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
            let shim = """
            #!/bin/sh
            COUNT=0
            [ ! -f "\(mvCount.path)" ] || COUNT="$(cat "\(mvCount.path)")"
            COUNT=$((COUNT + 1))
            echo "$COUNT" > "\(mvCount.path)"
            [ "$COUNT" -ne 2 ] || exit 1
            exec /bin/mv "$@"
            """
            try shim.write(to: mvShim, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mvShim.path)
        } catch {
            expect(false, "helper rollback sandbox setup failed: \(error)")
            return
        }
        expect(runHelper(stagedPath: staged.path, pathPrefix: shimDirectory.path) != 0,
               "helper reports a failed new-app rename")
        expect(marker(target) == "old",
               "helper restores the old app after the swap itself fails")
        expect(marker(staged) == "newer",
               "failed swap retains the downloaded update for diagnosis or retry")
    }

    // MARK: - Portable settings

    private static func testSettingsDocument() {
        var document = SettingsDocument.defaults
        document.settings.general.appearance = "dark"
        document.settings.general.soundVolume = 73
        document.settings.hud.position = .custom
        document.settings.hud.customOrigin = .init(x: 0.25, y: 0.75)
        document.settings.dictation.language = "hi"
        document.settings.dictation.typingWordsPerMinute = 67
        document.settings.engine.maximumRecordingSeconds = 420
        document.settings.engine.audioMaximumMegabytes = 8192
        document.settings.shortcuts.dictation = .fnGlobe

        do {
            let data = try SettingsDocumentCodec.encode(document)
            let decoded = try SettingsDocumentCodec.decode(data)
            expect(decoded == document, "settings document round-trips every typed field")

            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let dictation = ((root?["settings"] as? [String: Any])?["dictation"] as? [String: Any])
            expect(dictation?["typing_words_per_minute"] as? Int == 67,
                   "settings JSON uses stable human-readable snake_case keys")

            let portableData = try SettingsDocumentCodec.encode(document)
            let portableRoot = try JSONSerialization.jsonObject(with: portableData) as? [String: Any]
            let portable = try SettingsDocumentCodec.decode(portableData)
            expect(portableRoot?["local"] == nil,
                   "settings document never contains machine or security state")
            expect(portable.settings == document.settings,
                   "settings export preserves every portable preference")

            var withHostileLocal = portableRoot ?? [:]
            withHostileLocal["local"] = [
                "local_agent_access": true,
                "onboarding_complete": true,
                "input_device_uid": "other-machine",
            ]
            let hostileData = try JSONSerialization.data(withJSONObject: withHostileLocal)
            expect(try AppConfig.portableSettings(from: hostileData) == portable.settings,
                   "settings import ignores injected machine and security state")

            var withUnknownKey = portableRoot ?? [:]
            withUnknownKey["future_metadata"] = ["safe_to_ignore": true]
            let unknownData = try JSONSerialization.data(withJSONObject: withUnknownKey)
            expect(try SettingsDocumentCodec.decode(unknownData).settings == portable.settings,
                   "same-version settings ignore unknown future fields")
        } catch {
            expect(false, "valid settings document threw: \(error)")
        }

        let futureRoot: [String: Any] = [
            "format": SettingsDocument.formatIdentifier,
            "version": SettingsDocument.currentVersion + 1,
            "settings": [:],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: futureRoot)
            _ = try SettingsDocumentCodec.decode(data)
            expect(false, "future settings version is rejected")
        } catch let error as SettingsDocumentError {
            expect(error == .unsupportedVersion(SettingsDocument.currentVersion + 1),
                   "future settings version reports an actionable compatibility error")
        } catch {
            expect(false, "future settings version returned the wrong error")
        }

        var invalidVolume = document
        invalidVolume.settings.general.soundVolume = 101
        do {
            _ = try SettingsDocumentCodec.decode(SettingsDocumentCodec.encode(invalidVolume))
            expect(false, "out-of-range sound volume is rejected")
        } catch {
            expect(true, "out-of-range sound volume is rejected")
        }

        var invalidNumericLimits = document
        invalidNumericLimits.settings.dictation.typingWordsPerMinute = Int.max
        do {
            _ = try SettingsDocumentCodec.decode(SettingsDocumentCodec.encode(invalidNumericLimits))
            expect(false, "unbounded imported typing speed is rejected")
        } catch {
            expect(true, "unbounded imported typing speed is rejected")
        }
        invalidNumericLimits = document
        invalidNumericLimits.settings.engine.maximumRecordingSeconds = Double.greatestFiniteMagnitude
        do {
            _ = try SettingsDocumentCodec.decode(SettingsDocumentCodec.encode(invalidNumericLimits))
            expect(false, "unbounded imported recording duration is rejected")
        } catch {
            expect(true, "unbounded imported recording duration is rejected")
        }
        invalidNumericLimits = document
        invalidNumericLimits.settings.engine.audioRetentionDays = Double.greatestFiniteMagnitude
        do {
            _ = try SettingsDocumentCodec.decode(SettingsDocumentCodec.encode(invalidNumericLimits))
            expect(false, "unbounded imported audio retention is rejected")
        } catch {
            expect(true, "unbounded imported audio retention is rejected")
        }
        invalidNumericLimits = document
        invalidNumericLimits.settings.engine.audioMaximumMegabytes = Double.greatestFiniteMagnitude
        do {
            _ = try SettingsDocumentCodec.decode(SettingsDocumentCodec.encode(invalidNumericLimits))
            expect(false, "unbounded imported audio storage is rejected")
        } catch {
            expect(true, "unbounded imported audio storage is rejected")
        }

        var invalidShortcuts = document
        invalidShortcuts.settings.shortcuts.editSelection =
            invalidShortcuts.settings.shortcuts.dictation
        do {
            _ = try SettingsDocumentCodec.decode(SettingsDocumentCodec.encode(invalidShortcuts))
            expect(false, "conflicting imported shortcuts are rejected")
        } catch {
            expect(true, "conflicting imported shortcuts are rejected")
        }

        do {
            _ = try SettingsDocumentCodec.decode(Data("{\"version\":1}".utf8))
            expect(false, "non-Velora JSON is rejected")
        } catch {
            expect(true, "non-Velora JSON is rejected")
        }

        // One-time UserDefaults migration keeps current user choices and adopts
        // the engine-selected cleanup model without touching the real domain.
        let suite = "com.sushil.velora.selftest.settings.\(UUID().uuidString)"
        let legacy = UserDefaults(suiteName: suite)!
        let transactionSuite = "com.sushil.velora.selftest.settings-transaction.\(UUID().uuidString)"
        let transactionDefaults = UserDefaults(suiteName: transactionSuite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-settings-migration-\(UUID().uuidString)")
        let engineConfig = directory.appendingPathComponent("config.json")
        defer {
            legacy.removePersistentDomain(forName: suite)
            transactionDefaults.removePersistentDomain(forName: transactionSuite)
            try? FileManager.default.removeItem(at: directory)
        }
        legacy.set("dark", forKey: "velora.appearance")
        legacy.set(Hotkey.f19.defaultsRepresentation, forKey: "velora.hotkey.v2")
        legacy.set("hi", forKey: "velora.language")
        legacy.set(true, forKey: "velora.localAgentAccess")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{\"cleanup_model\":\"mlx-community/Test-Cleanup\",\"streaming_cleanup\":false,\"audio_max_mb\":2048}".utf8)
                .write(to: engineConfig)
            let migrated = AppConfig.migratedSettingsDocument(
                defaults: legacy, engineConfigURL: engineConfig)
            expect(migrated.settings.general.appearance == "dark"
                   && migrated.settings.shortcuts.dictation == .f19
                   && migrated.settings.dictation.language == "hi",
                   "settings migration preserves existing UserDefaults preferences")
            expect(!migrated.settings.engine.streamingCleanup
                   && migrated.settings.engine.audioMaximumMegabytes == 2048,
                   "settings migration preserves advanced engine preferences")
            expect(AppConfig.migratedLocalSettings(defaults: legacy).localAgentAccess,
                   "settings migration keeps security gates local")

            legacy.set(Hotkey.optionShiftE.defaultsRepresentation, forKey: "velora.hotkey.v2")
            legacy.removeObject(forKey: "velora.editHotkey.v1")
            let collisionSafe = AppConfig.migratedSettingsDocument(
                defaults: legacy, engineConfigURL: engineConfig)
            expect(collisionSafe.settings.shortcuts.dictation == .optionShiftE
                   && collisionSafe.settings.shortcuts.editSelection == .rightOption,
                   "shortcut migration chooses a distinct fallback when dictation uses the edit default")
            legacy.set(Hotkey.f19.defaultsRepresentation, forKey: "velora.hotkey.v2")

            // Drive the real import transaction against isolated files. A
            // directory at the engine config path forces projection failure;
            // the typed settings file must return to its exact prior value.
            let rollbackDirectory = directory.appendingPathComponent("rollback")
            let rollbackSettings = rollbackDirectory.appendingPathComponent("settings.json")
            let blockedEngineConfig = rollbackDirectory.appendingPathComponent("blocked-config")
            let rollbackConfig = AppConfig(
                defaults: transactionDefaults,
                settingsFileURL: rollbackSettings,
                engineConfigURL: blockedEngineConfig,
                registerDefaults: false)
            let previous = try SettingsDocumentCodec.decode(Data(contentsOf: rollbackSettings))
            var previousRoot = try JSONSerialization.jsonObject(
                with: Data(contentsOf: rollbackSettings)) as? [String: Any] ?? [:]
            previousRoot["future_metadata"] = ["keep": true]
            let previousRawData = try JSONSerialization.data(withJSONObject: previousRoot)
            try previousRawData.write(to: rollbackSettings)
            var imported = previous.settings
            imported.general.appearance = "dark"
            try FileManager.default.createDirectory(
                at: blockedEngineConfig, withIntermediateDirectories: true)
            do {
                try rollbackConfig.applyPortableSettings(imported)
                expect(false, "settings import reports engine projection failure")
            } catch let error as SettingsDocumentError {
                expect(error == .engineProjectionFailed,
                       "settings import reports engine projection failure")
            } catch {
                expect(false, "settings import returned the wrong projection error")
            }
            let restored = try SettingsDocumentCodec.decode(Data(contentsOf: rollbackSettings))
            expect(restored == previous,
                   "settings import restores the full previous document when engine projection fails")
            expect(try Data(contentsOf: rollbackSettings) == previousRawData,
                   "settings rollback preserves unknown fields byte-for-byte")
            let rollbackRecovery = rollbackSettings.deletingPathExtension()
                .appendingPathExtension("import-backup.json")
            expect(!FileManager.default.fileExists(atPath: rollbackRecovery.path),
                   "successful rollback removes its temporary recovery copy")

            let malformedEngine = directory.appendingPathComponent("malformed-config.json")
            let malformedData = Data("not-json".utf8)
            try malformedData.write(to: malformedEngine)
            expect(!AppConfig.applyManualDictionary(
                .init(vocabulary: ["Velora"], replacements: [:]), at: malformedEngine),
                "engine projection fails closed on malformed config")
            expect(try Data(contentsOf: malformedEngine) == malformedData,
                   "engine projection preserves malformed config for recovery")

            transactionDefaults.set(true, forKey: "velora.localAgentAccess")
            let successDirectory = directory.appendingPathComponent("successful-import")
            let successSettings = successDirectory.appendingPathComponent("settings.json")
            let successEngine = successDirectory.appendingPathComponent("config.json")
            try FileManager.default.createDirectory(
                at: successDirectory, withIntermediateDirectories: true)
            try Data("{\"cleanup_model\":\"ram/model\",\"future_key\":true}".utf8)
                .write(to: successEngine)
            let successConfig = AppConfig(
                defaults: transactionDefaults,
                settingsFileURL: successSettings,
                engineConfigURL: successEngine,
                registerDefaults: false)
            var successfulImport = try AppConfig.portableSettings(
                from: successConfig.exportSettingsData())
            successfulImport.general.appearance = "dark"
            successfulImport.dictation.language = "hi"
            successfulImport.engine.maximumRecordingSeconds = 720
            try successConfig.applyPortableSettings(successfulImport)
            let committed = try SettingsDocumentCodec.decode(Data(contentsOf: successSettings))
            let projected = try JSONSerialization.jsonObject(
                with: Data(contentsOf: successEngine)) as? [String: Any]
            expect(committed.settings == successfulImport,
                   "settings import commits the complete validated document")
            let settingsMode = (try FileManager.default.attributesOfItem(
                atPath: successSettings.path)[.posixPermissions] as? NSNumber)?.intValue
            expect(settingsMode == 0o600,
                   "settings import keeps the canonical file owner-only")
            expect(successConfig.localAgentAccess,
                   "successful settings import preserves machine-local security state")
            expect(projected?["language"] as? String == "hi"
                   && (projected?["max_recording_s"] as? NSNumber)?.doubleValue == 720,
                   "settings import projects engine-facing preferences")
            expect(projected?["cleanup_model"] as? String == "ram/model"
                   && projected?["future_key"] as? Bool == true,
                   "settings import preserves cleanup selection and unknown engine keys")
            let durableBackup = successSettings.deletingPathExtension()
                .appendingPathExtension("backup.json")
            expect(FileManager.default.fileExists(atPath: durableBackup.path),
                   "portable settings keep a last-known-good recovery copy")
            try FileManager.default.removeItem(at: successSettings)
            let missingRecovery = AppConfig(
                defaults: transactionDefaults,
                settingsFileURL: successSettings,
                engineConfigURL: successEngine,
                registerDefaults: false)
            expect(try AppConfig.portableSettings(
                from: missingRecovery.exportSettingsData()) == successfulImport,
                "a missing settings.json recovers without remigrating stale UserDefaults")
            try Data("not-json".utf8).write(to: successSettings)
            let corruptRecovery = AppConfig(
                defaults: transactionDefaults,
                settingsFileURL: successSettings,
                engineConfigURL: successEngine,
                registerDefaults: false)
            expect(try AppConfig.portableSettings(
                from: corruptRecovery.exportSettingsData()) == successfulImport,
                "a corrupt settings.json recovers from the last-known-good copy")
            let successRecovery = successSettings.deletingPathExtension()
                .appendingPathExtension("import-backup.json")
            expect(!FileManager.default.fileExists(atPath: successRecovery.path),
                   "successful settings import removes its temporary recovery copy")

            let newerDirectory = directory.appendingPathComponent("newer-version")
            let newerSettings = newerDirectory.appendingPathComponent("settings.json")
            try FileManager.default.createDirectory(
                at: newerDirectory, withIntermediateDirectories: true)
            let newerData = try JSONSerialization.data(withJSONObject: futureRoot)
            try newerData.write(to: newerSettings)
            let newerConfig = AppConfig(
                defaults: transactionDefaults,
                settingsFileURL: newerSettings,
                engineConfigURL: newerDirectory.appendingPathComponent("config.json"),
                registerDefaults: false)
            newerConfig.appearance = "dark"
            expect(try Data(contentsOf: newerSettings) == newerData,
                   "a downgraded app never overwrites a newer settings document")
            do {
                try newerConfig.applyPortableSettings(.defaults)
                expect(false, "a downgraded app refuses to import over newer settings")
            } catch let error as SettingsDocumentError {
                expect(error == .unsupportedVersion(SettingsDocument.currentVersion + 1),
                       "a downgraded app refuses to import over newer settings")
            } catch {
                expect(false, "newer settings import refusal returned the wrong error")
            }
            expect(try Data(contentsOf: newerSettings) == newerData,
                   "refused import leaves the newer settings document byte-for-byte intact")

        } catch {
            expect(false, "settings migration fixture failed: \(error)")
        }
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
        let ready = EngineEvent.parse([
            "event": "ready", "setup_complete": true,
            "stt_model": "mlx-community/whisper-large-v3-turbo",
        ])
        if case .ready(let setupComplete, let sttModel) = ready {
            expect(setupComplete, "ready event carries cached setup completion")
            expect(sttModel == "mlx-community/whisper-large-v3-turbo",
                   "ready event carries the engine's proven speech backend")
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

        let edited = EngineEvent.parse([
            "event": "edited", "id": "e9", "text": "Fixed.", "applied": true, "ms": 412,
        ])
        if case .edited(let id, let text, let applied, let ms, let reason) = edited {
            expect(id == "e9" && text == "Fixed." && applied && ms == 412 && reason == nil,
                   "edited event parses")
        } else {
            expect(false, "expected .edited, got \(edited)")
        }
        let editGuard = EngineEvent.parse([
            "event": "edited", "id": "e10", "text": "orig", "applied": false,
            "ms": 5, "reason": "instruction_echo",
        ])
        if case .edited(_, _, let applied, _, let reason) = editGuard {
            expect(!applied && reason == "instruction_echo", "guarded edit parses as not applied")
        } else {
            expect(false, "expected .edited for guard case")
        }
        let editFailed = EngineEvent.parse([
            "event": "edit_failed", "id": "e11", "error": "busy", "code": "busy",
        ])
        if case .editFailed(let id, _, let code) = editFailed {
            expect(id == "e11" && code == "busy", "edit_failed parses")
        } else {
            expect(false, "expected .editFailed")
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

    /// Manual transcript editing (History tab pencil → HistoryStore.updateFinal).
    private static func testHistoryEdit() {
        withHistoryStore { store, _ in
            store.insert(dictation(daysAgo: 0, words: 3, raw: "raw words here"))
            guard let row = store.recent(limit: 1).first else {
                expect(false, "edit test inserts a row")
                return
            }
            store.updateFinal(id: row.id, final: "edited transcript text")
            let reloaded = store.recent(limit: 1).first
            expect(reloaded?.final == "edited transcript text",
                   "manual edit replaces the final text")
            expect(reloaded?.raw == "raw words here",
                   "manual edit leaves the raw transcript untouched")
            expect(reloaded?.id == row.id, "manual edit keeps the same row")
        }
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

        // Diarized labels: the engine may split the system track into
        // s1/s2/… — parsing, display, and the TRACK-level resume cursor.
        // A separate meeting so the fixture above keeps its segment counts.
        expect(MeetingSpeaker(rawValue: "s1") == .remote(1)
               && MeetingSpeaker(rawValue: "s2")?.displayName == "Speaker 2"
               && MeetingSpeaker(rawValue: "s2")?.rawValue == "s2"
               && MeetingSpeaker(rawValue: "s0") == nil
               && MeetingSpeaker(rawValue: "sx") == nil
               && MeetingSpeaker(rawValue: "s123") == nil
               && MeetingSpeaker(rawValue: "guest") == nil,
               "diarized speaker labels parse s1/s2 and reject junk")
        let diarizedID = UUID().uuidString
        store.insertProcessing(MeetingRecord(
            id: diarizedID, title: "Panel call", startedAt: started,
            endedAt: started.addingTimeInterval(90), sourceApp: "zoom.us",
            status: .processing))
        store.appendSegment(MeetingSegment(
            meetingID: diarizedID, speaker: .them, chunkIndex: 0,
            startMs: 0, endMs: 60_000, text: "Joint intro."))
        store.appendSegment(MeetingSegment(
            meetingID: diarizedID, speaker: .remote(1), chunkIndex: 1,
            startMs: 60_000, endMs: 70_000, text: "Speaker one talks."))
        store.appendSegment(MeetingSegment(
            meetingID: diarizedID, speaker: .remote(2), chunkIndex: 2,
            startMs: 70_000, endMs: 80_000, text: "Speaker two answers."))
        expect(store.nextChunk(meetingID: diarizedID, speaker: .them) == 3,
               "remote resume cursor spans them AND diarized s1/s2 rows")
        expect(store.nextChunk(meetingID: diarizedID, speaker: .me) == 0,
               "mic cursor is unaffected by diarized remote rows")
        if let reloaded = store.record(id: diarizedID) {
            expect(reloaded.formattedTranscript.contains("Speaker 1: Speaker one talks.")
                   && reloaded.formattedTranscript.contains("Speaker 2: Speaker two answers."),
                   "transcript renders diarized speaker names")
        } else {
            expect(false, "meeting with diarized segments reloads")
        }
        // Settle it: the resume/recovery checks below must only see `id`.
        store.complete(meetingID: diarizedID, notes: MeetingNotes(summary: "Panel."))
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
        expect(store.audioURL(relativePath: "\(id)/them.caf")?.lastPathComponent == "them.caf",
               "meeting storage accepts the audio-only Core Audio system track")
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

    private static func testMeetingCaptureReadiness() {
        let gate = MeetingCaptureReadiness(requiresSystemAudio: true)
        expect(!gate.recordMicrophone(frames: 0),
               "an empty microphone callback cannot make meeting capture ready")
        expect(!gate.recordMicrophone(frames: 256),
               "microphone frames alone cannot claim full meeting capture")
        expect(gate.missingTracks == [.systemAudio],
               "startup health reports the exact missing system-audio track")
        expect(gate.recordSystemAudio(frames: 256),
               "the first healthy frame from both tracks makes capture ready")
        expect(!gate.recordSystemAudio(frames: 256),
               "meeting readiness fires exactly once")

        let fallback = MeetingCaptureReadiness(requiresSystemAudio: true)
        expect(!fallback.recordMicrophone(frames: 128),
               "full capture waits for computer audio")
        expect(fallback.continueWithoutSystemAudio(),
               "an explicit mic-only fallback becomes ready after microphone proof")
        expect(fallback.missingTracks.isEmpty,
               "a deliberate mic-only fallback no longer waits on a failed track")

        let noMic = MeetingCaptureReadiness(requiresSystemAudio: false)
        expect(!noMic.continueWithoutSystemAudio(),
               "mic-only capture still cannot start before microphone frames arrive")
        expect(noMic.missingTracks == [.microphone],
               "startup health names a missing microphone track")
    }

    private static func testMeetingSystemAudioBackendPolicy() {
        expect(
            MeetingSystemAudioPolicy.backend(for: OperatingSystemVersion(
                majorVersion: 14, minorVersion: 2, patchVersion: 0)) == .coreAudioTap,
            "macOS 14.2 uses an audio-only Core Audio process tap")
        expect(
            MeetingSystemAudioPolicy.backend(for: OperatingSystemVersion(
                majorVersion: 14, minorVersion: 1, patchVersion: 0)) == .unavailable,
            "older systems fail honestly instead of opening a display-capture stream")
        expect(MeetingSystemAudioPolicy.relativePath(meetingID: "m1") == "m1/them.caf",
               "computer audio is stored as a crash-resilient CAF track")
        expect(MeetingCoordinator.consentDescription.count <= 110
               && MeetingCoordinator.consentDescription.contains("microphone")
               && MeetingCoordinator.consentDescription.contains("computer audio"),
               "meeting consent stays minimal while naming both recorded sources")
        expect(MeetingCoordinator.systemAudioFailurePresentation == .hud,
               "computer-audio degradation stays in the compact HUD instead of opening a modal")
        expect(MeetingCoordinator.State.preparing(title: "Starting…").isActive
               && MeetingCoordinator.State.recording(
                    id: "m1", title: "Call", startedAt: Date(), systemAudio: true).isActive
               && !MeetingCoordinator.State.idle.isActive,
               "meeting capture exclusion covers preparation and recording, but not idle")
        expect(MeetingProcessingHUDPolicy.shouldShow(
            dictationIsIdle: true, meetingIsIdle: true, hudAllowsMeetingProgress: true),
               "meeting-note progress stays visible while the foreground is free")
        expect(!MeetingProcessingHUDPolicy.shouldShow(
            dictationIsIdle: false, meetingIsIdle: true, hudAllowsMeetingProgress: true)
               && !MeetingProcessingHUDPolicy.shouldShow(
                    dictationIsIdle: true, meetingIsIdle: false,
                    hudAllowsMeetingProgress: true)
               && !MeetingProcessingHUDPolicy.shouldShow(
                    dictationIsIdle: true, meetingIsIdle: true,
                    hudAllowsMeetingProgress: false),
               "background meeting-note progress never overwrites capture or error UI")
    }

    private static func testMeetingSystemAudioWarnings() {
        let denied = MeetingAudioCapture.systemAudioWarning(for: NSError(
            domain: "VeloraSystemAudioCapture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "system-audio permission denied"]
        ))
        expect(denied.contains("Screen & System Audio Recording")
               && !denied.contains("screen recording"),
               "a computer-audio denial gives the audio-only recovery path")

        let encoder = MeetingAudioCapture.systemAudioWarning(for: NSError(
            domain: "VeloraMeetingCapture", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "audio encoder is unavailable"]
        ))
        expect(encoder.contains("audio encoder is unavailable"),
               "non-permission computer-audio failures retain their actionable detail")
    }

    // MARK: - Local CLI / MCP control plane

    private static func testLocalAgentAccessRevocationSignal() {
        let center = NotificationCenter()
        var revocations = 0
        let observer = LocalAgentAccessRevocationObserver(center: center) {
            revocations += 1
        }

        center.post(name: .veloraLocalAgentAccessChanged, object: true)
        expect(revocations == 0, "enabling local-agent access does not cancel work")
        center.post(name: .veloraLocalAgentAccessChanged, object: false)
        expect(revocations == 1, "disabling local-agent access revokes active capability")
        observer.stop()
        center.post(name: .veloraLocalAgentAccessChanged, object: false)
        expect(revocations == 1, "stopped revocation observer receives no late events")
    }

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
        let serverInfo = initResult?["serverInfo"] as? [String: Any]
        let bundleVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        expect(serverInfo?["version"] as? String == bundleVersion,
               "MCP initialize advertises the running bundle version")
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

        // Agent integration: the skill must tell agents the truth about the
        // surface — command names, flags, the socket path, and the gate.
        let skill = AgentIntegration.skillMarkdown(
            cliPath: "/opt/homebrew/bin/velora", version: "9.9.9")
        for token in [
            "velora status", "velora recent", "velora search", "velora stats",
            "velora transcribe", "velora listen", "--json",
            "~/.velora/control.sock", "access_disabled",
            "/opt/homebrew/bin/velora", "velora mcp", "name: velora",
        ] {
            expect(skill.contains(token), "agent skill documents \(token)")
        }
        expect(skill.contains("Velora 9.9.9"), "agent skill stamps the real version")
        let dirs = AgentIntegration.candidateBinDirectories()
        expect(!dirs.isEmpty && dirs.allSatisfy { $0.path.hasPrefix("/") },
               "CLI install candidates are absolute paths")
        expect(dirs.contains { $0.path.hasSuffix("/.local/bin") },
               "CLI install candidates include the personal bin fallback")
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

        // Persistent standby pill (2026-07 HUD round).
        expect(!HUDState.standby.isHidden, "the standby pill is a visible state")
        expect(HUDState.standby.isAvailable, "standby counts as free for toasts")
        expect(HUDState.hidden(.cancel).isAvailable, "hidden stays free for toasts")
        expect(!HUDState.listening.isAvailable, "a live session blocks toasts")
        let meetingState = HUDState.meeting(title: "Design review", systemAudio: true)
        expect(!meetingState.isAvailable,
               "a live meeting owns the HUD until recording stops")
        let meetingMetrics = HUDView.capsuleMetrics(for: meetingState, context: nil)
        expect(meetingMetrics.visible && meetingMetrics.size.width <= 280,
               "the persistent meeting indicator is a compact HUD capsule")
        expect(
            HUDGeometry.standbySize.width < HUDGeometry.minListeningWidth
                && HUDGeometry.standbySize.height < HUDGeometry.height,
            "the standby pill is strictly smaller than the listening capsule")
        expect(
            HUDEdge.edge(for: .bottomRight) == .trailing
                && HUDEdge.edge(for: .topLeft) == .leading
                && HUDEdge.edge(for: .bottomCenter) == .center
                && HUDEdge.edge(for: .custom) == .center,
            "corner presets anchor the capsule to the matching panel edge")
        expect(
            HUDEdge.edge(for: .custom, custom: .trailing) == .trailing
                && HUDEdge.edge(for: .bottomCenter, custom: .trailing) == .center,
            "the stored custom anchor applies to custom positions only")
        expect(
            !HUDPosition.presets.contains(.custom),
            "custom placement is drag-only, never a menu preset")

        // Dragged placement re-anchors toward the nearest screen edge so the
        // listening capsule can never grow off-screen (user-reported crop:
        // pill parked at the right edge, waveform clipped mid-capsule).
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 950)
        let pill = HUDGeometry.standbySize
        func drop(x: CGFloat, y: CGFloat) -> (edge: HUDEdge, panelOrigin: NSPoint) {
            HUDPanel.customAnchor(
                capsule: NSRect(origin: CGPoint(x: x, y: y), size: pill), visible: visible)
        }
        let right = drop(x: visible.maxX - pill.width - 6, y: 400)
        expect(right.edge == .trailing, "a drop near the right edge anchors trailing")
        let left = drop(x: visible.minX + 6, y: 400)
        expect(left.edge == .leading, "a drop near the left edge anchors leading")
        let middle = drop(x: visible.midX - pill.width / 2, y: 400)
        expect(middle.edge == .center, "a drop in open space keeps the center anchor")
        for anchored in [right, left, middle] {
            // Reconstruct the widest session capsule at its anchor and assert
            // it stays fully inside the visible frame.
            let maxWidth = HUDGeometry.maxListeningWidth
            let grownMinX = anchored.panelOrigin.x
                + HUDPanel.capsuleMinX(edge: anchored.edge, capsuleWidth: maxWidth)
            expect(
                grownMinX >= visible.minX && grownMinX + maxWidth <= visible.maxX,
                "the max-width capsule fits on screen from a dragged anchor")
            let capsuleMidY = anchored.panelOrigin.y + HUDPanel.panelSize.height / 2
            expect(
                capsuleMidY - HUDGeometry.height / 2 >= visible.minY
                    && capsuleMidY + HUDGeometry.height / 2 <= visible.maxY,
                "the full-height capsule fits vertically from a dragged anchor")
        }
        // The pill itself must not move when it re-anchors in open space.
        let dropX = visible.midX - pill.width / 2
        expect(
            abs((middle.panelOrigin.x + HUDPanel.capsuleMinX(
                edge: .center, capsuleWidth: pill.width)) - dropX) < 0.5,
            "re-anchoring in open space keeps the pill exactly where it was dropped")
        // A drop dragged half off the right edge is pulled back on screen.
        let offscreen = drop(x: visible.maxX - pill.width / 2, y: 400)
        let pulledMaxX = offscreen.panelOrigin.x
            + HUDPanel.capsuleMinX(edge: .trailing, capsuleWidth: pill.width) + pill.width
        expect(
            offscreen.edge == .trailing && pulledMaxX <= visible.maxX,
            "a half-offscreen drop snaps back inside the visible frame")
        // A drop near the bottom clamps so the taller session capsule fits.
        let low = drop(x: 700, y: visible.minY + 2)
        expect(
            low.panelOrigin.y + HUDPanel.panelSize.height / 2 - HUDGeometry.height / 2
                >= visible.minY,
            "a drop hugging the Dock leaves room for the full-height capsule")

        // Persistence round-trip: the stored fraction is the pill CENTER, so
        // it is always 0…1 and restores fully on-screen on ANY display size —
        // a panel-origin fraction scaled its fixed overhang across screens
        // and pushed the capsule off-screen (review finding).
        let small = NSRect(x: 0, y: 25, width: 1280, height: 775)
        let big = NSRect(x: 0, y: 31, width: 3008, height: 1661)
        for (store, restore) in [(small, big), (big, small), (small, small)] {
            // Flush bottom-right drop on the store screen…
            let dropped = HUDPanel.customAnchor(
                capsule: NSRect(
                    x: store.maxX - pill.width - 2, y: store.minY + 1,
                    width: pill.width, height: pill.height),
                visible: store)
            let frac = HUDPanel.customFraction(
                panelOrigin: dropped.panelOrigin, edge: dropped.edge, visible: store)
            expect(
                (0...1).contains(frac.x) && (0...1).contains(frac.y),
                "the persisted custom fraction is always within 0…1")
            // …restored on the restore screen.
            let back = HUDPanel.customAnchor(
                capsule: HUDPanel.customPillRect(fraction: frac, visible: restore),
                visible: restore)
            let maxWidth = HUDGeometry.maxListeningWidth
            let grownMinX = back.panelOrigin.x
                + HUDPanel.capsuleMinX(edge: back.edge, capsuleWidth: maxWidth)
            expect(
                grownMinX >= restore.minX && grownMinX + maxWidth <= restore.maxX,
                "a custom spot restores with the max-width capsule on-screen on any display")
            let backMidY = back.panelOrigin.y + HUDPanel.panelSize.height / 2
            expect(
                backMidY - HUDGeometry.height / 2 >= restore.minY
                    && backMidY + HUDGeometry.height / 2 <= restore.maxY,
                "a custom spot restores with the full-height capsule on-screen on any display")
            if store == restore {
                expect(
                    abs(back.panelOrigin.x - dropped.panelOrigin.x) < 0.5
                        && abs(back.panelOrigin.y - dropped.panelOrigin.y) < 0.5,
                    "same-screen restore is an exact fixpoint — the pill does not creep")
            }
        }

        // Hit testing mirrors the visible capsule — an oversized rect is an
        // invisible click-to-record strip over the frontmost app (review
        // finding: the .inserted circle is 56 pt, not 420).
        expect(
            HUDPanel.hitRect(for: .hidden(.cancel), edge: .center, context: nil) == .zero,
            "a hidden HUD is fully click-through")
        let inserted = HUDPanel.hitRect(for: .inserted, edge: .center, context: nil)
        expect(
            inserted.width <= HUDGeometry.insertedDiameter + VeloraSpacing.s,
            "the success circle's hit area hugs the 56 pt circle")
        let standby = HUDPanel.hitRect(for: .standby, edge: .trailing, context: nil)
        expect(
            standby.width <= HUDGeometry.standbySize.width + VeloraSpacing.s,
            "the idle pill's hit area is pill-sized")
        expect(
            abs(standby.maxX
                - (HUDPanel.panelSize.width - HUDGeometry.panelEdgePadding + VeloraSpacing.xs))
                < 0.5,
            "a trailing-anchored pill's hit area hugs the panel's right padding")
        expect(
            HUDPanel.capsuleMinX(edge: .leading, capsuleWidth: 100)
                == HUDGeometry.panelEdgePadding,
            "leading anchor starts at the panel padding")
        expect(
            HUDPanel.capsuleMinX(edge: .center, capsuleWidth: HUDPanel.panelSize.width)
                == 0,
            "center anchor is symmetric")

        // Click-through: the interactive screen rect is the hit rect offset by
        // the panel frame, and vanishes with the capsule — the whole reason
        // the panel can keep `ignoresMouseEvents` on while the margins overlap
        // the frontmost app (user report: a top-center pill deadened the
        // browser's address bar).
        expect(
            HUDPanel.interactiveScreenRect(
                panelFrame: NSRect(x: 100, y: 200, width: 480, height: 160),
                hitRect: .zero) == .zero,
            "no capsule → no interactive area anywhere on screen")
        let screenRect = HUDPanel.interactiveScreenRect(
            panelFrame: NSRect(x: 100, y: 200, width: 480, height: 160),
            hitRect: NSRect(x: 30, y: 60, width: 70, height: 40))
        expect(
            screenRect == NSRect(x: 130, y: 260, width: 70, height: 40),
            "interactive screen rect is the hit rect offset by the panel origin")
        expect(
            !screenRect.contains(NSPoint(x: 105, y: 270)),
            "panel margins outside the capsule stay click-through")
    }

    // MARK: - HUD performance (hot paths)

    /// The HUD is always on screen with "keep on screen when idle", so its hot
    /// paths run constantly: a global mouse monitor fires for every system-wide
    /// move, and the waveform Canvas redraws ~30×/s during a session. These pin
    /// that those paths stay cheap — and specifically that the mouse-move path
    /// no longer pays Core Text layout on every move (user report: hovering the
    /// HUD felt glitchy).
    ///
    /// The deterministic assertions (dependency contract + "not optimized away")
    /// always run. The wall-clock BUDGET assertions gate behind
    /// `VELORA_PERF_SELFTEST=1` (like `testIntelligencePerformance100K`) because
    /// `systemUptime` includes scheduler preemption — a loaded CI box could
    /// blow an absolute millisecond budget with no code regression. The timings
    /// are always printed, so they are visible evidence even in a normal run.
    private static func testHUDPerformance() {
        let context = HUDSessionContext(appIcon: nil, modeName: "Terminal")

        // Purity: the geometry that gets cached must be a stable function of its
        // inputs, or caching it would drift from what is on screen.
        let hit = HUDPanel.hitRect(for: .listening, edge: .trailing, context: context)
        expect(
            hit == HUDPanel.hitRect(for: .listening, edge: .trailing, context: context),
            "the listening hit rect is a pure function of its inputs")

        // Dependency contract: the hit rect must change when ANY of its inputs
        // changes, so each is a real cache dependency the panel must invalidate
        // on. If one of these stopped mattering, HUDPanel could skip
        // invalidating for it and cache a stale rect.
        let baseline = HUDPanel.hitRect(for: .listening, edge: .center, context: context)
        expect(
            baseline != HUDPanel.hitRect(for: .standby, edge: .center, context: context),
            "state changes the hit rect — HUDPanel must invalidate on transition")
        expect(
            baseline != HUDPanel.hitRect(for: .listening, edge: .trailing, context: context),
            "edge changes the hit rect — HUDPanel must invalidate on reposition")
        // Two contexts in the unclamped width band so this holds regardless of
        // the min/max listening-width constants.
        let shortCtx = HUDSessionContext(appIcon: nil, modeName: "Terminal")
        let longCtx = HUDSessionContext(appIcon: nil, modeName: "Terminal Window Here")
        expect(
            HUDView.capsuleMetrics(for: .listening, context: shortCtx).size
                != HUDView.capsuleMetrics(for: .listening, context: longCtx).size,
            "session context changes the capsule width — a cache dependency")
        // The panel FRAME is a dependency too: a display reconfiguration
        // relocates the panel with no state change, so the cache re-keys on the
        // frame (review finding — otherwise the pill's click region goes stale
        // at the new location).
        let frameA = HUDPanel.interactiveScreenRect(
            panelFrame: NSRect(x: 0, y: 0, width: 480, height: 160), hitRect: baseline)
        let frameB = HUDPanel.interactiveScreenRect(
            panelFrame: NSRect(x: 300, y: 400, width: 480, height: 160), hitRect: baseline)
        expect(
            frameA != frameB,
            "the panel frame changes the interactive rect — the cache re-keys on frame")

        // Drive the real cache HUDPanel uses. It must recompute exactly on a key
        // miss and reuse the memoized rect on a hit, so the hot mouse path pays
        // no Core Text. Each key field — frame, state, edge, context — counts as
        // a miss, which is what guarantees the pill's click region can never go
        // stale after a move, transition, reposition, or display reconfig.
        let cache = HUDHitRectCache()
        func lookup(_ key: HUDHitRectCache.Key) -> NSRect {
            cache.rect(for: key) { k in
                HUDPanel.interactiveScreenRect(
                    panelFrame: k.frame,
                    hitRect: HUDPanel.hitRect(for: k.state, edge: k.edge, context: k.context))
            }
        }
        let baseFrame = NSRect(x: 0, y: 0, width: 480, height: 160)
        let movedFrame = NSRect(x: 300, y: 400, width: 480, height: 160)
        let key0 = HUDHitRectCache.Key(
            frame: baseFrame, state: .listening, edge: .center, context: context)
        let r0 = lookup(key0)
        expect(cache.recomputeCount == 1, "the first lookup computes the rect")
        _ = lookup(key0)
        expect(
            cache.recomputeCount == 1,
            "an unchanged key reuses the memoized rect — no Core Text on the hot path")
        _ = lookup(HUDHitRectCache.Key(
            frame: movedFrame, state: .listening, edge: .center, context: context))
        expect(cache.recomputeCount == 2, "a frame move recomputes — no stale click region")
        _ = lookup(HUDHitRectCache.Key(
            frame: movedFrame, state: .standby, edge: .center, context: context))
        expect(cache.recomputeCount == 3, "a state transition recomputes")
        _ = lookup(HUDHitRectCache.Key(
            frame: movedFrame, state: .standby, edge: .trailing, context: context))
        expect(cache.recomputeCount == 4, "a reposition (edge change) recomputes")
        _ = lookup(HUDHitRectCache.Key(
            frame: movedFrame, state: .standby, edge: .trailing, context: nil))
        expect(cache.recomputeCount == 5, "a session-context change recomputes")
        expect(
            r0 == HUDPanel.interactiveScreenRect(
                panelFrame: key0.frame,
                hitRect: HUDPanel.hitRect(
                    for: key0.state, edge: key0.edge, context: key0.context)),
            "the memoized rect matches a direct computation")

        // Measure the worst-case per-move cost: BUILD a fresh key each iteration
        // (as production does from the model properties) using an icon-bearing
        // context, so the measurement includes NSImage ARC traffic and String
        // equality — then hit the cache and run contains. This is everything
        // syncMouseInteractivity does per move bar the panel.frame getter, with
        // no Core Text on the hit path.
        let hotIcon = NSImage(size: NSSize(width: 22, height: 22))
        let hotContext = HUDSessionContext(appIcon: hotIcon, modeName: "Terminal")
        let hotFrame = NSRect(x: 12, y: 24, width: 480, height: 160)
        func hotKey() -> HUDHitRectCache.Key {
            HUDHitRectCache.Key(
                frame: hotFrame, state: .listening, edge: .center, context: hotContext)
        }
        let hotRect = lookup(hotKey())         // prime the hot key (a miss)
        let primedCount = cache.recomputeCount
        let probe = NSPoint(x: hotRect.midX, y: hotRect.midY)
        var containsHits = 0
        let moveStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200_000 where lookup(hotKey()).contains(probe) { containsHits += 1 }
        let moveDuration = ProcessInfo.processInfo.systemUptime - moveStart
        expect(containsHits == 200_000, "the cached hit test is exercised, not optimized away")
        expect(
            cache.recomputeCount == primedCount,
            "200k hot-path lookups triggered zero recomputes — the cache holds")

        // For contrast, capsuleMetrics for a live session pays NSString Core
        // Text width measurement (the context chip) — orders of magnitude
        // costlier than the cached contains, which is exactly why it must never
        // run on every mouse move.
        let metricsStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<2_000 { _ = HUDView.capsuleMetrics(for: .listening, context: context) }
        let metricsDuration = ProcessInfo.processInfo.systemUptime - metricsStart

        let standbyStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200_000 { _ = HUDView.capsuleMetrics(for: .standby, context: nil) }
        let standbyDuration = ProcessInfo.processInfo.systemUptime - standbyStart

        // The waveform Canvas redraws ~30×/s while recording: push a spectrum
        // and compute bar heights per frame. 20k frames ≈ 11 minutes of
        // recording.
        let store = WaveformLevelStore()
        let bands = (0..<WaveformLevelStore.halfCount).map { Float($0 % 5) / 5.0 }
        var heightAccum: CGFloat = 0
        let waveStart = ProcessInfo.processInfo.systemUptime
        for frame in 0..<20_000 {
            if frame % 3 == 0 { store.push(bands) }
            let heights = store.displayHeights(settle: frame % 7 == 0, time: Double(frame) / 30.0)
            heightAccum += heights[0]
        }
        let waveDuration = ProcessInfo.processInfo.systemUptime - waveStart
        expect(heightAccum > 0, "the waveform smoothing actually advances (not optimized away)")

        print(String(
            format: "HUD perf — mouse move %.4fs/200k, metrics(listening) %.4fs/2k, "
                + "metrics(standby) %.4fs/200k, waveform %.4fs/20k",
            moveDuration, metricsDuration, standbyDuration, waveDuration))

        // Absolute wall-clock budgets: opt-in, since preemption on a shared box
        // can exceed them without any regression. Loose (≈10× the numbers above
        // on this dev machine) so they still catch a pathological slowdown.
        if ProcessInfo.processInfo.environment["VELORA_PERF_SELFTEST"] == "1" {
            expect(
                moveDuration < 0.1,
                "the cached mouse-move hit test stays effectively free (200k in <0.1s)")
            expect(
                metricsDuration < 1.0,
                "even the Core Text capsule-metrics path stays bounded (2k in <1s)")
            expect(
                standbyDuration < 0.3,
                "idle-pill metrics are a constant lookup (200k in <0.3s)")
            expect(
                waveDuration < 0.5,
                "20k waveform frames render in <0.5s — the 30 fps HUD has ~1000× headroom")
        }
    }

    // MARK: - Settings sidebar

    private static func testSettingsSidebar() {
        let listed = SettingsTab.sidebarGroups.flatMap { $0 }
        expect(
            listed.count == SettingsTab.allCases.count && Set(listed).count == listed.count
                && Set(listed) == Set(SettingsTab.allCases),
            "every settings pane appears in the sidebar exactly once")
        expect(
            listed.first == .general && listed.last == .about,
            "the sidebar starts at General and ends at About")

        // Sidebar search: title + control-label keywords, all tokens must hit.
        expect(
            SettingsTab.filteredGroups(query: "") == SettingsTab.sidebarGroups,
            "an empty query shows the full sidebar")
        expect(
            SettingsTab.general.matches(query: "volume")
                && SettingsTab.general.matches(query: "PILL"),
            "General is findable by its control labels, case-insensitively")
        expect(
            SettingsTab.meetings.matches(query: "speakers")
                && SettingsTab.shortcuts.matches(query: "hold to talk"),
            "panes are findable by what their controls do")
        expect(
            SettingsTab.general.matches(query: "sound volume"),
            "multi-token queries AND together")
        expect(
            !SettingsTab.modes.matches(query: "volume"),
            "keywords are per-pane, not global")
        expect(
            SettingsTab.filteredGroups(query: "qzxv").isEmpty,
            "a garbage query filters everything out (sidebar shows No matches)")
        let updates = SettingsTab.filteredGroups(query: "updates").flatMap { $0 }
        expect(
            updates.contains(.general) && updates.contains(.about),
            "\"updates\" finds both homes of the update controls")
    }

    // MARK: - Microphone selection

    private static func testAudioInputDeviceResolution() {
        let mac = AudioInputDevices.Device(uid: "BuiltInMicUID", name: "MacBook Pro Microphone", id: 41)
        let pods = AudioInputDevices.Device(uid: "AirPodsUID", name: "Sushil's AirPods Pro", id: 77)

        expect(
            AudioInputDevices.resolve(persistedUID: nil, in: [mac, pods]) == nil,
            "no persisted mic follows the system default")
        expect(
            AudioInputDevices.resolve(persistedUID: "", in: [mac, pods]) == nil,
            "an empty persisted UID follows the system default, never matches a device")
        expect(
            AudioInputDevices.resolve(persistedUID: "BuiltInMicUID", in: [mac, pods]) == mac.id,
            "the persisted mic resolves to its device id while connected")
        expect(
            AudioInputDevices.resolve(persistedUID: "BuiltInMicUID", in: [pods]) == nil,
            "an unplugged persisted mic falls back to the system default")

        // The AirPods scenario: the chosen built-in mic disappears and comes
        // back. The persisted UID is never rewritten by resolution — the same
        // value must win again the moment the device is available.
        let persisted = "BuiltInMicUID"
        expect(
            AudioInputDevices.resolve(persistedUID: persisted, in: []) == nil,
            "no devices at all still resolves cleanly to the system default")
        expect(
            AudioInputDevices.resolve(persistedUID: persisted, in: [pods, mac]) == mac.id,
            "the preserved choice wins again when its device reappears")

        // The mic picker must not show the HAL's private default-device
        // aggregate (user report: "CADefaultDeviceAggregate-43981-0" appeared
        // as a selectable mic). Real device names pass; internal identifiers
        // and empties are hidden.
        expect(
            AudioInputDevices.isInternalDeviceName("CADefaultDeviceAggregate-43981-0"),
            "the private default-device aggregate is hidden from the mic picker")
        expect(
            AudioInputDevices.isInternalDeviceName("CADefaultDeviceAggregate-7-2"),
            "any generated CADefaultDeviceAggregate-<pid>-<n> instance is hidden")
        expect(
            AudioInputDevices.isInternalDeviceName("   ") && AudioInputDevices.isInternalDeviceName(""),
            "a blank device name is treated as internal, never shown")
        expect(
            !AudioInputDevices.isInternalDeviceName("MacBook Pro Microphone")
                && !AudioInputDevices.isInternalDeviceName("Sushil's AirPods Pro")
                && !AudioInputDevices.isInternalDeviceName("External USB Mic"),
            "real microphone names are shown")
        // The backstop matches only the generated form — a real device whose
        // name merely starts with that string is NOT hidden (review finding);
        // the private-aggregate flag remains the authoritative filter.
        expect(
            !AudioInputDevices.isInternalDeviceName("CADefaultDeviceAggregate Pro")
                && !AudioInputDevices.isInternalDeviceName("CADefaultDeviceAggregate-mic"),
            "the name backstop does not over-match legitimate names")
    }

    private static func testMicrophoneCaptureDeviceSelection() {
        expect(
            MicrophoneCaptureDevicePolicy.selectedUID(
                persistedUID: "BuiltInMicrophoneDevice",
                availableUIDs: ["AirPods:input", "BuiltInMicrophoneDevice"],
                defaultUID: "AirPods:input") == "BuiltInMicrophoneDevice",
            "a chosen built-in microphone stays independent from AirPods system output")
        expect(
            MicrophoneCaptureDevicePolicy.selectedUID(
                persistedUID: "DisconnectedUSBMic",
                availableUIDs: ["AirPods:input", "BuiltInMicrophoneDevice"],
                defaultUID: "AirPods:input") == "AirPods:input",
            "a disconnected chosen microphone falls back to the current default")
        expect(
            MicrophoneCaptureDevicePolicy.selectedUID(
                persistedUID: nil,
                availableUIDs: ["BuiltInMicrophoneDevice"],
                defaultUID: nil) == "BuiltInMicrophoneDevice",
            "microphone capture can use the only available input when no default is reported")
    }

    private static func testMeetingSystemAudioFrameMath() {
        expect(
            SystemAudioFrameMath.frames(byteCount: 4_096, bytesPerFrame: 8) == 512,
            "system-audio IO derives frames from the tap stream format")
        expect(
            SystemAudioFrameMath.frames(byteCount: 4_096, bytesPerFrame: 0) == 0,
            "system-audio IO rejects an unusable zero-byte frame format")
    }

    /// Explicit opt-in integration probe for the signed app. It listens only
    /// long enough to prove buffers arrive, retains no microphone audio, and is
    /// excluded from ordinary/CI selftests because it needs the user's TCC grant.
    private static func testLiveMicrophoneCapture() {
        let source = MicrophoneStreamCapture()
        let sourceLock = NSLock()
        var rawFrames = 0
        var sourceFailure: String?
        var sourceStart: Result<Void, Error>?
        source.start(
            persistedUID: AppConfig.shared.inputDeviceUID,
            onBuffer: { buffer in
                sourceLock.lock(); rawFrames += Int(buffer.frameLength); sourceLock.unlock()
            },
            onFailure: { message in
                sourceLock.lock(); sourceFailure = message; sourceLock.unlock()
            },
            completion: { sourceStart = $0 })
        _ = waitUntil(timeout: 3) { sourceStart != nil }
        if case .success = sourceStart {
            _ = waitUntil(timeout: 3) {
                sourceLock.lock(); defer { sourceLock.unlock() }
                return rawFrames > 0 || sourceFailure != nil
            }
            var stopped = false
            source.stop { stopped = true }
            _ = waitUntil(timeout: 3) { stopped }
            sourceLock.lock()
            let receivedRaw = rawFrames
            let rawFailure = sourceFailure
            sourceLock.unlock()
            expect(receivedRaw > 0,
                   "direct selected-microphone source receives PCM"
                       + (rawFailure.map { ": \($0)" } ?? ""))
        } else {
            source.stop()
            let detail: String
            if case .failure(let error) = sourceStart {
                detail = error.localizedDescription
            } else {
                detail = "timed out"
            }
            expect(false, "direct selected-microphone source starts: \(detail)")
        }

        let capture = AudioCapture()
        let lock = NSLock()
        var byteCount = 0
        var captureFailure: String?
        capture.onDeviceLost = { message in
            lock.lock(); captureFailure = message; lock.unlock()
        }
        var captureStart: Result<Void, Error>?
        capture.start(onChunk: { data in
                lock.lock(); byteCount += data.count; lock.unlock()
            }, onLevel: { _ in }, completion: { captureStart = $0 })
        _ = waitUntil(timeout: 3) { captureStart != nil }
        if case .success = captureStart {
            _ = waitUntil(timeout: 3) {
                lock.lock(); defer { lock.unlock() }
                return byteCount > 0
            }
            var stopped = false
            capture.stop { stopped = true }
            _ = waitUntil(timeout: 3) { stopped }
            lock.lock()
            let captured = byteCount
            let convertedFailure = captureFailure
            lock.unlock()
            expect(captured > 0,
                   "live microphone probe receives 16 kHz PCM from the selected/AirPods route"
                       + (convertedFailure.map { ": \($0)" } ?? ""))
        } else {
            capture.stop()
            let detail: String
            if case .failure(let error) = captureStart {
                detail = error.localizedDescription
            } else {
                detail = "timed out"
            }
            expect(false, "live microphone probe starts: \(detail)")
        }
    }

    /// Plays one stock macOS sound from a child process and records it through
    /// the audio-only Core Audio tap. The temporary CAF is deleted immediately.
    private static func testLiveSystemAudioCapture() {
        guard #available(macOS 14.2, *) else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-system-audio-probe-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("probe.caf")
        let capture = CoreAudioSystemAudioCapture()
        let lock = NSLock()
        var frames = 0
        capture.onFrames = { count in
            lock.lock(); frames += count; lock.unlock()
        }
        do {
            try capture.start(to: url)
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["/System/Library/Sounds/Glass.aiff"]
            try player.run()
            _ = waitUntil(timeout: 4) {
                lock.lock(); defer { lock.unlock() }
                return frames > 0
            }
            player.waitUntilExit()
            let hadFrames = capture.stop()
            let audio = try? AVAudioFile(forReading: url)
            lock.lock(); let callbackFrames = frames; lock.unlock()
            expect(hadFrames && callbackFrames > 0 && (audio?.length ?? 0) > 0,
                   "audio-only Core Audio tap records synthetic computer audio into CAF")
        } catch {
            _ = capture.stop()
            expect(false, "live system-audio probe starts: \(error.localizedDescription)")
        }
    }

    /// Exercises the same two-track owner used by the meeting UI, including
    /// its frame-readiness gate and lazy microphone file creation. The probe
    /// deletes its private meeting directory immediately after inspection.
    private static func testLiveMeetingCapture() {
        let meetingID = "selftest-\(UUID().uuidString)"
        let directory = AppConfig.meetingsDirectory
            .appendingPathComponent(meetingID, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = MeetingAudioCapture()
        var startResult: Result<MeetingCaptureStart, MeetingCaptureError>?
        capture.start(meetingID: meetingID) { startResult = $0 }
        _ = waitUntil(timeout: 7) { startResult != nil }

        guard case .success(let start) = startResult else {
            if case .failure(let error) = startResult {
                expect(false, "live meeting capture becomes ready: \(error.localizedDescription)")
            } else {
                expect(false, "live meeting capture becomes ready before its startup deadline")
            }
            capture.stop(cancelled: true) { _ in }
            return
        }

        var files: MeetingCaptureFiles?
        var stopFinished = false
        capture.stop(cancelled: false) {
            files = $0
            stopFinished = true
        }
        _ = waitUntil(timeout: 5) { stopFinished }
        let micURL = directory.appendingPathComponent("me.caf")
        let systemURL = directory.appendingPathComponent("them.caf")
        let micAudio = try? AVAudioFile(forReading: micURL)
        let systemAudio = try? AVAudioFile(forReading: systemURL)
        expect(
            files?.micRelativePath == "\(meetingID)/me.caf"
                && (micAudio?.length ?? 0) > 0,
            "live meeting flow writes a readable nonempty selected-microphone track")
        if start.systemAudio {
            expect(
                files?.systemRelativePath == "\(meetingID)/them.caf"
                    && (systemAudio?.length ?? 0) > 0,
                "live meeting flow writes a readable nonempty computer-audio track")
        }
    }

    // MARK: - Dictation media pause/resume

    private final class FakeMicrophoneSource: MicrophoneStreamCapturing {
        struct StartCall {
            let onBuffer: (AVAudioPCMBuffer) -> Void
            let onFailure: (String) -> Void
            let completion: (Result<Void, Error>) -> Void
        }

        var starts: [StartCall] = []
        var stops: [() -> Void] = []

        func start(
            persistedUID: String?,
            onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
            onFailure: @escaping (String) -> Void,
            completion: @escaping (Result<Void, Error>) -> Void
        ) {
            starts.append(.init(
                onBuffer: onBuffer, onFailure: onFailure, completion: completion))
        }

        func stop(completion: @escaping () -> Void) {
            stops.append(completion)
        }
    }

    private static func testAudioCaptureRapidRestart() {
        let source = FakeMicrophoneSource()
        let capture = AudioCapture(source: source)
        var firstStarted = false
        var firstStopped = false
        var secondStarted = false
        var secondBytes = 0

        capture.start(
            onChunk: { _ in }, onLevel: { _ in },
            completion: { result in
                if case .success = result { firstStarted = true }
            })
        source.starts[0].completion(.success(()))
        expect(firstStarted && capture.isRunning, "first microphone session starts")

        capture.stop { firstStopped = true }
        capture.start(
            onChunk: { secondBytes += $0.count }, onLevel: { _ in },
            completion: { result in
                if case .success = result { secondStarted = true }
            })
        expect(source.starts.count == 2 && source.stops.count == 1,
               "a new microphone session may begin while old teardown is pending")

        // AVCapture stopRunning can take long enough for this completion to
        // arrive after the new start has installed its handlers.
        source.stops[0]()
        source.starts[1].completion(.success(()))
        expect(firstStopped && secondStarted && capture.isRunning,
               "a stale stop completion does not stop the newer session")

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for index in 0..<1600 { buffer.floatChannelData![0][index] = 0.1 }
        source.starts[1].onBuffer(buffer)
        _ = waitUntil { secondBytes > 0 }
        expect(secondBytes == 1600 * MemoryLayout<Float>.size,
               "new microphone handlers still receive PCM after stale teardown")

        capture.stop()
        source.stops[1]()
    }

    private static func testMediaPlaybackNoop() {
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { .init(processes: [], playing: []) },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        coordinator.restoreAfterDictation()

        expect(toggles == 0, "dictation never toggles media that was already paused")
        expect(scheduled.isEmpty, "no-player dictation schedules no media work")
    }

    private static func testMediaPlaybackUnknownStateFailsClosed() {
        let player = AudioObjectID(40)
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: {
                .init(processes: [player], playing: [player], isComplete: false)
            },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()

        expect(toggles == 0, "an unreadable Core Audio snapshot never sends a media command")
        expect(scheduled.isEmpty, "unknown media state never creates a resume obligation")
    }

    private static func testMediaPlaybackPauseResume() {
        let player = AudioObjectID(41) // browser, Music, Spotify, or another media process
        var snapshot = MediaPlaybackCoordinator.Snapshot(
            processes: [player], playing: [player])
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { snapshot },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        expect(toggles == 1, "single-process media gets one pause command at dictation start")
        expect(scheduled.count == 1, "a posted pause is verified before Velora owns resumption")

        snapshot.playing = []
        snapshot.allPlaying = []
        scheduled.removeFirst().1()
        coordinator.restoreAfterDictation()
        expect(scheduled.count == 1, "verified media pause schedules a delayed restore")

        scheduled.removeFirst().1()
        expect(toggles == 2, "only a verified Velora pause gets a matching resume command")
    }

    private static func testMediaPlaybackEarlyStop() {
        let player = AudioObjectID(42)
        var snapshot = MediaPlaybackCoordinator.Snapshot(
            processes: [player], playing: [player])
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { snapshot },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        coordinator.restoreAfterDictation()
        snapshot.playing = []
        snapshot.allPlaying = []
        scheduled.removeFirst().1()
        expect(scheduled.count == 1,
               "capture ending before pause verification still queues the required restore")

        scheduled.removeFirst().1()
        expect(toggles == 2, "an early stop restores media after verification completes")
    }

    private static func testMediaPlaybackFailedPause() {
        let player = AudioObjectID(43)
        let snapshot = MediaPlaybackCoordinator.Snapshot(
            processes: [player], playing: [player])
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { snapshot },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        while !scheduled.isEmpty { scheduled.removeFirst().1() }
        coordinator.restoreAfterDictation()

        expect(toggles == 1, "an unobserved pause is never followed by a destructive toggle")
        expect(scheduled.isEmpty, "failed pause verification leaves no restore pending")
    }

    private static func testMediaPlaybackUserOverride() {
        let player = AudioObjectID(44)
        var snapshot = MediaPlaybackCoordinator.Snapshot(
            processes: [player], playing: [player])
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { snapshot },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        snapshot.playing = []
        snapshot.allPlaying = []
        scheduled.removeFirst().1()
        coordinator.restoreAfterDictation()
        snapshot.playing = [player]
        snapshot.allPlaying = [player]
        scheduled.removeFirst().1()

        expect(toggles == 1, "Velora does not toggle media the user already resumed")
    }

    private static func testMediaPlaybackAmbiguousPlayers() {
        let first = AudioObjectID(45)
        let second = AudioObjectID(46)
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { .init(processes: [first, second], playing: [first, second]) },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()

        expect(toggles == 0, "simultaneous output processes make the global media target ambiguous")
        expect(scheduled.isEmpty, "ambiguous media ownership schedules no pause verification")
    }

    private static func testMediaPlaybackMisdirectedToggleRollsBack() {
        let intended = AudioObjectID(54)
        let accidental = AudioObjectID(55)
        var snapshot = MediaPlaybackCoordinator.Snapshot(
            processes: [intended], playing: [intended])
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { snapshot },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        snapshot.processes = [intended, accidental]
        snapshot.playing = [intended, accidental]
        snapshot.allPlaying = [intended, accidental]
        scheduled.removeFirst().1()
        coordinator.restoreAfterDictation()

        expect(toggles == 2, "a media key that starts the wrong player is immediately reversed")
        expect(scheduled.isEmpty, "a misdirected media key never earns a later resume")
    }

    private static func testMediaPlaybackUnsupportedOutput() {
        let music = AudioObjectID(47)
        let call = AudioObjectID(48)
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: {
                .init(
                    processes: [music], playing: [music],
                    allPlaying: [music, call])
            },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()

        expect(toggles == 0, "simultaneous conference output makes media-key targeting unsafe")
        expect(scheduled.isEmpty, "conference output schedules no media work")
    }

    private static func testMediaPlaybackActiveInput() {
        let browser = AudioObjectID(60)
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: {
                .init(
                    processes: [browser], playing: [browser],
                    inputProcesses: [browser],
                    bundleIDs: [browser: "com.google.Chrome.helper"])
            },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        expect(toggles == 0, "browser media keys are blocked while another process captures input")
        expect(scheduled.isEmpty, "active call input creates no media resume obligation")
    }

    private static func testMediaPlaybackUnrelatedSystemInput() {
        let browser = AudioObjectID(61)
        let systemSpeech = AudioObjectID(62)
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: {
                .init(
                    processes: [browser, systemSpeech], playing: [browser],
                    inputProcesses: [systemSpeech],
                    bundleIDs: [
                        browser: "com.google.Chrome.helper",
                        systemSpeech: "com.apple.CoreSpeech",
                    ])
            },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        expect(toggles == 1, "unrelated system speech input does not block browser media")
        expect(scheduled.count == 1, "eligible browser media still enters verification")
    }

    private static func testMediaPlaybackUnsupportedOutputOnRestore() {
        let music = AudioObjectID(50)
        let call = AudioObjectID(51)
        var snapshot = MediaPlaybackCoordinator.Snapshot(
            processes: [music], playing: [music])
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { snapshot },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        snapshot.playing = []
        snapshot.allPlaying = []
        scheduled.removeFirst().1()
        coordinator.restoreAfterDictation()
        snapshot.allPlaying = [call]
        scheduled.removeFirst().1()

        expect(toggles == 1, "new conference audio suppresses the media resume toggle")
    }

    private static func testMediaPlaybackTerminationRestore() {
        let player = AudioObjectID(49)
        var snapshot = MediaPlaybackCoordinator.Snapshot(
            processes: [player], playing: [player])
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { snapshot },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        snapshot.playing = []
        snapshot.allPlaying = []
        scheduled.removeFirst().1()
        coordinator.restoreAfterDictation()
        coordinator.restoreImmediatelyForTermination()

        expect(toggles == 2, "termination restores verified media without waiting on a timer")
        scheduled.removeFirst().1()
        expect(toggles == 2, "the stale delayed restore is inert after termination restoration")
    }

    private static func testMediaPlaybackTerminationDuringVerification() {
        let player = AudioObjectID(52)
        var snapshot = MediaPlaybackCoordinator.Snapshot(
            processes: [player], playing: [player])
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { snapshot },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        snapshot.playing = []
        snapshot.allPlaying = []
        coordinator.restoreImmediatelyForTermination()
        scheduled.removeFirst().1()

        expect(toggles == 2, "termination can restore a pause before verification fires")
    }

    private static func testMediaPlaybackRapidRestart() {
        let player = AudioObjectID(53)
        var snapshot = MediaPlaybackCoordinator.Snapshot(
            processes: [player], playing: [player])
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { snapshot },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        coordinator.restoreAfterDictation()
        coordinator.pauseForDictation()
        snapshot.playing = []
        snapshot.allPlaying = []
        scheduled.removeFirst().1()
        expect(scheduled.isEmpty,
               "a second dictation inherits a pending pause without an early resume")
        coordinator.restoreAfterDictation()
        expect(scheduled.count == 1,
               "the inherited pause is restored only after the second dictation")
        scheduled.removeFirst().1()
        expect(toggles == 2, "rapid dictations produce one pause and one final resume")

        // Also cover a restart after the restore timer was already scheduled.
        snapshot.playing = [player]
        snapshot.allPlaying = [player]
        coordinator.pauseForDictation()
        snapshot.playing = []
        snapshot.allPlaying = []
        scheduled.removeFirst().1()
        coordinator.restoreAfterDictation()
        let staleRestore = scheduled.removeFirst().1
        coordinator.pauseForDictation()
        staleRestore()
        expect(toggles == 3, "a restarted dictation cancels the stale resume timer")
        coordinator.restoreAfterDictation()
        scheduled.removeFirst().1()
        expect(toggles == 4, "the restarted dictation eventually performs one resume")
    }

    private static func testMediaPlaybackMisdirectedRestoreRollsBack() {
        let intended = AudioObjectID(56)
        let accidental = AudioObjectID(57)
        var snapshot = MediaPlaybackCoordinator.Snapshot(
            processes: [intended], playing: [intended])
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { snapshot },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        snapshot.playing = []
        snapshot.allPlaying = []
        scheduled.removeFirst().1()
        coordinator.restoreAfterDictation()
        scheduled.removeFirst().1()

        snapshot.processes = [intended, accidental]
        snapshot.playing = [accidental]
        snapshot.allPlaying = [accidental]
        scheduled.removeFirst().1()

        expect(toggles == 3, "a media restore that starts the wrong player is reversed")
        coordinator.restoreAfterDictation()
        expect(scheduled.isEmpty, "a misdirected restore leaves no outstanding media work")
    }

    private static func testMediaPlaybackBrowserStreamDrain() {
        let browser = AudioObjectID(58)
        let snapshot = MediaPlaybackCoordinator.Snapshot(
            processes: [browser],
            playing: [browser],
            bundleIDs: [browser: "com.google.Chrome.helper"])
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { snapshot },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        // Chrome deliberately remains `IsRunningOutput == true` for roughly
        // 15 seconds after its Media Session has accepted the pause.
        for _ in 0..<4 { scheduled.removeFirst().1() }
        coordinator.restoreAfterDictation()
        scheduled.removeFirst().1()
        expect(toggles == 2,
               "a browser pause is paired without waiting for its stale Core Audio stream")

        scheduled.removeFirst().1()
        expect(scheduled.isEmpty, "the paired browser restore creates no extra media commands")
    }

    private static func testMediaPlaybackSupportedPlayers() {
        expect(
            MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.apple.Music")
                && MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.spotify.client")
                && MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.google.Chrome")
                && MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.google.Chrome.helper")
                && MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "org.mozilla.firefox"),
            "dedicated players and browser playback are eligible for direct dictation pause")
        expect(
            !MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.apple.FaceTime")
                && !MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "us.zoom.xos")
                && !MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.microsoft.teams2")
                && !MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.example.unknown"),
            "conference clients and unknown output never trigger a global media toggle")
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

    /// The delivery-layer fallback for targets with no readable AX caret:
    /// a recent delivery into the same target synthesizes the boundary from
    /// the prior inserted text, so consecutive dictations never concatenate
    /// while punctuation follow-ups stay attached and code targets are
    /// never reshaped.
    private static func testInsertionContinuation() {
        let base = Date()
        let prior = TextInserter.PriorDelivery(
            bundleID: "com.example.chat", element: nil,
            tail: "First sentence.", at: base)

        let boundary = TextInserter.continuationBoundary(
            prior: prior, targetBundleID: "com.example.chat", targetElement: nil,
            mode: nil, typingFallbackApps: [], now: base.addingTimeInterval(5))
        expect(
            boundary == TextSelectionBoundary(before: "First sentence.", after: ""),
            "a recent same-target delivery yields its tail as the boundary")
        expect(
            TextInsertionBoundary.adjusted("Second sentence.", boundary: boundary, mode: nil)
                == " Second sentence.",
            "consecutive dictations without an AX caret get one separating space")
        expect(
            TextInsertionBoundary.adjusted("!", boundary: boundary, mode: nil) == "!",
            "a punctuation-only follow-up stays attached to the prior dictation")

        expect(
            TextInserter.continuationBoundary(
                prior: prior, targetBundleID: "com.example.chat", targetElement: nil,
                mode: nil, typingFallbackApps: [],
                now: base.addingTimeInterval(TextInserter.continuationWindow + 1)) == nil,
            "the continuation memory expires after the bounded window")
        expect(
            TextInserter.continuationBoundary(
                prior: prior, targetBundleID: "com.example.editor", targetElement: nil,
                mode: nil, typingFallbackApps: [], now: base.addingTimeInterval(5)) == nil,
            "a different app never inherits the prior delivery's boundary")
        expect(
            TextInserter.continuationBoundary(
                prior: prior, targetBundleID: nil, targetElement: nil,
                mode: nil, typingFallbackApps: [], now: base.addingTimeInterval(5)) == nil,
            "an unknown target never gets an invented separator")

        expect(
            TextInserter.continuationBoundary(
                prior: prior, targetBundleID: "com.example.chat", targetElement: nil,
                mode: "Code", typingFallbackApps: [], now: base.addingTimeInterval(5)) == nil,
            "Code mode never gets an invented separator")
        expect(
            TextInserter.continuationBoundary(
                prior: prior, targetBundleID: "com.example.chat", targetElement: nil,
                mode: "Terminal", typingFallbackApps: [], now: base.addingTimeInterval(5)) == nil,
            "Terminal mode never gets an invented separator")
        expect(
            TextInserter.continuationBoundary(
                prior: TextInserter.PriorDelivery(
                    bundleID: "com.apple.Terminal", element: nil,
                    tail: "ls", at: base),
                targetBundleID: "com.apple.Terminal", targetElement: nil,
                mode: nil, typingFallbackApps: ["com.apple.Terminal"],
                now: base.addingTimeInterval(5)) == nil,
            "typing-fallback (terminal-like) targets never get an invented separator")

        // AXUIElementCreateApplication needs no TCC grant; two pids give
        // distinguishable elements for the moved-fields check.
        let elementA = AXUIElementCreateApplication(1)
        let elementB = AXUIElementCreateApplication(2)
        let elementPrior = TextInserter.PriorDelivery(
            bundleID: "com.example.chat", element: elementA,
            tail: "First sentence.", at: base)
        expect(
            TextInserter.continuationBoundary(
                prior: elementPrior, targetBundleID: "com.example.chat",
                targetElement: elementB, mode: nil, typingFallbackApps: [],
                now: base.addingTimeInterval(5)) == nil,
            "a different focused element never inherits the prior boundary")
        expect(
            TextInserter.continuationBoundary(
                prior: elementPrior, targetBundleID: "com.example.chat",
                targetElement: elementA, mode: nil, typingFallbackApps: [],
                now: base.addingTimeInterval(5)) != nil,
            "the same focused element keeps the continuation boundary")
    }

    private static func testEngineRestartDelay() {
        expect(
            EngineSupervisor.restartDelay(
                status: EngineSupervisor.cleanupRestartExitStatus, attempt: 1) == 0,
            "a poisoned cleanup worker requests an immediate sidecar replacement")
        expect(
            EngineSupervisor.restartDelay(status: 1, attempt: 1) == 2,
            "the first unexpected engine crash retains exponential backoff")
        expect(
            EngineSupervisor.restartDelay(status: 1, attempt: 10) == 30,
            "unexpected engine crash backoff remains capped")
        expect(
            EngineSupervisor.nextRestartAttempt(
                status: EngineSupervisor.cleanupRestartExitStatus, current: 4) == 4,
            "controlled cleanup replacement does not consume the crash budget")
        expect(
            EngineSupervisor.nextRestartAttempt(status: 1, current: 4) == 5,
            "an unexpected engine crash increments the crash budget")
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

        let customType = NSPasteboard.PasteboardType("com.velora.selftest.custom")
        let original = NSPasteboardItem()
        original.setString("Original clipboard", forType: .string)
        original.setData(Data([0, 1, 2, 255]), forType: customType)
        pasteboard.clearContents()
        pasteboard.writeObjects([original])
        let saved = TextInserter.snapshotItems(from: pasteboard)
        inserter.stageFinalOutput("Temporary dictation")
        let dictationChange = pasteboard.changeCount
        expect(
            TextInserter.restore(saved, to: pasteboard, ifUnchanged: dictationChange)
                && pasteboard.string(forType: .string) == "Original clipboard"
                && pasteboard.data(forType: customType) == Data([0, 1, 2, 255]),
            "successful paste restoration preserves every clipboard representation")

        let savedAgain = TextInserter.snapshotItems(from: pasteboard)
        inserter.stageFinalOutput("Another temporary dictation")
        let staleChange = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("User copied this", forType: .string)
        expect(
            !TextInserter.restore(savedAgain, to: pasteboard, ifUnchanged: staleChange)
                && pasteboard.string(forType: .string) == "User copied this",
            "clipboard restoration never overwrites a newer user copy")
        pasteboard.clearContents()
    }
}
