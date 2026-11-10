import AVFoundation
import Foundation

/// Immutable, closed PCM. Times refer to this track's actual sample cursor;
/// the preview never derives word timing from text or opens a growing track.
struct MeetingLiveWindow: Codable, Equatable, Identifiable {
    let meetingID: String
    let speakerValue: String
    let startFrame: Int64
    let frameCount: Int64
    let sampleRate: Double
    var id: String { "\(speakerValue)-\(startFrame)" }
    var speaker: MeetingSpeaker { speakerValue == "me" ? .me : .them }
    var startMs: Int { Int((Double(startFrame) / sampleRate * 1_000).rounded()) }
    var endMs: Int { Int((Double(startFrame + frameCount) / sampleRate * 1_000).rounded()) }
    func audioURL(in directory: URL) -> URL { directory.appendingPathComponent(id + ".caf") }
}

/// One instance per track, confined to that track's non-realtime writer
/// queue. Consumers only read immutable descriptor files and retire closed
/// windows. Four windows per track and 16 MiB PCM per window bound disk use.
/// If inference falls behind, only preview audio is skipped; the main CAF and
/// the sample cursor continue. Each seal is a crash-safe checkpoint.
final class MeetingLiveWindowWriter {
    private struct Cursor: Codable { let totalFrames: Int64; let skippedFrames: Int64 }
    private let directory: URL
    private let meetingID: String
    private let speaker: MeetingSpeaker
    private let windowSeconds: Double
    private let maxPendingWindows: Int
    private let maxWindowBytes = 16 * 1_024 * 1_024
    private var file: AVAudioFile?
    private var openURL: URL?
    private var windowStart: Int64 = 0
    private var windowFrames: Int64 = 0
    private var capacity: Int64 = 0
    private var sampleRate: Double = 0
    private var disabled = false
    private(set) var totalFrames: Int64 = 0
    private(set) var skippedFrames: Int64 = 0
    var onSealed: (() -> Void)?

    init(directory: URL, meetingID: String, speaker: MeetingSpeaker,
         windowSeconds: Double = 30, maxPendingWindows: Int = 4) {
        self.directory = directory
        self.meetingID = meetingID
        self.speaker = speaker
        self.windowSeconds = max(0.2, min(30, windowSeconds))
        self.maxPendingWindows = max(1, min(4, maxPendingWindows))
        guard Self.safeDirectory(directory, create: true) else { disabled = true; return }
        if let data = Self.readData(at: cursorURL, maxBytes: 1_024),
           let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
           cursor.totalFrames >= 0, cursor.totalFrames < Int64.max / 2_000,
           cursor.skippedFrames >= 0, cursor.skippedFrames <= cursor.totalFrames {
            totalFrames = cursor.totalFrames
            skippedFrames = cursor.skippedFrames
        }
        // An open file was never published. Its cursor was not committed,
        // and it must never be mistaken for a sealed job after a crash.
        for url in (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent.hasPrefix(speaker.rawValue + "-")
                && url.pathExtension == "caf"
                && (url.lastPathComponent.hasSuffix(".open.caf")
                    || !FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("json").path)) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var cursorURL: URL { directory.appendingPathComponent(speaker.rawValue + "-cursor.json") }

    func append(_ buffer: AVAudioPCMBuffer) {
        let frames = Int64(buffer.frameLength)
        guard frames > 0 else { return }
        guard !disabled else { totalFrames += frames; skippedFrames += frames; return }
        var consumed: Int64 = 0
        do {
            while consumed < frames {
                if file == nil {
                    guard Self.safeDirectory(directory, create: false) else { throw CocoaError(.fileNoSuchFile) }
                    let pending = ((try? FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: nil)) ?? []).filter {
                        $0.lastPathComponent.hasPrefix(speaker.rawValue + "-") && $0.pathExtension == "caf"
                    }.count
                    if pending >= maxPendingWindows {
                        let skipped = frames - consumed
                        totalFrames += skipped; skippedFrames += skipped
                        checkpointCursor()
                        return
                    }
                    let bytesPerFrame = max(1, Int(buffer.format.streamDescription.pointee.mBytesPerFrame))
                        * (buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount))
                    capacity = min(Int64(buffer.format.sampleRate * windowSeconds),
                                   Int64(maxWindowBytes / bytesPerFrame))
                    guard capacity > 0, buffer.format.sampleRate.isFinite,
                          buffer.format.sampleRate > 0 else { throw CocoaError(.fileWriteUnknown) }
                    windowStart = totalFrames; windowFrames = 0
                    sampleRate = buffer.format.sampleRate
                    let url = directory.appendingPathComponent("\(speaker.rawValue)-\(windowStart).open.caf")
                    guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
                    openURL = url
                    file = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                        commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
                let count = min(frames - consumed, capacity - windowFrames)
                guard let slice = Self.slice(buffer, offset: Int(consumed), count: Int(count)) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try file?.write(from: slice)
                totalFrames += count; windowFrames += count; consumed += count
                if windowFrames == capacity { try seal() }
            }
        } catch {
            // Preview faults never become a capture fault.
            disabled = true
            file = nil
            if let openURL { try? FileManager.default.removeItem(at: openURL) }
            openURL = nil
            let skipped = frames - consumed
            totalFrames += skipped; skippedFrames += skipped
            checkpointCursor()
            onSealed?()
        }
    }

