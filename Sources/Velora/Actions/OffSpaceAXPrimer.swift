import Darwin
import Foundation

/// A bounded target-only focus lease. It materializes an off-Space window's
/// AX tree without activating, raising, or moving that window.
enum OffSpaceAXCleanup: Equatable {
    case restoreForeground
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
        pid: Int, windowID: Int,
        foregroundPID: Int, foregroundWindowID: Int,
        validate: () -> Bool,
        observe: () -> Bool,
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

    typealias ResolveWindowPSN = (
        pid_t, UInt32, UnsafeMutableRawPointer
    ) -> Int32
    typealias GetFrontPSN = (UnsafeMutableRawPointer) -> Int32
    typealias PostRecord = (
        UnsafeRawPointer, UnsafePointer<UInt8>
    ) -> Int32

    static let shared = OffSpaceAXPrimer()

    private let library: UnsafeMutableRawPointer?
    private let resolveWindowPSN: ResolveWindowPSN?
    private let getFrontPSN: GetFrontPSN?
    private let postRecord: PostRecord?

    init() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion
                == Self.supportedOSMajor,
              let handle = dlopen(Self.skyLightPath, RTLD_LAZY | RTLD_LOCAL),
              let getFront = dlsym(handle, "_SLPSGetFrontProcess"),
              let post = dlsym(handle, "SLPSPostEventRecordTo")
        else {
            library = nil
            resolveWindowPSN = nil
            getFrontPSN = nil
            postRecord = nil
            return
        }

