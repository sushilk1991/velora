import AudioToolbox
import AVFoundation
import CoreAudio
import Darwin
import Foundation

/// Meeting capture must never obtain computer audio by opening a display-wide
/// screen stream. Core Audio process taps are audio-only; on older macOS
/// versions the feature is unavailable and the coordinator can offer an honest
/// mic-only fallback.
enum MeetingSystemAudioPolicy {
    enum Backend: Equatable {
        case coreAudioTap
        case unavailable
    }

    static func backend(for version: OperatingSystemVersion) -> Backend {
        if version.majorVersion > 14
            || (version.majorVersion == 14 && version.minorVersion >= 2) {
            return .coreAudioTap
        }
        return .unavailable
    }

    static func relativePath(meetingID: String) -> String {
        "\(meetingID)/them.caf"
    }
}

enum SystemAudioFrameMath {
    static func frames(byteCount: UInt32, bytesPerFrame: UInt32) -> UInt32 {
        guard bytesPerFrame > 0 else { return 0 }
        return byteCount / bytesPerFrame
    }
}

/// Owns the computer-audio file off Core Audio's realtime callback.
///
/// `ExtAudioFileWriteAsync` has a small internal ring. Under ordinary disk
/// pressure it returned `kExtAudioFileError_AsyncWriteBufferOverflow` and the
/// rest of a meeting silently became mic-only. Copying into a bounded pool
/// lets the callback return immediately; one serial user-initiated queue does
/// the synchronous file writes in order and `finish()` drains them before the
/// CAF is closed.
@available(macOS 14.2, *)
final class SystemAudioFileWriter {
    enum WriterError: LocalizedError {
        case unsupportedFormat
        case couldNotCreateBuffer

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "computer-audio tap has an unsupported PCM layout"
            case .couldNotCreateBuffer:
                return "computer-audio buffer could not be allocated"
            }
        }
    }

    private final class Slot {
        let buffer: AVAudioPCMBuffer
        var byteCount = 0
        var frames: UInt32 = 0

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private enum FailureReason {
        case overrun
        case unsupportedFormat
        case fileWrite(String)
    }

    private let format: AVAudioFormat
    private let queue = DispatchQueue(
        label: "com.velora.meetings.system-audio-writer",
        qos: .userInitiated)
    private let workAvailable = DispatchSemaphore(value: 0)
    private let workerFinished = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private let maxPendingBytes: Int
    private let onWritten: (UInt32) -> Void
    private let onFailure: (String) -> Void
    private var file: AVAudioFile?
    private var slots: [Slot] = []
    private var freeIndices: [Int] = []
    private var pendingIndices: [Int] = []
    private var pendingBytes = 0
    private var accepting = true
    private var finishing = false
    private var failureReason: FailureReason?
    private var failureReported = false
    // The realtime callback cannot wait for `stateLock`. Use a one-way,
    // lock-free latch so teardown cannot erase a contended callback failure.
    private var callbackOverrun: Int32 = 0

    init(
        url: URL,
        format: AVAudioFormat,
        maxPendingBuffers: Int = 64,
        maxPendingBytes: Int = 32 * 1_024 * 1_024,
        bufferFrameCapacity: AVAudioFrameCount = 32_768,
        onWritten: @escaping (UInt32) -> Void = { _ in },
        onFailure: @escaping (String) -> Void = { _ in }
    ) throws {
        let stream = format.streamDescription.pointee
        // Process taps can expose valid interleaved LPCM that AVAudioFormat
        // does not classify as its narrow "standard" (deinterleaved Float32)
        // layout. AVAudioPCMBuffer and AVAudioFile both support that PCM, so
        // validate the actual requirements instead of rejecting live taps.
        guard stream.mFormatID == kAudioFormatLinearPCM,
              stream.mBytesPerFrame > 0, format.channelCount > 0,
              format.sampleRate > 0, maxPendingBuffers > 0,
              maxPendingBytes > 0, bufferFrameCapacity > 0 else {
            throw WriterError.unsupportedFormat
        }
        self.format = format
        self.maxPendingBytes = maxPendingBytes
        self.onWritten = onWritten
        self.onFailure = onFailure
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        slots.reserveCapacity(maxPendingBuffers)
        freeIndices.reserveCapacity(maxPendingBuffers)
        pendingIndices.reserveCapacity(maxPendingBuffers)
        for _ in 0..<maxPendingBuffers {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: bufferFrameCapacity)
            else { throw WriterError.couldNotCreateBuffer }
            slots.append(Slot(buffer: buffer))
        }
        guard slots.reduce(0, { $0 + storageBytes(for: $1.buffer) })
                <= maxPendingBytes else {
            throw WriterError.couldNotCreateBuffer
        }
        freeIndices.append(contentsOf: slots.indices)
        // One long-lived worker replaces a DispatchQueue.async allocation for
        // every Core Audio callback. The realtime side only copies into a
        // preallocated slot and signals this semaphore.
        queue.async { [self] in workerLoop() }
    }

    /// Deep-copies one callback buffer and schedules its ordered disk write.
    /// Returns false after the first terminal writer failure.
    @discardableResult
    func enqueue(
        _ inputData: UnsafePointer<AudioBufferList>,
        frames: UInt32
    ) -> Bool {
        guard frames > 0 else { return true }
        let capacity = AVAudioFrameCount(frames)
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        var inputByteCount = 0
        for input in source {
            inputByteCount += Int(input.mDataByteSize)
        }

        // The Core Audio callback must never wait for the disk queue. The pool
        // is fully allocated at start; a contended/empty pool fails closed and
        // stops the tap rather than blocking or allocating on the IO thread.
        guard stateLock.try() else {
            OSAtomicCompareAndSwap32Barrier(0, 1, &callbackOverrun)
            workAvailable.signal()
            return false
        }
        guard accepting, !freeIndices.isEmpty,
              inputByteCount <= maxPendingBytes - pendingBytes else {
            if accepting { requestFailureLocked(.overrun) }
            stateLock.unlock()
            workAvailable.signal()
            return false
        }
        let slotIndex = freeIndices.removeLast()
        let slot = slots[slotIndex]
        let buffer = slot.buffer
        guard buffer.frameCapacity >= capacity else {
            freeIndices.append(slotIndex)
            requestFailureLocked(.unsupportedFormat)
            stateLock.unlock()
            workAvailable.signal()
            return false
        }

        buffer.frameLength = capacity
        let destination = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList)
        guard source.count == destination.count else {
            freeIndices.append(slotIndex)
            requestFailureLocked(.unsupportedFormat)
            stateLock.unlock()
            workAvailable.signal()
            return false
        }
        for bufferIndex in source.indices {
            let input = source[bufferIndex]
            let byteCount = Int(input.mDataByteSize)
            guard byteCount <= Int(destination[bufferIndex].mDataByteSize),
                  let sourceData = input.mData,
                  let destinationData = destination[bufferIndex].mData else {
                freeIndices.append(slotIndex)
                requestFailureLocked(.unsupportedFormat)
                stateLock.unlock()
                workAvailable.signal()
                return false
            }
            memcpy(destinationData, sourceData, byteCount)
            destination[bufferIndex].mDataByteSize = input.mDataByteSize
        }
        slot.byteCount = inputByteCount
        slot.frames = frames
        pendingBytes += inputByteCount
        pendingIndices.append(slotIndex)
        stateLock.unlock()
        workAvailable.signal()
        return true
    }

    /// Stops accepting callbacks, drains every accepted buffer, then closes
    /// the CAF so its pending header/data are durable before capture returns.
    func finish() {
        stateLock.lock()
        accepting = false
        finishing = true
        stateLock.unlock()
        workAvailable.signal()
        workerFinished.wait()
    }

    private func storageBytes(for buffer: AVAudioPCMBuffer) -> Int {
        let planes = format.isInterleaved ? 1 : Int(format.channelCount)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        return Int(buffer.frameCapacity) * max(1, bytesPerFrame) * max(1, planes)
    }

    private func requestFailureLocked(_ reason: FailureReason) {
        if failureReason == nil { failureReason = reason }
        accepting = false
    }

    private func consumeFailureLocked() -> FailureReason? {
        guard !failureReported, let failureReason else { return nil }
        failureReported = true
        return failureReason
    }

    private func failureMessage(for reason: FailureReason) -> String {
        switch reason {
        case .overrun:
            return "computer-audio disk writer could not keep up"
        case .unsupportedFormat:
            return "computer-audio tap has an unsupported PCM layout"
        case .fileWrite(let message):
            return "computer-audio file write failed (\(message))"
        }
    }

    private func workerLoop() {
        while true {
            workAvailable.wait()
            var slotIndex: Int?
            var failure: FailureReason?
            var shouldFinish = false

            stateLock.lock()
            if OSAtomicCompareAndSwap32Barrier(1, 0, &callbackOverrun) {
                requestFailureLocked(.overrun)
            }
            if !pendingIndices.isEmpty {
                slotIndex = pendingIndices.removeFirst()
            } else {
                failure = consumeFailureLocked()
                shouldFinish = finishing
            }
            stateLock.unlock()

            if let failure { onFailure(failureMessage(for: failure)) }
            guard let slotIndex else {
                if shouldFinish { break }
                continue
            }

            let slot = slots[slotIndex]
            do {
                guard let file else { throw WriterError.unsupportedFormat }
                try file.write(from: slot.buffer)
                onWritten(slot.frames)
            } catch {
                stateLock.lock()
                requestFailureLocked(.fileWrite(error.localizedDescription))
                failure = consumeFailureLocked()
                stateLock.unlock()
                if let failure { onFailure(failureMessage(for: failure)) }
                workAvailable.signal()
            }

            stateLock.lock()
            pendingBytes = max(0, pendingBytes - slot.byteCount)
            slot.byteCount = 0
            slot.frames = 0
            freeIndices.append(slotIndex)
            stateLock.unlock()
        }
        file = nil
        workerFinished.signal()
    }

    /// Deterministically exercises the realtime lock-contention path from the
    /// in-process selftest without exposing production state mutation.
    func withStateLockForSelftest(_ body: () -> Void) {
        stateLock.lock()
        body()
        stateLock.unlock()
    }
}