    func finish() {
        if file != nil {
            do { try seal() } catch {
                file = nil
                if let openURL { try? FileManager.default.removeItem(at: openURL) }
                openURL = nil
            }
        }
        checkpointCursor()
    }

    private func seal() throws {
        guard let openURL, windowFrames > 0 else { return }
        file = nil // closes and flushes CAF before atomic publication
        let window = MeetingLiveWindow(meetingID: meetingID, speakerValue: speaker.rawValue,
            startFrame: windowStart, frameCount: windowFrames, sampleRate: sampleRate)
        let target = window.audioURL(in: directory)
        try FileManager.default.moveItem(at: openURL, to: target)
        // Commit the cursor before publishing work. A crash between these
        // writes can omit a preview, but cannot decode the same samples twice.
        try Self.write(Cursor(totalFrames: totalFrames, skippedFrames: skippedFrames), to: cursorURL)
        try Self.write(window, to: directory.appendingPathComponent(window.id + ".json"))
        self.openURL = nil; windowFrames = 0
        onSealed?()
    }

    private func checkpointCursor() {
        try? Self.write(Cursor(totalFrames: totalFrames, skippedFrames: skippedFrames), to: cursorURL)
    }

    static func pending(in directory: URL) -> [MeetingLiveWindow] {
        guard safeDirectory(directory, create: false) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix("-cursor.json") }
            .prefix(16).compactMap { url -> MeetingLiveWindow? in
                guard let data = readData(at: url, maxBytes: 2_048),
                      let window = try? JSONDecoder().decode(MeetingLiveWindow.self, from: data),
                      UUID(uuidString: window.meetingID) != nil,
                      ["me", "them"].contains(window.speakerValue), window.startFrame >= 0,
                      window.startFrame < Int64.max / 2_000,
                      window.frameCount > 0, window.frameCount < 100_000_000,
                      window.sampleRate.isFinite, window.sampleRate >= 1_000, window.sampleRate <= 768_000,
                      Double(window.frameCount) / window.sampleRate <= 30.001,
                      url.lastPathComponent == window.id + ".json", safeFile(window.audioURL(in: directory))
                else { return nil }
                return window
            }.sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
    }

    static func retire(_ window: MeetingLiveWindow, in directory: URL) {
        guard safeDirectory(directory, create: false) else { return }
        // The result checkpoint is committed by the consumer before this.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(window.id + ".json"))
        try? FileManager.default.removeItem(at: window.audioURL(in: directory))
    }

    static func readData(at url: URL, maxBytes: Int) -> Data? {
        guard safeFile(url),
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.intValue <= maxBytes,
              let data = try? Data(contentsOf: url), data.count <= maxBytes else { return nil }
        return data
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        guard safeDirectory(url.deletingLastPathComponent(), create: false),
              !FileManager.default.fileExists(atPath: url.path) || safeFile(url)
        else { throw CocoaError(.fileWriteNoPermission) }
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func safeDirectory(_ directory: URL, create: Bool) -> Bool {
        let path = directory.standardizedFileURL
        // No symlink in the owner directory or any parent may redirect I/O.
        guard path.resolvingSymlinksInPath().path == path.path else { return false }
        if create { MeetingStore.ensurePrivateDirectory(path) }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func safeFile(_ url: URL) -> Bool {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 17 * 1_024 * 1_024
        else { return false }
        return true
    }

    private static func slice(_ source: AVAudioPCMBuffer, offset: Int, count: Int) -> AVAudioPCMBuffer? {
        guard count > 0, let result = AVAudioPCMBuffer(pcmFormat: source.format,
            frameCapacity: AVAudioFrameCount(count)) else { return nil }
        result.frameLength = AVAudioFrameCount(count)
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let output = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        let stride = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        guard input.count == output.count, stride > 0 else { return nil }
        for index in input.indices {
            guard let from = input[index].mData, let to = output[index].mData,
                  (offset + count) * stride <= Int(input[index].mDataByteSize) else { return nil }
            memcpy(to, from.advanced(by: offset * stride), count * stride)
        }
        return result
    }
}