        typealias MainConnectionFn = @convention(c) () -> UInt32
        typealias WindowOwnerFn = @convention(c) (
            UInt32, UInt32, UnsafeMutablePointer<UInt32>
        ) -> Int32
        typealias ConnectionPSNFn = @convention(c) (
            UInt32, UnsafeMutableRawPointer
        ) -> Int32
        typealias ConnectionPIDFn = @convention(c) (
            UInt32, UnsafeMutablePointer<pid_t>
        ) -> Int32
        typealias GetFrontFn = @convention(c) (
            UnsafeMutableRawPointer
        ) -> Int32
        typealias PostFn = @convention(c) (
            UnsafeRawPointer, UnsafePointer<UInt8>
        ) -> Int32
        let mainConnection = dlsym(handle, "CGSMainConnectionID").map {
            unsafeBitCast($0, to: MainConnectionFn.self)
        }
        let windowOwner = dlsym(handle, "SLSGetWindowOwner").map {
            unsafeBitCast($0, to: WindowOwnerFn.self)
        }
        let connectionPSN = dlsym(handle, "SLSGetConnectionPSN").map {
            unsafeBitCast($0, to: ConnectionPSNFn.self)
        }
        let connectionPID = dlsym(handle, "SLSConnectionGetPID").map {
            unsafeBitCast($0, to: ConnectionPIDFn.self)
        }
        guard mainConnection != nil, windowOwner != nil,
              connectionPSN != nil, connectionPID != nil else {
            dlclose(handle)
            library = nil
            resolveWindowPSN = nil
            getFrontPSN = nil
            postRecord = nil
            return
        }
        let getFrontFn = unsafeBitCast(getFront, to: GetFrontFn.self)
        let postFn = unsafeBitCast(post, to: PostFn.self)
        library = handle
        // Bind the exact window to its WindowServer owner before resolving its
        // PSN. A stale or reused window ID must never redirect the focus lease.
        resolveWindowPSN = { pid, windowID, output in
            guard let mainConnection, let windowOwner,
                  let connectionPID, let connectionPSN
            else { return -1 }
            var ownerConnection: UInt32 = 0
            var ownerPID: pid_t = 0
            let connection = mainConnection()
            guard connection != 0,
                  windowOwner(connection, windowID, &ownerConnection) == 0,
                  ownerConnection != 0,
                  connectionPID(ownerConnection, &ownerPID) == 0,
                  ownerPID == pid
            else { return -1 }
            return connectionPSN(ownerConnection, output)
        }
        getFrontPSN = { getFrontFn($0) }
        postRecord = { postFn($0, $1) }
    }

    init(resolveWindowPSN: @escaping ResolveWindowPSN,
         getFrontPSN: @escaping GetFrontPSN,
         postRecord: @escaping PostRecord) {
        library = nil
        self.resolveWindowPSN = resolveWindowPSN
        self.getFrontPSN = getFrontPSN
        self.postRecord = postRecord
    }

    func withPrime(
        pid: Int, windowID: Int,
        foregroundPID: Int, foregroundWindowID: Int,
        validate: () -> Bool,
        observe: () -> Bool,
        cleanup: () -> OffSpaceAXCleanup
    ) -> OffSpaceAXPrimeResult {
        guard pid > 0, windowID > 0,
              foregroundPID > 0, foregroundWindowID > 0,
              UInt64(windowID) <= UInt64(UInt32.max),
              UInt64(foregroundWindowID) <= UInt64(UInt32.max),
              let resolveWindowPSN, let getFrontPSN, let postRecord
        else { return .focusFailed }

        let exactWindowID = UInt32(windowID)
        let foregroundID = UInt32(foregroundWindowID)
        guard let targetPSN = resolvePSN(
            pid: pid, windowID: exactWindowID, resolver: resolveWindowPSN),
              let expectedFrontPSN = resolvePSN(
                pid: foregroundPID, windowID: foregroundID,
                resolver: resolveWindowPSN),
              validate(),
              let currentFrontPSN = frontPSN(getFrontPSN),
              currentFrontPSN == expectedFrontPSN
        else { return .focusFailed }

        // Cua's no-raise recipe is a pair: defocus the proven foreground,
        // then focus the exact target without changing the window stack.
        let defocused = post(
            psn: currentFrontPSN, windowID: exactWindowID,
            marker: Self.defocusMarker, postRecord: postRecord)
        guard defocused == 0 else { return .focusFailed }
        let focused = post(
            psn: targetPSN, windowID: exactWindowID,
            marker: Self.focusMarker, postRecord: postRecord)
        guard focused == 0 else {
            _ = post(
                psn: targetPSN, windowID: exactWindowID,
                marker: Self.defocusMarker, postRecord: postRecord)
            _ = post(
                psn: expectedFrontPSN, windowID: foregroundID,
                marker: Self.focusMarker, postRecord: postRecord)
            return .focusFailed
        }

        let observed = observe()
        let decision = cleanup()
        switch decision {
        case .preserveUserFocus:
            return .userEnteredTarget
        case .restoreForeground:
            let targetCleaned = post(
                psn: targetPSN, windowID: exactWindowID,
                marker: Self.defocusMarker, postRecord: postRecord)
            let foregroundRestored = post(
                psn: expectedFrontPSN, windowID: foregroundID,
                marker: Self.focusMarker, postRecord: postRecord)
            guard targetCleaned == 0, foregroundRestored == 0 else {
                return .cleanupFailed
            }
            return observed ? .observed : .observationFailed
        case .defocus, .cancel:
            let targetCleaned = post(
                psn: targetPSN, windowID: exactWindowID,
                marker: Self.defocusMarker, postRecord: postRecord)
            guard targetCleaned == 0 else { return .cleanupFailed }
            if decision == .cancel { return .cancelled }
            return observed ? .observed : .observationFailed
        }
    }

    private func resolvePSN(
        pid: Int, windowID: UInt32,
        resolver: ResolveWindowPSN
    ) -> [UInt8]? {
        var psn = [UInt8](repeating: 0, count: Self.psnBytes)
        let result = psn.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return Int32(-1) }
            return resolver(pid_t(pid), windowID, base)
        }
        return result == 0 ? psn : nil
    }

    private func frontPSN(_ getter: GetFrontPSN) -> [UInt8]? {
        var psn = [UInt8](repeating: 0, count: Self.psnBytes)
        let result = psn.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return Int32(-1) }
            return getter(base)
        }
        return result == 0 ? psn : nil
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
