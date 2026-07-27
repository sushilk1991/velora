import AppKit
import Foundation
import Security

struct SublimeTextSelectionCapture {
    let text: String
    let token: SublimeTextSelectionToken
}

enum SublimeTextSelectionError: Error {
    case emptySelection
    case multipleSelections
    case integrationNeedsRestart
    case integrationUnavailable
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
    private let client: SublimeCommandClient
    private var state: State = .ready

    init(value: String, client: SublimeCommandClient) {
        self.value = value
        self.client = client
    }

    func replace(with text: String) -> Bool {
        lock.lock()
        guard state == .ready else {
            lock.unlock()
            return false
        }
        state = .applying
        lock.unlock()
        let result = client.apply(
            token: value,
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
        DispatchQueue.global(qos: .utility).async {
            client.discard(token: value)
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
              let bundleURL = app.bundleURL
        else { return .failure(.integrationUnavailable) }
        let helperURL = bundleURL
            .appendingPathComponent("Contents/SharedSupport/bin/subl")
        guard trustedSublimeCode(app: app, helperURL: helperURL)
        else {
            veloraLog("Velora: rejected untrusted Sublime Text command helper")
            return .failure(.integrationUnavailable)
        }

        let client = SublimeCommandClient(
            helperURL: helperURL,
            targetPID: app.processIdentifier)
        return client.capture()
    }

    private static func trustedSublimeCode(
        app: NSRunningApplication, helperURL: URL
    ) -> Bool {
        guard !isSymbolicLink(helperURL),
              FileManager.default.isExecutableFile(atPath: helperURL.path)
        else { return false }
        let bundleRequirement =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" "
                + "and identifier \"\(bundleID)\""
        let helperRequirement =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" "
                + "and identifier \"subl\""
        return runningCodeIsValid(
            pid: app.processIdentifier,
            requirement: bundleRequirement)
            && codeIsValid(at: helperURL, requirement: helperRequirement)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            .isSymbolicLink) == true
    }

    private static func codeIsValid(
        at url: URL, requirement expression: String
    ) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code
        else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            expression as CFString,
            SecCSFlags(rawValue: 0),
            &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            requirement) == errSecSuccess
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

struct SublimeCommandClient {
    private enum CommandResult {
        case completed
        case exitedWithFailure
        case timedOut
        case notLaunched
        case cancelled
    }

    private struct Response: Decodable {
        let ok: Bool
        let error: String?
        let token: String?
        let text: String?
    }

    private static let pluginDirectoryName = "VeloraVoiceEdit"
    private static let pluginFileName = "VeloraVoiceEdit.py"
    private static let pythonVersionFileName = ".python-version"
    private static let responseWait: TimeInterval = 0.6
    private static let applyLifetime: TimeInterval = 2.0

    let helperURL: URL
    let targetPID: pid_t

    func capture(
    ) -> Result<SublimeTextSelectionCapture, SublimeTextSelectionError> {
        guard targetIsCurrent(),
              installPluginIfNeeded() != nil
        else {
            return .failure(.integrationUnavailable)
        }

        // A newly installed/updated plugin may need one Sublime plugin-host
        // reload. Retry with fresh request IDs; expired attempts can only write
        // harmless response files and never mutate the document.
        for attempt in 0..<3 {
            let requestID = UUID().uuidString.lowercased()
            removeBridgeFile(responseURL(for: requestID))
            let commandResult = run(
                command: "velora_voice_edit_capture",
                args: ["request_id": requestID])
            if let response = waitForResponse(
                requestID: requestID, timeout: Self.responseWait) {
                guard response.ok,
                      response.token == requestID,
                      let text = response.text
                else {
                    switch response.error {
                    case "empty_selection":
                        return .failure(.emptySelection)
                    case "multiple_selections":
                        return .failure(.multipleSelections)
                    default:
                        return .failure(.integrationUnavailable)
                    }
                }
                return .success(SublimeTextSelectionCapture(
                    text: text,
                    token: SublimeTextSelectionToken(
                        value: requestID, client: self)))
            }
            switch commandResult {
            case .notLaunched, .cancelled, .exitedWithFailure:
                return .failure(.integrationUnavailable)
            case .completed, .timedOut:
                break
            }
            if attempt < 2 { usleep(150_000) }
        }
        // The helper accepted the command but no plugin responded. This also
        // happens on later attempts when an installed plugin is still attached
        // to Sublime's old Python host, so keep the restart guidance actionable
        // until a capture succeeds.
        return .failure(.integrationNeedsRestart)
    }