/// Audio-only computer-output recorder based directly on Apple's Core Audio
/// process-tap sample. The private tap is exposed as an input of a private
/// aggregate device and consumed with AudioDevice IO. AVAudioEngine is not
/// used: it can silently bind the aggregate to the AirPods/default-device
/// graph and deliver no input buffers.
@available(macOS 14.2, *)
final class CoreAudioSystemAudioCapture {
    enum CaptureError: LocalizedError {
        case tap(OSStatus)
        case tapUID(OSStatus)
        case tapFormat(OSStatus)
        case aggregate(OSStatus)
        case file(OSStatus)
        case ioProc(OSStatus)
        case deviceStart(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tap(let status):
                return "system-audio permission or tap creation failed (\(status))"
            case .tapUID(let status):
                return "system-audio tap could not be identified (\(status))"
            case .tapFormat(let status):
                return "system-audio tap has no usable PCM format (\(status))"
            case .aggregate(let status):
                return "system-audio input device could not be created (\(status))"
            case .file(let status):
                return "system-audio file could not be created (\(status))"
            case .ioProc(let status):
                return "system-audio input callback could not be installed (\(status))"
            case .deviceStart(let status):
                return "system-audio input could not start (\(status))"
            }
        }
    }

    var onFrames: ((Int) -> Void)?
    var onFailure: ((String) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var fileWriter: SystemAudioFileWriter?
    private var streamFormat = AudioStreamBasicDescription()
    private var heartbeat: Timer?
    private let healthLock = NSLock()
    private var capturedFrames = 0
    private var lastBufferAt: Date?
    private var failureReported = false
    private var stopping = false

    var hasCapturedFrames: Bool {
        healthLock.lock(); defer { healthLock.unlock() }
        return capturedFrames > 0
    }

    func start(to url: URL) throws {
        _ = stop()
        resetHealth()

        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: Self.currentProcessAudioObjects())
        description.name = "Velora Meeting Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr else { throw CaptureError.tap(tapStatus) }
        tapID = newTap

        do {
            let tapUID = try Self.stringProperty(
                object: newTap, selector: kAudioTapPropertyUID)
            streamFormat = try Self.tapFormat(object: newTap)
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Velora Meeting Audio",
                kAudioAggregateDeviceUIDKey: "com.sushil.velora.meeting.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            var newAggregate = AudioObjectID(kAudioObjectUnknown)
            let aggregateStatus = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary, &newAggregate)
            guard aggregateStatus == noErr else {
                throw CaptureError.aggregate(aggregateStatus)
            }
            aggregateID = newAggregate

            var format = streamFormat
            guard let audioFormat = AVAudioFormat(streamDescription: &format) else {
                throw CaptureError.tapFormat(kAudio_ParamError)
            }
            fileWriter = try SystemAudioFileWriter(
                url: url,
                format: audioFormat,
                onWritten: { [weak self] written in
                    guard let self else { return }
                    self.healthLock.lock()
                    self.capturedFrames += Int(written)
                    self.lastBufferAt = Date()
                    let stopping = self.stopping
                    self.healthLock.unlock()
                    if !stopping { self.onFrames?(Int(written)) }
                },
                onFailure: { [weak self] message in self?.reportFailure(message) })

            var proc: AudioDeviceIOProcID?
            let procStatus = AudioDeviceCreateIOProcIDWithBlock(
                &proc, newAggregate, nil
            ) { [weak self] _, inputData, _, _, _ in
                self?.receive(inputData)
            }
            guard procStatus == noErr, let proc else {
                throw CaptureError.ioProc(procStatus)
            }
            ioProcID = proc
            let startStatus = AudioDeviceStart(newAggregate, proc)
            guard startStatus == noErr else {
                throw CaptureError.deviceStart(startStatus)
            }

            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                self?.checkHeartbeat()
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            _ = stop()
            throw error
        }
    }

    @discardableResult
    func stop() -> Bool {
        healthLock.lock()
        stopping = true
        healthLock.unlock()

        heartbeat?.invalidate()
        heartbeat = nil
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        fileWriter?.finish()
        fileWriter = nil
        // `finish()` can complete buffers accepted just before AudioDeviceStop.
        // Read the proof after that drain or a short valid capture can be
        // misclassified as empty and deleted.
        healthLock.lock()
        let hadFrames = capturedFrames > 0
        healthLock.unlock()
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        streamFormat = AudioStreamBasicDescription()
        return hadFrames
    }

    /// Runs on the aggregate device's realtime IO thread. The writer copies
    /// the callback buffers before returning and performs file I/O elsewhere.
    private func receive(_ inputData: UnsafePointer<AudioBufferList>) {
        guard inputData.pointee.mNumberBuffers > 0, let fileWriter else { return }
        let first = inputData.pointee.mBuffers
        let frames = SystemAudioFrameMath.frames(
            byteCount: first.mDataByteSize,
            bytesPerFrame: streamFormat.mBytesPerFrame)
        guard frames > 0 else { return }
        fileWriter.enqueue(inputData, frames: frames)
    }

    private func resetHealth() {
        healthLock.lock()
        capturedFrames = 0
        lastBufferAt = nil
        failureReported = false
        stopping = false
        healthLock.unlock()
    }

    private func checkHeartbeat() {
        healthLock.lock()
        let last = lastBufferAt
        let hasStarted = capturedFrames > 0
        let stopping = stopping
        healthLock.unlock()
        guard !stopping, hasStarted, let last,
              Date().timeIntervalSince(last) > 5 else { return }
        reportFailure("computer-audio buffers stopped arriving")
    }

    private func reportFailure(_ message: String) {
        healthLock.lock()
        let shouldReport = !stopping && !failureReported
        if shouldReport { failureReported = true }
        healthLock.unlock()
        guard shouldReport else { return }
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
    }

    private static func tapFormat(object: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            object, &address, 0, nil, &size, &format)
        guard status == noErr,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mSampleRate > 0,
              format.mChannelsPerFrame > 0,
              format.mBytesPerFrame > 0 else {
            throw CaptureError.tapFormat(status)
        }
        return format
    }

    private static func currentProcessAudioObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        let pid = ProcessInfo.processInfo.processIdentifier
        return objects.filter { object in
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var value: pid_t = 0
            var valueSize = UInt32(MemoryLayout<pid_t>.size)
            return AudioObjectGetPropertyData(
                object, &pidAddress, 0, nil, &valueSize, &value) == noErr && value == pid
        }
    }

    private static func stringProperty(
        object: AudioObjectID, selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { throw CaptureError.tapUID(status) }
        return value as String
    }
}
