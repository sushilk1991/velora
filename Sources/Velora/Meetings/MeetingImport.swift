import AVFoundation
import Combine
import CoreMedia
import Foundation

enum MeetingImportError: LocalizedError {
    case invalidSource, noAudio, cancelled, saveFailed
    case conversion(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource: return "Choose a supported audio or video recording."
        case .noAudio: return "This file has no readable audio track."
        case .cancelled: return "Import cancelled."
        case .saveFailed: return "The recording could not be saved in the meeting library."
        case .conversion(let detail): return "The recording could not be imported. \(detail)"
        }
    }
}

/// One import owns its cancellation flag and private staging directory. UI
/// navigation cancels conversion; it never leaves a resumable half-file row.
final class MeetingImportOperation {
    private let lock = NSLock()
    private var stopped = false
    private var cancelReading: (() -> Void)?
    func cancel() {
        lock.lock()
        stopped = true
        let action = cancelReading
        lock.unlock()
        action?()
    }
    func onCancellation(_ action: (() -> Void)?) {
        lock.lock()
        cancelReading = action
        let alreadyStopped = stopped
        lock.unlock()
        if alreadyStopped { action?() }
    }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
}

final class MeetingRecordingImporter: ObservableObject {
    @Published private(set) var importing = false
    @Published private(set) var fraction = 0.0
    @Published private(set) var error: String?
    private let store: MeetingStore
    private var operation: MeetingImportOperation?

    init(store: MeetingStore) { self.store = store }
    deinit { operation?.cancel() }

    func cancel() {
        operation?.cancel()
        // The background job owns cleanup and clears `importing` when it has
        // actually stopped; a second import cannot race its directory work.
    }

    func start(_ source: URL, completion: @escaping (String) -> Void) {
        guard !importing else { return }
        guard FileTranscriptionTypePolicy.supports(url: source) else {
            error = MeetingImportError.invalidSource.localizedDescription
            return
        }
        importing = true
        error = nil
        fraction = 0
        let operation = MeetingImportOperation()
        self.operation = operation
        let store = store
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                try Self.importRecording(source, into: store, operation: operation) { value in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.operation === operation else { return }
                        self.fraction = value
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                // An activated recording is owned by this operation until its
                // completion is accepted. A late Cancel removes only that new row.
                if operation.isCancelled, case .success(let record) = result {
                    _ = store.delete(meetingID: record.id)
                }
                guard let self, self.operation === operation else { return }
                self.operation = nil
                self.importing = false
                switch result {
                case .success(let record) where !operation.isCancelled:
                    self.fraction = 1
                    NotificationCenter.default.post(name: .veloraMeetingsChanged, object: nil)
                    completion(record.id)
                case .success:
                    self.error = nil
                case .failure(let failure):
                    self.error = operation.isCancelled ? nil : failure.localizedDescription
                }
            }
        }
    }

    /// A bounded PCM stream, not a full recording in memory. Conversion also
    /// makes video imports directly playable through the meeting audio UI.
    static func importRecording(
        _ source: URL, into store: MeetingStore, operation: MeetingImportOperation,
        progress: (Double) -> Void = { _ in }
    ) throws -> MeetingRecord {
        guard FileTranscriptionTypePolicy.supports(url: source) else { throw MeetingImportError.invalidSource }
        if operation.isCancelled { throw MeetingImportError.cancelled }
        let id = UUID().uuidString
        let directory = try store.prepareImportDirectory(id: id)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("them.caf")
        let durationMs = try convert(source, to: destination, operation: operation, progress: progress)
        if operation.isCancelled { throw MeetingImportError.cancelled }
        let title = source.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try store.activateImport(id: id, title: title.isEmpty ? "Imported recording" : title,
            durationMs: durationMs, cancelled: { operation.isCancelled })
    }

    private static func convert(
        _ source: URL, to destination: URL, operation: MeetingImportOperation,
        progress: (Double) -> Void
    ) throws -> Int {
        let asset = AVURLAsset(url: source)
        guard !asset.hasProtectedContent, let track = asset.tracks(withMediaType: .audio).first else {
            throw MeetingImportError.noAudio
        }
        let reader = try AVAssetReader(asset: asset)
        operation.onCancellation { reader.cancelReading() }
        defer { operation.onCancellation(nil) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MeetingImportError.noAudio }
        reader.add(output)
        guard reader.startReading() else {
            throw MeetingImportError.conversion(reader.error?.localizedDescription ?? "Audio decoding did not start.")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 16_000, channels: 1, interleaved: true) else { throw MeetingImportError.noAudio }
        // Releasing the writer finalizes the CAF header before directory activation.
        var frames: Int64 = 0
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: destination, settings: format.settings,
                commonFormat: .pcmFormatInt16, interleaved: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let total = asset.duration.seconds
            var lastProgress = 0.0
            while let sample = output.copyNextSampleBuffer() {
                if operation.isCancelled { reader.cancelReading(); throw MeetingImportError.cancelled }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let bytes = CMBlockBufferGetDataLength(block)
                let count = CMSampleBufferGetNumSamples(sample)
                guard count > 0, count <= Int(UInt32.max), bytes == count * 2,
                      let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count)),
                      let address = pcm.int16ChannelData?.pointee else {
                    throw MeetingImportError.conversion("The decoded audio format was not supported.")
                }
                guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes,
                    destination: address) == kCMBlockBufferNoErr else {
                    throw MeetingImportError.conversion("An audio block could not be read.")
                }
                pcm.frameLength = UInt32(count)
                try file.write(from: pcm)
                frames += Int64(count)
                if total.isFinite, total > 0 {
                    let value = min(0.99, Double(frames) / (16_000 * total))
                    if value - lastProgress >= 0.01 { lastProgress = value; progress(value) }
                }
            }
        }
        if operation.isCancelled { throw MeetingImportError.cancelled }
        guard reader.status == .completed, frames > 0 else {
            throw MeetingImportError.conversion(reader.error?.localizedDescription ?? "No audio samples could be decoded.")
        }
        return Int(min(Int64(Int.max), frames / 16))
    }
}

enum MeetingTranscriptMatch {
    static func first(in segments: [MeetingSegment], query: String) -> MeetingSegment? {
        func words(_ text: String) -> [String] {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let terms = Array(words(query).prefix(12))
        guard !terms.isEmpty else { return nil }
        return segments.sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }.first { segment in
            let available = Set(words(segment.text))
            return terms.allSatisfy { available.contains($0) }
        }
    }
}
