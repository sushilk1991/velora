import AppKit
import Darwin
import Foundation
import Security

struct SublimeTextSelectionCapture {
    let text: String
    let token: SublimeTextSelectionToken
}

enum SublimeTextSelectionError: Error {
    case emptySelection
    case multipleSelections
    case unsupportedView
    case integrationNeedsRestart
    case integrationUnavailable
}

enum SublimeTextApplyResult: Equatable {
    case applied
    case rejected
    case unknown
}

/// Opaque identity for one exact Sublime view and region. Sublime's plugin
/// validates the active view, selection coordinates, bytes, and buffer change
/// count before it performs a one-shot replacement.
final class SublimeTextSelectionToken {
    private enum State {
        case ready
        case applying
        case consumed
        case cancelled
    }

    private let lock = NSLock()
    private let value: String
    private let generation: String
    private let client: SublimeCommandClient
    private var state: State = .ready

    init(
        value: String,
        generation: String,
        client: SublimeCommandClient
    ) {
        self.value = value
        self.generation = generation
        self.client = client
    }

    func replace(with text: String) -> SublimeTextApplyResult {
        lock.lock()
        guard state == .ready else {
            lock.unlock()
            return .rejected
        }
        state = .applying
        lock.unlock()
        let result = client.apply(
            token: value,
            generation: generation,
            replacement: text,
            isCancelled: { [weak self] in self?.isCancelled ?? true })
        lock.lock()
        if state == .applying { state = .consumed }
        lock.unlock()
        // Report the plugin's observed result even if cancellation raced with
        // the response. The controller ignores late completions by apply ID,
        // but turning a confirmed replacement into `false` would lie about
        // whether Sublime actually changed the buffer.
        return result
    }

    func discard() {
        lock.lock()
        let shouldDiscardCapturedToken: Bool
        switch state {
        case .ready:
            state = .cancelled
            shouldDiscardCapturedToken = true
        case .applying:
            state = .cancelled
            shouldDiscardCapturedToken = false
        case .consumed, .cancelled:
            lock.unlock()
            return
        }
        lock.unlock()
        guard shouldDiscardCapturedToken else { return }
        let client = client
        let value = value
        let generation = generation
        DispatchQueue.global(qos: .utility).async {
            client.discard(token: value, generation: generation)
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .cancelled
    }
}

enum SublimeTextSelectionBridge {
    static let bundleID = "com.sublimetext.4"
    private static let teamID = "Z6D26JE4Y4"

    static func supports(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier == bundleID
    }

    static func capture(
        of app: NSRunningApplication
    ) -> Result<SublimeTextSelectionCapture, SublimeTextSelectionError> {
        guard app.bundleIdentifier == bundleID,
              runningCodeIsValid(
                  pid: app.processIdentifier,
                  requirement:
                    "anchor apple generic and certificate leaf[subject.OU] "
                    + "= \"\(teamID)\" and identifier \"\(bundleID)\"")
        else {
            veloraLog("Velora: rejected untrusted Sublime Text process")
            return .failure(.integrationUnavailable)
        }

        return SublimeCommandClient(
            targetPID: app.processIdentifier
        ).capture()
    }

    private static func runningCodeIsValid(
        pid: pid_t, requirement expression: String
    ) -> Bool {
        let attributes = [
            kSecGuestAttributePid: NSNumber(value: pid),
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(rawValue: 0),
            &code) == errSecSuccess,
              let code
        else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            expression as CFString,
            SecCSFlags(rawValue: 0),
            &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: 0),
            requirement) == errSecSuccess
    }
}

