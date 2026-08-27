import Darwin
import Foundation

/// A bounded target-only focus lease. It materializes an off-Space window's
/// AX tree without activating, raising, or moving that window.
enum OffSpaceAXCleanup: Equatable {
    case defocus
    case preserveUserFocus
    case cancel
}

enum OffSpaceAXPrimeResult: Equatable {
    case observed
    case focusFailed
    case observationFailed
    case cleanupFailed
    case userEnteredTarget
    case cancelled
}

protocol OffSpaceAXPriming {
    func withPrime(
        pid: Int, windowID: Int, observe: () -> Bool,
        cleanup: () -> OffSpaceAXCleanup
    ) -> OffSpaceAXPrimeResult
}

struct OffSpaceAXPrimer: OffSpaceAXPriming {
    static let recordBytes = 0xF8

    private static let skyLightPath =
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let psnBytes = 8
    private static let sizeOffset = 0x04
    private static let typeOffset = 0x08
    private static let windowOffset = 0x3C
    private static let windowBytes = 4
    private static let focusOffset = 0x8A
    private static let focusRecordType: UInt8 = 0x0D
    private static let focusMarker: UInt8 = 0x01
    private static let defocusMarker: UInt8 = 0x02
    private static let supportedOSMajor = 26

    typealias ResolvePSN = (pid_t, UnsafeMutableRawPointer) -> Int32
    typealias PostRecord = (
        UnsafeRawPointer, UnsafePointer<UInt8>
    ) -> Int32

    static let shared = OffSpaceAXPrimer()

    private let library: UnsafeMutableRawPointer?
    private let resolvePSN: ResolvePSN?
    private let postRecord: PostRecord?

    init() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion
                == Self.supportedOSMajor,
              let handle = dlopen(Self.skyLightPath, RTLD_LAZY | RTLD_LOCAL),
              let resolve = dlsym(handle, "GetProcessForPID"),
              let post = dlsym(handle, "SLPSPostEventRecordTo")
        else {
            library = nil
            resolvePSN = nil
            postRecord = nil
            return
        }

        typealias ResolveFn = @convention(c) (
            pid_t, UnsafeMutableRawPointer
        ) -> Int32
        typealias PostFn = @convention(c) (
            UnsafeRawPointer, UnsafePointer<UInt8>
        ) -> Int32
        let resolveFn = unsafeBitCast(resolve, to: ResolveFn.self)
        let postFn = unsafeBitCast(post, to: PostFn.self)
        library = handle
        resolvePSN = { resolveFn($0, $1) }
        postRecord = { postFn($0, $1) }
    }

    init(resolvePSN: @escaping ResolvePSN,
         postRecord: @escaping PostRecord) {
        library = nil
        self.resolvePSN = resolvePSN
        self.postRecord = postRecord
    }

    func withPrime(
        pid: Int, windowID: Int, observe: () -> Bool,
        cleanup: () -> OffSpaceAXCleanup
    ) -> OffSpaceAXPrimeResult {
        guard pid > 0, windowID > 0,
              UInt64(windowID) <= UInt64(UInt32.max),
              let resolvePSN, let postRecord else { return .focusFailed }

        var psn = [UInt8](repeating: 0, count: Self.psnBytes)
        let resolved = psn.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return Int32(-1) }
            return resolvePSN(pid_t(pid), base)
        }
        guard resolved == 0 else { return .focusFailed }

        let exactWindowID = UInt32(windowID)
        let focused = post(
            psn: psn, windowID: exactWindowID,
            marker: Self.focusMarker, postRecord: postRecord)
        guard focused == 0 else {
            _ = post(
                psn: psn, windowID: exactWindowID,
                marker: Self.defocusMarker, postRecord: postRecord)
            return .focusFailed
        }

        let observed = observe()
        let decision = cleanup()
        switch decision {
        case .preserveUserFocus:
            return .userEnteredTarget
        case .defocus, .cancel:
            let cleaned = post(
                psn: psn, windowID: exactWindowID,
                marker: Self.defocusMarker, postRecord: postRecord)
            guard cleaned == 0 else { return .cleanupFailed }
            if decision == .cancel { return .cancelled }
            return observed ? .observed : .observationFailed
        }
    }

    private func post(
        psn: [UInt8], windowID: UInt32, marker: UInt8,
        postRecord: PostRecord
    ) -> Int32 {
        let record = makeRecord(windowID: windowID, marker: marker)
        return psn.withUnsafeBytes { psnBytes in
            record.withUnsafeBufferPointer { recordBytes in
                guard let target = psnBytes.baseAddress,
                      let bytes = recordBytes.baseAddress else {
                    return Int32(-1)
                }
                return postRecord(target, bytes)
            }
        }
    }

    private func makeRecord(
        windowID: UInt32, marker: UInt8
    ) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: Self.recordBytes)
        record[Self.sizeOffset] = UInt8(Self.recordBytes)
        record[Self.typeOffset] = Self.focusRecordType
        let bytes = windowID.littleEndian
        withUnsafeBytes(of: bytes) { source in
            record.replaceSubrange(
                Self.windowOffset..<(Self.windowOffset + Self.windowBytes),
                with: source)
        }
        record[Self.focusOffset] = marker
        return record
    }
}
