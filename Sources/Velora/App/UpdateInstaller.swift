import AppKit
import Foundation

extension Notification.Name {
    /// Posted on the main queue whenever `UpdateInstaller.shared.state` changes.
    static let veloraUpdateStateChanged = Notification.Name("VeloraUpdateStateChanged")
}

/// Downloads, verifies, and installs a newer Velora release in place.
///
/// Pipeline: release DMG from GitHub → download into Application
/// Support/Velora/updates → mount → copy Velora.app into a staging folder →
/// verify the copy → swap the running bundle with a detached helper that
/// waits for this process to exit → optionally relaunch.
///
/// Verification is the security boundary, not the feed: the staged app must
/// pass strict deep codesign validation, carry this project's Developer ID
/// team and bundle identifier, pass a Gatekeeper assessment (notarization),
/// report exactly the advertised version, and be newer than the running
/// build — and the swap helper re-validates the signature on the exact bytes
/// it installs, after this process has exited. A hijacked feed can point
/// anywhere it likes; nothing installs unless Apple's signature chain says
/// it is a genuine newer Velora release.
///
/// Threading: `state`, `pendingUpdate`, `downloadTask`, and `generation` are
/// main-queue-confined. URLSession delegate callbacks and the shell pipeline
/// hop to main before touching them; stale callbacks are dropped by task
/// identity (`task === downloadTask`) and by `generation`, which increments
/// whenever the user starts, cancels, or discards an attempt.
final class UpdateInstaller: NSObject, URLSessionDownloadDelegate {

    enum State: Equatable {
        case idle
        /// progress is 0…1.
        case downloading(version: String, progress: Double)
        case verifying(version: String)
        /// Staged and verified under Application Support. Installs via
        /// `installAndRelaunch()`, or on quit when auto-install is on.
        case ready(version: String)
        case installing
        case failed(String)
    }

    static let shared = UpdateInstaller()

    /// What a staged update must prove it belongs to before it may replace
    /// the running app (scripts/signing-config.sh pins the same values).
    static let requiredTeamID = "JZFVKGDPU4"
    static let requiredBundleID = "com.sushil.velora"

