import AppKit
import AVFoundation
import CoreAudio
import Foundation
import SQLite3
import UniformTypeIdentifiers

final class HotkeySelftestDelegate: HotkeyMonitorDelegate {
    var hotkeyDownCount = 0
    var hotkeyUpCount = 0
    var editHotkeyDownCount = 0
    var editHotkeyUpCount = 0
    var streamHotkeyDownCount = 0
    var streamHotkeyUpCount = 0
    var actionHotkeyDownCount = 0
    var actionHotkeyUpCount = 0
    var escapeCount = 0
    var nonHotkeyInputCount = 0

    func hotkeyDown() { hotkeyDownCount += 1 }
    func hotkeyUp() { hotkeyUpCount += 1 }

    func secondaryHotkeyDown(_ role: SecondaryHotkeyRole) {
        switch role {
        case .edit: editHotkeyDownCount += 1
        case .stream: streamHotkeyDownCount += 1
        case .action: actionHotkeyDownCount += 1
        }
    }

    func secondaryHotkeyUp(_ role: SecondaryHotkeyRole) {
        switch role {
        case .edit: editHotkeyUpCount += 1
        case .stream: streamHotkeyUpCount += 1
        case .action: actionHotkeyUpCount += 1
        }
    }
    func escapePressed() { escapeCount += 1 }
    func nonHotkeyInput() { nonHotkeyInputCount += 1 }
}

/// Headless pure-logic tests, run with `Velora --selftest` (CommandLineTools
/// ships no XCTest/swift-testing, so tests live in the binary). Covers the
/// learning loop's thresholds, the correction diff, and protocol parsing —
/// everything deterministic that doesn't need TCC grants or the engine.
enum Selftest {
    private static var failures = 0
    private static var checks = 0

    // Internal (not private) so suites can live in their own files —
    // ActionSelftest.swift is the first.
    static func expect(
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
    static func waitUntil(
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
        testSafeVoiceEditSelection()
        testModeCategories()
        testScreenContextSites()
        testModeApplicationAssignments()
        testVoiceCommands()
        testStreak()
        testLongestStreak()
        testHistoryStoreMigration()
        testHistoryEdit()
        testHistoryClearAll()
        testIntelligenceAggregates()
        if ProcessInfo.processInfo.environment["VELORA_PERF_SELFTEST"] == "1" {
            testIntelligencePerformance100K()
        }
        testQualityObservationMetrics()
        testMeetingStore()
        testMeetingProcessingPipeline()
        testMeetingFailurePresentation()
        testMeetingCaptureReadiness()
        testMeetingSystemAudioBackendPolicy()
        testMeetingSystemAudioFrameMath()
        testMeetingSystemAudioFileWriter()
        testMeetingSystemAudioWarnings()
        testMeetingDetection()
        testMeetingEndWatch()
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
        testAudioCaptureRequiresPCM()
        testAudioCaptureQuickReleasePreservesFirstPCM()
        testAudioCaptureStopPreservesConvertedTail()
        testAudioCaptureRapidRestart()
        testMediaPlaybackNoop()
        testMediaPlaybackUnknownStateFailsClosed()
        testMediaPlaybackPauseResume()
        testMediaPlaybackEarlyStop()
        testMediaPlaybackFailedPause()
        testMediaPlaybackUserOverride()
        testMediaPlaybackAmbiguousPlayers()
        testMediaPlaybackPausedBrowserBlocksDedicatedPause()
        testMediaPlaybackMisdirectedToggleRollsBack()
        testMediaPlaybackUnsupportedOutput()
        testMediaPlaybackActiveInput()
        testMediaPlaybackUnrelatedSystemInput()
        testMediaPlaybackUnsupportedOutputOnRestore()
        testMediaPlaybackTerminationRestore()
        testMediaPlaybackTerminationDuringVerification()
        testMediaPlaybackRapidRestart()
        testMediaPlaybackMisdirectedRestoreRollsBack()
        testMediaPlaybackPausedBrowserBlocksDedicatedRestore()
        testMediaPlaybackMisdirectedRestoreRollsBackOnTermination()
        testMediaPlaybackPausedBrowserFailsClosed()
        testMediaPlaybackSupportedPlayers()
        testInsertionBoundary()
        testInsertionContinuation()
        if ProcessInfo.processInfo.environment["VELORA_STREAM_TYPING_E2E"] == "1" {
            testLiveStreamTypingInsertion()
        }
        testEngineRestartDelay()
        testEmptyFinalFeedback()
        testClipboardStaging()
        testActionMode()
        testFinderFileTranscriptionQueue()
        testUpdateChecker()
        testStatusMenuUpdateEntry()
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

    /// Opt-in signed/install-surface proof against a real TextEdit AX target.
    /// It exercises capture → provisional insert → revision → polished final;
    /// deterministic policy and hotkey routing remain in the normal suite.
    private static func testLiveStreamTypingInsertion() {
        guard Permissions.accessibilityGranted, TextInserter.canPostEvents else {
            expect(false, "Stream Typing E2E requires Accessibility permission")
            return
        }
        let bundleID = "com.apple.TextEdit"
        let attachesPreparedFixture = ProcessInfo.processInfo.environment[
            "VELORA_STREAM_TYPING_E2E_ATTACHED_FIXTURE"] == "1"
        let runningTextEdit = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID)
        guard attachesPreparedFixture || runningTextEdit.isEmpty else {
            expect(false, "Stream Typing E2E requires TextEdit to be closed")
            return
        }
        let prefix = "Prefix "
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-stream-e2e-\(UUID().uuidString)")
        let fixtureURL = fixtureDirectory.appendingPathComponent("stream-fixture.txt")
        do {
            try FileManager.default.createDirectory(
                at: fixtureDirectory, withIntermediateDirectories: true)
            try prefix.write(to: fixtureURL, atomically: true, encoding: .utf8)
        } catch {
            expect(false, "Stream Typing E2E creates its temporary fixture")
            return
        }
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let app: NSRunningApplication
        let element: AXUIElement
        let ownsApp: Bool
        if attachesPreparedFixture {
            guard let attached = runningTextEdit.first,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == attached.processIdentifier,
                  let focused = ScreenContext.focusedElement(of: attached)
            else {
                expect(false, "Stream Typing E2E attaches only to focused TextEdit")
                return
            }
            app = attached
            element = focused
            ownsApp = false
        } else {
            guard let textEditURL = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: bundleID)
            else {
                expect(false, "Stream Typing E2E finds TextEdit")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            var launchedApp: NSRunningApplication?
            var launchFinished = false
            var launchError: Error?
            NSWorkspace.shared.open(
                [fixtureURL], withApplicationAt: textEditURL,
                configuration: configuration
            ) { openedApp, error in
                launchedApp = openedApp
                launchError = error
                launchFinished = true
            }
            guard waitUntil(timeout: 5, { launchFinished }), launchError == nil,
                  let launchedApp
            else {
                launchedApp?.forceTerminate()
                expect(false, "TextEdit opened the Stream Typing fixture")
                return
            }
            app = launchedApp
            ownsApp = true
            guard waitUntil(timeout: 5, {
                      if NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                          == bundleID {
                          return true
                      }
                      _ = launchedApp.activate()
                      return false
                  }),
                  let focused = ScreenContext.focusedElement(of: launchedApp)
            else {
                launchedApp.forceTerminate()
                expect(false, "TextEdit focused the Stream Typing fixture")
                return
            }
            element = focused
        }
        defer {
            if ownsApp { app.forceTerminate() }
        }

        guard AXUIElementSetAttributeValue(
                element, kAXValueAttribute as CFString, prefix as CFString) == .success
        else {
            expect(false, "TextEdit accepts the E2E fixture text")
            return
        }
        var caret = CFRange(location: prefix.utf16.count, length: 0)
        guard let caretValue = AXValueCreate(.cfRange, &caret),
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                caretValue) == .success,
              let target = ScreenContext.streamTarget(of: app)
        else {
            expect(false, "Stream Typing captures TextEdit's exact caret")
            return
        }

        let stream = StreamTypingSession(target: target)
        stream.update("hello", mode: "Note")
        expect(waitUntil(timeout: 3) {
            ScreenContext.streamOwnsDraft("hello", target: target)
        }, "the first provisional transcript appears at the real cursor")

        stream.update("hello world", mode: "Note")
        expect(waitUntil(timeout: 3) {
            ScreenContext.streamOwnsDraft("hello world", target: target)
        }, "a newer provisional transcript replaces the owned draft")

        var finish: StreamTypingSession.FinishResult?
        stream.finish("Hello, world.", mode: "Note") { finish = $0 }
        expect(waitUntil(timeout: 3) { finish != nil },
               "the polished Stream Typing final completes")
        if case .applied? = finish {
            expect(true, "the polished final retained exact range ownership")
        } else {
            expect(false, "the polished final retained exact range ownership")
        }
        expect(
            ScreenContext.stringValue(of: element) == "Prefix Hello, world.",
            "TextEdit contains one polished final with no duplicate provisional text")

        let polished = "Prefix Hello, world."
        var selectedHello = CFRange(location: prefix.utf16.count, length: 5)
        guard let selectedHelloValue = AXValueCreate(.cfRange, &selectedHello),
              AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString,
                selectedHelloValue) == .success,
              let cancelTarget = ScreenContext.streamTarget(of: app)
        else {
            expect(false, "the cancellation fixture captures a non-empty selection")
            return
        }
        var cancelled: StreamTypingSession? = StreamTypingSession(target: cancelTarget)
        weak let releasedCancellation = cancelled
        var cancellationFinished = false
        var restorationCompleteAtCallback = false
        cancelled?.update(String(repeating: "temporary-", count: 80), mode: "Note")
        cancelled?.cancel { result in
            restorationCompleteAtCallback =
                result == .restored
                && ScreenContext.stringValue(of: element) == polished
                && ScreenContext.streamOriginalIsCurrent(cancelTarget)
            cancellationFinished = true
            // Mirrors DictationController releasing streamCancellation only
            // after asynchronous restoration has completed.
            cancelled = nil
        }
        expect(waitUntil(timeout: 5) { cancellationFinished },
               "mid-chunk cancellation finishes its asynchronous restoration")
        expect(
            ScreenContext.stringValue(of: element) == polished
                && ScreenContext.streamOriginalIsCurrent(cancelTarget),
            "mid-chunk cancellation restores the exact original text and selection")
        expect(restorationCompleteAtCallback,
               "a Stream voice command callback runs only after exact restoration")
        expect(waitUntil(timeout: 1) { releasedCancellation == nil },
               "the cancelled session is released only after restoration")

