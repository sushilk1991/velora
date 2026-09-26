import AppKit
import SwiftUI

/// Dev-only real-window captures: `Velora --window-snapshot <dir>` puts the
/// production shell windows, onboarding and the HUD pill ON SCREEN, captures
/// each with `screencapture -l`, and orders it out again. It shows what
/// `--snapshot`'s offscreen `cacheDisplay` cannot draw: traffic lights,
/// toolbar safe areas, glass and vibrancy.
///
///     --window-snapshot dir
///       └ re-exec in place with CFFIXED_USER_HOME=<scratch>   ~/.velora → fixtures
///                           and VELORA_SCRATCH_DEFAULTS       defaults → <scratch>/defaults
///           └ per shot: orderFrontRegardless → settle → screencapture → orderOut
///
/// The app is never activated (grey traffic lights, no Dock icon, no menu
/// bar), and no engine, hotkey, or status item is started. The launching
/// shell needs Screen Recording. The binary embeds the app's Info.plist, so
/// `.standard` would be the installed app's defaults domain: the re-exec'd
/// process swaps AppConfig onto an absolute-path suite inside the scratch
/// home. Debug builds only, and after the exec the process refuses any home
/// but a fresh one it made itself before the exec (`isHarnessHome`), so
/// caller-set variables cannot point the fixtures at the live stores.
///
/// The scratch-home gate (`enterScratchHome` and its helpers) compiles in
/// every build: `--selftest` runs behind it in debug and release.
enum WindowSnapshot {
    private static let homeKey = "VELORA_WINDOW_SNAPSHOT_HOME"
    private static let homePrefix = "velora-window-snapshot-"
    /// Written into the scratch home before the exec: the pid, which execv
    /// keeps.
    private static let markerName = ".velora-window-snapshot"
    /// This run's scratch home once it checks out; removed at exit.
    private static var scratchHome: URL?
    #if DEBUG
    /// Enough for SwiftUI to swap panes and run their async loads.
    private static let settle: Duration = .milliseconds(900)
    private static let mainSizes = [
        NSSize(width: 980, height: 640),
        NSSize(width: 1180, height: 760),
        NSSize(width: 1600, height: 1000),
    ]
    /// MainWindowController's minimum; the last main shot asks for less.
    private static let mainMinimum = NSSize(width: 960, height: 620)
    private static let belowMinimum = NSSize(width: 500, height: 400)
    private static let settingsSize = NSSize(width: 780, height: 640)

