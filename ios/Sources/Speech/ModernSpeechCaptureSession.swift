@preconcurrency import AVFoundation
import Foundation
import Speech

@MainActor
protocol ActiveSpeechCaptureSession: AnyObject {
    func finish()
    func cancel()
}

@available(iOS 26.0, *)
@MainActor
final class ModernSpeechCaptureSession: ActiveSpeechCaptureSession {
    enum SessionError: Error {
        case unavailable
        case unsupportedLocale
        case missingAudioFormat
        case microphoneUnavailable
    }

    private let audioEngine = AVAudioEngine()
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let analyzerInputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let audioInputBuilder: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let processingTask: Task<Void, Never>
    private let onTranscript: @MainActor (String) -> Void
    private let onLevel: @MainActor (Double) -> Void
    private let onFinished: @MainActor (String) -> Void
    private let onFailure: @MainActor () -> Void

    private var resultTask: Task<Void, Never>?
    private var finishingTask: Task<Void, Never>?
    private var inputTapInstalled = false
    private var stopped = false
    private var finalizedTranscript: AttributedString = ""
    private var volatileTranscript: AttributedString = ""

    static func start(
        localeIdentifier: String,
        onTranscript: @escaping @MainActor (String) -> Void,
        onLevel: @escaping @MainActor (Double) -> Void,
        onFinished: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) async throws -> ModernSpeechCaptureSession {
        guard SpeechTranscriber.isAvailable else { throw SessionError.unavailable }
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw SessionError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let installation = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await installation.downloadAndInstall()
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw SessionError.missingAudioFormat
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .lingering
            )
        )
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let (analyzerInputs, analyzerInputBuilder) = AsyncStream.makeStream(
            of: AnalyzerInput.self
        )
        let (audioInputs, audioInputBuilder) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self
        )
        let converter = SpeechBufferConverter()
        let processingTask = Task.detached {
            do {
                for await buffer in audioInputs {
                    guard !Task.isCancelled else { break }
                    let converted = try await converter.convert(buffer, to: analyzerFormat)
                    analyzerInputBuilder.yield(AnalyzerInput(buffer: converted))
                }
            } catch {
                // The result stream reports the failed analysis. Finishing the
                // input here prevents the analyzer from waiting indefinitely.
            }
            analyzerInputBuilder.finish()
        }

        try await analyzer.start(inputSequence: analyzerInputs)
        let session = ModernSpeechCaptureSession(
            analyzer: analyzer,
            transcriber: transcriber,
            analyzerInputBuilder: analyzerInputBuilder,
            audioInputBuilder: audioInputBuilder,
            processingTask: processingTask,
            onTranscript: onTranscript,
            onLevel: onLevel,
            onFinished: onFinished,
            onFailure: onFailure
        )
        session.observeResults()
        do {
            try session.startAudioEngine()
        } catch {
            session.cancel()
            throw error
        }
        return session
    }

    private init(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        analyzerInputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        audioInputBuilder: AsyncStream<AVAudioPCMBuffer>.Continuation,
        processingTask: Task<Void, Never>,
        onTranscript: @escaping @MainActor (String) -> Void,
        onLevel: @escaping @MainActor (Double) -> Void,
        onFinished: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.analyzerInputBuilder = analyzerInputBuilder
        self.audioInputBuilder = audioInputBuilder
        self.processingTask = processingTask
        self.onTranscript = onTranscript
        self.onLevel = onLevel
        self.onFinished = onFinished
        self.onFailure = onFailure
    }

    func finish() {
        guard !stopped else { return }
        stopped = true
        stopAudioInput()
        audioInputBuilder.finish()

        finishingTask = Task { [weak self] in
            guard let self else { return }
            await processingTask.value
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                // Finishing the analyzer closes its module result streams.
                // Consume every already-published final result before delivery.
                await resultTask?.value
                let finalText = String((finalizedTranscript + volatileTranscript).characters)
                onFinished(finalText)
            } catch {
                onFailure()
            }
        }
    }

    func cancel() {
        if !stopped {
            stopped = true
            stopAudioInput()
            audioInputBuilder.finish()
        }
        analyzerInputBuilder.finish()
        processingTask.cancel()
        resultTask?.cancel()
        finishingTask?.cancel()
        Task { await analyzer.cancelAndFinishNow() }
    }

    private func startAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SessionError.microphoneUnavailable
        }

        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) {
            [audioInputBuilder, onLevel] buffer, _ in
            audioInputBuilder.yield(buffer)
            let level = SpeechCaptureService.normalizedLevel(from: buffer)
            Task { @MainActor in onLevel(level) }
        }
        inputTapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopAudioInput() {
        if audioEngine.isRunning { audioEngine.stop() }
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        onLevel(0.08)
    }

    private func observeResults() {
        resultTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard let self, !Task.isCancelled else { return }
                    if result.isFinal {
                        finalizedTranscript += result.text
                        volatileTranscript = ""
                    } else {
                        volatileTranscript = result.text
                    }
                    onTranscript(String((finalizedTranscript + volatileTranscript).characters))
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !stopped else { return }
                onFailure()
            }
        }
    }
}

@available(iOS 26.0, *)
private actor SpeechBufferConverter {
    enum ConversionError: Error {
        case unavailable
        case bufferAllocation
        case failed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.format != format else { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConversionError.unavailable }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: capacity
        ) else {
            throw ConversionError.bufferAllocation
        }

        var conversionError: NSError?
        var supplied = false
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            defer { supplied = true }
            inputStatus.pointee = supplied ? .noDataNow : .haveData
            return supplied ? nil : buffer
        }
        guard status != .error else { throw ConversionError.failed(conversionError) }
        return output
    }
}