/// One-request-per-connection client for the owner-only AF_UNIX endpoint that
/// the bundled Sublime plugin opens inside ~/.velora/sublime-bridge. This
/// deliberately does not use `subl --command`: that helper can lose contact
/// with a long-running editor even while the editor itself is responsive.
struct SublimeCommandClient {
    private struct Response: Decodable {
        let ok: Bool
        let error: String?
        let token: String?
        let text: String?
        let generation: String?
        let editorPID: Int?
        let known: Bool?
        let resultOK: Bool?
        let resultError: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case error
            case token
            case text
            case generation
            case editorPID = "editor_pid"
            case known
            case resultOK = "result_ok"
            case resultError = "result_error"
        }
    }

    private static let protocolVersion = 1
    private static let pluginDirectoryName = "VeloraVoiceEdit"
    private static let pluginFileName = "VeloraVoiceEdit.py"
    private static let pythonVersionFileName = ".python-version"
    private static let socketStartupWait: TimeInterval = 0.8
    private static let applyLifetime: TimeInterval = 2.0
    private static let maxResponseBytes = 1_048_576

    let targetPID: pid_t

    func capture(
    ) -> Result<SublimeTextSelectionCapture, SublimeTextSelectionError> {
        guard targetIsCurrent(),
              let pluginChanged = installPluginIfNeeded()
        else {
            return .failure(.integrationUnavailable)
        }
        if pluginChanged {
            veloraLog(
                "Velora: installed updated Sublime Text integration")
        }

        let requestID = UUID().uuidString.lowercased()
        let request: [String: Any] = [
            "version": Self.protocolVersion,
            "command": "capture",
            "request_id": requestID,
        ]
        guard let response = waitForPlugin(
            request: request,
            startupTimeout: Self.socketStartupWait,
            socketTimeoutSeconds: 1)
        else {
            // The package is present but its plugin host has not opened the
            // PID-specific endpoint. A normal Sublime restart is the only
            // honest recovery; Accessibility cannot read its editor surface.
            veloraLog(
                "Velora: Sublime plugin endpoint unavailable for pid "
                    + "\(targetPID)")
            return .failure(.integrationNeedsRestart)
        }
        guard response.ok,
              response.token == requestID,
              let generation = response.generation,
              !generation.isEmpty,
              let text = response.text
        else {
            switch response.error {
            case "empty_selection":
                return .failure(.emptySelection)
            case "multiple_selections":
                return .failure(.multipleSelections)
            case "unsupported_view":
                return .failure(.unsupportedView)
            default:
                veloraLog(
                    "Velora: Sublime capture rejected: "
                        + (response.error ?? "invalid response"))
                return .failure(.integrationUnavailable)
            }
        }
        return .success(SublimeTextSelectionCapture(
            text: text,
            token: SublimeTextSelectionToken(
                value: requestID,
                generation: generation,
                client: self)))
    }

    func apply(
        token: String,
        generation: String,
        replacement: String,
        isCancelled: @escaping () -> Bool = { false }
    ) -> SublimeTextApplyResult {
        guard targetIsCurrent(), !isCancelled() else { return .rejected }
        let requestID = UUID().uuidString.lowercased()
        let request: [String: Any] = [
            "version": Self.protocolVersion,
            "command": "apply",
            "request_id": requestID,
            "token": token,
            "generation": generation,
            "replacement": replacement,
            "expires_at":
                Date().timeIntervalSince1970 + Self.applyLifetime,
        ]
        if let response = transact(
            request,
            timeoutSeconds: 3,
            isCancelled: isCancelled
        ) {
            guard response.generation == generation else { return .rejected }
            return response.ok ? .applied : .rejected
        }
        guard !isCancelled(),
              let status = transact([
                  "version": Self.protocolVersion,
                  "command": "status",
                  "request_id": UUID().uuidString.lowercased(),
                  "apply_request_id": requestID,
              ], timeoutSeconds: 1),
              status.generation == generation,
              status.ok,
              status.known == true
        else { return .unknown }
        return status.resultOK == true ? .applied : .rejected
    }

    func discard(token: String, generation: String) {
        guard targetIsRunning() else { return }
        _ = transact([
            "version": Self.protocolVersion,
            "command": "discard",
            "request_id": UUID().uuidString.lowercased(),
            "token": token,
            "generation": generation,
        ], timeoutSeconds: 1)
    }

    private func targetIsCurrent() -> Bool {
        onMain {
            guard let current = NSWorkspace.shared.frontmostApplication else {
                return false
            }
            return current.processIdentifier == targetPID
                && current.bundleIdentifier
                    == SublimeTextSelectionBridge.bundleID
        }
    }

    private func targetIsRunning() -> Bool {
        onMain {
            guard let app = NSRunningApplication(
                processIdentifier: targetPID)
            else { return false }
            return !app.isTerminated
                && app.bundleIdentifier
                    == SublimeTextSelectionBridge.bundleID
        }
    }

    private func onMain(_ body: @escaping () -> Bool) -> Bool {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }

    /// Returns whether this call changed the installed plugin, or nil on an
    /// unsafe/unavailable installation path.
    private func installPluginIfNeeded() -> Bool? {
        let fileManager = FileManager.default
        guard let pluginSource = bundledPluginData(
                  named: Self.pluginFileName),
              let pythonVersion = bundledPluginData(
                  named: Self.pythonVersionFileName)
        else { return nil }
        let packages = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Sublime Text/Packages",
                isDirectory: true)
        let directory = packages.appendingPathComponent(
            Self.pluginDirectoryName, isDirectory: true)
        let pluginTarget = directory.appendingPathComponent(Self.pluginFileName)
        let pythonVersionTarget = directory.appendingPathComponent(
            Self.pythonVersionFileName)
        guard !isSymbolicLink(packages), !isSymbolicLink(directory),
              !isSymbolicLink(pluginTarget),
              !isSymbolicLink(pythonVersionTarget)
        else { return nil }

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            var changed = false
            for (data, target) in [
                (pythonVersion, pythonVersionTarget),
                // Install the host declaration first. A first-time Sublime
                // package must never load this modern plugin under the legacy
                // Python host before `.python-version` exists.
                (pluginSource, pluginTarget),
            ] where (try? Data(contentsOf: target)) != data {
                try data.write(to: target, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: target.path)
                changed = true
            }
            return changed
        } catch {
            veloraLog(
                "Velora: failed to install Sublime Text integration: "
                    + error.localizedDescription)
            return nil
        }
    }

    private func bundledPluginData(named fileName: String) -> Data? {
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("SublimeText")
            .appendingPathComponent(fileName),
           let data = try? Data(contentsOf: resourceURL) {
            return data
        }
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let developmentURL = sourceRoot
            .appendingPathComponent("Resources/SublimeText")
            .appendingPathComponent(fileName)
        return try? Data(contentsOf: developmentURL)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            .isSymbolicLink) == true
    }

    private func bridgeDirectory() -> URL? {
        let fileManager = FileManager.default
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".velora/sublime-bridge", isDirectory: true)
        guard !isSymbolicLink(directory) else { return nil }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path)
            return directory
        } catch {
            return nil
        }
    }

    private func socketPath() -> String? {
        bridgeDirectory()?
            .appendingPathComponent("bridge-\(targetPID).sock")
            .path
    }

    private func socketIsTrusted(_ path: String) -> Bool {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return false }
        return metadata.st_uid == geteuid()
            && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
            && metadata.st_mode & mode_t(0o077) == 0
    }

    private func waitForPlugin(
        request: [String: Any],
        startupTimeout: TimeInterval,
        socketTimeoutSeconds: Int
    ) -> Response? {
        let deadline = Date().addingTimeInterval(startupTimeout)
        repeat {
            if let response = transact(
                request,
                timeoutSeconds: socketTimeoutSeconds) {
                return response
            }
            if Date() < deadline { usleep(20_000) }
        } while Date() < deadline
        return nil
    }

    private func transact(
        _ request: [String: Any],
        timeoutSeconds: Int,
        isCancelled: () -> Bool = { false }
    ) -> Response? {
        guard !isCancelled(),
              JSONSerialization.isValidJSONObject(request),
              let path = socketPath(),
              socketIsTrusted(path),
              var data = try? JSONSerialization.data(
                  withJSONObject: request, options: [.sortedKeys])
        else { return nil }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        UnixSocket.disableSigpipe(descriptor)
        UnixSocket.setTimeouts(
            descriptor, seconds: max(1, timeoutSeconds))
        guard let connected = UnixSocket.withAddress(
            path: path,
            { address, length in
                Darwin.connect(descriptor, address, length) == 0
            }),
              connected,
              !isCancelled()
        else { return nil }

        data.append(0x0A)
        UnixSocket.writeAll(data, to: descriptor)
        guard !isCancelled(),
              let responseData = UnixSocket.readLine(
                  descriptor, cap: Self.maxResponseBytes),
              responseData.count <= Self.maxResponseBytes
        else { return nil }
        guard let response = try? JSONDecoder().decode(
            Response.self, from: responseData),
              response.editorPID == Int(targetPID)
        else { return nil }
        return response
    }
}