    func apply(
        token: String,
        replacement: String,
        isCancelled: @escaping () -> Bool = { false }
    ) -> Bool {
        guard targetIsCurrent(), !isCancelled() else { return false }
        let requestID = UUID().uuidString.lowercased()
        let expiresAt = Date().timeIntervalSince1970 + Self.applyLifetime
        let request: [String: Any] = [
            "token": token,
            "replacement": replacement,
            "expires_at": expiresAt,
        ]
        guard writeRequest(request, requestID: requestID) else {
            return false
        }
        guard !isCancelled() else {
            removeBridgeFile(requestURL(for: requestID))
            return false
        }
        let commandResult = run(
            command: "velora_voice_edit_apply",
            args: ["request_id": requestID],
            isCancelled: isCancelled)
        switch commandResult {
        case .notLaunched:
            removeBridgeFile(requestURL(for: requestID))
            return false
        case .cancelled:
            removeBridgeFile(requestURL(for: requestID))
            return false
        case .completed, .exitedWithFailure, .timedOut:
            break
        }
        if isCancelled() {
            // The helper may time out after it has already delivered the
            // command. Remove the unread request to prevent a later edit, but
            // the controller deliberately ignores any late completion.
            removeBridgeFile(requestURL(for: requestID))
            return false
        }
        let response = waitForResponse(
            requestID: requestID,
            timeout: Self.applyLifetime + 0.35,
            isCancelled: isCancelled)
        removeBridgeFile(requestURL(for: requestID))
        return response?.ok == true
    }

    func discard(token: String) {
        guard targetIsCurrent() else { return }
        _ = run(
            command: "velora_voice_edit_discard",
            args: ["token": token])
    }

    private func targetIsCurrent() -> Bool {
        let check = {
            guard let current = NSWorkspace.shared.frontmostApplication else {
                return false
            }
            return current.processIdentifier == targetPID
                && current.bundleIdentifier
                    == SublimeTextSelectionBridge.bundleID
        }
        if Thread.isMainThread { return check() }
        return DispatchQueue.main.sync(execute: check)
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
                // package must never load this Python 3.8 plugin under the
                // legacy 3.3 host before `.python-version` exists.
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

    private func requestURL(for requestID: String) -> URL? {
        bridgeDirectory()?.appendingPathComponent(
            "\(requestID).request.json")
    }

    private func responseURL(for requestID: String) -> URL? {
        bridgeDirectory()?.appendingPathComponent(
            "\(requestID).response.json")
    }

    private func writeRequest(
        _ value: [String: Any], requestID: String
    ) -> Bool {
        guard JSONSerialization.isValidJSONObject(value),
              let url = requestURL(for: requestID),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return false }
        do {
            removeBridgeFile(url)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path)
            return true
        } catch {
            removeBridgeFile(url)
            return false
        }
    }

    private func waitForResponse(
        requestID: String,
        timeout: TimeInterval,
        isCancelled: () -> Bool = { false }
    ) -> Response? {
        guard let url = responseURL(for: requestID) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        defer { removeBridgeFile(url) }
        while Date() < deadline {
            if isCancelled() { return nil }
            if let data = try? Data(contentsOf: url),
               let response = try? JSONDecoder().decode(
                   Response.self, from: data) {
                return response
            }
            usleep(5_000)
        }
        return nil
    }

    private func removeBridgeFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func run(
        command: String,
        args: [String: Any],
        isCancelled: () -> Bool = { false }
    ) -> CommandResult {
        if isCancelled() { return .cancelled }
        guard targetIsCurrent(),
              JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(
                  withJSONObject: args, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return .notLaunched }
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--command", "\(command) \(json)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .notLaunched
        }
        let deadline = Date().addingTimeInterval(0.3)
        while process.isRunning, Date() < deadline {
            if isCancelled() {
                process.terminate()
                return .cancelled
            }
            usleep(2_000)
        }
        if process.isRunning {
            process.terminate()
            return .timedOut
        }
        return process.terminationStatus == 0
            ? .completed
            : .exitedWithFailure
    }
}
