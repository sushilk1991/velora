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
    private var inputTapInstalled = false
    private var finalizationStartedAt: Date?
    private var lastTranscriptUpdateAt: Date?

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var audioLevel = 0.08
    private(set) var errorMessage: String?
    private(set) var copiedPulse = 0

    init(store: TranscriptStore) {
        self.store = store
        clipboard = SystemClipboard()
    }

    init(store: TranscriptStore, clipboard: ClipboardWriting) {
        self.store = store
        self.clipboard = clipboard
    }

    func start() async {
        guard phase != .listening, phase != .requestingPermission, phase != .finishing else {
            return
        }

        phase = .requestingPermission
        transcript = ""
        errorMessage = nil
        audioLevel = 0.08

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
                        guard let self, self.activeSessionID == sessionID else { return }
                        self.beginRefinement(with: finalTranscript)
                    },
                    onFailure: { [weak self] in
                        guard let self, self.activeSessionID == sessionID else { return }
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
        tearDownSession(cancelRecognition: true)
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
        transcript = ""
        errorMessage = nil
        audioLevel = 0.08
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

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
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
                guard let self, self.activeSessionID == sessionID else { return }

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
        tearDownSession(cancelRecognition: true)

        guard !basic.isEmpty else {
            fail("Velora did not hear any words. Move closer to the microphone and try again.")
            return
        }

        phase = .finishing
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
        }
    }

    private func fail(_ message: String) {
        refinementTask?.cancel()
        refinementTask = nil
        refinementSessionID = nil
        tearDownSession(cancelRecognition: true)
        errorMessage = message
        phase = .failed
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
        audioLevel = 0.08
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
        guard let channel = buffer.floatChannelData?.pointee else { return 0.08 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0.08 }

        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(1, max(0.08, Double((decibels + 52) / 52)))
    }
}

private enum CaptureError: Error {
    case microphoneUnavailable
}
