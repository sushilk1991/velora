import AudioToolbox
import CoreAudio
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
    private var audioFile: ExtAudioFileRef?
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

            var file: ExtAudioFileRef?
            var format = streamFormat
            let fileStatus = ExtAudioFileCreateWithURL(
                url as CFURL, kAudioFileCAFType, &format, nil,
                AudioFileFlags.eraseFile.rawValue, &file)
            guard fileStatus == noErr, let file else {
                throw CaptureError.file(fileStatus)
            }
            audioFile = file
            // Prime the async writer away from the realtime callback.
            let primeStatus = ExtAudioFileWriteAsync(file, 0, nil)
            guard primeStatus == noErr else { throw CaptureError.file(primeStatus) }

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
        let hadFrames = capturedFrames > 0
        healthLock.unlock()

        heartbeat?.invalidate()
        heartbeat = nil
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if let audioFile { ExtAudioFileDispose(audioFile) }
        audioFile = nil
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

    /// Runs on the aggregate device's realtime IO thread. ExtAudioFile's async
    /// writer is primed before IO starts; only the failure path dispatches.
    private func receive(_ inputData: UnsafePointer<AudioBufferList>) {
        guard inputData.pointee.mNumberBuffers > 0, let audioFile else { return }
        let first = inputData.pointee.mBuffers
        let frames = SystemAudioFrameMath.frames(
            byteCount: first.mDataByteSize,
            bytesPerFrame: streamFormat.mBytesPerFrame)
        guard frames > 0 else { return }
        let status = ExtAudioFileWriteAsync(audioFile, frames, inputData)
        guard status == noErr else {
            reportFailure("computer-audio file write failed (\(status))")
            return
        }

        healthLock.lock()
        capturedFrames += Int(frames)
        lastBufferAt = Date()
        let stopping = stopping
        healthLock.unlock()
        if !stopping { onFrames?(Int(frames)) }
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