    /// Main-queue only.
    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            NotificationCenter.default.post(name: .veloraUpdateStateChanged, object: nil)
        }
    }

    private let workQueue = DispatchQueue(label: "com.sushil.velora.updater", qos: .utility)
    private lazy var session = URLSession(
        configuration: .ephemeral, delegate: self, delegateQueue: nil)
    private var downloadTask: URLSessionDownloadTask?
    private var pendingUpdate: UpdateChecker.Update?
    /// Invalidates in-flight work after cancel/discard/restart (main-confined).
    private var generation = 0
    /// Set once a swap helper has been spawned so quit-time install never
    /// races a restart-time install.
    private var helperSpawned = false
    /// Set by the explicit "Install Update" action. Verification still
    /// completes first; reaching `.ready` then immediately enters the existing
    /// reverify → swap-helper → quit → relaunch path instead of asking again.
    private var installAndRelaunchWhenReady = false {
        didSet {
            guard installAndRelaunchWhenReady != oldValue else { return }
            NotificationCenter.default.post(
                name: .veloraUpdateStateChanged, object: nil)
        }
    }
    /// Shared truth for every install surface. The update window must reflect
    /// an explicit restart requested from Settings or the status menu too, so
    /// closing that window cannot reinterpret the request as Remind Me Later.
    var explicitInstallRequested: Bool {
        if installAndRelaunchWhenReady || helperSpawned { return true }
        if case .installing = state { return true }
        return false
    }
    /// Main-queue safety gate supplied by the composition root. A one-click
    /// install waits for user-owned foreground work instead of cancelling it
    /// when a slow download happens to finish.
    var relaunchBlockReason: (() -> String?)?
    /// Headless update E2E exits directly after the helper starts; the app
    /// default requests normal AppKit termination so lifecycle cleanup runs.
    var terminationHandler: (() -> Void)?
    private var installRetryWorkItem: DispatchWorkItem?
    private var lastRelaunchBlockReason: String?

    static var updatesDirectory: URL {
        ResourceLocator.applicationSupportDirectory
            .appendingPathComponent("updates", isDirectory: true)
    }

    /// Local name for an in-flight download — feed-supplied asset names
    /// never become filesystem paths, and the task identifier keeps a
    /// straggler callback from a cancelled attempt from clobbering the
    /// current attempt's bytes.
    private static func downloadDestination(taskIdentifier: Int) -> URL {
        updatesDirectory.appendingPathComponent("pending-update-\(taskIdentifier).dmg")
    }

    private static func stagedURL(for version: String) -> URL {
        updatesDirectory.appendingPathComponent("Velora-\(version).app")
    }

    // MARK: - Eligibility

    /// Why an in-place install is impossible, or nil when it can proceed.
    /// Bare `swift build` binaries, translocated bundles, and app folders the
    /// user cannot write to all fall back to the release page.
    static func installBlocker() -> String? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            return "Running outside an app bundle — updates apply to packaged builds only"
        }
        if bundle.path.contains("/AppTranslocation/") {
            return "Velora is running from a translocated path — drag Velora.app into Applications, relaunch, and update again"
        }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: bundle.path),
              fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
        else {
            return "No permission to replace \(bundle.path) — update manually from the releases page"
        }
        return nil
    }

    static var canInstallInPlace: Bool { installBlocker() == nil }

    // MARK: - Download

    /// Starts the download → verify → stage pipeline. A newer discovered
    /// release supersedes an older in-flight attempt; repeated requests for
    /// the same release coalesce.
    func begin(_ update: UpdateChecker.Update) {
        begin(update, installAfterStaging: false)
    }

    /// One user decision drives the complete safe pipeline. If an automatic
    /// background download is already in flight, this upgrades that attempt to
    /// install and relaunch as soon as verification succeeds.
    func beginAndInstall(_ update: UpdateChecker.Update) {
        dispatchPrecondition(condition: .onQueue(.main))
        clearPromptSuppression(for: update.version)
        begin(update, installAfterStaging: true)
    }

    private func begin(_ update: UpdateChecker.Update, installAfterStaging: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch state {
        case .downloading(let version, _):
            if version == update.version {
                if installAfterStaging { installAndRelaunchWhenReady = true }
                return
            }
            cancelDownload()
        case .verifying(let version):
            if version == update.version {
                if installAfterStaging { installAndRelaunchWhenReady = true }
                return
            }
            abandonVerification(version: version)
        case .ready(let version) where version == update.version:
            if installAfterStaging { installAndRelaunch() }
            return
        case .installing:
            return
        case .ready(let version):
            let stale = Self.stagedURL(for: version)
            workQueue.async { try? FileManager.default.removeItem(at: stale) }
        case .idle, .failed:
            break
        }
        cancelInstallRetry()
        if let blocker = Self.installBlocker() {
            state = .failed(blocker)
            return
        }
        guard let current = UpdateChecker.currentVersion,
              UpdateChecker.isNewer(update.version, than: current) else {
            state = .failed("Already running the latest version")
            return
        }
        // The version becomes part of the staging path — never let feed
        // content smuggle path separators or anything else exotic in.
        guard update.version.range(
            of: "^[0-9A-Za-z.-]+$", options: .regularExpression) != nil else {
            state = .failed("Release version looks invalid")
            return
        }
        guard let asset = update.asset else {
            state = .failed("Release \(update.version) has no DMG to download")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: Self.updatesDirectory, withIntermediateDirectories: true)
        } catch {
            state = .failed("Could not create the updates folder: \(error.localizedDescription)")
            return
        }
        veloraLog("Velora: update \(update.version) — downloading \(asset.url.absoluteString)")
        generation += 1
        installAndRelaunchWhenReady = installAfterStaging
        pendingUpdate = update
        state = .downloading(version: update.version, progress: 0)
        let task = session.downloadTask(with: asset.url)
        // Delegate callbacks read the expected size from the task itself —
        // no cross-queue property access.
        task.taskDescription = String(asset.size)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard case .downloading = state else { return }
        generation += 1
        let dmg = downloadTask.map { Self.downloadDestination(taskIdentifier: $0.taskIdentifier) }
        downloadTask?.cancel()
        downloadTask = nil
        pendingUpdate = nil
        installAndRelaunchWhenReady = false
        cancelInstallRetry()
        state = .idle
        if let dmg {
            workQueue.async { try? FileManager.default.removeItem(at: dmg) }
        }
    }

    /// Deletes a staged-and-ready update and returns to idle (the user backs
    /// out — e.g. a release gets pulled after they downloaded it).
    func discardStagedUpdate() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard case .ready(let version) = state else { return }
        generation += 1
        installAndRelaunchWhenReady = false
        cancelInstallRetry()
        state = .idle
        let staged = Self.stagedURL(for: version)
        workQueue.async { try? FileManager.default.removeItem(at: staged) }
        veloraLog("Velora: staged update \(version) discarded")
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        var expected = totalBytesExpectedToWrite
        if expected <= 0 { expected = Int64(downloadTask.taskDescription ?? "") ?? 0 }
        guard expected > 0 else { return }
        let progress = min(Double(totalBytesWritten) / Double(expected), 1)
        DispatchQueue.main.async { [weak self] in
            guard let self, downloadTask === self.downloadTask,
                  case .downloading(let version, let last) = self.state,
                  progress - last >= 0.01 || progress >= 1
            else { return }
            self.state = .downloading(version: version, progress: progress)
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file dies when this callback returns — park it at a
        // task-scoped path now, on this queue, before hopping anywhere. No
        // shared state is touched until the main-queue hop below.
        let dmg = Self.downloadDestination(taskIdentifier: downloadTask.taskIdentifier)
        let fm = FileManager.default
        try? fm.removeItem(at: dmg)
        var moveError: String?
        do {
            try fm.moveItem(at: location, to: dmg)
        } catch {
            moveError = error.localizedDescription
        }
        let httpStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode
        DispatchQueue.main.async { [weak self] in
            guard let self, downloadTask === self.downloadTask,
                  let update = self.pendingUpdate, let asset = update.asset
            else {
                // Stale attempt (cancelled or superseded) — drop the bytes.
                DispatchQueue.global(qos: .utility).async { try? fm.removeItem(at: dmg) }
                return
            }
            if let httpStatus, httpStatus != 200 {
                self.failCurrent("Download failed (HTTP \(httpStatus))")
                return
            }
            if let moveError {
                self.failCurrent("Could not save the downloaded update: \(moveError)")
                return
            }
            self.state = .verifying(version: update.version)
            let gen = self.generation
            self.workQueue.async { [weak self] in
                self?.verifyAndStage(
                    dmg: dmg, update: update, expectedSize: asset.size, generation: gen)
            }
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, task === self.downloadTask else { return }
            self.failCurrent("Download failed: \(error.localizedDescription)")
        }
    }

    /// Main queue: fail the in-flight attempt and clear its bookkeeping.
    private func failCurrent(_ reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        veloraLog("Velora: update failed — \(reason)")
        downloadTask = nil
        pendingUpdate = nil
        installAndRelaunchWhenReady = false
        cancelInstallRetry()
        state = .failed(reason)
    }

    /// Any queue: apply a state outcome unless the attempt was cancelled or
    /// superseded in the meantime.
    private func finish(_ outcome: State, ifGeneration gen: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.generation else { return }
            self.downloadTask = nil
            self.pendingUpdate = nil
            if case .failed(let reason) = outcome {
                veloraLog("Velora: update failed — \(reason)")
            }
            self.state = outcome
            switch outcome {
            case .ready where self.installAndRelaunchWhenReady:
                self.installWhenSafe()
            case .failed:
                self.installAndRelaunchWhenReady = false
                self.cancelInstallRetry()
            case .idle, .downloading, .verifying, .ready, .installing:
                break
            }
        }
    }

    // MARK: - Verify + stage

    private func verifyAndStage(
        dmg: URL, update: UpdateChecker.Update, expectedSize: Int, generation gen: Int
    ) {
        let staged = Self.stagedURL(for: update.version)
        let failure = Self.stage(
            dmg: dmg, to: staged, expectedVersion: update.version, expectedSize: expectedSize)
        try? FileManager.default.removeItem(at: dmg)
        if let failure {
            try? FileManager.default.removeItem(at: staged)
            finish(.failed(failure), ifGeneration: gen)
        } else {
            veloraLog("Velora: update \(update.version) verified and staged at \(staged.path)")
            finish(.ready(version: update.version), ifGeneration: gen)
        }
    }

    /// Mounts the DMG, copies Velora.app to `staged`, and verifies the copy.
    /// Returns a user-facing failure reason, or nil on success.
    private static func stage(
        dmg: URL, to staged: URL, expectedVersion: String, expectedSize: Int
    ) -> String? {
        if expectedSize > 0 {
            let size = (try? FileManager.default.attributesOfItem(atPath: dmg.path)[.size])
                as? Int ?? -1
            guard size == expectedSize else {
                return "Downloaded file size does not match the release (\(size) vs \(expectedSize) bytes)"
            }
        }
        // -noautoopen/-nobrowse: never surface the mount in Finder.
        let attach = run("/usr/bin/hdiutil",
                         ["attach", dmg.path, "-plist", "-nobrowse", "-noautoopen", "-readonly"])
        guard attach.status == 0,
              let mount = mountPoint(fromHdiutilPlist: Data(attach.output.utf8))
        else { return "Could not open the downloaded DMG" }
        defer {
            if run("/usr/bin/hdiutil", ["detach", mount]).status != 0 {
                Thread.sleep(forTimeInterval: 2)
                _ = run("/usr/bin/hdiutil", ["detach", mount, "-force"])
            }
        }
        let appInDMG = URL(fileURLWithPath: mount).appendingPathComponent("Velora.app")
        guard FileManager.default.fileExists(atPath: appInDMG.path) else {
            return "The downloaded DMG does not contain Velora.app"
        }
        try? FileManager.default.removeItem(at: staged)
        guard run("/usr/bin/ditto", [appInDMG.path, staged.path]).status == 0 else {
            return "Could not copy the update out of the DMG"
        }
        if let failure = verifyStagedApp(at: staged, expectedVersion: expectedVersion) {
            return failure
        }
        // Verified against Gatekeeper directly above; a lingering quarantine
        // flag would only re-trigger translocation on relaunch.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return nil
    }

    /// The security gate every staged bundle passes before it may replace the
    /// running app. Returns a user-facing failure reason, or nil when clean.
    static func verifyStagedApp(
        at app: URL, expectedVersion: String?, includeGatekeeper: Bool = true
    ) -> String? {
        guard run("/usr/bin/codesign",
                  ["--verify", "--deep", "--strict", app.path]).status == 0 else {
            return "The update's code signature is invalid"
        }
        let details = run("/usr/bin/codesign", ["-dvv", app.path]).output
        guard signingField(in: details, named: "TeamIdentifier") == requiredTeamID else {
            return "The update is not signed by the Velora team"
        }
        guard signingField(in: details, named: "Identifier") == requiredBundleID else {
            return "The update is signed for a different app"
        }
        if includeGatekeeper,
           run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]).status != 0 {
            return "Gatekeeper rejected the update (not notarized)"
        }
        let infoPlist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let info = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              info["CFBundleIdentifier"] as? String == requiredBundleID
        else { return "The update's Info.plist is unreadable" }
        if let expectedVersion, version != expectedVersion {
            return "The update reports version \(version), expected \(expectedVersion)"
        }
        if let current = UpdateChecker.currentVersion,
           !UpdateChecker.isNewer(version, than: current) {
            return "The staged build (\(version)) is not newer than this one"
        }
        return nil
    }

    /// First mount point in `hdiutil attach -plist` output.
    static func mountPoint(fromHdiutilPlist data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }

    private static func signingField(in output: String, named name: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("\(name)=") {
            return String(line.dropFirst(name.count + 1))
        }
        return nil
    }

    // MARK: - Install

    /// Re-verifies the staged bundle, spawns the swap helper, and terminates
    /// the app; the helper relaunches the new build once we have exited.
    func installAndRelaunch() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard case .ready(let version) = state, !helperSpawned else { return }
        clearPromptSuppression(for: version)
        installAndRelaunchWhenReady = true
        installWhenSafe()
    }

    private func clearPromptSuppression(for version: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        // The disposable-copy E2E deliberately shares the production bundle
        // identifier. A local feed must never mutate the installed app's real
        // Skip/Later choices.
        guard UpdateChecker.persistentStateAllowed else { return }
        let config = AppConfig.shared
        var skippedVersion = config.skippedUpdateVersion
        var deferredVersion = config.deferredUpdateVersion
        var deferredUntil = config.deferredUpdateUntil
        UpdatePromptPolicy.clearSuppression(
            for: version,
            skippedVersion: &skippedVersion,
            deferredVersion: &deferredVersion,
            deferredUntil: &deferredUntil)
        if skippedVersion != config.skippedUpdateVersion {
            config.skippedUpdateVersion = skippedVersion
        }
        if deferredVersion != config.deferredUpdateVersion {
            config.deferredUpdateVersion = deferredVersion
        }
        if deferredUntil != config.deferredUpdateUntil {
            config.deferredUpdateUntil = deferredUntil
        }
    }

    private func installWhenSafe() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard installAndRelaunchWhenReady,
              case .ready = state, !helperSpawned
        else {
            cancelInstallRetry()
            return
        }
        if let reason = relaunchBlockReason?() {
            if reason != lastRelaunchBlockReason {
                veloraLog("Velora: update ready — \(reason.lowercased())")
                lastRelaunchBlockReason = reason
            }
            guard installRetryWorkItem == nil else { return }
            let retry = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.installRetryWorkItem = nil
                self.installWhenSafe()
            }
            installRetryWorkItem = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
            return
        }
        cancelInstallRetry()
        performInstallAndRelaunch()
    }

    private func performInstallAndRelaunch() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard case .ready(let version) = state, !helperSpawned else { return }
        // The bundle location or its permissions may have changed since the
        // update was staged (Claude review: adopted updates especially).
        if let blocker = Self.installBlocker() {
            installAndRelaunchWhenReady = false
            state = .failed(blocker)
            return
        }
        let staged = Self.stagedURL(for: version)
        state = .installing
        generation += 1
        let gen = generation
        workQueue.async { [weak self] in
            guard let self else { return }
            // Full re-verify: the staging folder has been sitting in user
            // space since the download.
            if let failure = Self.verifyStagedApp(at: staged, expectedVersion: version) {
                try? FileManager.default.removeItem(at: staged)
                self.finish(.failed(failure), ifGeneration: gen)
                return
            }
            DispatchQueue.main.async {
                guard gen == self.generation, case .installing = self.state else { return }
                // Quit from a run-loop turn, NOT synchronously inside this
                // main-dispatch-queue block. -[NSApplication terminate:]
                // answers a .terminateLater delegate by spinning a nested
                // event loop that waits for reply(toApplicationShouldTerminate:).
                // That reply — and every termination watchdog — is delivered on
                // DispatchQueue.main, which is non-reentrant and already
                // draining THIS block, so none of them ever run and the quit
                // deadlocks (sampled from a hung build: installAndRelaunch →
                // terminate: → nested runloop pinned in mach_msg forever,
                // "Installing…" stuck until the swap helper gives up 5 min
                // later). Firing terminate from a CFRunLoop timer runs it after
                // this block returns with the main queue free — the same
                // context a menubar Quit uses, where the reply is serviced and
                // the app quits cleanly.
                let quit = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
                    guard let self, gen == self.generation,
                          case .installing = self.state, !self.helperSpawned
                    else { return }
                    // Foreground work may have started during the final
                    // signature/Gatekeeper pass or in the run-loop turn above.
                    // Gate and spawn in this same callback, so no AppKit event
                    // can start user work between the last check and quit.
                    if self.relaunchBlockReason?() != nil {
                        self.state = .ready(version: version)
                        self.installAndRelaunchWhenReady = true
                        self.installWhenSafe()
                        return
                    }
                    self.installAndRelaunchWhenReady = false
                    guard self.spawnHelper(
                        staged: staged, version: version, relaunch: true)
                    else { return }
                    if let terminationHandler = self.terminationHandler {
                        terminationHandler()
                    } else {
                        NSApp.terminate(nil)
                    }
                    // Last-resort guarantee on a queue the main-thread quit
                    // cannot starve: if graceful termination still stalls,
                    // hard-exit so the swap helper (which re-verifies the exact
                    // bytes it installs) can finish. The engine self-exits via
                    // --parent-pid, so a hard exit loses nothing. 75s clears
                    // the 60s a meeting finalize may legitimately hold the
                    // quit (AppDelegate's watchdog), so this never clips a real
                    // finalize — only a genuine hang.
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + 75
                    ) {
                        veloraLog(
                            "Velora: update quit stalled >75s — forcing exit for the swap helper")
                        exit(0)
                    }
                }
                RunLoop.main.add(quit, forMode: .common)
            }
        }
    }

    private func cancelInstallRetry() {
        installRetryWorkItem?.cancel()
        installRetryWorkItem = nil
        lastRelaunchBlockReason = nil
    }

    private func abandonVerification(version: String) {
        generation += 1
        pendingUpdate = nil
        downloadTask = nil
        installAndRelaunchWhenReady = false
        cancelInstallRetry()
        state = .idle
        // Queued on the same serial worker as verification, so it runs after
        // any current mount/copy finishes and cannot race a replacement
        // version's later verification.
        let staged = Self.stagedURL(for: version)
        workQueue.async { try? FileManager.default.removeItem(at: staged) }
    }

    func cancelPendingInstall() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard installAndRelaunchWhenReady else { return }
        switch state {
        case .downloading, .verifying, .ready:
            installAndRelaunchWhenReady = false
            cancelInstallRetry()
            // Intent changed while the public state stayed the same.
            NotificationCenter.default.post(
                name: .veloraUpdateStateChanged, object: nil)
        case .idle, .installing, .failed:
            break
        }
    }

    /// Skip/Later suppress automatic work for the exact release. Explicit
    /// install intent never exposes those controls, so this cannot cancel a
    /// user-committed install.
    func suppressAutomaticAttempt(for version: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch state {
        case .downloading(let active, _) where active == version:
            cancelDownload()
        case .verifying(let active) where active == version:
            abandonVerification(version: version)
        case .ready(let active) where active == version:
            discardStagedUpdate()
        case .idle, .downloading, .verifying, .ready, .installing, .failed:
            break
        }
    }

    /// Quit-time hook (applicationWillTerminate): with auto-install on and a
    /// verified update staged, swap it in after this process exits — without
    /// relaunching, respecting that the user chose to quit. Must stay fast:
    /// the helper itself re-validates the signature of the exact bytes it
    /// installs, so no slow verification happens on the quit path.
    func installOnQuitIfReady() {
        guard case .ready(let version) = state else { return }
        let config = AppConfig.shared
        let explicitlyRequested = installAndRelaunchWhenReady
        guard explicitlyRequested || (
            config.autoInstallUpdates
                && UpdatePromptPolicy.allowsAutomaticAction(
                    version: version,
                    skippedVersion: config.skippedUpdateVersion,
                    deferredVersion: config.deferredUpdateVersion,
                    deferredUntil: config.deferredUpdateUntil))
        else { return }
        installOnExit()
    }

    /// The quit-install core, config gate not included (the update e2e
    /// harness uses it directly).
    func installOnExit() {
        guard !helperSpawned, case .ready(let version) = state,
              Self.installBlocker() == nil else { return }
        let staged = Self.stagedURL(for: version)
        guard FileManager.default.fileExists(atPath: staged.path) else { return }
        _ = spawnHelper(staged: staged, version: version, relaunch: false)
    }

    @discardableResult
    private func spawnHelper(staged: URL, version: String, relaunch: Bool) -> Bool {
        let dir = Self.updatesDirectory
        let script = dir.appendingPathComponent("install.sh")
        let log = dir.appendingPathComponent("install.log")
        do {
            try Self.helperScript.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            failCurrent("Could not write the install helper: \(error.localizedDescription)")
            return false
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            staged.path,
            Bundle.main.bundleURL.path,
            relaunch ? "1" : "0",
            log.path,
            Self.requiredTeamID,
            Self.requiredBundleID,
            version,
        ]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            failCurrent("Could not start the install helper: \(error.localizedDescription)")
            return false
        }
        helperSpawned = true
        veloraLog("Velora: install helper spawned (relaunch=\(relaunch)) — swapping \(staged.path) into \(Bundle.main.bundleURL.path) after exit")
        return true
    }

    /// The swap helper. Paths arrive as positional arguments (never
    /// interpolated into the script), so no quoting can break on odd paths.
    ///
    /// Safety properties, in order:
    /// - copies the staged app onto the target's volume first, so both `mv`s
    ///   below are atomic same-device renames — a cross-volume `mv` of a
    ///   directory can die half-copied;
    /// - re-validates signature, team, bundle ID, version, and Gatekeeper
    ///   acceptance AFTER the app has exited, on the exact bytes about to be
    ///   installed ($6 empty skips this — selftest dry-runs only);
    /// - restore path removes any partial target before putting the old
    ///   bundle back, and checks that the restore actually worked;
    /// - on any failure with relaunch requested, reopens whatever bundle is
    ///   at the target path — the user is never left with nothing running.
    static let helperScript = """
    #!/bin/sh
    # Velora update helper — spawned by the app right before it exits.
    # $1 app pid   $2 staged .app   $3 target .app   $4 relaunch (0/1)
    # $5 log   $6 TeamIdentifier ("" skips dry-run checks)
    # $7 bundle identifier   $8 expected marketing version
    PID="$1"; STAGED="$2"; TARGET="$3"; RELAUNCH="$4"; LOG="$5"; TEAM="$6"
    BUNDLE_ID="$7"; VERSION="$8"
    exec >> "$LOG" 2>&1

    # Reopen an app for the user on failure: the target if it survived,
    # otherwise the moved-aside old bundle. Never exit leaving nothing.
    fail() {
      echo "$(date) helper: $1"
      if [ "$RELAUNCH" = "1" ]; then
        if [ -d "$TARGET" ]; then
          /usr/bin/open "$TARGET"
        elif [ -n "$OLD" ] && [ -d "$OLD" ]; then
          /usr/bin/open "$OLD"
        fi
      fi
      exit 1
    }

    # The app-side 180 s tool watchdog died with the app — a wedged ditto or
    # codesign here would otherwise leave Velora exited forever.
    run_to() {
      "$@" &
      CMD=$!
      # Watchdog gets /dev/null stdio: it must never hold open a pipe the
      # caller is reading (grep would block on it until the sleep expired).
      ( sleep 300; kill "$CMD" 2>/dev/null ) >/dev/null 2>&1 &
      WATCH=$!
      wait "$CMD"
      RC=$?
      kill "$WATCH" 2>/dev/null
      wait "$WATCH" 2>/dev/null
      return "$RC"
    }

    echo "$(date) helper: waiting for pid $PID"
    i=0
    while /bin/kill -0 "$PID" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -gt 1500 ]; then fail "app never exited; giving up"; fi
      sleep 0.2
    done

    PARENT="$(dirname "$TARGET")"
    PRE="$PARENT/.Velora-update-$$.app"
    OLD="$PARENT/.Velora-old-$$.app"

    rm -rf "$PRE"
    if ! run_to /usr/bin/ditto "$STAGED" "$PRE"; then
      rm -rf "$PRE"
      fail "could not copy the update onto the app's volume"
    fi

    if [ -n "$TEAM" ]; then
      if ! run_to /usr/bin/codesign --verify --deep --strict "$PRE"; then
        rm -rf "$PRE"
        fail "update failed signature validation"
      fi
      if ! run_to /usr/bin/codesign -dvv "$PRE" 2>&1 | /usr/bin/grep -Fqx "TeamIdentifier=$TEAM"; then
        rm -rf "$PRE"
        fail "update signed by the wrong team"
      fi
      if ! run_to /usr/bin/codesign -dvv "$PRE" 2>&1 | /usr/bin/grep -Fqx "Identifier=$BUNDLE_ID"; then
        rm -rf "$PRE"
        fail "update signed for a different app"
      fi
      INFO="$PRE/Contents/Info.plist"
      if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO" 2>/dev/null)" != "$BUNDLE_ID" ]; then
        rm -rf "$PRE"
        fail "update bundle identifier does not match"
      fi
      if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO" 2>/dev/null)" != "$VERSION" ]; then
        rm -rf "$PRE"
        fail "update version does not match"
      fi
      if ! run_to /usr/sbin/spctl --assess --type execute "$PRE"; then
        rm -rf "$PRE"
        fail "Gatekeeper rejected the update"
      fi
    fi

    if ! mv "$TARGET" "$OLD"; then
      rm -rf "$PRE"
      fail "cannot move the old app aside"
    fi
    if ! mv "$PRE" "$TARGET"; then
      echo "$(date) helper: swap failed; restoring the previous app"
      rm -rf "$TARGET"
      if ! mv "$OLD" "$TARGET"; then
        fail "RESTORE FAILED — previous app is at $OLD"
      fi
      rm -rf "$PRE"
      fail "swap failed; previous app restored"
    fi
    rm -rf "$OLD" "$STAGED"
    echo "$(date) helper: installed $TARGET"
    if [ "$RELAUNCH" = "1" ]; then
      if ! /usr/bin/open "$TARGET"; then
        fail "update installed but relaunch failed"
      fi
    fi
    exit 0
    """

    // MARK: - Launch housekeeping

    /// Adopts a staged update left by a previous run (downloaded, then the
    /// user quit without restarting) and deletes everything else in the
    /// updates folder.
    func resumeOrCleanOnLaunch() {
        workQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: Self.updatesDirectory, includingPropertiesForKeys: nil)
            else { return }
            let current = UpdateChecker.currentVersion
            let canInstall = Self.canInstallInPlace
            let config = AppConfig.shared
            var adopted: (version: String, url: URL)?
            for entry in entries {
                let name = entry.lastPathComponent
                if name == "install.log" { continue }
                if canInstall, let current,
                   name.hasPrefix("Velora-"), entry.pathExtension == "app" {
                    let version = String(name.dropFirst("Velora-".count).dropLast(".app".count))
                    if UpdateChecker.isNewer(version, than: current),
                       UpdatePromptPolicy.allowsAutomaticAction(
                            version: version,
                            skippedVersion: config.skippedUpdateVersion,
                            deferredVersion: config.deferredUpdateVersion,
                            deferredUntil: config.deferredUpdateUntil),
                       UpdateChecker.isNewer(version, than: adopted?.version ?? current),
                       Self.verifyStagedApp(at: entry, expectedVersion: version) == nil {
                        if let previous = adopted { try? fm.removeItem(at: previous.url) }
                        adopted = (version, entry)
                        continue
                    }
                }
                try? fm.removeItem(at: entry)
            }
            guard let adopted else { return }
            veloraLog("Velora: found verified staged update \(adopted.version) from a previous run")
            DispatchQueue.main.async {
                let config = AppConfig.shared
                // A download/verification that started while launch adoption
                // was checking may now own this version's staging path. Leave
                // cleanup to that pipeline (or the next launch) rather than
                // deleting bytes out from under it.
                guard case .idle = self.state else { return }
                guard UpdatePromptPolicy.allowsAutomaticAction(
                        version: adopted.version,
                        skippedVersion: config.skippedUpdateVersion,
                        deferredVersion: config.deferredUpdateVersion,
                        deferredUntil: config.deferredUpdateUntil)
                else {
                    // Skip/Later may have been chosen while the slow
                    // signature/Gatekeeper pass above was in flight. Do not
                    // publish stale ready state or leave the suppressed bundle.
                    self.workQueue.async {
                        try? FileManager.default.removeItem(at: adopted.url)
                    }
                    return
                }
                self.state = .ready(version: adopted.version)
            }
        }
    }

    // MARK: - Shell

    /// Runs a tool to completion with a hang guard — a wedged hdiutil/spctl
    /// must land the updater in .failed (retryable), never freeze it in
    /// .verifying forever.
    private static func run(
        _ tool: String, _ args: [String], timeout: TimeInterval = 180
    ) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        var data = Data()
        let readDone = DispatchSemaphore(value: 0)
        Thread {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }.start()
        if readDone.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            if readDone.wait(timeout: .now() + 5) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = readDone.wait(timeout: .now() + 5)
            }
            veloraLog("Velora: updater tool timed out — \(tool) \(args.joined(separator: " "))")
            return (-1, "timed out: \(tool)")
        }
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