        var finalEnd = CFRange(location: polished.utf16.count, length: 0)
        guard let finalEndValue = AXValueCreate(.cfRange, &finalEnd),
              AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString,
                finalEndValue) == .success,
              let movedTarget = ScreenContext.streamTarget(of: app)
        else {
            expect(false, "the cursor-loss fixture captures its starting caret")
            return
        }
        let moved = StreamTypingSession(target: movedTarget)
        moved.update("draft", mode: "Note")
        expect(waitUntil(timeout: 3) {
            ScreenContext.streamOwnsDraft(" draft", target: movedTarget)
        }, "the cursor-loss fixture owns its provisional draft")
        var movedCaret = CFRange(location: 0, length: 0)
        if let movedCaretValue = AXValueCreate(.cfRange, &movedCaret) {
            _ = AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString,
                movedCaretValue)
        }
        var movedFinish: StreamTypingSession.FinishResult?
        moved.finish("authoritative final", mode: "Note") { movedFinish = $0 }
        expect(waitUntil(timeout: 3) { movedFinish != nil },
               "cursor loss resolves without hanging")
        if case .ownershipLost? = movedFinish {
            expect(true, "cursor loss refuses to replace unrelated text")
        } else {
            expect(false, "cursor loss refuses to replace unrelated text")
        }
        expect(
            ScreenContext.stringValue(of: element) == polished + " draft",
            "cursor loss leaves the last visible draft untouched")

        // Force the universal fallback adapter even though TextEdit also
        // supports the preferred mutable-AX path. This is a signed, real-app
        // proof that Unicode events revise one bounded draft and cancellation
        // removes only that verified draft.
        let beforeKeystrokes = polished + " draft"
        var keystrokeCaret = CFRange(
            location: beforeKeystrokes.utf16.count, length: 0)
        guard let keystrokeCaretValue = AXValueCreate(
                .cfRange, &keystrokeCaret),
              AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString,
                keystrokeCaretValue) == .success,
              let keystrokeTarget = ScreenContext.keystrokeStreamTarget(of: app)
        else {
            expect(false, "the keystroke fallback captures a real editable control")
            return
        }
        let fallback = KeystrokeStreamTypingSession(target: keystrokeTarget)
        let firstFallback = TextInsertionBoundary.adjusted(
            "live words", boundary: keystrokeTarget.boundary, mode: "Note")
        fallback.update("live words", mode: "Note")
        expect(waitUntil(timeout: 3) {
            ScreenContext.keystrokeStreamOwnsDraft(
                firstFallback, target: keystrokeTarget)
        }, "the keystroke fallback types its first provisional transcript")

        let revisedFallback = TextInsertionBoundary.adjusted(
            "live words revised", boundary: keystrokeTarget.boundary,
            mode: "Note")
        fallback.update("live words revised", mode: "Note")
        expect(waitUntil(timeout: 3) {
            ScreenContext.keystrokeStreamOwnsDraft(
                revisedFallback, target: keystrokeTarget)
        }, "the keystroke fallback revises the owned provisional transcript")

        let finalFallback = TextInsertionBoundary.adjusted(
            "Live words, final.", boundary: keystrokeTarget.boundary,
            mode: "Note")
        var fallbackFinish: StreamTypingSession.FinishResult?
        fallback.finish("Live words, final.", mode: "Note") {
            fallbackFinish = $0
        }
        expect(waitUntil(timeout: 3) { fallbackFinish != nil },
               "the keystroke fallback polished final completes")
        let fallbackValue = ScreenContext.stringValue(of: element)
        expect(
            fallbackFinish == .applied,
            "the keystroke fallback verifies its polished final")
        expect(
            fallbackValue == beforeKeystrokes + finalFallback,
            "the keystroke fallback leaves one polished final")
        if fallbackValue != beforeKeystrokes + finalFallback {
            print(
                "keystroke fallback mismatch — finish=\(String(describing: fallbackFinish)) "
                    + "expected=\(String(reflecting: beforeKeystrokes + finalFallback)) "
                    + "actual=\(String(reflecting: fallbackValue))")
        }

        let beforeFallbackCancel = beforeKeystrokes + finalFallback
        var cancellationCaret = CFRange(
            location: beforeFallbackCancel.utf16.count, length: 0)
        guard let cancellationCaretValue = AXValueCreate(
                .cfRange, &cancellationCaret),
              AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString,
                cancellationCaretValue) == .success,
              let fallbackCancelTarget = ScreenContext.keystrokeStreamTarget(of: app)
        else {
            expect(false, "the keystroke cancellation fixture captures its caret")
            return
        }
        let fallbackCancel = KeystrokeStreamTypingSession(
            target: fallbackCancelTarget)
        let cancellationDraft = TextInsertionBoundary.adjusted(
            "temporary words", boundary: fallbackCancelTarget.boundary,
            mode: "Note")
        fallbackCancel.update("temporary words", mode: "Note")
        expect(waitUntil(timeout: 3) {
            ScreenContext.keystrokeStreamOwnsDraft(
                cancellationDraft, target: fallbackCancelTarget)
        }, "the keystroke cancellation fixture owns its draft")
        var fallbackCancellation: StreamTypingSession.CancellationResult?
        fallbackCancel.cancel { fallbackCancellation = $0 }
        expect(waitUntil(timeout: 3) { fallbackCancellation != nil },
               "the keystroke fallback cancellation completes")
        expect(
            fallbackCancellation == .restored
                && ScreenContext.stringValue(of: element)
                    == beforeFallbackCancel
                && ScreenContext.keystrokeStreamOwnsDraft(
                    "", target: fallbackCancelTarget),
            "the keystroke fallback cancellation restores the exact field")
    }

    // MARK: - Finder file transcription

    private static func testFinderFileTranscriptionQueue() {
        expect(
            FileTranscriptionTypePolicy.supports(contentType: .mp3)
                && FileTranscriptionTypePolicy.supports(contentType: .wav)
                && FileTranscriptionTypePolicy.supports(contentType: .quickTimeMovie)
                && FileTranscriptionTypePolicy.supports(contentType: .mpeg4Movie)
                && !FileTranscriptionTypePolicy.supports(contentType: .midi)
                && !FileTranscriptionTypePolicy.supports(contentType: .appleProtectedMPEG4Audio)
                && !FileTranscriptionTypePolicy.supports(contentType: .appleProtectedMPEG4Video)
                && !FileTranscriptionTypePolicy.supports(contentType: .movie),
            "file transcription accepts decodable media without advertising MIDI or DRM media")
        expect(
            FileTranscriptionTypePolicy.allowedContentTypes.map(\.identifier)
                == [
                    "public.mp3", "com.microsoft.waveform-audio", "public.aiff-audio",
                    "public.mpeg-4-audio", "com.apple.m4a-audio", "public.aac-audio",
                    "com.apple.coreaudio-format", "org.xiph.flac", "org.xiph.ogg-audio",
                    "com.apple.quicktime-movie", "public.mpeg-4",
                ],
            "the native picker exposes the exact Finder media type policy")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-open-files-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["first.wav", "ignored.txt", "second.mov", "third.mp4"].map {
            directory.appendingPathComponent($0)
        }
        for url in urls { try! Data().write(to: url) }

        var queue = FileTranscriptionQueue()
        expect(queue.enqueue(urls) == 3,
               "Finder queue rejects unsupported files before they can run")
        expect(queue.dequeueIfReady(engineReady: false, transcriberBusy: false) == nil,
               "Finder files wait through cold engine launch")
        expect(queue.dequeueIfReady(engineReady: true, transcriberBusy: true) == nil,
               "Finder files wait behind an existing transcription")
        let busy = queue.dequeueIfReady(engineReady: true, transcriberBusy: false)!
        queue.retry(busy)
        let drained = (0..<3).compactMap { _ in
            queue.dequeueIfReady(engineReady: true, transcriberBusy: false)?.lastPathComponent
        }
        expect(drained == ["first.wav", "second.mov", "third.mp4"]
                && queue.pendingURLs.isEmpty,
               "Finder files retain their original order across a busy retry")
        expect(!FileTranscriptionTypePolicy.supports(
            url: URL(string: "https://example.com/remote.mp4")!),
            "file transcription never admits a network URL")
    }

    // MARK: - Update checker

    private static func testStatusMenuUpdateEntry() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-status-menu-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let history = HistoryStore(url: directory.appendingPathComponent("history.sqlite3"))
        let controller = StatusItemController(history: history)
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        expect(
            menu.items.contains { $0.title == "Check for Updates…" && $0.isEnabled },
            "the status menu always exposes a manual update check")
        expect(
            !menu.items.contains { $0.title == "Check Permissions…" },
            "the status menu uses cached granted permission state")

        controller.permissionsMissing = true
        controller.menuNeedsUpdate(menu)
        expect(
            menu.items.contains { $0.title == "Check Permissions…" },
            "the status menu uses cached missing permission state")

        let hud = HUDPanel()
        let rootMenu = NSMenu()
        let submenu = NSMenu()
        NotificationCenter.default.post(
            name: NSMenu.didBeginTrackingNotification, object: rootMenu)
        NotificationCenter.default.post(
            name: NSMenu.didBeginTrackingNotification, object: submenu)
        expect(
            hud.menuTrackingDepth == 2,
            "HUD mouse tracking stays suspended through nested menu tracking")
        NotificationCenter.default.post(
            name: NSMenu.didEndTrackingNotification, object: submenu)
        expect(
            hud.menuTrackingDepth == 1,
            "closing a submenu does not resume HUD mouse tracking early")
        NotificationCenter.default.post(
            name: NSMenu.didEndTrackingNotification, object: rootMenu)
        expect(
            hud.menuTrackingDepth == 0,
            "HUD mouse tracking resumes only after the root menu closes")
    }

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
        {"tag_name": "v9.9.9", "html_url": "https://github.com/sushilk1991/velora/releases/tag/v9.9.9",
         "body": "## Improvements\\n\\n- One-click updates\\n- Full release notes",
         "published_at": "2026-07-30T01:02:03Z",
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
            expect(update.notes.contains("One-click updates"),
                   "carries the complete GitHub release body")
            expect(update.publishedAt != nil, "parses the release publication date")
        } else {
            expect(false, "release feed with newer tag parses as updateAvailable")
        }
        let noAssets = """
        {"tag_name": "v9.9.9", "html_url": "https://github.com/x/y/releases/tag/v9.9.9"}
        """.data(using: .utf8)
        if case .updateAvailable(let update) = UpdateChecker.parse(
            current: "0.7.2", data: noAssets, response: http, error: nil) {
            expect(update.asset == nil, "release without a DMG still surfaces, without an asset")
            expect(update.notes == "No release notes were provided for this version.",
                   "missing release notes get an honest fallback")
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
        let restoredAsset = UpdateChecker.restoredAsset(
            name: "Velora-1.2.3.dmg",
            rawURL:
                "https://github.com/sushilk1991/velora/releases/download/v1.2.3/Velora-1.2.3.dmg",
            size: 12_345)
        expect(
            restoredAsset?.name == "Velora-1.2.3.dmg"
                && restoredAsset?.size == 12_345,
            "validated cached DMG metadata restores the one-click update asset")
        expect(
            UpdateChecker.restoredAsset(
                name: "Velora-1.2.3.dmg",
                rawURL: "https://example.com/Velora-1.2.3.dmg",
                size: 12_345) == nil,
            "cached DMG metadata from an untrusted host is rejected")
        let restoredState = UpdateChecker.restoredState(
            currentVersion: "1.2.2",
            version: "1.2.3",
            rawPage:
                "https://github.com/sushilk1991/velora/releases/tag/v1.2.3",
            notes: "## Saved notes",
            publishedAt: Date(timeIntervalSince1970: 10_000),
            name: "Velora-1.2.3.dmg",
            rawURL:
                "https://github.com/sushilk1991/velora/releases/download/v1.2.3/Velora-1.2.3.dmg",
            size: 12_345)
        expect(
            restoredState?.latest.notes == "## Saved notes"
                && restoredState?.available?.asset?.size == 12_345,
            "cache rehydration restores both changelog and actionable update state")
        let currentCachedState = UpdateChecker.restoredState(
            currentVersion: "1.2.3",
            version: "1.2.3",
            rawPage:
                "https://github.com/sushilk1991/velora/releases/tag/v1.2.3",
            notes: "Current notes",
            publishedAt: nil,
            name: "Velora-1.2.3.dmg",
            rawURL:
                "https://github.com/sushilk1991/velora/releases/download/v1.2.3/Velora-1.2.3.dmg",
            size: 12_345)
        expect(
            currentCachedState?.latest.notes == "Current notes"
                && currentCachedState?.available == nil,
            "current-version cache restores changelog without a phantom update")
        expect(
            UpdateChecker.restoredState(
                currentVersion: "1.2.4",
                version: "1.2.3",
                rawPage:
                    "https://github.com/sushilk1991/velora/releases/tag/v1.2.3",
                notes: "Old notes",
                publishedAt: nil,
                name: nil,
                rawURL: nil,
                size: 0) == nil,
            "cache older than the running app is discarded")
        expect(
            UpdateChecker.restoredState(
                currentVersion: "1.2.2",
                version: "1.2.3",
                rawPage: "https://example.com/releases/tag/v1.2.3",
                notes: "Untrusted notes",
                publishedAt: nil,
                name: nil,
                rawURL: nil,
                size: 0) == nil,
            "cache with an untrusted release page is discarded")
        expect(
            UpdateChecker.allowsPersistentState(feedOverridden: false)
                && !UpdateChecker.allowsPersistentState(feedOverridden: true),
            "a local update E2E feed cannot mutate persistent update preferences")
        if case .upToDate(let release) = UpdateChecker.parse(
            current: "9.9.9", data: ok, response: http, error: nil) {
            expect(release.notes.contains("Full release notes"),
                   "an up-to-date check still returns changelog content")
            expect(
                !UpdateChecker.Outcome.upToDate(release).shouldOpenUpdateWindow,
                "an up-to-date manual check does not open the release-notes window")
            expect(
                !UpdateWindowController.shouldPresent(
                    releaseVersion: release.version, currentVersion: "9.9.9"),
                "the software-update controller rejects a current release")
        } else {
            expect(false, "same-version feed parses as upToDate")
        }
        if case .updateAvailable(let update) = UpdateChecker.parse(
            current: "0.7.2", data: ok, response: http, error: nil) {
            expect(
                UpdateChecker.Outcome.updateAvailable(update).shouldOpenUpdateWindow,
                "a newer release opens the actionable software-update window")
            expect(
                UpdateWindowController.shouldPresent(
                    releaseVersion: update.version, currentVersion: "0.7.2"),
                "the software-update controller accepts a newer release")
            expect(
                SettingsModel.statusAfterSuccessfulUpdateCheck(
                    availableUpdate: nil, currentVersion: "0.7.2")
                    == "Velora 0.7.2 is up to date."
                    && SettingsModel.statusAfterSuccessfulUpdateCheck(
                        availableUpdate: update, currentVersion: "0.7.2")
                        == "Velora 9.9.9 is available.",
                "a later automatic discovery replaces a stale up-to-date status")
        }
        expect(
            !UpdateChecker.Outcome.failed("offline").shouldOpenUpdateWindow,
            "a failed update check stays on its initiating surface")
        let rateLimitBody = """
        {"message":"API rate limit exceeded"}
        """.data(using: .utf8)!
        let rateLimited = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!, statusCode: 403,
            httpVersion: nil,
            headerFields: [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "1800000000",
            ])!
        expect(
            UpdateChecker.isRateLimited(
                response: rateLimited, data: rateLimitBody),
            "an exhausted GitHub API allowance is recognized as rate limiting")
        if case .failed(let reason) = UpdateChecker.parse(
            current: "0.7.2", data: rateLimitBody,
            response: rateLimited, error: nil) {
            expect(
                reason.contains("temporarily limited"),
                "rate-limit failures explain the temporary condition")
        } else {
            expect(false, "a rate-limited feed never parses as an update")
        }
        let deterministicRateLimitMessage = UpdateChecker.rateLimitMessage(
            response: rateLimited,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!)
        expect(
            deterministicRateLimitMessage.contains("Try again after"),
            "a known reset timestamp produces an actionable retry time")
        let ordinaryForbidden = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!, statusCode: 403,
            httpVersion: nil, headerFields: nil)!
        expect(
            !UpdateChecker.isRateLimited(
                response: ordinaryForbidden,
                data: "{\"message\":\"Forbidden\"}".data(using: .utf8)),
            "an unrelated GitHub 403 does not trigger the release-page fallback")
        let tooManyRequests = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!, statusCode: 429,
            httpVersion: nil, headerFields: nil)!
        expect(
            UpdateChecker.isRateLimited(
                response: tooManyRequests, data: nil),
            "HTTP 429 always triggers the public release-page fallback")
        let unavailable = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!, statusCode: 503,
            httpVersion: nil, headerFields: nil)!
        if case .failed(let reason) = UpdateChecker.parse(
            current: "0.7.2", data: nil,
            response: unavailable, error: nil) {
            expect(
                reason.contains("HTTP 503"),
                "non-rate-limit feed failures retain their exact HTTP status")
        } else {
            expect(false, "an unavailable feed never parses as an update")
        }
        let publicReleasePage = URL(
            string: "https://github.com/sushilk1991/velora/releases/tag/v9.9.9")!
        let publicReleaseResponse = HTTPURLResponse(
            url: publicReleasePage, statusCode: 200,
            httpVersion: nil, headerFields: nil)!
        if case .updateAvailable(let fallback) = UpdateChecker.parsePublicReleasePage(
            current: "0.10.30", response: publicReleaseResponse, error: nil) {
            expect(
                fallback.version == "9.9.9"
                    && fallback.page == publicReleasePage
                    && fallback.asset?.name == "Velora-9.9.9.dmg"
                    && fallback.asset?.url.absoluteString
                        == "https://github.com/sushilk1991/velora/releases/download/v9.9.9/Velora-9.9.9.dmg"
                    && fallback.asset?.size == 0,
                "the public redirect constructs the canonical official update asset")
            expect(
                fallback.asset.map { UpdateChecker.assetURLAllowed($0.url) } == true,
                "the fallback asset still passes the installer's GitHub-host gate")
        } else {
            expect(false, "a newer public release redirect remains installable")
        }
        if case .upToDate = UpdateChecker.parsePublicReleasePage(
            current: "9.9.9", response: publicReleaseResponse, error: nil) {} else {
            expect(false, "a current public release redirect reports up to date")
        }
        let offSiteResponse = HTTPURLResponse(
            url: URL(string: "https://example.com/releases/tag/v99.0.0")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!
        if case .failed = UpdateChecker.parsePublicReleasePage(
            current: "0.7.2", response: offSiteResponse, error: nil) {} else {
            expect(false, "an off-site fallback redirect is rejected")
        }
        let unredirectedResponse = HTTPURLResponse(
            url: URL(string: "https://github.com/sushilk1991/velora/releases/latest")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!
        if case .failed = UpdateChecker.parsePublicReleasePage(
            current: "0.7.2", response: unredirectedResponse, error: nil) {} else {
            expect(false, "the fallback requires an exact official release tag")
        }
        expect(
            UpdateChecker.releaseTag(from: publicReleasePage) == "v9.9.9"
                && UpdateChecker.releaseTag(from: URL(
                    string: "https://github.com/sushilk1991/velora/releases/tag/v9.9.9%2Fevil")!) == nil,
            "release tags are exact safe path components")
        if case .failed = UpdateChecker.parse(
            current: "0.7.2", data: "not json".data(using: .utf8),
            response: http, error: nil) {} else {
            expect(false, "garbage body parses as failed")
        }
        expect(UpdateChecker.releasePageAllowed(
            URL(string: "https://github.com/sushilk1991/velora/releases/tag/v1.2.3")!),
            "the official Velora release page is allowed")
        expect(!UpdateChecker.releasePageAllowed(
            URL(string: "https://example.com/fake-release")!),
            "an off-site release page is never trusted by the update window")
        let oversizedNotes = String(
            repeating: "a", count: UpdateChecker.maximumReleaseNotesBytes + 100)
        let boundedNotes = UpdateChecker.boundedReleaseNotes(oversizedNotes)
        expect(
            boundedNotes.utf8.count <= UpdateChecker.maximumReleaseNotesBytes
                && boundedNotes.contains("View the complete notes on GitHub"),
            "oversized release notes are bounded with an honest GitHub fallback")
        let inertLink = ReleaseNotesContentView.inertInlineMarkdown(
            "[Install now](https://example.com/phishing)")
        expect(
            !inertLink.runs.contains(where: { $0.link != nil }),
            "release-note Markdown links render as inert labels")

        let now = Date(timeIntervalSince1970: 10_000)
        expect(!UpdatePromptPolicy.shouldPresent(
            version: "1.2.3", skippedVersion: "1.2.3",
            deferredVersion: nil, deferredUntil: .distantPast, now: now),
            "skip suppresses only the exact automatic update prompt")
        expect(UpdatePromptPolicy.shouldPresent(
            version: "1.2.4", skippedVersion: "1.2.3",
            deferredVersion: nil, deferredUntil: .distantPast, now: now),
            "a newer release bypasses the previously skipped version")
        expect(!UpdatePromptPolicy.shouldPresent(
            version: "1.2.3", skippedVersion: nil,
            deferredVersion: "1.2.3", deferredUntil: now.addingTimeInterval(60), now: now),
            "remind-later suppresses the exact version until its deadline")
        expect(UpdatePromptPolicy.shouldPresent(
            version: "1.2.4", skippedVersion: nil,
            deferredVersion: "1.2.3", deferredUntil: now.addingTimeInterval(60), now: now),
            "a new release bypasses an older version's reminder")
        expect(UpdatePromptPolicy.shouldPresent(
            version: "1.2.3", skippedVersion: nil,
            deferredVersion: "1.2.3", deferredUntil: now, now: now),
            "the automatic prompt returns when the reminder deadline arrives")
        var skippedVersion: String? = "1.2.3"
        var deferredVersion: String? = "1.2.3"
        var deferredUntil = now.addingTimeInterval(60)
        UpdatePromptPolicy.clearSuppression(
            for: "1.2.3",
            skippedVersion: &skippedVersion,
            deferredVersion: &deferredVersion,
            deferredUntil: &deferredUntil)
        expect(
            skippedVersion == nil && deferredVersion == nil
                && deferredUntil == .distantPast,
            "an explicit install clears exact-version Skip and Later suppression")
        skippedVersion = "1.2.4"
        deferredVersion = "1.2.4"
        deferredUntil = now.addingTimeInterval(60)
        UpdatePromptPolicy.clearSuppression(
            for: "1.2.3",
            skippedVersion: &skippedVersion,
            deferredVersion: &deferredVersion,
            deferredUntil: &deferredUntil)
        expect(
            skippedVersion == "1.2.4" && deferredVersion == "1.2.4"
                && deferredUntil > now,
            "an explicit install preserves suppression for a different release")
        skippedVersion = "1.2.3"
        deferredVersion = nil
        deferredUntil = .distantPast
        UpdatePromptPolicy.setReminder(
            for: "1.2.3",
            skippedVersion: &skippedVersion,
            deferredVersion: &deferredVersion,
            deferredUntil: &deferredUntil,
            now: now)
        expect(
            skippedVersion == nil && deferredVersion == "1.2.3"
                && deferredUntil == now.addingTimeInterval(
                    UpdatePromptPolicy.reminderInterval),
            "Remind Me Later replaces an earlier Skip for the exact release")
        expect(
            !UpdateWindowPresentation.manual.defersOnClose
                && UpdateWindowPresentation.automatic.defersOnClose,
            "only an automatically presented update treats window close as Remind Me Later")
        expect(
            UpdateWindowPresentation.resolved(
                current: .manual,
                incoming: .automatic,
                windowIsVisible: true) == .manual,
            "an automatic check cannot reclassify an already-visible manual changelog")
        expect(
            !UpdateWindowController.shouldDeferOnClose(
                presentation: .manual,
                closingProgrammatically: false)
                && UpdateWindowController.shouldDeferOnClose(
                    presentation: .automatic,
                    closingProgrammatically: false)
                && !UpdateWindowController.shouldDeferOnClose(
                    presentation: .automatic,
                    closingProgrammatically: true),
            "window-close wiring defers only a user-closed automatic prompt")

        let backgroundDownloadAction = UpdateWindowModel.primaryAction(
            releaseVersion: "1.2.3", isUpdateAvailable: true,
            canInstallInPlace: true,
            installerState: .downloading(version: "1.2.3", progress: 0.4),
            userRequestedInstall: false)
        expect(
            backgroundDownloadAction
                == .init(title: "Install Update", disabled: false),
            "an automatic download still accepts the user's one-click install intent")
        let committedDownloadAction = UpdateWindowModel.primaryAction(
            releaseVersion: "1.2.3", isUpdateAvailable: true,
            canInstallInPlace: true,
            installerState: .verifying(version: "1.2.3"),
            userRequestedInstall: true)
        expect(
            committedDownloadAction
                == .init(title: "Installing…", disabled: true),
            "an explicit install intent cannot be submitted twice while verification runs")
        let waitingAction = UpdateWindowModel.primaryAction(
            releaseVersion: "1.2.3", isUpdateAvailable: true,
            canInstallInPlace: true,
            installerState: .ready(version: "1.2.3"),
            userRequestedInstall: true)
        expect(
            waitingAction
                == .init(title: "Waiting to Install…", disabled: true),
            "a verified update shows that it is waiting for foreground work")
        expect(
            UpdateWindowModel.installIntentApplies(
                to: "1.2.3",
                installerState: .ready(version: "1.2.3"),
                explicitInstallRequested: true),
            "the update window adopts explicit restart intent from another surface")
        expect(
            !UpdateWindowModel.installIntentApplies(
                to: "1.2.4",
                installerState: .ready(version: "1.2.3"),
                explicitInstallRequested: true),
            "external install intent does not leak onto a different release")
        let differentDownloadAction = UpdateWindowModel.primaryAction(
            releaseVersion: "1.2.4", isUpdateAvailable: true,
            canInstallInPlace: true,
            installerState: .downloading(version: "1.2.3", progress: 0.4),
            userRequestedInstall: false)
        expect(
            differentDownloadAction.disabled
                && differentDownloadAction.title.contains("1.2.3"),
            "a different in-flight release is identified instead of accepting a no-op install")
        expect(UpdateRelaunchSafety.blockReason(
            dictationBusy: false,
            fileTranscriptionBusy: false,
            meetingCaptureBusy: false) == nil,
            "a one-click update may relaunch when foreground work is idle")
        expect(UpdateRelaunchSafety.blockReason(
            dictationBusy: true,
            fileTranscriptionBusy: false,
            meetingCaptureBusy: false)?.contains("dictation") == true,
            "a one-click update waits for active dictation")
        expect(UpdateRelaunchSafety.blockReason(
            dictationBusy: false,
            fileTranscriptionBusy: true,
            meetingCaptureBusy: false)?.contains("audio-file") == true,
            "a one-click update waits for active file transcription")
        expect(UpdateRelaunchSafety.blockReason(
            dictationBusy: false,
            fileTranscriptionBusy: false,
            meetingCaptureBusy: true)?.contains("meeting") == true,
            "a one-click update waits for meeting capture or finalization")

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
        expect(script.contains("CFBundleIdentifier"),
               "helper re-validates the exact bundle identifier")
        expect(script.contains("CFBundleShortVersionString"),
               "helper re-validates the exact release version")
        expect(script.contains("spctl --assess --type execute"),
               "helper re-runs Gatekeeper on the exact bytes it installs")
        expect(!script.contains("/Applications"),
               "helper hard-codes no paths — everything arrives as arguments")

        testHelperScriptDryRun(script)

        // Exercise the eligibility branch for the artifact actually running
        // the selftest: debug binaries cannot swap themselves, while the
        // packaged app produced by make-app is writable and installable.
        if Bundle.main.bundleURL.pathExtension == "app" {
            expect(UpdateInstaller.installBlocker() == nil,
                   "a writable packaged app can install updates in place")
        } else {
            expect(UpdateInstaller.installBlocker() != nil,
                   "bare binaries are blocked from in-place installs")
        }

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
                              "0", log.path, "", "", ""]
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

            // Documents written before notes_prompt existed must keep
            // decoding, and a 0.12.0 document carrying the short-lived
            // end_action key must import with the key ignored.
            var legacyMeetingsRoot = portableRoot ?? [:]
            var legacySettings = legacyMeetingsRoot["settings"] as? [String: Any] ?? [:]
            var legacyMeetings = legacySettings["meetings"] as? [String: Any] ?? [:]
            legacyMeetings.removeValue(forKey: "notes_prompt")
            legacyMeetings["end_action"] = "stop"
            legacySettings["meetings"] = legacyMeetings
            legacyMeetingsRoot["settings"] = legacySettings
            let legacyMeetingsData = try JSONSerialization.data(withJSONObject: legacyMeetingsRoot)
            let legacyDecoded = try SettingsDocumentCodec.decode(legacyMeetingsData)
            expect(
                legacyDecoded.settings.meetings.notesPrompt.isEmpty,
                "pre-0.12 settings without the prompt key (or with the retired end_action key) decode cleanly")
            let reEncoded = try SettingsDocumentCodec.encode(legacyDecoded)
            let reEncodedMeetings = ((try JSONSerialization.jsonObject(with: reEncoded)
                as? [String: Any])?["settings"] as? [String: Any])?["meetings"] as? [String: Any]
            expect(reEncodedMeetings?["end_action"] == nil,
                   "the retired end_action key is never written back out")

            var version1Root = portableRoot ?? [:]
            version1Root["version"] = 1
            var version1Settings = version1Root["settings"] as? [String: Any] ?? [:]
            var version1Engine = version1Settings["engine"] as? [String: Any] ?? [:]
            version1Engine["maximum_recording_seconds"] =
                SettingsDocument.Engine.legacyMaximumRecordingSeconds
            version1Settings["engine"] = version1Engine
            version1Root["settings"] = version1Settings
            let version1Data = try JSONSerialization.data(withJSONObject: version1Root)
            let upgraded = try SettingsDocumentCodec.decode(version1Data)
            expect(
                upgraded.version == SettingsDocument.currentVersion
                    && upgraded.settings.engine.maximumRecordingSeconds
                        == SettingsDocument.Engine.defaultMaximumRecordingSeconds,
                "version 1 settings migrate the legacy five-minute cap to one hour")

            version1Engine["maximum_recording_seconds"] = 720
            version1Settings["engine"] = version1Engine
            version1Root["settings"] = version1Settings
            let customVersion1Data = try JSONSerialization.data(withJSONObject: version1Root)
            expect(
                try SettingsDocumentCodec.decode(customVersion1Data)
                    .settings.engine.maximumRecordingSeconds == 720,
                "version 1 settings migration preserves a custom recording cap")
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
        legacy.set("1.2.3", forKey: "velora.cachedReleaseVersion")
        legacy.set(
            "https://github.com/sushilk1991/velora/releases/tag/v1.2.3",
            forKey: "velora.cachedReleasePage")
        legacy.set("## Saved notes", forKey: "velora.cachedReleaseNotes")
        legacy.set(10_000.0, forKey: "velora.cachedReleasePublishedAt")
        legacy.set("Velora-1.2.3.dmg", forKey: "velora.cachedReleaseAssetName")
        legacy.set(
            "https://github.com/sushilk1991/velora/releases/download/v1.2.3/Velora-1.2.3.dmg",
            forKey: "velora.cachedReleaseAssetURL")
        legacy.set(12_345, forKey: "velora.cachedReleaseAssetSize")
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
            let local = AppConfig.migratedLocalSettings(defaults: legacy)
            expect(local.cachedReleaseVersion == "1.2.3"
                   && local.cachedReleaseNotes == "## Saved notes"
                   && local.cachedReleasePublishedAt == 10_000
                   && local.cachedReleaseAssetName == "Velora-1.2.3.dmg"
                   && local.cachedReleaseAssetSize == 12_345,
                   "the machine-local changelog and DMG metadata survive relaunch")

            let wireDirectory = directory.appendingPathComponent("wire-version-migration")
            let wireSettings = wireDirectory.appendingPathComponent("settings.json")
            let wireEngine = wireDirectory.appendingPathComponent("config.json")
            try FileManager.default.createDirectory(
                at: wireDirectory, withIntermediateDirectories: true)
            var wireRoot = try JSONSerialization.jsonObject(
                with: SettingsDocumentCodec.encode(document)) as? [String: Any] ?? [:]
            wireRoot["version"] = 1
            var wireSettingsRoot = wireRoot["settings"] as? [String: Any] ?? [:]
            var wireEngineRoot = wireSettingsRoot["engine"] as? [String: Any] ?? [:]
            wireEngineRoot["maximum_recording_seconds"] =
                SettingsDocument.Engine.legacyMaximumRecordingSeconds
            wireSettingsRoot["engine"] = wireEngineRoot
            wireRoot["settings"] = wireSettingsRoot
            try JSONSerialization.data(withJSONObject: wireRoot).write(to: wireSettings)
            _ = AppConfig(
                defaults: transactionDefaults,
                settingsFileURL: wireSettings,
                engineConfigURL: wireEngine,
                registerDefaults: false)
            let persistedWireData = try Data(contentsOf: wireSettings)
            let persistedWireRoot = try JSONSerialization.jsonObject(
                with: persistedWireData) as? [String: Any]
            let persistedWire = try SettingsDocumentCodec.decode(persistedWireData)
            expect(
                persistedWireRoot?["version"] as? Int == SettingsDocument.currentVersion
                    && persistedWire.settings.engine.maximumRecordingSeconds
                        == SettingsDocument.Engine.defaultMaximumRecordingSeconds,
                "AppConfig persists the version 1 recording-cap migration")

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

    private static func testSafeVoiceEditSelection() {
        expect(
            LateFinalPolicy.errorCancelsSession(
                "edit-session",
                editInstructionSession: "edit-session",
                externalRequestSession: nil,
                actionInstructionSession: nil),
            "an errored edit session rejects its late instruction final")
        expect(
            LateFinalPolicy.errorCancelsSession(
                "external-session",
                editInstructionSession: nil,
                externalRequestSession: "external-session",
                actionInstructionSession: nil),
            "an errored external session rejects its late API final")
        expect(
            LateFinalPolicy.errorCancelsSession(
                "action-session",
                editInstructionSession: nil,
                externalRequestSession: nil,
                actionInstructionSession: "action-session"),
            "an errored Action capture rejects a late command final")
        expect(
            !LateFinalPolicy.errorCancelsSession(
                "normal-session",
                editInstructionSession: nil,
                externalRequestSession: nil,
                actionInstructionSession: nil),
            "normal dictation retains its bounded late-final recovery")
        expect(
            VoiceCommand.parse(text: "", raw: "scratch that") == .undoLastInsertion
                && !LateFinalPolicy.commandMayExecute(
                    allowAutomaticInsertion: false),
            "a cleanup-empty late voice command is recognized but never executed")
        expect(
            ErrorRetryIntent.resolve(
                explicit: nil,
                failedSession: "edit-session",
                editInstructionSession: "edit-session") == .voiceEdit,
            "an edit capture error keeps Retry routed through Voice Edit")
        expect(
            ErrorRetryIntent.resolve(
                explicit: .voiceEdit,
                failedSession: "already-consumed-session",
                editInstructionSession: nil) == .voiceEdit,
            "an empty instruction or edit-engine failure keeps explicit edit intent")
        expect(
            ErrorRetryIntent.resolve(
                explicit: nil,
                failedSession: "normal-session",
                editInstructionSession: nil) == .dictation,
            "a normal dictation error retains normal Retry behavior")
        var retryRoute = ""
        ErrorRetryIntent.voiceEdit.perform(
            dictation: { retryRoute = "dictation" },
            voiceEdit: { retryRoute = "edit" })
        expect(
            retryRoute == "edit",
            "Voice Edit Retry executes the edit route, never ordinary dictation")
        ErrorRetryIntent.dictation.perform(
            dictation: { retryRoute = "dictation" },
            voiceEdit: { retryRoute = "edit" })
        expect(
            retryRoute == "dictation",
            "normal Retry still executes the ordinary dictation route")

        var markerReads = 0
        let native = ScreenContext.resolvedSelectionText(
            direct: { "  Native selection  " },
            textMarker: {
                markerReads += 1
                return "Web selection"
            })
        expect(native == "  Native selection  " && markerReads == 0,
               "native AX selection stays byte-exact without a web-marker IPC")

        let web = ScreenContext.resolvedSelectionText(
            direct: { nil },
            textMarker: {
                markerReads += 1
                return "  Web selection  "
            })
        expect(web == "  Web selection  " && markerReads == 1,
               "web text-marker fallback preserves boundary whitespace")

        let whitespaceFallback = ScreenContext.resolvedSelectionText(
            direct: { " \n " },
            textMarker: { "Marker selection" })
        expect(whitespaceFallback == "Marker selection",
               "empty native selection does not hide a web selection")
        expect(ScreenContext.resolvedSelectionText(
            direct: { "\t" }, textMarker: { "\n" }) == nil,
               "whitespace-only selections stay invalid")
        let multiline = "  Hello 👨‍👩‍👧\nsecond line\n"
        expect(ScreenContext.resolvedSelectionText(
            direct: { multiline }, textMarker: { nil }) == multiline,
               "multiline emoji selections stay exact")

        let elementA = AXUIElementCreateApplication(1)
        let elementB = AXUIElementCreateApplication(2)
        let captured = ScreenTextSelection(
            text: "Approved", element: elementA,
            identity: .characterRange(location: 10, length: 8),
            isEditable: true)
        let unchanged = ScreenTextSelection(
            text: "Approved", element: elementA,
            identity: .characterRange(location: 10, length: 8),
            isEditable: true)
        expect(captured.canReplace(with: unchanged),
               "the exact native selection remains replaceable")
        let moved = ScreenTextSelection(
            text: "Approved", element: elementA,
            identity: .characterRange(location: 40, length: 8),
            isEditable: true)
        expect(!captured.canReplace(with: moved),
               "identical text at another range cannot be replaced")
        let otherField = ScreenTextSelection(
            text: "Approved", element: elementB,
            identity: .characterRange(location: 10, length: 8),
            isEditable: true)
        expect(!captured.canReplace(with: otherField),
               "the same range in another field cannot be replaced")
        let changedWhitespace = ScreenTextSelection(
            text: "Approved ", element: elementA,
            identity: .characterRange(location: 10, length: 9),
            isEditable: true)
        expect(!captured.canReplace(with: changedWhitespace),
               "boundary-whitespace changes invalidate replacement")

        let markerA = "web-marker-a" as CFString
        let sameMarkerA = "web-marker-a" as CFString
        let markerB = "web-marker-b" as CFString
        let webCaptured = ScreenTextSelection(
            text: "Approved", element: elementA,
            identity: .textMarkerRange(markerA), isEditable: true)
        let webUnchanged = ScreenTextSelection(
            text: "Approved", element: elementA,
            identity: .textMarkerRange(sameMarkerA), isEditable: true)
        let webMoved = ScreenTextSelection(
            text: "Approved", element: elementA,
            identity: .textMarkerRange(markerB), isEditable: true)
        expect(webCaptured.canReplace(with: webUnchanged),
               "an unchanged web marker remains replaceable")
        expect(!webCaptured.canReplace(with: webMoved),
               "identical web text at another marker cannot be replaced")
        let staticWebSelection = ScreenTextSelection(
            text: "Approved", element: elementA,
            identity: .textMarkerRange(markerA), isEditable: false)
        expect(!staticWebSelection.canReplace(with: webUnchanged),
               "read-only webpage selections remain clipboard-only")
        let unknownIdentity = ScreenTextSelection(
            text: "Approved", element: elementA,
            identity: .unavailable, isEditable: true)
        expect(!unknownIdentity.canReplace(with: unchanged),
               "a selection without a range identity cannot be replaced")

        let sublimeToken = SublimeTextSelectionToken(
            value: UUID().uuidString.lowercased(),
            generation: UUID().uuidString.lowercased(),
            client: SublimeCommandClient(
                targetPID: -1))
        let sublimeSelection = ScreenTextSelection(
            text: "Approved",
            element: elementA,
            identity: .sublimeToken(sublimeToken),
            isEditable: true)
        expect(
            !sublimeSelection.canReplace(with: unchanged),
            "Sublime plugin tokens never fall through to the AX paste rail")
        sublimeSelection.discardMutableIdentity()
        expect(
            sublimeToken.replace(with: "No") == .rejected,
            "a discarded Sublime token can never replace text")

        let oneShotSublimeToken = SublimeTextSelectionToken(
            value: UUID().uuidString.lowercased(),
            generation: UUID().uuidString.lowercased(),
            client: SublimeCommandClient(
                targetPID: -1))
        expect(
            oneShotSublimeToken.replace(with: "No") == .rejected,
            "an unavailable Sublime client fails closed")
        expect(
            oneShotSublimeToken.replace(with: "Still no") == .rejected,
            "a Sublime replacement token is one-shot even after transport failure")

        let monitor = HotkeyMonitor()
        monitor.hotkey = .rightOption
        let commandShiftE = Hotkey(
            keyCode: 14,
            modifiers: CGEventFlags.maskCommand.rawValue
                | CGEventFlags.maskShift.rawValue,
            isModifierOnly: false)
        monitor.editHotkey = commandShiftE
        expect(monitor.handleKeyDown(
            keyCode: 14, flags: commandShiftE.modifiers,
            isRepeat: false, invalidateContinuation: false),
               "edit combo key-down is marked for suppression")
        expect(monitor.handleKeyDown(
            keyCode: 14, flags: commandShiftE.modifiers,
            isRepeat: true, invalidateContinuation: false),
               "latched edit combo autorepeat is marked for suppression")
        expect(monitor.handleKeyDown(
            keyCode: 14, flags: 0,
            isRepeat: true, invalidateContinuation: false),
               "latched autorepeat stays suppressed after modifier release")
        expect(monitor.handleKeyUp(keyCode: 14),
               "edit combo key-up is marked for suppression")
        expect(!monitor.handleKeyUp(keyCode: 14),
               "an unrelated edit key-up is not suppressed")
        expect(!monitor.handleKeyDown(
            keyCode: 14, flags: CGEventFlags.maskShift.rawValue,
            isRepeat: false, invalidateContinuation: false),
               "a partial modifier match remains target-app input")

        let inputGeneration = UserInputActivity.snapshot()
        expect(!monitor.handleKeyDown(
            keyCode: 0, flags: 0,
            isRepeat: false, invalidateContinuation: true),
               "an ordinary user key remains target-app input")
        expect(
            UserInputActivity.snapshot() == inputGeneration &+ 1,
            "real user input synchronously invalidates in-flight selection capture")
        let generationAfterUserKey = UserInputActivity.snapshot()
        _ = monitor.handleKeyDown(
            keyCode: 0, flags: 0,
            isRepeat: true, invalidateContinuation: true)
        expect(
            UserInputActivity.snapshot() == generationAfterUserKey,
            "key autorepeat does not create redundant input generations")
        expect(
            DictationController.delayedEditCaptureRelease(heldFor: 0.1)
                == .lockRecording,
            "a quick edit-hotkey tap locks recording after async selection capture")
        expect(
            DictationController.delayedEditCaptureRelease(heldFor: 0.5)
                == .cancel,
            "a released hold never starts an unlocked recording after capture")

        expect(
            HotkeyMonitor.resyncedComboLatch(
                wasLatched: true, keyCurrentlyDown: true),
            "tap re-enable preserves a latched combo while its key is held")
        expect(
            !HotkeyMonitor.resyncedComboLatch(
                wasLatched: true, keyCurrentlyDown: false),
            "tap re-enable clears a latch after the key was released")
        expect(
            !HotkeyMonitor.resyncedComboLatch(
                wasLatched: false, keyCurrentlyDown: true),
            "tap re-enable never invents a combo from key state alone")

        let probe = HotkeySelftestDelegate()
        monitor.delegate = probe
        expect(monitor.handleKeyDown(
            keyCode: 14, flags: commandShiftE.modifiers,
            isRepeat: false, invalidateContinuation: false),
               "a filtering tap suppresses the edit combo")
        expect(
            probe.editHotkeyDownCount == 0,
            "event-tap interpretation never runs controller work synchronously")
        expect(
            waitUntil { probe.editHotkeyDownCount == 1 },
            "the edit hotkey callback is delivered asynchronously on the main queue")
        expect(monitor.handleKeyUp(keyCode: 14),
               "the asynchronously delivered edit combo still suppresses key-up")
        expect(
            waitUntil { probe.editHotkeyUpCount == 1 },
            "the edit key-up callback is delivered in order")

        expect(!monitor.handleKeyDown(
            keyCode: 14, flags: commandShiftE.modifiers,
            isRepeat: false, invalidateContinuation: false,
            comboCanBeSuppressed: false),
               "a listen-only tap refuses to activate an unsuppressible combo")
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        expect(
            probe.editHotkeyDownCount == 1 && !monitor.handleKeyUp(keyCode: 14),
            "a refused listen-only combo emits nothing and creates no latch")
    }

    // MARK: - Onboarding setup gate

    private static func testOnboardingSetup() {
        let downloading = OnboardingSetupState(
            isComplete: false,
            status: "Downloading the speech model (1.6 GB) — 42%",
            fraction: 0.42)
        expect(!downloading.canTryIt, "model download keeps onboarding try-it locked")
        expect(downloading.primaryActionTitle == "Continue in the Background",
               "model download keeps a visible primary exit without unlocking try-it")

        let staleDownload = OnboardingSetupState(
            isComplete: true,
            status: "Preparing the writing model…",
            fraction: nil)
        expect(!staleDownload.canTryIt, "visible model work wins over a stale completion signal")
        expect(staleDownload.primaryActionTitle == "Continue in the Background",
               "visible setup work keeps the background-continuation action")

        let ready = OnboardingSetupState(isComplete: true, status: nil, fraction: nil)
        expect(ready.canTryIt, "explicit setup completion unlocks onboarding try-it")
        expect(ready.primaryActionTitle == "Finish",
               "ready onboarding retains the successful-dictation finish action")

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
            try! FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let letters = Array("abcdefghijklmnopqrstuvwxyz")
            let replacements = Dictionary(uniqueKeysWithValues: (0..<250).map { index in
                ("qzx\(letters[index / 26])\(letters[index % 26])",
                 String(format: "Term%03d", index))
            })
            try! JSONSerialization.data(withJSONObject: [
                "replacements": replacements,
                "soft_replacements": [:],
                "vocabulary": Array(replacements.values),
                "counts": [:],
            ]).write(to: url)
            _ = store.observe([("zzzwrong", "zzzright")])
            expect(store.observe([("zzzwrong", "zzzright")]).isEmpty,
                   "a correction evicted by the bounded store is not reported learned")
            expect(tiers(url).hard["zzzwrong"] == nil,
                   "the rejected correction is absent from the durable projection")
        }
        withStore { store, url in
            _ = store.observe([("lung", "Airlearn")])
            store.remove(wrong: "lung")
            expect(store.count == 0, "remove forgets the entry")
            expect(tiers(url).soft["lung"] == nil, "remove clears soft tier on disk")
        }
        let blockedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-learning-save-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: blockedDirectory, withIntermediateDirectories: true)
        let blockedParent = blockedDirectory.appendingPathComponent("not-a-directory")
        try! Data("blocked".utf8).write(to: blockedParent)
        let blockedStore = LearningStore(
            url: blockedParent.appendingPathComponent("learned.json"))
        expect(blockedStore.observe([("velor", "Velora")]).isEmpty,
               "a correction is not reported committed when atomic save fails")
        expect(blockedStore.count == 0,
               "a failed atomic save restores the prior in-memory learning state")
        try? FileManager.default.removeItem(at: blockedDirectory)
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
        expect(repository.observeCorrections([("vercel", "Netlify")]).isEmpty,
               "first unconfirmed correction remains pending")
        expect(reloads == 4,
               "pending wrong side requests an immediate live Config reload")
        fixture.remove()

        let persistenceFixture = DictionaryRepositoryFixture()
        let stateDirectory = persistenceFixture.directory.appendingPathComponent("canonical")
        let persistenceRepository = DictionaryRepository(
            stateURL: stateDirectory.appendingPathComponent("dictionary.json"),
            configURL: persistenceFixture.config,
            learnedURL: persistenceFixture.learned,
            autoURL: persistenceFixture.auto,
            deviceID: "persistence-failure")
        try! FileManager.default.removeItem(at: stateDirectory)
        try! Data("blocked".utf8).write(to: stateDirectory)
        expect(persistenceRepository.observeCorrections([("velor", "Velora")]).isEmpty,
               "edit learning is not reported committed when canonical persistence fails")
        expect(tiers(persistenceFixture.learned).hard["velor"] == nil,
               "canonical failure rolls back the learned projection before restart")
        try! FileManager.default.removeItem(at: stateDirectory)
        try! FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true)
        expect(persistenceRepository.observeCorrections([("velor", "Velora")]).count == 1,
               "the correction can commit normally after canonical persistence recovers")
        expect(persistenceRepository.rows.contains(where: {
            $0.writeAs == "Velora" && $0.source == .learned
        }), "a later observation repairs a previously failed learning capture")
        persistenceFixture.remove()

        let boundedFixture = DictionaryRepositoryFixture()
        let boundedLetters = Array("abcdefghijklmnopqrstuvwxyz")
        var boundedReplacements = Dictionary(uniqueKeysWithValues: (0..<249).map { index in
            ("qzx\(boundedLetters[index / 26])\(boundedLetters[index % 26])",
             String(format: "Term%03d", index))
        })
        boundedReplacements["zzzwrong"] = "Zzzright"
        try! JSONSerialization.data(withJSONObject: [
            "replacements": boundedReplacements,
            "soft_replacements": [:],
            "vocabulary": Array(boundedReplacements.values),
            "counts": [:],
        ]).write(to: boundedFixture.learned)
        let boundedRepository = DictionaryRepository(
            stateURL: boundedFixture.state,
            configURL: boundedFixture.config,
            learnedURL: boundedFixture.learned,
            autoURL: boundedFixture.auto,
            deviceID: "bounded-learning",
            now: { Date(timeIntervalSince1970: 200) })
        expect(boundedRepository.rows.contains(where: { $0.writeAs == "Zzzright" }),
               "bounded fixture starts with the alphabetically-last learned rule")
        let boundedCommitted = boundedRepository.observeCorrections([("aaanew", "Aaanew")])
        expect(boundedCommitted.count == 1,
               "a surviving correction at capacity is reported learned")
        expect(!boundedRepository.rows.contains(where: { $0.writeAs == "Zzzright" })
               && boundedRepository.rows.contains(where: { $0.writeAs == "Aaanew" }),
               "bounded-store eviction removes stale canonical learning")
        let boundedPersisted = try! DictionaryDocument.decode(
            Data(contentsOf: boundedFixture.state))
        expect(!boundedPersisted.activeEntries.contains(where: { $0.writeAs == "Zzzright" }),
               "bounded-store eviction survives repository relaunch")
        boundedFixture.remove()
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
        expect(repository.observeCorrections([("velor", "Velora")]).isEmpty,
               "edit learning is not reported committed when engine projection fails")
        expect(!repository.rows.contains(where: { $0.writeAs == "Velora" }),
               "failed automatic learning rolls canonical UI state back")
        let learningFailureDocument = try! DictionaryDocument.decode(
            Data(contentsOf: fixture.state))
        expect(!learningFailureDocument.activeEntries.contains(where: {
            $0.writeAs == "Velora"
        }), "failed automatic learning rolls canonical persistence back")
        let recoveredRepository = DictionaryRepository(
            stateURL: fixture.state,
            configURL: fixture.directory.appendingPathComponent("recovered-config.json"),
            learnedURL: fixture.learned,
            autoURL: fixture.auto,
            deviceID: "projection-relaunch")
        expect(!recoveredRepository.rows.contains(where: { $0.writeAs == "Velora" }),
               "a relaunch cannot resurrect learning that was reported uncommitted")
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
        expect(
            CorrectionDiff.normalizedTokens("  Valora, valora! ...  ")
                == ["valora", "valora"],
            "baseline membership reuses punctuation-trimmed lowercase tokens without deduplicating")

        let nameFix = CorrectionDiff.corrections(
            baseline: "i met airline at the office today",
            edited: "i met Airlearn at the office today")
        expect(
            nameFix == [CorrectionDiff.Correction(wrong: "airline", right: "Airlearn")],
            "1:1 name fix detected")

        for (baseline, edited) in [
            ("velor,", "Velora."),
            ("meet velor,", "meet Velora."),
            ("please meet velor,", "please meet Velora."),
            ("velor Velora", "Velora Velora"),
        ] {
            expect(
                CorrectionDiff.corrections(baseline: baseline, edited: edited)
                    == [CorrectionDiff.Correction(wrong: "velor", right: "Velora")],
                "one clean substitution is accepted in a \(baseline.split(separator: " ").count)-token utterance")
        }
        expect(
            CorrectionDiff.corrections(
                baseline: "send status now", edited: "buy groceries tomorrow").isEmpty,
            "an unrelated short rewrite is not learned")
        expect(
            CorrectionDiff.corrections(
                baseline: "Frobnitz deploy", edited: "QuuxCorp deploy").isEmpty,
            "a capitalized short content swap is not learned")
        expect(
            CorrectionDiff.corrections(
                baseline: "meet airline", edited: "meet Airlearn")
                == [CorrectionDiff.Correction(wrong: "airline", right: "Airlearn")],
            "a plausible short name mishearing remains learnable")
        expect(
            CorrectionDiff.corrections(
                baseline: "please keep velor, exactly as written today",
                edited: "please keep Velora. exactly as written today")
                == [CorrectionDiff.Correction(wrong: "velor", right: "Velora")],
            "longer text keeps the 70-percent anchor with punctuation-normalized tokens")

        let insertion = CorrectionDiff.corrections(
            baseline: "hello world how are you",
            edited: "hello brave world how are you")
        expect(insertion.isEmpty, "pure insertion learns nothing")

        let unrelated = CorrectionDiff.corrections(
            baseline: "the quarterly numbers look strong this week",
            edited: "remember to buy milk and call the plumber")
        expect(unrelated.isEmpty, "wholesale replacement learns nothing")

        let acceptedBaseline = Array(repeating: "velor", count: 500).joined(separator: " ")
        let acceptedEdited = (
            Array(repeating: "velor", count: 499) + ["Velora"]
        ).joined(separator: " ")
        expect(
            CorrectionDiff.corrections(baseline: acceptedBaseline, edited: acceptedEdited)
                == [CorrectionDiff.Correction(wrong: "velor", right: "Velora")],
            "the aligned 500-token cap is accepted")
        let rejectedBaseline = Array(repeating: "velor", count: 501).joined(separator: " ")
        let rejectedEdited = (
            Array(repeating: "velor", count: 500) + ["Velora"]
        ).joined(separator: " ")
        expect(
            CorrectionDiff.corrections(baseline: rejectedBaseline, edited: rejectedEdited).isEmpty,
            "token 501 is rejected before diffing")
        expect(
            CorrectionDiff.normalizedTokens(String(repeating: "!", count: 61)) == nil,
            "a punctuation-only token cannot bypass the per-token work bound")
        expect(
            CorrectionDiff.corrections(
                baseline: String(repeating: "a", count: 61), edited: "Velora").isEmpty,
            "an oversized single token is rejected before edit-distance work")
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
            "event": "final", "session": "s1", "text": "Hello.",
            "cleanup_applied": true, "cleanup_wall_ms": 123, "total_ms": 321,
            "auto_stopped": true,
        ])
        if case .final(
            let session, let text, let raw, _, _, let cleanupWallMs,
            let applied, let totalMs, let audio, let autoStopped
        ) = final {
            expect(session == "s1" && text == "Hello." && raw == "Hello.", "final fields parse")
            expect(
                applied && cleanupWallMs == 123 && totalMs == 321 && audio == nil
                    && autoStopped,
                "final flags parse")
        } else {
            expect(false, "expected .final, got \(final)")
        }

        let autoStop = EngineEvent.parse([
            "event": "recording_auto_stopped", "session": "s-cap",
            "duration_s": 3_600.1, "limit_s": 3_600,
        ])
        if case .recordingAutoStopped(
            let session, let durationS, let limitS
        ) = autoStop {
            expect(
                session == "s-cap" && durationS > 3_600 && limitS == 3_600,
                "recording_auto_stopped fields parse")
        } else {
            expect(false, "expected .recordingAutoStopped, got \(autoStop)")
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

        var commandExecutions = 0
        var clipboardStages = 0
        // A live AX range and a final-only fallback share this decision: the
        // command is recognized before either path may stage or insert text.
        for liveTargetAvailable in [true, false] {
            if StreamTypingFinalPolicy.voiceCommand(
                enabled: true,
                text: liveTargetAvailable ? "Scratch that." : "",
                raw: "scratch that"
            ) == .undoLastInsertion {
                commandExecutions += 1
            } else {
                StreamFinalOutputStagingPolicy.stage(
                    "Scratch that.", alreadyStaged: false,
                    write: { _ in clipboardStages += 1 })
            }
        }
        expect(commandExecutions == 2 && clipboardStages == 0,
               "Stream commands execute once in live and fallback targets without clipboard staging")
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
        cleanupApplied: Bool? = nil, cleanupWallMs: Int? = nil,
        finalizationMs: Int? = nil
    ) -> DictationRecord {
        let text = final ?? Array(repeating: "word", count: words).joined(separator: " ")
        return DictationRecord(
            timestamp: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!,
            bundleID: bundle, appName: app, raw: raw ?? text, final: text,
            mode: mode, durationMs: durationMs, cleanupMs: cleanupMs,
            cleanupWallMs: cleanupWallMs,
            finalizationMs: finalizationMs,
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

    private static func testHistoryClearAll() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-history-clear-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var removedClips: [String] = []
        let store = HistoryStore(
            url: directory.appendingPathComponent("history.sqlite3"),
            removeArchivedClip: { removedClips.append($0) })
        var first = dictation(daysAgo: 0, words: 3)
        first.audioPath = "first.flac"
        var second = dictation(daysAgo: 1, words: 4)
        second.audioPath = "second.wav"
        store.insert(first)
        store.insert(second)

        store.deleteAll()

        expect(store.recent(limit: 10).isEmpty,
               "clear all permanently removes every history row")
        expect(Set(removedClips) == Set(["first.flac", "second.wav"]),
               "clear all removes every archived clip referenced by history")
        expect(
            HistoryClearPolicy.confirmationMessage.contains("archived audio")
                && HistoryClearPolicy.confirmationMessage.contains("can't be undone"),
            "clear-all confirmation accurately discloses destructive audio deletion")
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
               && migrated.first?.cleanupApplied == nil
               && migrated.first?.cleanupWallMs == nil
               && migrated.first?.finalizationMs == nil,
               "legacy row's new columns decode as unknown, not fabricated values")

        store.insert(dictation(
            daysAgo: 0, words: 5, session: "migrated-session",
            sttMs: 250, cleanupMs: 120, cleanupApplied: true,
            cleanupWallMs: 155, finalizationMs: 410))
        let rows = store.recent(limit: 10)
        expect(rows.count == 2, "a migrated store accepts new inserts")
        let fresh = rows.first(where: { $0.sessionID == "migrated-session" })
        expect(
            fresh?.sttMs == 250 && fresh?.cleanupApplied == true
                && fresh?.cleanupWallMs == 155
                && fresh?.finalizationMs == 410,
            "session id and all finalization latency fields round-trip")

        // Reopen: re-running the migration on an already-migrated store must
        // be harmless.
        let reopened = HistoryStore(url: url)
        expect(reopened.recent(limit: 10).count == 2, "migration is idempotent on reopen")
        let window = reopened.insights().allTime
        expect(window.count == 2, "aggregates run over a migrated store")
        expect(window.sttSamples == 1, "legacy rows never fake latency samples")
        expect(
            window.cleanupWallSamples == 1 && window.averageCleanupWallMs == 155,
            "legacy rows stay out of cleanup wall-time averages")
        expect(
            window.finalizationSamples == 1 && window.averageFinalizationMs == 410,
            "legacy rows stay out of stop-to-final latency averages")
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
                session: "a", sttMs: 200, cleanupMs: 100, cleanupApplied: true,
                cleanupWallMs: 150, finalizationMs: 350))
            store.insert(dictation(
                daysAgo: 0, words: 20, durationMs: 30_000, app: "Notes",
                bundle: "com.notes", mode: "Note",
                session: "b", sttMs: 400, cleanupMs: 300, cleanupApplied: true,
                cleanupWallMs: 450, finalizationMs: 650))
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
            expect(
                insights.allTime.cleanupWallSamples == 2
                    && insights.allTime.averageCleanupWallMs == 300,
                "cleanup wall latency averages only instrumented rows")
            expect(
                insights.allTime.finalizationSamples == 2
                    && insights.allTime.averageFinalizationMs == 500,
                "stop-to-final latency averages only instrumented rows")

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
                mode: "Note", sttMs: 77, cleanupMs: 33, cleanupApplied: true,
                cleanupWallMs: 55)
            let reprocessed = store.recent(limit: 10).first { $0.id == fixedID }
            expect(
                reprocessed?.sttMs == 77 && reprocessed?.cleanupMs == 33
                    && reprocessed?.cleanupApplied == true
                    && reprocessed?.cleanupWallMs == 55
                    && reprocessed?.finalizationMs == nil,
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

        // Backward compatibility: releases before stable Me/Them could persist
        // s1/s2 labels. Keep parsing, display, and the track-level cursor so
        // those existing transcripts remain readable.
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
        expect(store.recordMetadata(id: id)?.segments.isEmpty == true,
               "focused meeting windows load notes before transcript rows")
        let notesFailedID = UUID().uuidString
        store.insertProcessing(MeetingRecord(
            id: notesFailedID, title: "Transcript without notes",
            startedAt: started.addingTimeInterval(-60),
            endedAt: started, status: .processing))
        store.appendSegment(MeetingSegment(
            meetingID: notesFailedID, speaker: .me, chunkIndex: 0,
            startMs: 0, endMs: 4_000, text: "Durable transcript content."))
        store.markNotesFailed(
            meetingID: notesFailedID,
            error: "local notes generation failed (timeout_hard)")
        expect(store.recordMetadata(id: notesFailedID)?.status == .ready
               && store.hasCommittedSegments(meetingID: notesFailedID)
               && store.hasPendingNotes(meetingID: notesFailedID)
               && store.search("Durable transcript", limit: 10)
                    .contains(where: { $0.meetingID == notesFailedID }),
               "notes-only failure keeps the durable transcript searchable")
        expect(!store.hasUsableAudio(relativePath: "\(id)/me.caf"),
               "header-only or tiny meeting captures are not offered for Retry")
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
        store.delete(meetingID: notesFailedID)
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
        let recoveredSystem = recoveredDirectory.appendingPathComponent("them.caf")
        if let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9_600) {
            buffer.frameLength = 9_600
            if let samples = buffer.floatChannelData?[0] {
                for index in 0..<Int(buffer.frameLength) {
                    samples[index] = sin(Float(index) * 0.04) * 0.1
                }
            }
            for url in [recoveredMic, recoveredSystem] {
                autoreleasepool {
                    if let file = try? AVAudioFile(forWriting: url, settings: format.settings) {
                        try? file.write(from: buffer)
                    }
                }
            }
        }
        let recoveredSize = (try? recoveredMic.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let recoveredProbe = try? AVAudioFile(forReading: recoveredMic)
        expect((recoveredProbe?.length ?? 0) > 0 && recoveredSize > 4_096,
               "flushed CAF audio stays readable without a final container rewrite")
        let interruptedAt = Date(timeIntervalSince1970: 1_700_001_000)
        interrupted?.insertRecording(MeetingRecord(
            id: recoveredID, title: "Interrupted meeting",
            startedAt: interruptedAt, endedAt: interruptedAt,
            status: .recording, micPath: "\(recoveredID)/me.caf",
            systemPath: "\(recoveredID)/them.caf"))
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
        expect(recoveredRecord?.systemPath == "\(recoveredID)/them.caf"
               && FileManager.default.fileExists(atPath: recoveredSystem.path),
               "relaunch retains readable interrupted system CAF audio for Retry")
        expect(reopened.record(id: emptyID) == nil,
               "relaunch removes an interrupted preparation that captured no audio")
        let pruneID = UUID().uuidString
        let pruneDirectory = recoveryRoot.appendingPathComponent(pruneID, isDirectory: true)
        MeetingStore.ensurePrivateDirectory(pruneDirectory)
        try? FileManager.default.copyItem(
            at: recoveredMic, to: pruneDirectory.appendingPathComponent("me.caf"))
        try? FileManager.default.copyItem(
            at: recoveredSystem, to: pruneDirectory.appendingPathComponent("them.caf"))
        reopened.insertProcessing(MeetingRecord(
            id: pruneID, title: "Old retained meeting",
            startedAt: interruptedAt, endedAt: interruptedAt,
            status: .processing, micPath: "\(pruneID)/me.caf",
            systemPath: "\(pruneID)/them.caf"))
        reopened.complete(
            meetingID: pruneID, notes: MeetingNotes(summary: "Old notes"))
        var pruneNotificationReceived = false
        let pruneObserver = NotificationCenter.default.addObserver(
            forName: .veloraMeetingsChanged, object: nil, queue: .main
        ) { _ in
            pruneNotificationReceived = true
        }
        reopened.pruneAudio(olderThanDays: 7)
        expect(waitUntil {
            reopened.recordMetadata(id: pruneID)?.micPath == nil
                && pruneNotificationReceived
        }, "audio pruning refreshes cached Retry/Recreate eligibility")
        NotificationCenter.default.removeObserver(pruneObserver)

        let legacyNotesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "velora-meeting-notes-migration-\(UUID().uuidString)",
                isDirectory: true)
        let legacyNotesDB = legacyNotesRoot.appendingPathComponent("meetings.sqlite3")
        defer { try? FileManager.default.removeItem(at: legacyNotesRoot) }
        try? FileManager.default.createDirectory(
            at: legacyNotesRoot, withIntermediateDirectories: true)
        var legacyHandle: OpaquePointer?
        let legacyID = UUID().uuidString
        let legacyOpened = sqlite3_open(legacyNotesDB.path, &legacyHandle) == SQLITE_OK
        let legacySQL = """
            CREATE TABLE meetings (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, started_at REAL NOT NULL,
                ended_at REAL NOT NULL, source_app TEXT, calendar_event_id TEXT,
                status TEXT NOT NULL, summary TEXT NOT NULL DEFAULT '',
                decisions TEXT NOT NULL DEFAULT '', action_items TEXT NOT NULL DEFAULT '',
                mic_path TEXT, system_path TEXT, error TEXT
            );
            CREATE TABLE meeting_segments (
                id INTEGER PRIMARY KEY AUTOINCREMENT, meeting_id TEXT NOT NULL,
                speaker TEXT NOT NULL, chunk_index INTEGER NOT NULL,
                start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, text TEXT NOT NULL,
                UNIQUE(meeting_id, speaker, chunk_index)
            );
            INSERT INTO meetings
                (id, title, started_at, ended_at, status, error)
            VALUES ('\(legacyID)', 'Legacy notes timeout', 1, 2, 'failed',
                    'local notes generation failed (timeout_hard)');
            INSERT INTO meeting_segments
                (meeting_id, speaker, chunk_index, start_ms, end_ms, text)
            VALUES ('\(legacyID)', 'me', 0, 0, 1000, 'Saved before upgrade.');
            """
        let legacySeeded = legacyOpened
            && sqlite3_exec(legacyHandle, legacySQL, nil, nil, nil) == SQLITE_OK
        if legacyHandle != nil { sqlite3_close(legacyHandle) }
        expect(legacySeeded, "legacy notes-timeout fixture seeds")
        if legacySeeded {
            let migratedStore = MeetingStore(
                url: legacyNotesDB, filesRoot: legacyNotesRoot)
            expect(migratedStore.recordMetadata(id: legacyID)?.status == .processing
                   && migratedStore.hasPendingNotes(meetingID: legacyID)
                   && migratedStore.resumable().contains(where: { $0.id == legacyID }),
                   "legacy notes timeout migrates into one durable automatic retry")
        }
    }

    private static func testMeetingProcessingPipeline() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-meeting-pipeline-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingStore(
            url: root.appendingPathComponent("meetings.sqlite3"), filesRoot: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID().uuidString
        let audioDir = root.appendingPathComponent(id, isDirectory: true)
        MeetingStore.ensurePrivateDirectory(audioDir)
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        for name in ["me.caf", "them.caf"] {
            if let audioFormat,
               let buffer = AVAudioPCMBuffer(
                    pcmFormat: audioFormat, frameCapacity: 9_600) {
                buffer.frameLength = 9_600
                if let samples = buffer.floatChannelData?[0] {
                    for index in 0..<Int(buffer.frameLength) {
                        samples[index] = sin(Float(index) * 0.04) * 0.1
                    }
                }
                autoreleasepool {
                    if let file = try? AVAudioFile(
                        forWriting: audioDir.appendingPathComponent(name),
                        settings: audioFormat.settings) {
                        try? file.write(from: buffer)
                    }
                }
            }
        }
        store.insertProcessing(MeetingRecord(
            id: id, title: "Two-person review",
            startedAt: Date(timeIntervalSince1970: 1_700_002_000),
            endedAt: Date(timeIntervalSince1970: 1_700_002_120),
            status: .processing, micPath: "\(id)/me.caf",
            systemPath: "\(id)/them.caf"))
        expect(store.hasUsableAudio(relativePath: "\(id)/me.caf")
               && store.hasUsableAudio(relativePath: "\(id)/them.caf"),
               "meeting Retry accepts retained tracks with captured payload bytes")
        expect(store.recordMetadata(id: id).map {
            store.hasAllCapturedAudio(for: $0)
        } == true, "Recreate is available only when every captured side remains readable")
        let corruptID = UUID().uuidString
        let corruptDir = root.appendingPathComponent(corruptID, isDirectory: true)
        MeetingStore.ensurePrivateDirectory(corruptDir)
        FileManager.default.createFile(
            atPath: corruptDir.appendingPathComponent("me.caf").path,
            contents: Data(repeating: 0xA5, count: 8_192))
        expect(!store.hasUsableAudio(relativePath: "\(corruptID)/me.caf"),
               "meeting Retry rejects corrupt bytes even when the file exceeds the size threshold")
        store.insertProcessing(MeetingRecord(
            id: corruptID, title: "Unreadable interrupted meeting",
            startedAt: Date(timeIntervalSince1970: 1_700_001_500),
            endedAt: Date(timeIntervalSince1970: 1_700_001_510),
            status: .processing, micPath: "\(corruptID)/me.caf"))
        let recoveryProcessor = MeetingProcessor(
            store: store, engineIsReady: { false },
            sendToEngine: { _ in })
        recoveryProcessor.resumeRecoverable()
        expect(store.recordMetadata(id: corruptID)?.status == .failed,
               "launch recovery fails unreadable processing rows instead of leaving them stuck")

        var commands: [[String: Any]] = []
        var processorEngineReady = true
        let processor = MeetingProcessor(
            store: store, engineIsReady: { processorEngineReady },
            sendToEngine: { commands.append($0) })
        var presentedMeetingID: String?
        processor.onNotesReady = { presentedMeetingID = $0 }

        let missingTrackID = UUID().uuidString
        let missingTrackDir = root.appendingPathComponent(
            missingTrackID, isDirectory: true)
        MeetingStore.ensurePrivateDirectory(missingTrackDir)
        try? FileManager.default.copyItem(
            at: audioDir.appendingPathComponent("me.caf"),
            to: missingTrackDir.appendingPathComponent("me.caf"))
        store.insertProcessing(MeetingRecord(
            id: missingTrackID, title: "Two-sided retained meeting",
            startedAt: Date(timeIntervalSince1970: 1_700_001_700),
            endedAt: Date(timeIntervalSince1970: 1_700_001_760),
            status: .processing, micPath: "\(missingTrackID)/me.caf",
            systemPath: "\(missingTrackID)/them.caf"))
        store.appendSegment(MeetingSegment(
            meetingID: missingTrackID, speaker: .me, chunkIndex: 0,
            startMs: 0, endMs: 10_000, text: "Existing microphone side."))
        store.appendSegment(MeetingSegment(
            meetingID: missingTrackID, speaker: .them, chunkIndex: 0,
            startMs: 500, endMs: 10_500, text: "Existing remote side."))
        store.complete(
            meetingID: missingTrackID,
            notes: MeetingNotes(summary: "Existing two-sided notes."))
        expect(store.recordMetadata(id: missingTrackID).map {
            store.hasAllCapturedAudio(for: $0)
        } == false, "Recreate availability rejects a missing side before presenting Retry")
        processor.reprocess(meetingID: missingTrackID)
        expect(commands.isEmpty
               && store.recordMetadata(id: missingTrackID)?.status == .ready
               && store.record(id: missingTrackID)?.segments.count == 2
               && store.search("Existing two-sided", limit: 10)
                    .contains(where: { $0.meetingID == missingTrackID })
               && !store.isReprocessing(meetingID: missingTrackID),
               "Recreate preflight preserves searchable two-sided notes when one captured track is missing")

        processor.enqueue(meetingID: id)

        expect(commands.count == 1
               && commands[0]["cmd"] as? String == "meeting_transcribe"
               && commands[0]["speaker"] as? String == "me",
               "two-track meeting processing starts with the microphone track")
        guard let micJob = commands.first?["id"] as? String else {
            expect(false, "microphone meeting command carries a job id")
            return
        }
        processor.handle(.meetingSegment(
            id: micJob,
            segment: MeetingSegment(
                meetingID: id, speaker: .me, chunkIndex: 0,
                startMs: 0, endMs: 60_000, text: "I will send the proposal.")))
        processor.handle(.meetingTranscribed(
            id: micJob, meetingID: id, speaker: .me, durationS: 120, chunks: 1))

        expect(commands.count == 2
               && commands[1]["cmd"] as? String == "meeting_transcribe"
               && commands[1]["speaker"] as? String == "them",
               "two-track meeting processing continues with computer audio")
        guard let systemJob = commands.last?["id"] as? String else {
            expect(false, "system-audio meeting command carries a job id")
            return
        }
        processor.handle(.meetingSegment(
            id: systemJob,
            segment: MeetingSegment(
                meetingID: id, speaker: .them, chunkIndex: 0,
                startMs: 1_000, endMs: 61_000, text: "Please send it tomorrow.")))
        processor.handle(.meetingTranscribed(
            id: systemJob, meetingID: id, speaker: .them, durationS: 120, chunks: 1))

        let notesCommand = commands.last
        let notesTranscript = notesCommand?["transcript"] as? String
        expect(commands.count == 3
               && notesCommand?["cmd"] as? String == "meeting_notes"
               && notesTranscript?.contains("Me: I will send") == true
               && notesTranscript?.contains("Them: Please send") == true,
               "meeting notes receive the complete chronological Me/Them transcript")
        guard let notesJob = notesCommand?["id"] as? String else {
            expect(false, "meeting notes command carries a job id")
            return
        }
        let notes = MeetingNotes(
            summary: "The proposal will be sent tomorrow.",
            decisions: ["Send tomorrow"],
            actionItems: ["Me: send the proposal"])
        processor.handle(.meetingNotesFailed(
            id: notesJob, meetingID: id,
            error: "local notes generation failed (timeout_hard)",
            code: "timeout_hard"))
        expect(store.recordMetadata(id: id)?.status == .ready
               && store.record(id: id)?.segments.count == 2
               && store.recordMetadata(id: id)?.error != nil,
               "notes timeout preserves the completed transcript as a ready meeting")

        commands.removeAll()
        processor.enqueue(meetingID: id)
        let retryNotesCommand = commands.last
        expect(commands.count == 1
               && retryNotesCommand?["cmd"] as? String == "meeting_notes",
               "Retry after notes failure skips already-completed transcription")
        guard let retryNotesJob = retryNotesCommand?["id"] as? String else {
            expect(false, "notes-only retry carries a job id")
            return
        }
        processor.handle(.meetingNotesReady(
            id: retryNotesJob, meetingID: id, notes: notes))

        expect(store.record(id: id)?.status == .ready
               && store.record(id: id)?.segments.count == 2,
               "notes-ready atomically exposes the completed two-track meeting")
        expect(presentedMeetingID == id,
               "notes-ready publishes the meeting id for automatic focused-window presentation")

        let model = MeetingNotesWindowModel(store: store)
        let start = Date()
        model.show(meetingID: id)
        expect(Date().timeIntervalSince(start) < 0.1 && model.loading,
               "focused meeting presentation returns immediately while metadata loads")
        expect(waitUntil { model.record?.id == id },
               "focused meeting presentation loads completed notes asynchronously")
        expect(model.record?.notes == notes && model.record?.segments.isEmpty == true,
               "focused meeting presentation renders notes without eagerly loading transcript rows")
        model.loadTranscript()
        expect(waitUntil { model.transcript?.count == 2 },
               "focused meeting transcript loads only after explicit expansion")
        let firstPresentation = model.presentationToken
        model.show(meetingID: id)
        expect(model.presentationToken != firstPresentation && model.transcript == nil,
               "showing the same finished meeting resets lazy transcript presentation")

        model.show(meetingID: UUID().uuidString)
        model.show(meetingID: id)
        expect(waitUntil { model.record?.id == id },
               "a stale async meeting load cannot replace the latest selection")

        let transcriptOnlyID = UUID().uuidString
        store.insertProcessing(MeetingRecord(
            id: transcriptOnlyID, title: "Audio already expired",
            startedAt: Date(timeIntervalSince1970: 1_700_001_900),
            endedAt: Date(timeIntervalSince1970: 1_700_001_960),
            status: .processing))
        store.appendSegment(MeetingSegment(
            meetingID: transcriptOnlyID, speaker: .them, chunkIndex: 0,
            startMs: 0, endMs: 20_000, text: "Use the saved transcript."))
        store.markNotesFailed(
            meetingID: transcriptOnlyID,
            error: "local notes generation failed (timeout_hard)")
        commands.removeAll()
        processor.enqueue(meetingID: transcriptOnlyID)
        expect(commands.count == 1
               && commands.first?["cmd"] as? String == "meeting_notes"
               && commands.first?["transcript"] as? String
                    == "[00:00] Them: Use the saved transcript.",
               "notes can be retried from the transcript after all audio is gone")
        processorEngineReady = false
        processor.handleEngineStateChange(.launching)
        processorEngineReady = true
        processor.handleEngineStateChange(.ready)
        expect(commands.count == 2
               && commands.last?["cmd"] as? String == "meeting_notes"
               && store.recordMetadata(id: transcriptOnlyID)?.status == .processing,
               "engine restart preserves an audio-free notes-only retry")
        if let transcriptOnlyJob = commands.last?["id"] as? String {
            processor.handle(.meetingNotesReady(
                id: transcriptOnlyJob, meetingID: transcriptOnlyID,
                notes: MeetingNotes(summary: "Recovered without audio.")))
        }

        let partialID = UUID().uuidString
        let partialDirectory = root.appendingPathComponent(
            partialID, isDirectory: true)
        MeetingStore.ensurePrivateDirectory(partialDirectory)
        try? FileManager.default.copyItem(
            at: audioDir.appendingPathComponent("me.caf"),
            to: partialDirectory.appendingPathComponent("me.caf"))
        store.insertProcessing(MeetingRecord(
            id: partialID, title: "Interrupted transcription",
            startedAt: Date(timeIntervalSince1970: 1_700_001_800),
            endedAt: Date(timeIntervalSince1970: 1_700_001_860),
            status: .processing, micPath: "\(partialID)/me.caf"))
        store.appendSegment(MeetingSegment(
            meetingID: partialID, speaker: .me, chunkIndex: 0,
            startMs: 0, endMs: 10_000, text: "Only the first chunk exists."))
        store.markFailed(
            meetingID: partialID, error: "transcription failed mid-track")
        commands.removeAll()
        processor.enqueue(meetingID: partialID)
        expect(commands.count == 1
               && commands.first?["cmd"] as? String == "meeting_transcribe",
               "a partial transcription error never masquerades as notes-only recovery")
        processor.cancelAndForget(meetingID: partialID)
        store.delete(meetingID: partialID)

        let crashRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "velora-meeting-notes-crash-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: crashRoot) }
        let crashID = UUID().uuidString
        var crashStore: MeetingStore? = MeetingStore(
            url: crashRoot.appendingPathComponent("meetings.sqlite3"),
            filesRoot: crashRoot)
        let crashAudioDir = crashRoot.appendingPathComponent(
            crashID, isDirectory: true)
        MeetingStore.ensurePrivateDirectory(crashAudioDir)
        try? FileManager.default.copyItem(
            at: audioDir.appendingPathComponent("me.caf"),
            to: crashAudioDir.appendingPathComponent("me.caf"))
        crashStore?.insertProcessing(MeetingRecord(
            id: crashID, title: "Crash during notes",
            startedAt: Date(timeIntervalSince1970: 1_700_001_600),
            endedAt: Date(timeIntervalSince1970: 1_700_001_660),
            status: .processing, micPath: "\(crashID)/me.caf"))
        var beforeCrashCommands: [[String: Any]] = []
        var beforeCrash: MeetingProcessor? = crashStore.map { crashStore in
            MeetingProcessor(
                store: crashStore, engineIsReady: { true },
                sendToEngine: { beforeCrashCommands.append($0) })
        }
        beforeCrash?.enqueue(meetingID: crashID)
        if let transcribeJob = beforeCrashCommands.first?["id"] as? String {
            beforeCrash?.handle(.meetingSegment(
                id: transcribeJob,
                segment: MeetingSegment(
                    meetingID: crashID, speaker: .me, chunkIndex: 0,
                    startMs: 0, endMs: 8_000,
                    text: "The transcript was committed before the crash.")))
            beforeCrash?.handle(.meetingTranscribed(
                id: transcribeJob, meetingID: crashID, speaker: .me,
                durationS: 8, chunks: 1))
        }
        expect(beforeCrashCommands.last?["cmd"] as? String == "meeting_notes"
               && crashStore?.hasPendingNotes(meetingID: crashID) == true,
               "entering notes persists the notes-only crash boundary before engine send")
        beforeCrash = nil
        crashStore = nil

        let reopenedCrashStore = MeetingStore(
            url: crashRoot.appendingPathComponent("meetings.sqlite3"),
            filesRoot: crashRoot)
        var afterCrashCommands: [[String: Any]] = []
        let afterCrash = MeetingProcessor(
            store: reopenedCrashStore, engineIsReady: { true },
            sendToEngine: { afterCrashCommands.append($0) })
        afterCrash.resumeRecoverable()
        expect(afterCrashCommands.count == 1
               && afterCrashCommands.first?["cmd"] as? String == "meeting_notes",
               "hard app restart during notes resumes notes instead of retranscribing audio")
        if let notesJob = afterCrashCommands.first?["id"] as? String {
            afterCrash.handle(.meetingNotesReady(
                id: notesJob, meetingID: crashID,
                notes: MeetingNotes(summary: "Recovered after hard exit.")))
        }

        let durableID = UUID().uuidString
        store.insertProcessing(MeetingRecord(
            id: durableID, title: "Restarted notes retry",
            startedAt: Date(timeIntervalSince1970: 1_700_001_700),
            endedAt: Date(timeIntervalSince1970: 1_700_001_760),
            status: .processing))
        store.appendSegment(MeetingSegment(
            meetingID: durableID, speaker: .me, chunkIndex: 0,
            startMs: 0, endMs: 12_000, text: "Notes survive app restart."))
        store.markNotesFailed(
            meetingID: durableID,
            error: "local notes generation failed (timeout_hard)")
        do {
            let preRestart = MeetingProcessor(
                store: store, engineIsReady: { false },
                sendToEngine: { _ in
                    expect(false, "unavailable engine cannot receive notes")
                })
            preRestart.enqueue(meetingID: durableID)
        }
        var restartedCommands: [[String: Any]] = []
        let postRestart = MeetingProcessor(
            store: store, engineIsReady: { true },
            sendToEngine: { restartedCommands.append($0) })
        postRestart.resumeRecoverable()
        expect(restartedCommands.count == 1
               && restartedCommands.first?["cmd"] as? String == "meeting_notes",
               "notes-only retry is durable across an app-process restart")
        if let restartedJob = restartedCommands.first?["id"] as? String {
            postRestart.handle(.meetingNotesReady(
                id: restartedJob, meetingID: durableID,
                notes: MeetingNotes(summary: "Recovered after restart.")))
        }

        commands.removeAll()
        processor.reprocess(meetingID: id)
        let rebuilding = store.record(id: id)
        expect(commands.first?["speaker"] as? String == "me"
               && rebuilding?.status == .processing
               && rebuilding?.segments.count == 2
               && store.reprocessRecord(id: id)?.segments.isEmpty == true
               && rebuilding?.notes == notes,
               "explicit Recreate stages replacement while preserving the committed transcript and notes")

        guard let replacementMicJob = commands.first?["id"] as? String else {
            expect(false, "replacement microphone command carries a job id")
            return
        }
        processor.handle(.meetingSegment(
            id: replacementMicJob,
            segment: MeetingSegment(
                meetingID: id, speaker: .me, chunkIndex: 0,
                startMs: 0, endMs: 50_000, text: "Replacement microphone text.")))
        processor.handle(.meetingTranscribed(
            id: replacementMicJob, meetingID: id, speaker: .me,
            durationS: 120, chunks: 1))
        guard let replacementSystemJob = commands.last?["id"] as? String else {
            expect(false, "replacement system command carries a job id")
            return
        }
        processor.handle(.meetingSegment(
            id: replacementSystemJob,
            segment: MeetingSegment(
                meetingID: id, speaker: .them, chunkIndex: 0,
                startMs: 1_000, endMs: 51_000, text: "Replacement system text.")))
        processor.handle(.meetingTranscribed(
            id: replacementSystemJob, meetingID: id, speaker: .them,
            durationS: 120, chunks: 1))
        guard let replacementNotesJob = commands.last?["id"] as? String else {
            expect(false, "replacement notes command carries a job id")
            return
        }
        let replacementNotes = MeetingNotes(summary: "Replacement summary.")
        processor.handle(.meetingNotesReady(
            id: replacementNotesJob, meetingID: id, notes: replacementNotes))
        let replaced = store.record(id: id)
        expect(replaced?.status == .ready
               && replaced?.segments.map(\.text) == [
                    "Replacement microphone text.", "Replacement system text."]
               && replaced?.notes == replacementNotes
               && !store.isReprocessing(meetingID: id),
               "Recreate atomically swaps the staged transcript and notes only after success")

        commands.removeAll()
        processor.reprocess(meetingID: id)
        guard let failingJob = commands.first?["id"] as? String else {
            expect(false, "failing replacement command carries a job id")
            return
        }
        processor.handle(.meetingSegment(
            id: failingJob,
            segment: MeetingSegment(
                meetingID: id, speaker: .me, chunkIndex: 0,
                startMs: 0, endMs: 10_000, text: "Uncommitted replacement.")))
        processor.handle(.meetingTranscribeFailed(
            id: failingJob, meetingID: id, speaker: .me,
            error: "decode failed", code: "invalid_file"))
        expect(store.record(id: id)?.segments.map(\.text) == [
                    "Replacement microphone text.", "Replacement system text."]
               && store.record(id: id)?.notes == replacementNotes
               && store.recordMetadata(id: id)?.status == .ready
               && store.search("Replacement", limit: 10).contains(where: { $0.meetingID == id })
               && store.isReprocessing(meetingID: id),
               "a failed Recreate keeps the committed meeting visible and searchable for Retry")
        commands.removeAll()
        processor.enqueue(meetingID: id)
        expect(commands.first?["speaker"] as? String == "me"
               && commands.first?["start_chunk"] as? Int == 1,
               "Retry resumes the staged Recreate cursor instead of touching committed rows")
        guard let resumedMicJob = commands.first?["id"] as? String else {
            expect(false, "resumed replacement microphone command carries a job id")
            return
        }
        processor.handle(.meetingTranscribed(
            id: resumedMicJob, meetingID: id, speaker: .me,
            durationS: 120, chunks: 1))
        guard let emptySystemJob = commands.last?["id"] as? String else {
            expect(false, "empty replacement system command carries a job id")
            return
        }
        processor.handle(.meetingTranscribed(
            id: emptySystemJob, meetingID: id, speaker: .them,
            durationS: 120, chunks: 0))
        expect(commands.last?["cmd"] as? String == "meeting_transcribe"
               && store.record(id: id)?.segments.map(\.text) == [
                    "Replacement microphone text.", "Replacement system text."]
               && store.recordMetadata(id: id)?.status == .ready,
               "Recreate refuses an incomplete captured track and preserves both committed sides")

        commands.removeAll()
        processor.reprocess(meetingID: id)
        processor.cancelCurrent()
        expect(store.recordMetadata(id: id)?.status == .ready
               && store.record(id: id)?.segments.count == 2
               && store.isReprocessing(meetingID: id),
               "cancelling Recreate preserves the last good meeting and a resumable retry")

        commands.removeAll()
        processor.enqueue(meetingID: id)
        guard let busyJob = commands.first?["id"] as? String else {
            expect(false, "busy retry carries a job id")
            return
        }
        processor.handle(.meetingTranscribeFailed(
            id: busyJob, meetingID: id, speaker: .me,
            error: "engine busy", code: "busy"))
        expect(processor.isPending(meetingID: id),
               "busy backoff remains cancellable while active work is cleared")
        processor.cancelCurrent()
        let commandsAfterBusyCancel = commands.count
        processor.handleEngineStateChange(.ready)
        expect(processor.state == .failed(
                    meetingID: id, message: "Processing cancelled")
               && store.recordMetadata(id: id)?.status == .ready
               && store.isReprocessing(meetingID: id)
               && !processor.isPending(meetingID: id)
               && commands.count == commandsAfterBusyCancel,
               "Cancel stops a queued busy retry instead of silently restarting it")

        commands.removeAll()
        processor.enqueue(meetingID: id)
        expect(!commands.isEmpty, "engine-restart retry begins before interruption")
        processorEngineReady = false
        processor.handleEngineStateChange(.launching)
        let interveningID = UUID().uuidString
        let interveningDirectory = root.appendingPathComponent(
            interveningID, isDirectory: true)
        MeetingStore.ensurePrivateDirectory(interveningDirectory)
        try? FileManager.default.copyItem(
            at: audioDir.appendingPathComponent("me.caf"),
            to: interveningDirectory.appendingPathComponent("me.caf"))
        store.insertProcessing(MeetingRecord(
            id: interveningID, title: "Intervening queued meeting",
            startedAt: Date(timeIntervalSince1970: 1_700_002_500),
            endedAt: Date(timeIntervalSince1970: 1_700_002_560),
            status: .processing, micPath: "\(interveningID)/me.caf"))
        processor.enqueue(meetingID: interveningID)
        expect(processor.isPending(meetingID: id)
               && processor.isPending(meetingID: interveningID)
               && processor.state == .processing(
                    meetingID: id,
                    label: "Waiting for speech engine…", fraction: 0),
               "new queued work cannot displace an engine-interrupted meeting")
        processor.cancel(meetingID: id)
        let commandsAfterRestartCancel = commands.count
        expect(!processor.isPending(meetingID: id)
               && processor.isPending(meetingID: interveningID)
               && processor.state == .processing(
                    meetingID: interveningID,
                    label: "Waiting for speech engine…", fraction: 0),
               "targeted Cancel advances to the next queued meeting")
        processorEngineReady = true
        processor.handleEngineStateChange(.ready)
        expect(store.recordMetadata(id: id)?.status == .ready
               && store.isReprocessing(meetingID: id)
               && !processor.isPending(meetingID: id)
               && commands.count == commandsAfterRestartCancel + 1
               && commands.last?["meeting_id"] as? String == interveningID,
               "engine recovery cannot resurrect the cancelled interrupted meeting")
        processor.cancel(meetingID: interveningID)

        let firstQueuedID = UUID().uuidString
        let secondQueuedID = UUID().uuidString
        for queuedID in [firstQueuedID, secondQueuedID] {
            let directory = root.appendingPathComponent(queuedID, isDirectory: true)
            MeetingStore.ensurePrivateDirectory(directory)
            try? FileManager.default.copyItem(
                at: audioDir.appendingPathComponent("me.caf"),
                to: directory.appendingPathComponent("me.caf"))
            store.insertProcessing(MeetingRecord(
                id: queuedID, title: "Queued meeting",
                startedAt: Date(timeIntervalSince1970: 1_700_003_000),
                endedAt: Date(timeIntervalSince1970: 1_700_003_060),
                status: .processing, micPath: "\(queuedID)/me.caf"))
        }
        let waitingProcessor = MeetingProcessor(
            store: store, engineIsReady: { false },
            sendToEngine: { _ in
                expect(false, "engine-unavailable queued work never sends a command")
            })
        waitingProcessor.enqueue(meetingID: firstQueuedID)
        waitingProcessor.enqueue(meetingID: secondQueuedID)
        expect(waitingProcessor.isPending(meetingID: firstQueuedID)
               && waitingProcessor.isPending(meetingID: secondQueuedID)
               && waitingProcessor.state == .processing(
                    meetingID: firstQueuedID,
                    label: "Waiting for speech engine…", fraction: 0),
               "prelaunch recovery exposes every queued meeting as pending")
        waitingProcessor.cancel(meetingID: secondQueuedID)
        expect(waitingProcessor.isPending(meetingID: firstQueuedID)
               && !waitingProcessor.isPending(meetingID: secondQueuedID)
               && waitingProcessor.state == .processing(
                    meetingID: firstQueuedID,
                    label: "Waiting for speech engine…", fraction: 0),
               "targeted Cancel removes a queued meeting without cancelling the head")
        waitingProcessor.cancelAndForget(meetingID: firstQueuedID)
        store.delete(meetingID: firstQueuedID)
        expect(waitingProcessor.state == .idle
               && !waitingProcessor.isPending(meetingID: firstQueuedID),
               "deleting workless processing clears the processor presentation state")
    }

    private static func testMeetingEndWatch() {
        var watch = MeetingEndWatch(threshold: 2)
        expect(watch.observe(present: false) == .none
               && watch.observe(present: false) == .none
               && watch.observe(present: false) == .none,
               "a manual recording with no detectable call never fires an end event")

        watch = MeetingEndWatch(threshold: 2)
        _ = watch.observe(present: true)
        expect(watch.observe(present: false) == .none,
               "one absent poll (minimized window, flaky AX read) never ends a meeting")
        expect(watch.observe(present: false) == .ended,
               "two consecutive absent polls after a confirmed call fire the end event")
        expect(watch.observe(present: false) == .none,
               "the end event fires once; Keep Recording stays honored while absent")

        _ = watch.observe(present: true)
        _ = watch.observe(present: false)
        expect(watch.observe(present: false) == .ended,
               "after the call demonstrably resumes, its next end fires again")

        watch = MeetingEndWatch(threshold: 2)
        _ = watch.observe(present: true)
        _ = watch.observe(present: false)
        _ = watch.observe(present: true)
        expect(watch.observe(present: false) == .none,
               "a present poll resets the absence streak")

        // A capture born from a title-confirmed call is pre-confirmed, so a
        // call that dies before the first watch poll still ends the meeting.
        watch = MeetingEndWatch(threshold: 2, confirmed: true)
        _ = watch.observe(present: false)
        expect(watch.observe(present: false) == .ended,
               "a seeded watch detects a call that ended before its first poll")

        // Scope policy: display copy is not transport identity. In particular,
        // Zoom-in-Chrome must never become a native Zoom watch.
        let huddlePresence = MeetingPresence(
            source: "Slack Huddle", channel: .native("Slack Huddle"), micBacked: true)
        let chromePresence = MeetingPresence(
            source: "Browser meeting", channel: .browser("com.google.Chrome"),
            micBacked: true)
        let safariPresence = MeetingPresence(
            source: "Browser meeting", channel: .browser("com.apple.Safari"),
            micBacked: true)
        let meetPresence = MeetingPresence(
            source: "Google Meet", channel: .browser("com.google.Chrome"),
            micBacked: false)
        let zoomTitlePresence = MeetingPresence(
            source: "Zoom", channel: .native("Zoom"), micBacked: false)

        let manual = MeetingWatchScope.forChannel(.unknown)
        expect(manual == .unknown, "a manual recording has an unknown watch scope")
        expect(!manual.matches(chromePresence) && !manual.matches(huddlePresence),
               "mic activity elsewhere is never attributed to a manual recording")
        expect(manual.matches(zoomTitlePresence),
               "a manual recording still accepts title evidence for the ask flow")
        expect(!manual.mayLatchMicEvidence(huddlePresence),
               "a manual recording can never arm automatic stopping")

        let slackScope = MeetingWatchScope.forChannel(.native("Slack Huddle"))
        expect(slackScope.matches(huddlePresence) && !slackScope.matches(chromePresence),
               "a huddle watch only listens to Slack, not to a browser on the mic")
        expect(slackScope.mayLatchMicEvidence(huddlePresence),
               "the huddle's own mic evidence arms automatic stopping")
        expect(!slackScope.mayLatchMicEvidence(zoomTitlePresence),
               "title-only presence never arms automatic stopping")

        let browserScope = MeetingWatchScope.forChannel(.browser("com.google.Chrome"))
        expect(browserScope.matches(chromePresence) && browserScope.matches(meetPresence),
               "a browser watch accepts generic and titled presence from its own browser")
        expect(!browserScope.matches(huddlePresence) && !browserScope.matches(safariPresence),
               "a browser watch ignores native calls and other browser processes")
        let zoomWebScope = MeetingWatchScope.forChannel(.browser("com.google.Chrome"))
        expect(zoomWebScope == browserScope && !zoomWebScope.mayAutoStop,
               "browser-hosted Zoom remains browser transport and can never auto-stop")
        expect(slackScope.mayAutoStop,
               "an attributable native microphone may stop without another question")

        // Streak lengths: native apps hold titles and mic through mutes and
        // device switches; browser calls need a full minute at the 5s watch
        // cadence before asking because a browser may release the mic on mute.
        expect(slackScope.endThreshold == 2 && browserScope.endThreshold == 12
               && manual.endThreshold == 4,
               "native, browser, and manual absence streaks match evidence quality")
    }

    private static func testMeetingDetection() {
        let slackOnly = MeetingDetectionInput(
            runningBundleIDs: ["com.tinyspeck.slackmacgap"],
            windowTitles: ["com.tinyspeck.slackmacgap": ["Velora team — Slack"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false)
        expect(MeetingDetector.candidate(from: slackOnly) == nil,
               "Slack merely running never triggers a meeting suggestion")

        let huddleTitleOnly = MeetingDetectionInput(
            runningBundleIDs: ["com.tinyspeck.slackmacgap"],
            windowTitles: ["com.tinyspeck.slackmacgap": ["Huddle with Product"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false)
        expect(MeetingDetector.candidate(from: huddleTitleOnly) == nil,
               "a call-looking window without live or matching Calendar evidence stays a lobby")

        let huddle = MeetingDetectionInput(
            runningBundleIDs: ["com.tinyspeck.slackmacgap"],
            windowTitles: ["com.tinyspeck.slackmacgap": ["Huddle with Product"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            micCapturingBundleIDs: ["com.tinyspeck.slackmacgap.helper"])
        let huddleCandidate = MeetingDetector.candidate(from: huddle)
        expect(huddleCandidate?.sourceApp == "Slack Huddle"
               && huddleCandidate?.channel == .native("Slack Huddle")
               && huddleCandidate?.micBacked == true,
               "Slack's own microphone produces an attributable native candidate")

        let zoomLink = MeetingDetector.browserConference(
            documentURL: "https://acme.zoom.us/j/123456789")!
        let zoomCalendar = MeetingDetectionInput(
            runningBundleIDs: ["us.zoom.xos"], windowTitles: [:],
            calendarTitle: "Weekly planning", calendarEventID: "event-1",
            calendarHasConferenceLink: true, calendarSource: "Zoom",
            calendarConferenceKey: zoomLink.key)
        expect(MeetingDetector.candidate(from: zoomCalendar) == nil,
               "Calendar plus an idle Zoom process names a possibility but never claims it started")

        let meetURL = "https://meet.google.com/abc-defg-hij"
        let browserMeet = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome"],
            windowTitles: ["com.google.Chrome": ["Harshi Ko"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            browserPages: ["com.google.Chrome": [
                MeetingBrowserPage(title: "Harshi Ko", documentURL: meetURL),
            ]],
            micCapturingBundleIDs: ["com.google.Chrome.helper"])
        let meetCandidate = MeetingDetector.candidate(from: browserMeet)
        expect(meetCandidate?.sourceApp == "Google Meet"
               && meetCandidate?.title == "Harshi Ko"
               && meetCandidate?.channel == .browser("com.google.Chrome")
               && meetCandidate?.micBacked == true,
               "a Meet URL plus Chrome's helper mic detects the reported person-name title case")

        let browserZoom = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome"],
            windowTitles: ["com.google.Chrome": ["Client kickoff - Zoom"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            browserPages: ["com.google.Chrome": [MeetingBrowserPage(
                title: "Client kickoff - Zoom",
                documentURL: "https://acme.zoom.us/j/123456789")]],
            micCapturingBundleIDs: ["com.google.Chrome.helper"])
        let browserZoomCandidate = MeetingDetector.candidate(from: browserZoom)
        expect(browserZoomCandidate?.sourceApp == "Zoom"
               && browserZoomCandidate?.channel == .browser("com.google.Chrome"),
               "Zoom in Chrome stays browser transport instead of arming native Zoom auto-stop")

        let renamedMeet = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome"],
            windowTitles: ["com.google.Chrome": ["Design review"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            browserPages: ["com.google.Chrome": [
                MeetingBrowserPage(
                    title: "Design review",
                    documentURL: meetURL + "?authuser=1#ignored"),
            ]],
            micCapturingBundleIDs: ["com.google.Chrome.helper"])
        expect(MeetingDetector.candidate(from: renamedMeet)?.key == meetCandidate?.key,
               "query, fragment, and title changes do not create a second prompt for one call")
        expect(meetCandidate?.key.contains("abc-defg-hij") == false,
               "the in-memory candidate identity does not retain the meeting code")

        let meetPrejoin = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome"],
            windowTitles: ["com.google.Chrome": ["Harshi Ko"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            browserPages: ["com.google.Chrome": [
                MeetingBrowserPage(title: "Harshi Ko", documentURL: meetURL),
            ]], micCapturingBundleIDs: [])
        expect(MeetingDetector.candidate(from: meetPrejoin) == nil,
               "a recognized Meet page without live evidence remains a prejoin surface")

        // Chrome titles an active Meet tab with the meeting code, never the
        // words "Google Meet". With the mic it should use a provider default,
        // not persist the opaque code as the user's meeting title.
        let meetCodeTab = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome"],
            windowTitles: ["com.google.Chrome": ["Meet – abc-defg-hij"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            micCapturingBundleIDs: ["com.google.Chrome.helper"])
        expect(MeetingDetector.candidate(from: meetCodeTab)?.title == "Google Meet",
               "a code-only active Meet tab falls back to the product name")

        let unrelatedTab = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome"],
            windowTitles: ["com.google.Chrome": ["Meetups near me – Eventbrite"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false)
        expect(MeetingDetector.candidate(from: unrelatedTab) == nil,
               "a tab merely starting with 'meet' never reads as a call")

        expect(MeetingDetector.browserConference(
            documentURL: "https://meet.google.com/landing") == nil,
               "the Meet homepage is not a call")
        expect(MeetingDetector.browserConference(
            documentURL: "https://meet.google.com.evil.example/abc-defg-hij") == nil,
               "a lookalike host is never accepted as Google Meet")
        expect(MeetingDetector.browserConference(
            documentURL: "https://teams.microsoft.com/l/meetup-join/abc")?.source
                == "Microsoft Teams"
               && MeetingDetector.browserConference(
                    documentURL: "https://acme.webex.com/meet/person")?.source == "Webex",
               "Teams and Webex join URLs use the same provider parser")

        // End-watch presence via titles: only call-specific ones count. Zoom
        // idling in the dock must not pin a recording to "still in a meeting",
        // and calendar events cannot see a call that ended early.
        expect(MeetingDetector.activePresences(from: huddle).contains(MeetingPresence(
            source: "Slack Huddle", channel: .native("Slack Huddle"), micBacked: true)),
               "a live huddle microphone reads as attributable presence")
        expect(MeetingDetector.activePresence(from: zoomCalendar) == nil,
               "calendar plus an idle Zoom process is not an active call")
        expect(MeetingDetector.activePresences(from: meetCodeTab).contains(where: {
            $0.channel == .browser("com.google.Chrome") && $0.micBacked
        }),
               "an active Meet tab reads as an active call")
        expect(MeetingDetector.activePresence(from: slackOnly) == nil,
               "Slack without a huddle window is not an active call")

        // Title presence terms are stricter than suggestion scoring: windows
        // whose titles merely contain "call"/"meeting" (Teams Calls tab,
        // Zoom scheduling sheet) would otherwise pin presence forever and
        // end detection would silently never fire.
        let teamsCallsTab = MeetingDetectionInput(
            runningBundleIDs: ["com.microsoft.teams2"],
            windowTitles: ["com.microsoft.teams2": ["Calls | Microsoft Teams"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false)
        expect(MeetingDetector.activePresence(from: teamsCallsTab) == nil,
               "the Teams Calls tab is not an active call")
        let teamsLiveMeeting = MeetingDetectionInput(
            runningBundleIDs: ["com.microsoft.teams2"],
            windowTitles: ["com.microsoft.teams2": ["Meeting with Design | Microsoft Teams"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false)
        expect(MeetingDetector.activePresence(from: teamsLiveMeeting)?.source == "Microsoft Teams",
               "a live Teams meeting window is an active call")
        let zoomScheduling = MeetingDetectionInput(
            runningBundleIDs: ["us.zoom.xos"],
            windowTitles: ["us.zoom.xos": ["Schedule Meeting"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false)
        expect(MeetingDetector.activePresence(from: zoomScheduling) == nil,
               "a Zoom scheduling sheet is not an active call")

        // The microphone is the authoritative signal: an app holding an
        // input stream IS in a call, titles regardless — and releasing it
        // ends one. This is what makes auto-stop safe.
        let zoomOnMic = MeetingDetectionInput(
            runningBundleIDs: ["us.zoom.xos"], windowTitles: [:],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            micCapturingBundleIDs: ["us.zoom.xos"])
        let zoomOnMicCandidate = MeetingDetector.candidate(from: zoomOnMic)
        expect(zoomOnMicCandidate?.sourceApp == "Zoom"
               && zoomOnMicCandidate?.channel == .native("Zoom")
               && zoomOnMicCandidate?.micBacked == true
               && zoomOnMicCandidate?.callConfirmed == true,
               "Zoom holding the microphone is a call even with no titles at all")
        expect(MeetingDetector.activePresence(from: zoomOnMic)
               == MeetingPresence(
                    source: "Zoom", channel: .native("Zoom"), micBacked: true),
               "Zoom holding the microphone reads as mic-backed presence")

        let slackQuiet = MeetingDetectionInput(
            runningBundleIDs: ["com.tinyspeck.slackmacgap"],
            windowTitles: ["com.tinyspeck.slackmacgap": ["Velora team — Slack"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            micCapturingBundleIDs: [])
        expect(MeetingDetector.activePresence(from: slackQuiet) == nil,
               "Slack off the microphone with no huddle window is not a call")

        // A browser mic alone is ambiguous. A matching conference Calendar
        // event can name a background call when Accessibility cannot see its tab.
        let hiddenMeetTab = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome"],
            windowTitles: ["com.google.Chrome": ["Roadmap doc — Google Docs"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            micCapturingBundleIDs: ["com.google.Chrome"])
        expect(MeetingDetector.candidate(from: hiddenMeetTab) == nil,
               "a browser merely holding the mic never suggests recording by itself")
        let hiddenMeetWithCalendar = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome"],
            windowTitles: ["com.google.Chrome": ["Roadmap doc — Google Docs"]],
            calendarTitle: "Design sync", calendarEventID: "ev9",
            calendarHasConferenceLink: true, calendarSource: "Google Meet",
            calendarConferenceKey: MeetingDetector.browserConference(
                documentURL: meetURL)!.key,
            micCapturingBundleIDs: ["com.google.Chrome"])
        let hiddenCandidate = MeetingDetector.candidate(from: hiddenMeetWithCalendar)
        expect(hiddenCandidate != nil && hiddenCandidate?.micBacked == true,
               "calendar plus a browser on the mic finds the call behind a background tab")
        expect(MeetingDetector.activePresences(from: hiddenMeetTab).contains(where: {
            $0.channel == .browser("com.google.Chrome") && $0.micBacked
        }),
               "a browser on the microphone sustains an armed end watch")

        // The process on the mic is routinely a helper, not the app: Chrome
        // captures in "com.google.Chrome.helper", Safari in the shared
        // WebKit GPU process, Electron apps in "<bundle>.helper" children.
        let chromeHelperMeet = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome"],
            windowTitles: ["com.google.Chrome": ["Meet – abc-defg-hij"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            micCapturingBundleIDs: ["com.google.Chrome.helper"])
        let chromeHelperCandidate = MeetingDetector.candidate(from: chromeHelperMeet)
        expect(chromeHelperCandidate?.micBacked == true
               && chromeHelperCandidate?.sourceApp == "Google Meet",
               "Chrome's helper process on the mic counts as the browser capturing")

        let canaryHelper = Set(["com.google.Chrome.canary.helper"])
        expect(MeetingDetector.capturedBrowserBundles(canaryHelper)
               == Set(["com.google.Chrome.canary"])
               && !MeetingDetector.browserMicMatch(
                    bundle: "com.google.Chrome", captured: canaryHelper),
               "Chrome Canary's helper belongs only to the longest matching browser bundle")
        let stablePageWithCanaryMic = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome", "com.google.Chrome.canary"],
            windowTitles: ["com.google.Chrome": ["Harshi Ko"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            browserPages: ["com.google.Chrome": [
                MeetingBrowserPage(title: "Harshi Ko", documentURL: meetURL),
            ]], micCapturingBundleIDs: canaryHelper)
        expect(MeetingDetector.candidate(from: stablePageWithCanaryMic) == nil,
               "Canary microphone evidence cannot confirm a Meet page open in stable Chrome")
        let canaryMeet = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome", "com.google.Chrome.canary"],
            windowTitles: ["com.google.Chrome.canary": ["Harshi Ko"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            browserPages: ["com.google.Chrome.canary": [
                MeetingBrowserPage(title: "Harshi Ko", documentURL: meetURL),
            ]], micCapturingBundleIDs: canaryHelper)
        expect(MeetingDetector.candidate(from: canaryMeet)?.channel
               == .browser("com.google.Chrome.canary")
               && MeetingDetector.candidate(from: canaryMeet)?.micBacked == true,
               "Chrome Canary's own Meet page receives its helper microphone evidence")
        let safariWebKitGPU = MeetingDetectionInput(
            runningBundleIDs: ["com.apple.Safari"], windowTitles: [:],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            micCapturingBundleIDs: ["com.apple.WebKit.GPU"])
        expect(MeetingDetector.activePresences(from: safariWebKitGPU).contains(where: {
            $0.channel == .browser("com.apple.Safari") && $0.micBacked
        }),
               "Safari captures via the WebKit GPU process and still reads as present")
        let slackHelperHuddle = MeetingDetectionInput(
            runningBundleIDs: ["com.tinyspeck.slackmacgap"], windowTitles: [:],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            micCapturingBundleIDs: ["com.tinyspeck.slackmacgap.helper"])
        expect(MeetingDetector.activePresence(from: slackHelperHuddle)
               == MeetingPresence(
                    source: "Slack Huddle", channel: .native("Slack Huddle"),
                    micBacked: true),
               "Slack's Electron helper on the mic reads as a live huddle")

        let secondMeetURL = "https://meet.google.com/xyz-wxyz-xyz"
        let secondMeetKey = MeetingDetector.browserConference(documentURL: secondMeetURL)!.key
        let multipleMeetTabs = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome"], windowTitles: [:],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            browserPages: ["com.google.Chrome": [
                MeetingBrowserPage(title: "Person One", documentURL: meetURL),
                MeetingBrowserPage(title: "Person Two", documentURL: secondMeetURL),
            ]], micCapturingBundleIDs: ["com.google.Chrome.helper"])
        expect(MeetingDetector.candidate(from: multipleMeetTabs)?.title == "Google Meet",
               "two open Meet tabs never assign an arbitrary person's title to the mic")
        let correlatedTabs = MeetingDetectionInput(
            runningBundleIDs: multipleMeetTabs.runningBundleIDs,
            windowTitles: multipleMeetTabs.windowTitles,
            calendarTitle: "Weekly design", calendarEventID: "calendar-2",
            calendarHasConferenceLink: true, calendarSource: "Google Meet",
            calendarConferenceKey: secondMeetKey,
            browserPages: multipleMeetTabs.browserPages,
            micCapturingBundleIDs: multipleMeetTabs.micCapturingBundleIDs)
        expect(MeetingDetector.candidate(from: correlatedTabs)?.title == "Weekly design"
               && MeetingDetector.candidate(from: correlatedTabs)?.key == secondMeetKey,
               "Calendar selects and names only the browser tab with the same conference identity")

        let unrelatedCalendar = MeetingDetectionInput(
            runningBundleIDs: browserMeet.runningBundleIDs,
            windowTitles: browserMeet.windowTitles,
            calendarTitle: "Unrelated Zoom sales call", calendarEventID: "wrong-event",
            calendarHasConferenceLink: true, calendarSource: "Zoom",
            calendarConferenceKey: zoomLink.key,
            browserPages: browserMeet.browserPages,
            micCapturingBundleIDs: browserMeet.micCapturingBundleIDs)
        expect(MeetingDetector.candidate(from: unrelatedCalendar)?.title == "Harshi Ko",
               "an overlapping event for another provider cannot rename the detected call")

        let simultaneous = MeetingDetectionInput(
            runningBundleIDs: ["com.google.Chrome", "com.tinyspeck.slackmacgap"],
            windowTitles: browserMeet.windowTitles,
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            browserPages: browserMeet.browserPages,
            micCapturingBundleIDs: [
                "com.google.Chrome.helper", "com.tinyspeck.slackmacgap.helper",
            ])
        let simultaneousPresence = MeetingDetector.activePresences(from: simultaneous)
        expect(simultaneousPresence.contains(where: {
            $0.channel == .browser("com.google.Chrome") && $0.micBacked
        }) && simultaneousPresence.contains(where: {
            $0.channel == .native("Slack Huddle") && $0.micBacked
        }), "simultaneous browser and native calls are both observable")

        let hostile = "\u{202E}  Design\n\t sync \u{0007}" + String(repeating: "x", count: 100)
        let sanitized = MeetingDetector.sanitizedMeetingTitle(hostile)
        expect(sanitized?.contains("\u{202E}") == false
               && sanitized?.contains("\n") == false
               && sanitized?.count == 80,
               "meeting titles remove controls, collapse whitespace, and stay bounded")

        // Only call-confirmed candidates may seed end watching; Calendar plus
        // an idle app and an uncorrelated title must not.
        expect(MeetingDetector.candidate(from: huddle)?.callConfirmed == true,
               "a mic-backed huddle candidate is call-confirmed")
        expect(MeetingDetector.candidate(from: zoomCalendar) == nil,
               "a calendar-plus-idle-app candidate is rejected")
        expect(MeetingDetector.candidate(from: huddleTitleOnly) == nil,
               "title evidence alone is never treated as a started call")

        func revalidationCandidate(
            key: String = "call-key", micBacked: Bool,
            channel: MeetingChannel = .browser("com.google.Chrome")
        ) -> MeetingCandidate {
            MeetingCandidate(
                key: key, title: "Call", sourceApp: "Google Meet", channel: channel,
                calendarEventID: nil, confidence: 100, callConfirmed: true,
                micBacked: micBacked)
        }
        expect(!MeetingDetector.revalidationMatches(
            expected: revalidationCandidate(micBacked: true),
            current: revalidationCandidate(micBacked: false)),
               "consent to a mic-confirmed call cannot transfer to weaker title evidence")
        expect(MeetingDetector.revalidationMatches(
            expected: revalidationCandidate(micBacked: true),
            current: revalidationCandidate(micBacked: true))
               && MeetingDetector.revalidationMatches(
                    expected: revalidationCandidate(micBacked: false),
                    current: revalidationCandidate(micBacked: true)),
               "revalidation accepts the same live call and allows evidence to strengthen")
        expect(!MeetingDetector.revalidationMatches(
            expected: revalidationCandidate(micBacked: true),
            current: revalidationCandidate(
                key: "other-call", micBacked: true)),
               "revalidation cannot transfer consent to another call identity")

        let unknownMicSample = MeetingDetectionInput(
            runningBundleIDs: ["us.zoom.xos"],
            windowTitles: ["us.zoom.xos": ["Zoom Meeting"]],
            calendarTitle: nil, calendarEventID: nil, calendarHasConferenceLink: false,
            micCapturingBundleIDs: nil)
        expect(!MeetingDetector.endWatchSampleIsReliable(unknownMicSample)
               && MeetingDetector.endWatchSampleIsReliable(MeetingDetectionInput(
                    runningBundleIDs: unknownMicSample.runningBundleIDs,
                    windowTitles: unknownMicSample.windowTitles,
                    calendarTitle: nil, calendarEventID: nil,
                    calendarHasConferenceLink: false,
                    micCapturingBundleIDs: [])),
               "an unavailable mic probe is unknown and cannot accrue an end-watch absence")

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

    private static func testMeetingFailurePresentation() {
        expect(
            MeetingFailurePresentation.hudMessage(
                "local notes generation failed (timeout_hard); retry")
                == "Meeting notes timed out",
            "meeting timeout HUD names the failed stage instead of a generic warning")
        let state = HUDState.meetingFailure(
            meetingID: "meeting-1", message: "Meeting notes timed out")
        expect(
            state.usesNativeMouseControls
                && HUDView.capsuleMetrics(for: state, context: nil).size.width
                    == HUDGeometry.errorWidth,
            "meeting failure HUD owns Open and Retry without starting dictation")
        var failures = MeetingFailureHUDQueue()
        failures.retain(meetingID: "first", message: "First failed")
        failures.retain(meetingID: "second", message: "Second failed")
        failures.remove(meetingID: "second")
        expect(failures.first == .meetingFailure(
            meetingID: "first", message: "First failed"),
            "processing a second queued meeting cannot discard the first actionable failure")
        failures.retain(meetingID: "second", message: "Second failed")
        failures.remove(meetingID: "first")
        expect(failures.first == .meetingFailure(
            meetingID: "second", message: "Second failed"),
            "opening or retrying one failure replays the next retained failure")
        expect(MeetingFailureHUDReplayPolicy.shouldShow(
            dictationIsIdle: true, meetingIsIdle: true,
            processorAllowsFailure: true, hudIsAvailable: true,
            ownsVisibleHUD: false)
               && MeetingFailureHUDReplayPolicy.shouldShow(
                    dictationIsIdle: true, meetingIsIdle: true,
                    processorAllowsFailure: true, hudIsAvailable: false,
                    ownsVisibleHUD: true)
               && !MeetingFailureHUDReplayPolicy.shouldShow(
                    dictationIsIdle: false, meetingIsIdle: true,
                    processorAllowsFailure: true, hudIsAvailable: true,
                    ownsVisibleHUD: false),
               "meeting failure replay waits for dictation release and may replace its own progress HUD")

        var retainedDuringWork = MeetingFailureHUDQueue()
        retainedDuringWork.retain(meetingID: "meeting-a", message: "A failed")
        retainedDuringWork.remove(meetingID: "meeting-b")
        let replayDeniedWhileBProcesses = !MeetingFailureHUDReplayPolicy.shouldShow(
            dictationIsIdle: true, meetingIsIdle: true,
            processorAllowsFailure: false, hudIsAvailable: true,
            ownsVisibleHUD: false)
        let replayAttemptedWhenBBecomesIdle = !retainedDuringWork.isEmpty
        let replayAllowedWhenBBecomesIdle = MeetingFailureHUDReplayPolicy.shouldShow(
            dictationIsIdle: true, meetingIsIdle: true,
            processorAllowsFailure: true, hudIsAvailable: true,
            ownsVisibleHUD: false)
        expect(replayDeniedWhileBProcesses
               && replayAttemptedWhenBBecomesIdle
               && replayAllowedWhenBBecomesIdle,
               "processor processing-to-idle replays a failure retained behind queued work")
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
                    id: "m1", title: "Call", startedAt: Date(), systemAudio: true,
                    endDetected: false).isActive
               && !MeetingCoordinator.State.suggesting(
                    title: "Call", sourceApp: "Google Meet").isActive
               && !MeetingCoordinator.State.idle.isActive,
               "meeting capture exclusion covers capture work, not an unanswered suggestion")
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
        // 2026-08-21 coverage expansion: new chat/email/notes/code/terminal
        // apps land on their categories.
        for (bundleID, name) in [
            ("org.whispersystems.signal-desktop", "Message"),
            ("com.microsoft.teams2", "Message"),
            ("org.telegram.desktop", "Message"),
            ("com.mimestream.Mimestream", "Email"),
            ("com.apple.TextEdit", "Notes"),
            ("com.microsoft.Word", "Notes"),
            ("com.sublimetext.4", "Code"),
            ("com.apple.dt.Xcode", "Code"),
            ("com.jetbrains.pycharm", "Code"),
            ("com.github.wez.wezterm", "Terminal"),
            ("org.mozilla.firefox", "Browser"),
            ("com.brave.Browser", "Browser"),
            ("com.microsoft.edgemac", "Browser"),
        ] {
            expect(ModeCategory.displayName(forBundleID: bundleID) == name,
                   "\(bundleID) maps to \(name)")
        }
        // Site-slug chip refinement: a browser showing a known web app reads
        // as that app's category, mirroring the engine's mode refinement.
        expect(ModeCategory.displayName(forBundleID: "com.google.Chrome", siteSlug: "gmail")
               == "Email", "Chrome+gmail chip reads Email")
        expect(ModeCategory.displayName(forBundleID: "com.google.Chrome", siteSlug: "notion")
               == "Notes", "Chrome+notion chip reads Notes")
        expect(ModeCategory.displayName(forBundleID: "com.google.Chrome", siteSlug: "slack")
               == "Message", "Chrome+slack chip reads Message")
        expect(ModeCategory.displayName(forBundleID: "com.google.Chrome", siteSlug: nil)
               == "Browser", "Chrome without a site stays Browser")
        expect(ModeCategory.displayName(forBundleID: "com.google.Chrome", siteSlug: "nope")
               == "Browser", "unknown slug stays Browser")
        expect(ModeCategory.displayName(forBundleID: "com.apple.mail", siteSlug: "notion")
               == "Email", "site slugs refine browsers only")
        // Every slug the chip can refine to must exist in the engine mirror
        // direction too: the Swift slug table and site tables agree.
        let emittable = Set(ScreenContext.siteKeywords.map(\.slug))
            .union(ScreenContext.siteHosts.map(\.slug))
        for slug in ModeCategory.bySiteSlug.keys {
            expect(emittable.contains(slug),
                   "chip slug \(slug) is emittable by ScreenContext")
        }
        for slug in emittable {
            expect(ModeCategory.bySiteSlug[slug] != nil,
                   "emittable slug \(slug) has a chip category")
        }
    }

    private static func testScreenContextSites() {
        // URL-host detection: exact host, subdomain, www strip, unknown.
        expect(ScreenContext.siteSlug(forHost: "mail.google.com") == "gmail",
               "gmail host detected")
        expect(ScreenContext.siteSlug(forHost: "www.notion.so") == "notion",
               "www-prefixed notion host detected")
        expect(ScreenContext.siteSlug(forHost: "usw2.notion.so") == "notion",
               "notion subdomain detected")
        expect(ScreenContext.siteSlug(forHost: "linear.app") == "linear",
               "linear host detected")
        expect(ScreenContext.siteSlug(forHost: "teams.microsoft.com") == "teams",
               "teams host detected")
        expect(ScreenContext.siteSlug(forHost: "evilnotion.so") == nil,
               "lookalike host is not suffix-matched")
        expect(ScreenContext.siteSlug(forHost: "example.com") == nil,
               "unknown host yields no slug")
        expect(ScreenContext.siteSlug(forHost: nil) == nil, "nil host yields no slug")

        // Page-URL normalization: web schemes only, credentials stripped.
        expect(ScreenContext.normalizedPageURL("https://mail.google.com/mail/u/0/#inbox")?
                .host == "mail.google.com", "https URL accepted")
        expect(ScreenContext.normalizedPageURL("file:///Users/me/secret.txt") == nil,
               "file URL rejected")
        expect(ScreenContext.normalizedPageURL("chrome://settings") == nil,
               "chrome scheme rejected")
        expect(ScreenContext.normalizedPageURL("about:blank") == nil,
               "about scheme rejected")
        expect(ScreenContext.normalizedPageURL("not a url") == nil,
               "garbage rejected")
        let cleaned = ScreenContext.normalizedPageURL("https://user:pw@example.com/a")
        expect(cleaned?.user == nil && cleaned?.password == nil,
               "credentials stripped from page URL")

        // Title-based site detection: trailing browser names dropped, long
        // page-content segments never hijack the site.
        expect(ScreenContext.site(in: ["Inbox (5)", "s@example.com", "Gmail"],
                                  appName: "Google Chrome") == "gmail",
               "Gmail trailing segment detected")
        expect(ScreenContext.site(in: ["Inbox (5)", "Gmail", "Mozilla Firefox"],
                                  appName: "Firefox") == "gmail",
               "Firefox suffix dropped before site detection")
        expect(ScreenContext.site(in: ["Doc", "Google Docs", "Microsoft\u{200B} Edge"],
                                  appName: "Microsoft Edge") == "gdocs",
               "Edge zero-width-space suffix dropped")
        expect(ScreenContext.site(in: ["How to use Gmail effectively"],
                                  appName: "Google Chrome") == nil,
               "long page-content segment cannot hijack the site")
        expect(ScreenContext.site(in: ["#general", "Slack"],
                                  appName: "Safari") == "slack",
               "Slack web detected")
        expect(ScreenContext.site(in: ["Google Chrome"],
                                  appName: "Google Chrome") == nil,
               "bare browser-name title yields nothing")

        // Browser press policy: links join rows/cells in browsers only;
        // send authority (communication bundles) is untouched.
        expect(ActionRuntimePolicy.pressRoles(forBundleID: "com.google.Chrome")?
                .contains("AXLink") == true, "browser press allows links")
        expect(ActionRuntimePolicy.pressRoles(forBundleID: "com.tinyspeck.slackmacgap")
               == ScreenContext.actionNavigationRoles,
               "communication press stays rows/cells")
        expect(ActionRuntimePolicy.pressRoles(forBundleID: "com.apple.TextEdit") == nil,
               "other apps cannot press at all")
        expect(!ActionRuntimePolicy.isCommunicationBundle("com.google.Chrome"),
               "browsers gain no send authority")
        for bundleID in ["com.apple.Safari", "org.mozilla.firefox", "app.zen-browser.zen"] {
            expect(ActionRuntimePolicy.isBrowserBundle(bundleID),
                   "\(bundleID) recognized as a browser")
        }
    }

    private static func testModeApplicationAssignments() {
        expect(
            Mode.normalizedApplicationIDs([
                " com.apple.Mail ", "com.tinyspeck.slackmacgap", "COM.APPLE.MAIL", "",
            ]) == ["com.apple.Mail", "com.tinyspeck.slackmacgap"],
            "manual mode app assignments deduplicate case-insensitively")
        expect(
            Mode.normalizedApplicationIDs(Mode.parseList(
                "com.apple.Notes, com.microsoft.VSCode, com.apple.Notes"))
                == ["com.apple.Notes", "com.microsoft.VSCode"],
            "advanced bundle-id input shares the app picker's normalization")
        expect(
            Mode.mergingApplicationIDs(
                existing: ["COM.APPLE.MAIL", "com.tinyspeck.slackmacgap", "com.apple.Mail"],
                selected: ["com.apple.mail", "com.apple.Notes"])
                == ["com.apple.mail", "com.tinyspeck.slackmacgap", "com.apple.Notes"],
            "native app selection replaces manual casing and collapses stale variants")
        let email = Mode(
            name: "Email", prompt: "", formatting: "full",
            apps: ["com.apple.Mail"], vocabulary: [], replacements: [])
        let note = Mode(
            name: "Note", prompt: "", formatting: "full",
            apps: [], vocabulary: [], replacements: [])
        let conflict = Mode.firstAssignmentConflict(
            applications: ["COM.APPLE.MAIL"], modes: [email, note], excluding: note.id)
        expect(conflict?.modeName == "Email" && conflict?.bundleID == "com.apple.Mail",
               "an app cannot silently activate whichever duplicate mode loads first")
        expect(
            Mode.firstAssignmentConflict(
                applications: ["com.apple.Mail"], modes: [email, note], excluding: email.id) == nil,
            "saving an app assignment back to its current mode remains valid")
        expect(
            Mode.assignmentConflictExclusion(
                selectedID: email.id, originalIsProtected: true, draftName: "Work Email") == nil,
            "renaming a protected mode validates inherited apps against the retained original")
        expect(
            Mode.assignmentConflictExclusion(
                selectedID: email.id, originalIsProtected: false, draftName: "Work Email") == email.id,
            "renaming a normal mode excludes the row it replaces")
        let index = ModeApplicationIndex.build([
            (name: "Banter", applications: ["COM.TINYSPECK.SLACKMACGAP"]),
        ])
        expect(index["com.tinyspeck.slackmacgap"] == "Banter",
               "custom app assignment supplies the HUD mode label case-insensitively")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-mode-index-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let codeURL = directory.appendingPathComponent("code.json")
        let terminalURL = directory.appendingPathComponent("terminal.json")
        try! Data(#"{"name":"Code","apps":["com.apple.Terminal"]}"#.utf8)
            .write(to: codeURL)
        let lifecycleIndex = ModeApplicationIndex()
        lifecycleIndex.reload(directory: directory)
        expect(lifecycleIndex.modeName(forBundleID: "com.apple.Terminal") == "Code",
               "HUD mode cache reads the pre-migration assignment at startup")
        try! Data(#"{"name":"Code","apps":[]}"#.utf8).write(to: codeURL)
        try! Data(#"{"name":"Terminal","apps":["com.apple.Terminal"]}"#.utf8)
            .write(to: terminalURL)
        lifecycleIndex.reload(directory: directory)
        expect(lifecycleIndex.modeName(forBundleID: "com.apple.Terminal") == "Terminal",
               "ready-state cache refresh follows engine mode migration")
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
        expect(HUDView.elapsedString(seconds: -1) == "0:00",
               "HUD timer clamps negative elapsed time")
        expect(HUDView.elapsedString(seconds: 599) == "9:59",
               "HUD timer stays in its four-character form through nine minutes")
        expect(HUDView.elapsedString(seconds: 600) == "10:00",
               "HUD timer expands rightward at ten minutes")
        expect(HUDView.elapsedString(seconds: 3_599) == "59:59",
               "HUD timer stays compact below one hour")
        expect(HUDView.elapsedString(seconds: 3_600) == "1:00:00",
               "HUD timer adds an hour field for long recordings")
        expect(HUDView.elapsedString(seconds: 11_229) == "3:07:09",
               "HUD timer keeps multi-hour recordings readable")
        expect(HUDView.elapsedString(seconds: 86_400) == "24:00:00",
               "HUD timer represents the maximum custom recording duration")
        expect(HUDGeometry.recordingClusterWidth == 136,
               "recording dot and waveform form a stable centered cluster")
        expect(HUDGeometry.recordingTimerWidth == 32,
               "normal dictation timer reserves only enough room for 59:59")
        expect(HUDGeometry.maximumTimerWidth == 49,
               "recording layout still accounts for the 24-hour custom limit")
        expect(HUDGeometry.maximumChipWidth == 118,
               "long mode labels cannot enter the centered recording cluster")
        let oversizedIcon = NSImage(size: NSSize(width: 512, height: 512))
        let normalizedContext = HUDSessionContext(
            appIcon: oversizedIcon, modeName: "Text")
        expect(
            normalizedContext.appIcon?.size == NSSize(width: 22, height: 22),
            "HUD normalizes lazy app icons before they participate in layout")
        expect(
            oversizedIcon.size == NSSize(width: 512, height: 512),
            "HUD icon normalization does not mutate the source app icon")
        let previewContext = HUDSessionContext(
            appIcon: nil, modeName: "Stream Preview", livePreview: true)
        expect(
            HUDView.capsuleMetrics(
                for: .listening, context: previewContext).size.width
                == HUDGeometry.maxListeningWidth,
            "opaque-target Stream preview reserves the bounded wide capsule")
        expect(
            previewContext != HUDSessionContext(
                appIcon: nil, modeName: "Stream Preview"),
            "live-preview state participates in the HUD geometry cache key")
        expect(HUDGeometry.meetingTimerWidth == 52,
               "meeting timer retains its fixed multi-hour column")
        expect(HUDGeometry.meetingWidth == 260,
               "meeting HUD shrinks with the compact timer instead of adding dead space")
        expect(HUDGeometry.meetingPromptWidth == 420,
               "meeting questions use the bounded wide HUD without changing recording geometry")
        expect(HUDGeometry.controlRowWidth(chipWidth: 72) == 328,
               "Terminal HUD keeps eight points around its centered controls")
        expect(HUDGeometry.controlRowWidth(chipWidth: 55) == 294,
               "Code HUD stays compact around the same centered controls")
        expect(HUDGeometry.controlRowWidth(chipWidth: 49) == 282,
               "Text HUD stays compact around the same centered controls")
        expect(HUDGeometry.controlRowWidth(chipWidth: 0) == 248,
               "context-free recording content fits within the 280-point minimum")
        let terminalInnerGap = (
            HUDGeometry.controlRowWidth(chipWidth: 72)
                - HUDGeometry.contentInsetH * 2
                - 72
                - HUDGeometry.recordingClusterWidth
                - HUDGeometry.recordingTimerWidth
        ) / 2
        expect(terminalInnerGap == 28,
               "Terminal recording cluster has equal 28-point inner gaps")
        let terminalShortCenter = HUDGeometry.recordingClusterCenterX(
            innerWidth: 296, chipWidth: 72, timerWidth: 25)
        expect(
            terminalShortCenter - HUDGeometry.recordingClusterWidth / 2 - 72
                == 296 - 25
                    - (terminalShortCenter + HUDGeometry.recordingClusterWidth / 2),
            "recording cluster is centered between the rendered context and timer")
        let textMaximumTimerGap = (
            HUDGeometry.controlRowWidth(chipWidth: 49)
                - HUDGeometry.contentInsetH * 2
                - 49
                - HUDGeometry.recordingClusterWidth
                - HUDGeometry.maximumTimerWidth
        ) / 2
        expect(textMaximumTimerGap == VeloraSpacing.s,
               "small app labels retain equal gaps around a 24-hour timer")
        let terminalHalfWidth = HUDGeometry.controlRowWidth(chipWidth: 72) / 2
        expect(
            HUDGeometry.recordingClusterWidth / 2
                + VeloraSpacing.s + HUDGeometry.maximumTimerWidth
                <= terminalHalfWidth - HUDGeometry.contentInsetH,
            "Terminal HUD leaves room for an intrinsic 24-hour custom timer")
        expect(
            DictationController.transcribeTimeout(recordingDurationMs: 15_000) == 20,
            "short dictations retain the 20-second finalize watchdog")
        expect(
            DictationController.transcribeTimeout(recordingDurationMs: 3_600_000) == 360,
            "one-hour dictations receive a duration-scaled finalize watchdog")
        expect(
            DictationController.recordingLimitMessage(seconds: 720)
                == "12-minute dictation limit reached",
            "recording-limit notice reflects a preserved custom duration")
        expect(
            DictationController.recordingLimitMessage(seconds: 3_600)
                == "1-hour dictation limit reached",
            "recording-limit notice describes the one-hour default")
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
        expect(
            HUDPanel.panelSize.width >= HUDGeometry.meetingPromptWidth + 40,
            "HUD host leaves shadow room around the meeting prompt")

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
        let suggestionState = HUDState.meetingSuggestion(
            title: "Harshi Ko", source: "Google Meet")
        let suggestionMetrics = HUDView.capsuleMetrics(for: suggestionState, context: nil)
        let endState = HUDState.meetingEnd(title: "Harshi Ko")
        expect(suggestionMetrics.visible
               && suggestionMetrics.size.width == HUDGeometry.meetingPromptWidth
               && HUDView.capsuleMetrics(for: endState, context: nil).size.width
                    == HUDGeometry.meetingPromptWidth,
               "meeting start and end questions render as one stable wide capsule")
        expect(!suggestionState.isAvailable && suggestionState.isMeetingPrompt
               && endState.isMeetingPrompt,
               "meeting questions own the HUD until answered")
        expect(suggestionState.usesNativeMouseControls
               && endState.usesNativeMouseControls
               && meetingState.usesNativeMouseControls
               && !HUDState.listening.usesNativeMouseControls,
               "meeting buttons receive native clicks while dictation keeps whole-pill taps")
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

    private static func testMeetingSystemAudioFileWriter() {
        guard #available(macOS 14.2, *) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-system-writer-\(UUID().uuidString).caf")
        let rejectedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-system-writer-reject-\(UUID().uuidString).caf")
        let contendedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-system-writer-contended-\(UUID().uuidString).caf")
        let interleavedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-system-writer-interleaved-\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: rejectedURL)
            try? FileManager.default.removeItem(at: contendedURL)
            try? FileManager.default.removeItem(at: interleavedURL)
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: 512)
        else {
            expect(false, "system-audio writer test creates PCM fixtures")
            return
        }
        buffer.frameLength = 512
        for channel in 0..<Int(format.channelCount) {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(buffer.frameLength) { samples[frame] = 0.05 }
        }

        let lock = NSLock()
        var writtenFrames = 0
        var failure: String?
        do {
            let writer = try SystemAudioFileWriter(
                url: url, format: format,
                onWritten: { frames in
                    lock.lock(); writtenFrames += Int(frames); lock.unlock()
                },
                onFailure: { message in
                    lock.lock(); failure = message; lock.unlock()
                })
            let accepted = writer.enqueue(
                buffer.audioBufferList,
                frames: UInt32(buffer.frameLength))
            writer.finish()
            let saved = try AVAudioFile(forReading: url)
            lock.lock()
            let callbackFrames = writtenFrames
            let callbackFailure = failure
            lock.unlock()
            expect(
                accepted && callbackFailure == nil
                    && callbackFrames == 512 && saved.length == 512,
                "system audio is copied off the realtime callback and fully flushed")
        } catch {
            expect(false, "system-audio writer saves a CAF: \(error.localizedDescription)")
        }
        if let interleavedFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true),
           let interleavedBuffer = AVAudioPCMBuffer(
            pcmFormat: interleavedFormat, frameCapacity: 256) {
            interleavedBuffer.frameLength = 256
            do {
                let writer = try SystemAudioFileWriter(
                    url: interleavedURL, format: interleavedFormat)
                let accepted = writer.enqueue(
                    interleavedBuffer.audioBufferList,
                    frames: UInt32(interleavedBuffer.frameLength))
                writer.finish()
                let saved = try AVAudioFile(forReading: interleavedURL)
                expect(accepted && saved.length == 256,
                       "system-audio writer accepts the live tap's interleaved LPCM layout")
            } catch {
                expect(false,
                       "interleaved system-audio writer saves a CAF: \(error.localizedDescription)")
            }
        } else {
            expect(false, "interleaved system-audio writer fixtures initialize")
        }
        do {
            var rejection: String?
            let writer = try SystemAudioFileWriter(
                url: rejectedURL, format: format,
                maxPendingBuffers: 1, maxPendingBytes: 1_024,
                bufferFrameCapacity: 128,
                onFailure: { rejection = $0 })
            let accepted = writer.enqueue(
                buffer.audioBufferList,
                frames: UInt32(buffer.frameLength))
            writer.finish()
            expect(!accepted && rejection != nil,
                   "system-audio writer fails closed at its byte bound")
        } catch {
            expect(false, "bounded system-audio writer initializes: \(error.localizedDescription)")
        }
        do {
            let callbackReturned = DispatchSemaphore(value: 0)
            let callbackResultLock = NSLock()
            var callbackAccepted: Bool?
            var contentionFailure: String?
            let writer = try SystemAudioFileWriter(
                url: contendedURL, format: format,
                onFailure: { message in
                    callbackResultLock.lock()
                    contentionFailure = message
                    callbackResultLock.unlock()
                })
            writer.withStateLockForSelftest {
                DispatchQueue.global(qos: .userInitiated).async {
                    let accepted = writer.enqueue(
                        buffer.audioBufferList,
                        frames: UInt32(buffer.frameLength))
                    callbackResultLock.lock()
                    callbackAccepted = accepted
                    callbackResultLock.unlock()
                    callbackReturned.signal()
                }
                _ = callbackReturned.wait(timeout: .now() + 1)
            }
            // Reproduce the teardown race immediately after the realtime
            // callback loses its nonblocking state-lock acquisition.
            writer.finish()
            callbackResultLock.lock()
            let accepted = callbackAccepted
            let reportedFailure = contentionFailure
            callbackResultLock.unlock()
            expect(accepted == false
                   && reportedFailure == "computer-audio disk writer could not keep up",
                   "lock contention remains a durable failure across immediate finish")
        } catch {
            expect(false, "contended system-audio writer initializes: \(error.localizedDescription)")
        }
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
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for index in 0..<1600 { buffer.floatChannelData![0][index] = 0.1 }

        capture.start(
            onChunk: { _ in }, onLevel: { _ in },
            completion: { result in
                if case .success = result { firstStarted = true }
            })
        source.starts[0].completion(.success(()))
        expect(!firstStarted && !capture.isRunning,
               "a session flag alone does not claim microphone readiness")
        source.starts[0].onBuffer(buffer)
        _ = waitUntil { firstStarted }
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
        source.starts[1].onBuffer(buffer)
        _ = waitUntil { secondStarted }
        expect(firstStopped && secondStarted && capture.isRunning,
               "a stale stop completion does not stop the newer session")

        _ = waitUntil { secondBytes > 0 }
        expect(secondBytes == 1600 * MemoryLayout<Float>.size,
               "new microphone handlers still receive PCM after stale teardown")

        capture.stop()
        source.stops[1]()
    }

    private static func testAudioCaptureRequiresPCM() {
        let source = FakeMicrophoneSource()
        var scheduled: [DispatchWorkItem] = []
        let capture = AudioCapture(
            source: source,
            scheduleStartupCheck: { _, work in scheduled.append(work) })
        var result: Result<Void, Error>?

        capture.start(onChunk: { _ in }, onLevel: { _ in }) { result = $0 }
        source.starts[0].completion(.success(()))

        expect(result == nil && !capture.isRunning,
               "microphone startup waits for observed PCM after the session opens")
        scheduled[0].perform()
        if case .failure(let error) = result {
            expect(error.localizedDescription.contains("delivered no audio"),
                   "missing first PCM fails with an actionable microphone error")
        } else {
            expect(false, "missing first PCM must fail startup")
        }
        expect(!capture.isRunning && source.stops.count == 1,
               "first-PCM timeout tears down the unusable microphone session")
        source.stops[0]()
    }

    private static func testAudioCaptureQuickReleasePreservesFirstPCM() {
        let source = FakeMicrophoneSource()
        let capture = AudioCapture(source: source)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for index in 0..<1600 { buffer.floatChannelData![0][index] = 0.1 }
        var bytes = 0
        var stopped = false

        capture.start(
            onChunk: { bytes += $0.count }, onLevel: { _ in },
            completion: { result in
                if case .success = result {
                    capture.stop { stopped = true }
                }
            })
        source.starts[0].completion(.success(()))
        source.starts[0].onBuffer(buffer)
        _ = waitUntil { source.stops.count == 1 }
        source.stops[0]()
        _ = waitUntil { stopped }

        expect(bytes == 1600 * MemoryLayout<Float>.size,
               "quick hold release preserves the first PCM buffer before stop")
    }

    private static func testAudioCaptureStopPreservesConvertedTail() {
        let source = FakeMicrophoneSource()
        let capture = AudioCapture(source: source)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false)!
        let first = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        first.frameLength = 1600
        let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800)!
        tail.frameLength = 800
        var bytes = 0
        var started = false
        var stopped = false

        capture.start(
            onChunk: { bytes += $0.count }, onLevel: { _ in },
            completion: { result in
                if case .success = result { started = true }
            })
        source.starts[0].completion(.success(()))
        source.starts[0].onBuffer(first)
        _ = waitUntil { started }

        source.starts[0].onBuffer(tail)
        capture.stop { stopped = true }
        source.stops[0]()
        _ = waitUntil { stopped }

        expect(bytes == 2400 * MemoryLayout<Float>.size,
               "ordinary stop flushes converted tail PCM queued before source teardown")
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
            processes: [intended], playing: [intended],
            bundleIDs: [intended: "com.spotify.client"])
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: { snapshot },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        snapshot.processes = [intended, accidental]
        // Production excludes browsers from `playing`; the all-output set is
        // the only evidence that the global key started paused YouTube.
        snapshot.playing = [intended]
        snapshot.allPlaying = [intended, accidental]
        snapshot.bundleIDs[accidental] = "com.google.Chrome.helper"
        scheduled.removeFirst().1()
        coordinator.restoreAfterDictation()

        expect(toggles == 2, "a media key that starts the wrong player is immediately reversed")
        expect(scheduled.isEmpty, "a misdirected media key never earns a later resume")
    }

    private static func testMediaPlaybackPausedBrowserBlocksDedicatedPause() {
        let player = AudioObjectID(66)
        let browser = AudioObjectID(67)
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: {
                .init(
                    processes: [player, browser],
                    playing: [player],
                    allPlaying: [player],
                    bundleIDs: [
                        player: "com.spotify.client",
                        browser: "app.zen-browser.zen-media-plugin-helper",
                    ])
            },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()

        expect(toggles == 0,
               "a paused browser that could own the media key blocks a dedicated-player pause")
        expect(scheduled.isEmpty,
               "an ambiguous paused media-key target creates no later media work")
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
        let player = AudioObjectID(60)
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: {
                .init(
                    processes: [player], playing: [player],
                    inputProcesses: [player],
                    bundleIDs: [player: "com.spotify.client"])
            },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        expect(toggles == 0, "media keys are blocked while the player process captures input")
        expect(scheduled.isEmpty, "active call input creates no media resume obligation")
    }

    private static func testMediaPlaybackUnrelatedSystemInput() {
        let player = AudioObjectID(61)
        let systemSpeech = AudioObjectID(62)
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: {
                .init(
                    processes: [player, systemSpeech], playing: [player],
                    inputProcesses: [systemSpeech],
                    bundleIDs: [
                        player: "com.apple.Music",
                        systemSpeech: "com.apple.CoreSpeech",
                    ])
            },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()
        expect(toggles == 1, "unrelated system speech input does not block dedicated media")
        expect(scheduled.count == 1, "an eligible dedicated player still enters verification")
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
            processes: [intended], playing: [intended],
            bundleIDs: [intended: "com.spotify.client"])
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
        snapshot.playing = []
        snapshot.allPlaying = [accidental]
        snapshot.bundleIDs[accidental] = "com.google.Chrome.helper"
        scheduled.removeFirst().1()

        expect(toggles == 3, "a media restore that starts the wrong player is reversed")
        coordinator.restoreAfterDictation()
        expect(scheduled.isEmpty, "a misdirected restore leaves no outstanding media work")
    }

    private static func testMediaPlaybackPausedBrowserBlocksDedicatedRestore() {
        let player = AudioObjectID(68)
        let browser = AudioObjectID(69)
        var snapshot = MediaPlaybackCoordinator.Snapshot(
            processes: [player], playing: [player],
            bundleIDs: [player: "com.apple.Music"])
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
        snapshot.processes = [player, browser]
        snapshot.bundleIDs[browser] = "app.zen-browser.zen"
        scheduled.removeFirst().1()

        expect(toggles == 1,
               "a paused browser that could own the media key suppresses player restore")
        expect(scheduled.isEmpty,
               "a suppressed ambiguous restore creates no verification work")
    }

    private static func testMediaPlaybackMisdirectedRestoreRollsBackOnTermination() {
        let intended = AudioObjectID(64)
        let accidental = AudioObjectID(65)
        var snapshot = MediaPlaybackCoordinator.Snapshot(
            processes: [intended], playing: [intended],
            bundleIDs: [intended: "com.apple.Music"])
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
        snapshot.allPlaying = [accidental]
        snapshot.bundleIDs[accidental] = "com.google.Chrome.helper"
        coordinator.restoreImmediatelyForTermination()
        scheduled.removeFirst().1()

        expect(toggles == 3,
               "termination reverses a restore key that started paused browser media")
        expect(scheduled.isEmpty,
               "termination invalidates stale misdirected-restore verification")
    }

    private static func testMediaPlaybackPausedBrowserFailsClosed() {
        let browser = AudioObjectID(63)
        var toggles = 0
        var scheduled: [(TimeInterval, () -> Void)] = []
        let coordinator = MediaPlaybackCoordinator(
            snapshot: {
                // Chromium keeps IsRunningOutput set after YouTube is paused,
                // so a browser process in this Core Audio set is not evidence
                // that sending a global Play/Pause key will pause anything.
                .init(
                    processes: [browser], playing: [browser],
                    bundleIDs: [browser: "com.google.Chrome.helper"])
            },
            postToggle: { toggles += 1; return true },
            schedule: { delay, work in scheduled.append((delay, work)) })

        coordinator.pauseForDictation()

        expect(toggles == 0, "paused browser playback is never started by dictation")
        expect(scheduled.isEmpty, "paused browser playback creates no restore obligation")
    }

    private static func testMediaPlaybackSupportedPlayers() {
        expect(
            MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.apple.Music")
                && MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.spotify.client"),
            "dedicated players with observable playback state are eligible for dictation pause")
        expect(
            !MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.google.Chrome")
                && !MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.google.Chrome.helper")
                && !MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "org.mozilla.firefox")
                && !MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "app.zen-browser.zen")
                && !MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.apple.FaceTime")
                && !MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "us.zoom.xos")
                && !MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.microsoft.teams2")
                && !MediaPlaybackSystem.isAutomaticPlaybackCandidate(bundleID: "com.example.unknown"),
            "browsers, conference clients, and unknown output never trigger a global media toggle")
        expect(
            MediaPlaybackSystem.isMediaKeyPlaybackCandidate("app.zen-browser.zen")
                && MediaPlaybackSystem.isMediaKeyPlaybackCandidate(
                    "app.zen-browser.zen-media-plugin-helper"),
            "Zen browser processes remain visible to media-key ambiguity guards")
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

        let stagedFinal = TextInserter.snapshotItems(from: pasteboard)
        inserter.stageFinalOutput(" A boundary-adjusted delivery")
        let deliveryChange = pasteboard.changeCount
        expect(
            TextInserter.restore(
                stagedFinal, to: pasteboard, ifUnchanged: deliveryChange)
                && pasteboard.string(forType: .string) == "A final sentence.",
            "paste restoration returns to the persistent final transcript")

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
        pasteboard.setString("Clipboard before guarded edit", forType: .string)
        var exactSelectionChecks = 0
        var pasteCommandPosts = 0
        let guardedInserter = TextInserter(
            pasteboard: pasteboard,
            pasteDeliveryOverride: { _, _ in true },
            pasteCommandOverride: {
                pasteCommandPosts += 1
                return true
            })
        let guardedInsert = guardedInserter.insertViaPasteboard(
            "Edited text",
            additionalDeliveryCheck: {
                exactSelectionChecks += 1
                // Stable at the first boundary, moved after the pasteboard
                // write but before the final Command-V boundary.
                return exactSelectionChecks == 1
            })
        expect(
            !guardedInsert && exactSelectionChecks == 2,
            "guarded paste rechecks the exact edit selection after clipboard write")
        expect(
            pasteCommandPosts == 0,
            "a selection change immediately before paste posts no Command-V")
        expect(
            pasteboard.string(forType: .string) == "Clipboard before guarded edit",
            "a blocked edit paste restores the pre-edit clipboard")
        pasteboard.clearContents()
    }
}
