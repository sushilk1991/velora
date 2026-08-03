import AVFoundation
import Observation
import Speech
import UIKit

@MainActor
@Observable
final class SpeechCaptureService {
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case listening
        case finishing
        case copied
        case failed
    }

    private let store: TranscriptStore
    private let clipboard: ClipboardWriting
    private let audioEngine = AVAudioEngine()

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var activeSpeechSession: ActiveSpeechCaptureSession?
    private var finalizationWatchdogTask: Task<Void, Never>?
    private var refinementTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var refinementSessionID: UUID?
    /// Session the watchdog force-finalized with a stale partial. When the
    /// recognizer's authoritative final arrives moments later, it may
    /// supersede the in-flight refinement instead of being dropped.
    private var fallbackFinalizedSessionID: UUID?
    /// Recognition kept alive after a watchdog fallback. Cancelling it with
    /// the normal teardown would abort the very finalize whose result the
    /// supersede path exists to accept; it gets a deadline instead.
    private var detachedSpeechSession: ActiveSpeechCaptureSession?
    private var detachedRecognitionTask: SFSpeechRecognitionTask?
    private var detachedSessionDeadline: Task<Void, Never>?
    private var refinementSourceText: String?
    private var deliveryProtection: UIBackgroundTaskIdentifier = .invalid
    private var inputTapInstalled = false
    private var finalizationStartedAt: Date?
    private var lastTranscriptUpdateAt: Date?

    static let idleAudioLevel = 0.08

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var audioLevel = SpeechCaptureService.idleAudioLevel
    private(set) var errorMessage: String?
    private(set) var copiedPulse = 0

    init(store: TranscriptStore, clipboard: ClipboardWriting? = nil) {
        self.store = store
        self.clipboard = clipboard ?? SystemClipboard()
        observeAudioInterruptions()
    }

    func start() async {
        guard phase != .listening, phase != .requestingPermission, phase != .finishing else {
            return
        }

        phase = .requestingPermission
        transcript = ""
        errorMessage = nil
        audioLevel = Self.idleAudioLevel
        fallbackFinalizedSessionID = nil
        refinementSourceText = nil
        releaseDetachedSession()

        guard await requestMicrophonePermission() else {
            fail("Microphone access is off. Open Settings and allow Velora to listen while you dictate.")
            return
        }
        guard await requestSpeechPermission() else {
            fail("Speech recognition access is off. Open Settings and allow Velora to turn speech into text.")
            return
        }

        let identifier = VeloraPreferences.resolvedSpeechLocaleIdentifier(
            storedIdentifier: UserDefaults.standard.string(
                forKey: VeloraPreferences.speechLocaleIdentifierKey
            )
        )

        do {
            try configureAudioSession()
        } catch {
            fail("Velora could not start the microphone. Check that another app is not using it, then try again.")
            return
        }

        if #available(iOS 26.0, *) {
            let sessionID = UUID()
            activeSessionID = sessionID
            do {
                let session = try await ModernSpeechCaptureSession.start(
                    localeIdentifier: identifier,
                    onTranscript: { [weak self] updatedTranscript in
                        guard let self, self.activeSessionID == sessionID else { return }
                        if updatedTranscript != self.transcript {
                            self.transcript = updatedTranscript
                            self.lastTranscriptUpdateAt = Date()
                        }
                    },
                    onLevel: { [weak self] level in
                        guard let self, self.activeSessionID == sessionID else { return }
                        self.audioLevel = level
                    },
                    onFinished: { [weak self] finalTranscript in
                        guard let self else { return }
                        if self.activeSessionID == sessionID {
                            self.beginRefinement(with: finalTranscript)
                        } else if self.fallbackFinalizedSessionID == sessionID {
                            // The watchdog delivered a stale partial while the
                            // real finalize kept running detached; the
                            // authoritative final supersedes it while the copy
                            // is still pending.
                            self.fallbackFinalizedSessionID = nil
                            self.releaseDetachedSession()
                            let authoritative = TranscriptFormatter.normalize(finalTranscript)
                            if self.phase == .finishing, !authoritative.isEmpty,
                               authoritative != self.refinementSourceText {
                                self.beginRefinement(with: finalTranscript)
                            }
                        }
                    },
                    onFailure: { [weak self] in
                        guard let self else { return }
                        if self.fallbackFinalizedSessionID == sessionID {
                            // The detached finalize died; the fallback text
                            // already being refined is the best we have.
                            self.fallbackFinalizedSessionID = nil
                            self.releaseDetachedSession()
                            return
                        }
                        guard self.activeSessionID == sessionID else { return }
                        if self.phase == .finishing, !self.transcript.isEmpty {
                            self.beginRefinement(with: self.transcript)
                        } else {
                            self.fail("Dictation stopped before Velora received any words. Check the selected language and try again.")
                        }
                    }
                )
                activeSpeechSession = session
                phase = .listening
                prewarmRefinement()
                return
            } catch {
                activeSessionID = nil
            }
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)) else {
            fail("Speech recognition is not available for the selected language. Choose another language in Settings.")
            return
        }
        guard VeloraPreferences.recognitionLocale(
            recognizer.locale,
            matches: identifier
        ) else {
            fail("On-device recognition is not available for the selected language. Choose another language in Velora Settings.")
            return
        }
        guard recognizer.isAvailable else {
            fail("Speech recognition is temporarily unavailable. Wait a moment, then try again.")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            fail("On-device dictation is unavailable for this language on this iPhone. Check Siri & Dictation settings or choose another language in Velora.")
            return
        }

        do {
            try beginRecognition(using: recognizer)
            prewarmRefinement()
        } catch {
            fail("Velora could not start the microphone. Check that another app is not using it, then try again.")
        }
    }

    func stopAndCopy() {
        guard phase == .listening else { return }
        phase = .finishing
        finalizationStartedAt = Date()
        beginDeliveryProtection()

        if let activeSpeechSession {
            activeSpeechSession.finish()
        } else {
            stopAudioInput(endingRecognition: true)
            recognitionTask?.finish()
        }

        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled,
                      let self,
                      self.phase == .finishing,
                      let startedAt = self.finalizationStartedAt
                else { return }

                let now = Date()
                let decision = RecognitionFinalizationPolicy.decision(
                    transcript: self.transcript,
                    elapsed: now.timeIntervalSince(startedAt),
                    secondsSinceLastUpdate: self.lastTranscriptUpdateAt.map {
                        now.timeIntervalSince($0)
                    } ?? .infinity
                )

                switch decision {
                case .wait:
                    continue
                case .deliverFallback:
                    self.fallbackFinalizedSessionID = self.activeSessionID
                    self.detachSessionForLateFinal()
                    self.beginRefinement(with: self.transcript)
                    return
                case .fail:
                    self.fail("Velora did not hear any words. Move closer to the microphone and try again.")
                    return
                }
            }
        }
    }

    func cancel() {
        guard phase == .listening || phase == .finishing else { return }
        refinementTask?.cancel()
        refinementTask = nil
        refinementSessionID = nil
        fallbackFinalizedSessionID = nil
        refinementSourceText = nil
        releaseDetachedSession()
        tearDownSession(cancelRecognition: true)
        endDeliveryProtection()
        transcript = ""
        errorMessage = nil
        phase = .idle
    }

    func copyAgain() {
        let normalized = TranscriptFormatter.normalizeStructured(transcript)
        guard !normalized.isEmpty else { return }
        clipboard.write(normalized)
        copiedPulse += 1
    }

    func reset() {
        guard phase == .copied || phase == .failed else { return }
        refinementTask?.cancel()
        refinementTask = nil
        refinementSessionID = nil
        fallbackFinalizedSessionID = nil
        refinementSourceText = nil
        transcript = ""
        errorMessage = nil
        audioLevel = Self.idleAudioLevel
        phase = .idle
    }

    private func beginRecognition(using recognizer: SFSpeechRecognizer) throws {
        tearDownSession(cancelRecognition: true)
        try configureAudioSession()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.addsPunctuation = true

        let sessionID = UUID()
        activeSessionID = sessionID
        self.recognizer = recognizer
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.microphoneUnavailable
        }

        // 4096 frames ≈ 85 ms per callback. 1024 spawned ~47 main-actor tasks
        // a second just to move a level number the waveform samples at 20 Hz.
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.normalizedLevel(from: buffer)
            Task { @MainActor [weak self] in
                guard let self, self.activeSessionID == sessionID else { return }
                self.audioLevel = level
            }
        }
        inputTapInstalled = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeSessionID == sessionID else {
                    guard self.fallbackFinalizedSessionID == sessionID else { return }
                    if let result, result.isFinal {
                        // Same race as the modern path: a watchdog fallback
                        // must not outrank the recognizer's real final.
                        self.fallbackFinalizedSessionID = nil
                        self.releaseDetachedSession()
                        let text = result.bestTranscription.formattedString
                        let authoritative = TranscriptFormatter.normalize(text)
                        if self.phase == .finishing, !authoritative.isEmpty,
                           authoritative != self.refinementSourceText {
                            self.beginRefinement(with: text)
                        }
                    } else if error != nil {
                        self.fallbackFinalizedSessionID = nil
                        self.releaseDetachedSession()
                    }
                    return
                }

                if let result {
                    let updatedTranscript = result.bestTranscription.formattedString
                    if updatedTranscript != self.transcript {
                        self.transcript = updatedTranscript
                        self.lastTranscriptUpdateAt = Date()
                    }
                    if result.isFinal {
                        self.beginRefinement(with: self.transcript)
                        return
                    }
                }

                if error != nil {
                    if self.phase == .listening {
                        self.fail("Dictation stopped before Velora received any words. Check the selected language and try again.")
                    }
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        phase = .listening
    }

    private func beginRefinement(with rawText: String) {
        guard phase == .listening || phase == .finishing else { return }
        let basic = TranscriptFormatter.normalize(rawText)
        refinementSourceText = basic
        tearDownSession(cancelRecognition: true)

        guard !basic.isEmpty else {
            fail("Velora did not hear any words. Move closer to the microphone and try again.")
            return
        }

        phase = .finishing
        beginDeliveryProtection()
        let sessionID = UUID()
        refinementSessionID = sessionID
        let style = DictationStyle.resolve(
            UserDefaults.standard.string(forKey: VeloraPreferences.dictationStyleKey)
        )
        let localeIdentifier = VeloraPreferences.resolvedSpeechLocaleIdentifier(
            storedIdentifier: UserDefaults.standard.string(
                forKey: VeloraPreferences.speechLocaleIdentifierKey
            )
        )
        refinementTask?.cancel()
        refinementTask = Task { [weak self] in
            let refined = await TranscriptRefiner.refine(
                basic,
                for: style,
                localeIdentifier: localeIdentifier
            )
            guard !Task.isCancelled, let self,
                  self.phase == .finishing,
                  self.refinementSessionID == sessionID
            else { return }

            self.refinementTask = nil
            self.refinementSessionID = nil
            guard let normalized = TranscriptDelivery.deliver(
                refined,
                to: self.clipboard,
                store: self.store
            ) else {
                self.fail("Velora did not hear any words. Move closer to the microphone and try again.")
                return
            }

            self.transcript = normalized
            self.phase = .copied
            self.copiedPulse += 1
            self.refinementSourceText = nil
            self.fallbackFinalizedSessionID = nil
            self.endDeliveryProtection()
        }
    }

    private func fail(_ message: String) {
        refinementTask?.cancel()
        refinementTask = nil
        refinementSessionID = nil
        fallbackFinalizedSessionID = nil
        refinementSourceText = nil
        releaseDetachedSession()
        tearDownSession(cancelRecognition: true)
        endDeliveryProtection()
        errorMessage = message
        phase = .failed
    }

    /// Moves the live recognition out of `activeSpeechSession` (or the
    /// legacy task) so the coming teardown does not cancel the finalize whose
    /// authoritative result the supersede path wants. A deadline bounds it.
    private func detachSessionForLateFinal() {
        if let session = activeSpeechSession {
            activeSpeechSession = nil
            detachedSpeechSession = session
        } else if let task = recognitionTask {
            recognitionTask = nil
            detachedRecognitionTask = task
        } else {
            return
        }
        detachedSessionDeadline?.cancel()
        detachedSessionDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.releaseDetachedSession()
        }
    }

    private func releaseDetachedSession() {
        detachedSessionDeadline?.cancel()
        detachedSessionDeadline = nil
        detachedSpeechSession?.cancel()
        detachedSpeechSession = nil
        detachedRecognitionTask?.cancel()
        detachedRecognitionTask = nil
    }

    /// The Action Button flow is press → speak → finish → switch apps →
    /// paste. Without a background assertion, iOS can suspend Velora during
    /// the finishing window right after the user leaves, silently losing the
    /// clipboard write.
    private func beginDeliveryProtection() {
        guard deliveryProtection == .invalid else { return }
        deliveryProtection = UIApplication.shared.beginBackgroundTask(
            withName: "VeloraTranscriptDelivery"
        ) { [weak self] in
            // Called on the main thread moments before suspension. Deliver
            // the already-normalized text NOW — the user is typically in the
            // target app about to paste, and the frozen refinement task
            // cannot beat them there.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deliverPendingFallbackBeforeSuspension()
                self.endDeliveryProtection()
            }
        }
    }

    private func deliverPendingFallbackBeforeSuspension() {
        guard phase == .finishing,
              let pending = refinementSourceText, !pending.isEmpty else { return }
        refinementTask?.cancel()
        refinementTask = nil
        refinementSessionID = nil
        refinementSourceText = nil
        fallbackFinalizedSessionID = nil
        releaseDetachedSession()
        guard let normalized = TranscriptDelivery.deliver(
            pending, to: clipboard, store: store
        ) else { return }
        transcript = normalized
        phase = .copied
        copiedPulse += 1
    }

    private func endDeliveryProtection() {
        guard deliveryProtection != .invalid else { return }
        UIApplication.shared.endBackgroundTask(deliveryProtection)
        deliveryProtection = .invalid
    }

    /// An incoming call or Siri kills the audio session mid-dictation;
    /// without this the UI sits on "Listening" until the hard watchdog cap.
    /// Finish with whatever was heard instead of hanging.
    private func observeAudioInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .began
            else { return }
            Task { @MainActor [weak self] in self?.handleAudioInterruption() }
        }
    }

    private func handleAudioInterruption() {
        guard phase == .listening else { return }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail("Dictation was interrupted before Velora heard any words. Try again.")
        } else {
            stopAndCopy()
        }
    }

    private func stopAudioInput(endingRecognition: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if endingRecognition {
            recognitionRequest?.endAudio()
        }
        audioLevel = Self.idleAudioLevel
    }

    private func tearDownSession(cancelRecognition: Bool) {
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = nil
        finalizationStartedAt = nil
        lastTranscriptUpdateAt = nil
        activeSpeechSession?.cancel()
        activeSpeechSession = nil
        stopAudioInput(endingRecognition: !cancelRecognition)
        if cancelRecognition {
            recognitionTask?.cancel()
        }
        recognitionTask = nil
        recognitionRequest = nil
        recognizer = nil
        activeSessionID = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [])
        try audioSession.setActive(true)
    }

    private func prewarmRefinement() {
        let style = DictationStyle.resolve(
            UserDefaults.standard.string(forKey: VeloraPreferences.dictationStyleKey)
        )
        Task { await TranscriptRefiner.prewarm(for: style) }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestSpeechPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status == .denied || status == .restricted { return false }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    nonisolated static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?.pointee else { return idleAudioLevel }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return idleAudioLevel }

        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(1, max(idleAudioLevel, Double((decibels + 52) / 52)))
    }
}

private enum CaptureError: Error {
    case microphoneUnavailable
}