    static func run(outputDir: String) -> Never {
        enterScratchHome(label: "window-snapshot")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            await shootAll(into: dir)
            exit(0)
        }
        app.run()
        exit(1)  // app.run never returns
    }
    #endif

    // Shared gate: internal so both dev harnesses run behind it,
    // `--window-snapshot` (`run` above) and `--snapshot`
    // (`SnapshotRenderer.run`), and `--selftest` (main.swift).
    /// Puts this command in a scratch home before anything touches
    /// ~/.velora or the defaults. The process re-execs itself in place there
    /// with the same arguments; execv keeps the pid, process group and
    /// signal routing, so killing the launched pid stops the run and its exit
    /// status is the command's own. After the exec it returns once its home
    /// and defaults suite check out, and exits 2 otherwise. `label` starts
    /// each message ("window-snapshot: …").
    ///
    ///     launch (no homeKey) ── make + mark home ── setenv ── execv ─┐
    ///     same pid (homeKey set) ◀────────────────────────────────────┘
    ///       └ validate ── atexit(remove home) ── return to the command
    static func enterScratchHome(label: String) {
        guard let home = ProcessInfo.processInfo.environment[homeKey] else {
            exit(relaunchInScratchHome(label: label))
        }

        // CFFIXED_USER_HOME must have redirected ~ to a fresh home this
        // process made before its exec, and the defaults suite must live
        // inside it, before anything touches ~/.velora; otherwise stop rather
        // than seed the live stores.
        let homeURL = URL(fileURLWithPath: home)
        let resolvedHome = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let expectedDefaults = homeURL.appendingPathComponent("defaults").path
        guard isHarnessHome(
                homeURL, realHome: realHome,
                temporaryDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                ownerPID: getpid()),
              resolvedHome.path == homeURL.resolvingSymlinksInPath().path,
              ProcessInfo.processInfo.environment[AppConfig.scratchDefaultsKey] == expectedDefaults else {
            print("\(label): home is \(resolvedHome.path), not a scratch home this harness made; refusing")
            exit(2)
        }

        // Nothing outlives the process to clean up after it, so the run
        // removes its own home on any `exit`, failing tests included. A
        // signal or crash leaves it in $TMPDIR.
        scratchHome = homeURL
        atexit {
            WindowSnapshot.removeScratchHome()
        }
    }

    /// Re-execs this binary in place with ~ pointed at a fresh scratch
    /// directory. Returns only when that fails, after removing the directory:
    /// 2 when a variable cannot be set (without `homeKey` the new image
    /// would re-exec again, leaking a home per pass), 1 otherwise.
    private static func relaunchInScratchHome(label: String) -> Int32 {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(homePrefix)\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            try makeScratchHome(at: home)
            seedModes(intoHome: home)
            guard let executable = Bundle.main.executablePath else {
                throw CocoaError(.executableNotLoadable)
            }

            let variables = [
                ("CFFIXED_USER_HOME", home.path),
                (homeKey, home.path),
                (AppConfig.scratchDefaultsKey, home.appendingPathComponent("defaults").path),
            ]
            for (name, value) in variables {
                guard setenv(name, value, 1) == 0 else {
                    print("\(label): could not set \(name): \(String(cString: strerror(errno))); refusing")
                    return 2
                }
            }

            execv(executable, CommandLine.unsafeArgv)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOEXEC)
        } catch {
            print("\(label): \(error)")
            return 1
        }
    }

    /// Removes this run's scratch home at exit, after checking again that
    /// this process made it: cleanup must never delete anything else.
    private static func removeScratchHome() {
        guard let home = scratchHome,
              ownsHome(
                home, realHome: realHome,
                temporaryDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                ownerPID: getpid()) else {
            return
        }

        try? FileManager.default.removeItem(at: home)
    }

    /// Creates an empty scratch home and marks it with this process's pid,
    /// which the process checks against its own after the exec.
    static func makeScratchHome(at home: URL) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        try String(getpid()).write(
            to: home.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
    }

    /// Whether `home` is a scratch home made for this run before its exec:
    /// one `ownsHome` accepts, and fresh, with nothing under `.velora` but
    /// the seeded modes.
    ///
    ///     $TMPDIR/velora-window-snapshot-<uuid>/
    ///       .velora-window-snapshot   "<owner pid>"
    ///       .velora/modes/            seeded built-ins only
    static func isHarnessHome(
        _ home: URL, realHome: URL, temporaryDirectory: URL, ownerPID: pid_t
    ) -> Bool {
        guard ownsHome(
                home, realHome: realHome, temporaryDirectory: temporaryDirectory,
                ownerPID: ownerPID) else {
            return false
        }

        let velora = (try? FileManager.default.contentsOfDirectory(
            atPath: home.standardizedFileURL.resolvingSymlinksInPath()
                .appendingPathComponent(".velora").path)) ?? []
        return velora.allSatisfy { $0 == "modes" }
    }

    /// Whether `ownerPID` marked `home` as its scratch home: a
    /// `velora-window-snapshot-*` directory directly inside the temporary
    /// directory, not the real home. Exit cleanup re-checks this, without
    /// freshness, before deleting anything.
    private static func ownsHome(
        _ home: URL, realHome: URL, temporaryDirectory: URL, ownerPID: pid_t
    ) -> Bool {
        let home = home.standardizedFileURL.resolvingSymlinksInPath()
        guard home.path != realHome.standardizedFileURL.resolvingSymlinksInPath().path else {
            return false
        }

        let temporary = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard home.deletingLastPathComponent().path == temporary.path,
              home.lastPathComponent.hasPrefix(homePrefix) else {
            return false
        }

        let marker = try? String(
            contentsOf: home.appendingPathComponent(markerName), encoding: .utf8)
        return marker == String(ownerPID)
    }

    /// The account's home from the user database; CFFIXED_USER_HOME
    /// redirects every Foundation home lookup.
    static var realHome: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return URL(fileURLWithPath: NSHomeDirectory())
        }

        return URL(fileURLWithPath: String(cString: directory))
    }

    /// Copies the repo's built-in modes into the scratch ~/.velora/modes, as
    /// the engine would on first launch, so the Modes pane is not empty.
    private static func seedModes(intoHome home: URL) {
        guard let root = ResourceLocator.repoRoot else { return }
        let source = root.appendingPathComponent("engine/src/velora_engine/modes_builtin")
        let target = home.appendingPathComponent(".velora/modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            try? FileManager.default.copyItem(
                at: file, to: target.appendingPathComponent(file.lastPathComponent))
        }
    }

    #if DEBUG
    // MARK: - Shots

    @MainActor
    private static func shootAll(into dir: URL) async {
        // Same store graph as `--snapshot`, but every default URL now
        // resolves inside the scratch home.
        let history = HistoryStore()
        SnapshotRenderer.seedFixtureHistory(history)
        let meetings = MeetingStore()
        SnapshotRenderer.seedFixtureMeeting(meetings)
        // An explicit device id: the default one lives in `.standard`.
        let dictionary = DictionaryRepository(deviceID: "window-snapshot")
        SnapshotRenderer.seedFixtureDictionary(dictionary)
        let sync = ICloudDictionarySync(repository: dictionary)
        let supervisor = EngineSupervisor()  // never started
        let processor = MeetingProcessor(supervisor: supervisor, store: meetings)
        let coordinator = MeetingCoordinator(
            store: meetings, processor: processor, sounds: SoundPlayer(),
            foregroundBusy: { true })
        let model = SettingsModel(supervisor: nil, dictionary: dictionary, dictionarySync: sync)

        // VELORA_WINDOW_SNAPSHOT_ONLY=hud|main|settings|onboarding shoots
        // one group, for quick before/after pairs.
        let only = ProcessInfo.processInfo.environment["VELORA_WINDOW_SNAPSHOT_ONLY"]
        func wants(_ group: String) -> Bool { only == nil || only == group }

        if wants("hud") {
            await shootHUD(into: dir)
        }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            if wants("main") {
                await shootMain(
                    model: model, history: history, meetings: meetings,
                    coordinator: coordinator, processor: processor,
                    suffix: suffix, into: dir)
            }
            if wants("settings") {
                await shootSettings(model: model, coordinator: coordinator, suffix: suffix, into: dir)
            }
            if wants("onboarding") {
                await shootOnboarding(suffix: suffix, into: dir)
            }
        }
    }

    /// Every pane at every size, built exactly as `MainWindowController`
    /// builds its window, then a shrink back to the smallest size and one
    /// below the minimum.
    @MainActor
    private static func shootMain(
        model: SettingsModel, history: HistoryStore, meetings: MeetingStore,
        coordinator: MeetingCoordinator, processor: MeetingProcessor,
        suffix: String, into dir: URL
    ) async {
        let selection = MainWindowSelection()
        let actions = MainWindowActions(
            toggleDictation: {}, startMeeting: {}, openSettings: {},
            openMeetingNotes: { _ in })
        let root = MainRootView(
            model: model, selection: selection, supervisor: nil,
            history: history, meetings: meetings,
            meetingCoordinator: coordinator, meetingProcessor: processor,
            actions: actions)
        let window = MainWindowController.makeShellWindow(
            rootView: root, title: "Velora", size: mainSizes[0], minimumSize: mainMinimum)
        for size in mainSizes {
            window.setContentSize(size)
            window.center()
            for pane in MainPane.allCases {
                selection.pane = pane
                let name = "main-\(pane.rawValue)-\(Int(size.width))x\(Int(size.height))-\(suffix)"
                await shoot(window, name: name, into: dir)
            }

            // One mode's editor: the open request lands when the Modes pane
            // is rebuilt, hence the hop through Home.
            selection.pane = .home
            await Task.yield()
            ModesViewModel.requestOpen("Code")
            selection.pane = .modes
            let editor = "main-modes-editor-\(Int(size.width))x\(Int(size.height))-\(suffix)"
            await shoot(window, name: editor, into: dir)
        }
        selection.pane = .home
        window.setContentSize(mainSizes[0])
        await shoot(window, name: "main-home-resized-back-\(suffix)", into: dir)

        // Home's dictation button while listening, then while writing up.
        actions.dictation.phase = .recording(locked: true)
        await shoot(window, name: "main-home-dictating-\(suffix)", into: dir)
        actions.dictation.phase = .transcribing
        await shoot(window, name: "main-home-transcribing-\(suffix)", into: dir)
        actions.dictation.phase = .idle

        window.setContentSize(belowMinimum)
        await shoot(window, name: "main-home-below-minimum-\(suffix)", into: dir)
    }

    @MainActor
    private static func shootSettings(
        model: SettingsModel, coordinator: MeetingCoordinator,
        suffix: String, into dir: URL
    ) async {
        let selection = SettingsWindowSelection()
        let root = SettingsRootView(
            model: model, selection: selection,
            meetingCoordinator: coordinator, openSetupAssistant: {})
        let window = MainWindowController.makeShellWindow(
            rootView: root, title: "Settings", size: settingsSize, minimumSize: settingsSize)
        for tab in SettingsTab.allCases {
            selection.tab = tab
            await shoot(window, name: "settings-\(tab.rawValue)-\(suffix)", into: dir)
        }
    }

    /// The production onboarding window with a harness-owned model, so the
    /// step can be set without `show()` activating the app. Input
    /// Monitoring is skipped: its onAppear fires the system TCC prompt.
    @MainActor
    private static func shootOnboarding(suffix: String, into dir: URL) async {
        let controller = OnboardingWindowController()
        guard let window = controller.window else { return }
        for step in OnboardingModel.Step.allCases where step != .inputMonitoring {
            let model = OnboardingModel()
            model.step = step
            window.contentView = NSHostingView(rootView: OnboardingView(model: model))
            await shoot(window, name: "onboarding-\(step)-\(suffix)", into: dir)
        }
    }

    /// The real `HUDPanel` driven through a dictation: listening with a
    /// moving waveform, polishing, then inserted mid-morph and settled.
    @MainActor
    private static func shootHUD(into dir: URL) async {
        // Bottom-left keeps the harness pill off the installed app's
        // default bottom-right pill (scratch config only).
        AppConfig.shared.hudPosition = .bottomLeft
        let hud = HUDPanel()
        hud.model.beginSession(context: HUDSessionContext(
            appIcon: NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app"),
            modeName: "Notes", livePreview: false))
        hud.model.recordingStart = Date(timeIntervalSinceNow: -12)
        var phase = 0.0
        let levels = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            phase += 0.2
            hud.model.levels.push((0..<WaveformLevelStore.halfCount).map { band in
                Float(0.35 + 0.3 * sin(phase + Double(band) * 0.7))
            })
        }
        RunLoop.main.add(levels, forMode: .common)
        defer { levels.invalidate() }

        // Launch order, as AppDelegate does it: the hosting view renders its
        // hidden state before the first transition. Transitioning in the
        // same turn as init skips HUDView's onChange and leaves the pill
        // transparent.
        try? await Task.sleep(for: settle)
        hud.applyPreferences()
        guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) else {
            print("window-snapshot: HUD panel not on screen")
            return
        }
        try? await Task.sleep(for: settle)
        capture(panel, name: "hud-standby", into: dir)
        hud.transition(to: .listening)
        try? await Task.sleep(for: settle)
        capture(panel, name: "hud-listening", into: dir)
        hud.transition(to: .transcribing)
        try? await Task.sleep(for: settle)
        capture(panel, name: "hud-processing", into: dir)
        hud.transition(to: .inserted)
        try? await Task.sleep(for: .milliseconds(80))
        capture(panel, name: "hud-inserted-flash", into: dir)
        try? await Task.sleep(for: .milliseconds(170))
        capture(panel, name: "hud-inserted-morph", into: dir)
        try? await Task.sleep(for: settle)
        capture(panel, name: "hud-inserted", into: dir)
        panel.orderOut(nil)
    }

    // MARK: - Capture

    @MainActor
    private static func shoot(_ window: NSWindow, name: String, into dir: URL) async {
        window.orderFrontRegardless()
        try? await Task.sleep(for: settle)
        capture(window, name: name, into: dir)
        window.orderOut(nil)
    }

    /// `screencapture -l` grabs this one window at the display's scale,
    /// without its shadow (`-o`), wherever other windows overlap it.
    @MainActor
    private static func capture(_ window: NSWindow, name: String, into dir: URL) {
        let path = dir.appendingPathComponent("\(name).png").path
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        tool.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        try? tool.run()
        tool.waitUntilExit()

        // A locked screen or asleep display gives screencapture no image.
        // Draw the content view instead: no traffic lights, glass or
        // vibrancy, but layout, type and symbols still show.
        var source = ""
        if !FileManager.default.fileExists(atPath: path) {
            renderOffscreen(window, to: path)
            source = " (offscreen: screen unavailable)"
        }
        print("window-snapshot \(name) id \(window.windowNumber) \(trafficLights(window))\(source)")
    }

    @MainActor
    private static func renderOffscreen(_ window: NSWindow, to path: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// The close button in window points, y down from the top edge — the
    /// numbers to hold against the rail corner and the pane title.
    @MainActor
    private static func trafficLights(_ window: NSWindow) -> String {
        guard let close = window.standardWindowButton(.closeButton),
              let container = close.superview,
              !close.isHidden else {
            return "size \(window.frame.size)"
        }
        let frame = container.convert(close.frame, to: nil)
        let height = window.frame.height
        return String(
            format: "size %.0fx%.0f close x %.1f top %.1f midY %.1f",
            window.frame.width, height, frame.minX, height - frame.maxY, height - frame.midY)
    }
    #endif
}
