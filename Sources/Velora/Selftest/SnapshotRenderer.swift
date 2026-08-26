import AppKit
import SwiftUI

/// Headless UI snapshots: `Velora --snapshot <dir>` renders the HUD states and
/// every Settings pane to PNGs without needing Screen Recording permission —
/// the CLI-era answer to "open the screenshot before calling it done".
/// Windows are created but never ordered onto the screen; rendering goes
/// through `NSView.cacheDisplay`, so nothing flashes in front of the user.
enum SnapshotRenderer {
    static func run(outputDir: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        DispatchQueue.main.async {
            renderHUDStates(into: dir)
            renderSidebarRows(into: dir)
            renderUpdateWindow(into: dir)
            renderSettingsPanes(into: dir)
            renderMeetingNotes(into: dir) { exit(0) }
        }
        app.run()
        exit(1)  // app.run never returns; keep the signature honest
    }

    // MARK: - HUD

    @MainActor
    private static func renderHUDStates(into dir: URL) {
        let cases: [(String, HUDState)] = [
            ("hud-standby", .standby),
            ("hud-listening", .listening),
            ("hud-stream-preview", .listening),
            ("hud-listening-text", .listening),
            ("hud-listening-9m", .listening),
            ("hud-listening-10m", .listening),
            ("hud-listening-max", .listening),
            ("hud-listening-max-code", .listening),
            ("hud-listening-max-text", .listening),
            ("hud-listening-long-mode", .listening),
            ("hud-listening-hour", .listening),
            ("hud-listening-day", .listening),
            ("hud-meeting-suggestion", .meetingSuggestion(
                title: "Harshi Ko", source: "Google Meet")),
            ("hud-meeting-suggestion-long", .meetingSuggestion(
                title: "Quarterly product planning with the leadership team",
                source: "Microsoft Teams")),
            ("hud-meeting-end", .meetingEnd(title: "Harshi Ko")),
            ("hud-meeting", .meeting(title: "Design review", systemAudio: true)),
            ("hud-meeting-hour", .meeting(title: "Design review", systemAudio: true)),
            ("hud-meeting-mic-only", .meeting(title: "Design review", systemAudio: false)),
            ("hud-inserted", .inserted),
            ("hud-learned", .learned(wrong: "valora", right: "Velora")),
            ("hud-error", .error("Microphone disconnected")),
            ("hud-action-reading", .notice(
                symbol: "wand.and.stars",
                message: ActionProgress.readingScreen.hudMessage)),
            ("hud-action-planning", .notice(
                symbol: "wand.and.stars",
                message: ActionProgress.planning(turn: 2).hudMessage)),
            ("hud-action-verifying", .notice(
                symbol: "wand.and.stars",
                message: ActionProgress.verifyingTarget.hudMessage)),
            ("hud-action-executing", .notice(
                symbol: "wand.and.stars",
                message: ActionProgress.executing(
                    step: 2, total: 4, description: "Opening Shivangi Gupta").hudMessage)),
            ("hud-action-retrying", .notice(
                symbol: "wand.and.stars",
                message: ActionProgress.retrying("stale screen").hudMessage)),
            ("hud-action-result-verified", .actionResult(
                id: "action-verified",
                status: .verified,
                symbol: "paperplane.fill",
                message: "Sent Hi to Gaurav Singh Bissain",
                appName: "Slack")),
            ("hud-action-result-ready", .actionResult(
                id: "action-ready",
                status: .ready,
                symbol: "arrow.up.forward.app.fill",
                message: "Slack is ready",
                appName: "Slack")),
            ("hud-action-result-unverified", .actionResult(
                id: "action-unverified",
                status: .unverified,
                symbol: "paperplane.fill",
                message: "Could not verify the recipient",
                appName: "Slack")),
            ("hud-action-failed", .error("The selected conversation changed")),
        ]
        for (name, state) in cases {
            let model = HUDModel()
            model.state = state
            model.edge = .trailing
            if name == "hud-action-failed" {
                model.retryTitle = "Retry Action"
                model.onRetry = {}
            }
            if state == .listening {
                let elapsed: TimeInterval
                switch name {
                case "hud-listening-text": elapsed = 5
                case "hud-listening-9m": elapsed = 599
                case "hud-listening-10m": elapsed = 600
                case "hud-listening-max",
                     "hud-listening-max-code",
                     "hud-listening-max-text",
                     "hud-listening-long-mode":
                    elapsed = 3_599
                case "hud-listening-hour": elapsed = 3_723
                case "hud-listening-day": elapsed = 86_400
                default: elapsed = 15
                }
                model.recordingStart = Date(timeIntervalSinceNow: -elapsed)
                let context: (appPath: String, modeName: String)
                switch name {
                case "hud-listening-text":
                    context = ("/Applications/ChatGPT.app", "Text")
                case "hud-listening-max-code":
                    context = ("/Applications/Xcode.app", "Code")
                case "hud-listening-max-text":
                    context = ("/System/Applications/TextEdit.app", "Text")
                case "hud-listening-long-mode":
                    context = (
                        "/System/Applications/Utilities/Terminal.app",
                        "A Very Long Custom Mode Name")
                default:
                    context = (
                        "/System/Applications/Utilities/Terminal.app",
                        "Terminal")
                }
                let appIcon = name == "hud-listening-text"
                    ? NSRunningApplication.runningApplications(
                        withBundleIdentifier: "com.openai.codex").first?.icon
                    : nil
                model.sessionContext = HUDSessionContext(
                    appIcon: appIcon
                        ?? NSWorkspace.shared.icon(forFile: context.appPath),
                    modeName: name == "hud-stream-preview"
                        ? "Stream Preview" : context.modeName,
                    livePreview: name == "hud-stream-preview")
                if name == "hud-stream-preview" {
                    model.liveTranscript =
                        "Let's meet at 6 p.m. and review the launch notes."
                }
            }
            if case .meeting = state {
                model.recordingStart = Date(
                    timeIntervalSinceNow: name == "hud-meeting-hour" ? -14_400 : -372)
            }
            // Force the exact light-appearance case that previously washed the
            // glass HUD out over pale Terminal and browser backgrounds.
            let view = NSHostingView(
                rootView: ZStack {
                    // Simulate the pale Terminal/browser surface from the
                    // reported regression; a transparent offscreen window can
                    // otherwise render black on a dark-system Mac.
                    Color(red: 0.95, green: 0.94, blue: 0.91)
                    HUDView(model: model)
                }
                .environment(\.colorScheme, .light)
            )
            snapshot(view, size: HUDPanel.panelSize, name: name, dir: dir)
        }
    }

    // MARK: - Update window

    @MainActor
    private static func renderUpdateWindow(into dir: URL) {
        renderUpdateWindow(
            state: .idle, userRequestedInstall: false,
            name: "software-update", into: dir)
        renderUpdateWindow(
            state: .downloading(version: "9.9.9", progress: 0.42),
            userRequestedInstall: false,
            name: "software-update-auto-downloading", into: dir)
        renderUpdateWindow(
            state: .ready(version: "9.9.9"),
            userRequestedInstall: true,
            name: "software-update-waiting", into: dir)
    }

    @MainActor
    private static func renderUpdateWindow(
        state: UpdateInstaller.State,
        userRequestedInstall: Bool,
        name: String,
        into dir: URL
    ) {
        let model = UpdateWindowModel(
            installBlockerOverride: nil, usesInstallBlockerOverride: true)
        model.present(sampleUpdateRelease)
        model.configureSnapshot(
            installerState: state,
            userRequestedInstall: userRequestedInstall)
        let view = NSHostingView(rootView: UpdateWindowView(model: model))
        snapshot(
            view, size: NSSize(width: 760, height: 600),
            name: name, dir: dir)
    }

    private static var sampleUpdateRelease: UpdateChecker.Release {
        UpdateChecker.Release(
            version: "9.9.9",
            page: URL(string: "https://github.com/sushilk1991/velora/releases/tag/v9.9.9")!,
            notes: """
            ## Features & Improvements

            - Added a complete release-notes window for every update.
            - Install Update now downloads, verifies, installs, and relaunches in one step.

            ## Fixes

            - Removed the duplicate Install or Discard decision after verification.
            - Added version-scoped Skip and Remind Me Later controls.
            """,
            publishedAt: Date(timeIntervalSince1970: 1_775_000_000),
            asset: .init(
                name: "Velora-9.9.9.dmg",
                url: URL(string: "https://github.com/sushilk1991/velora/releases/download/v9.9.9/Velora-9.9.9.dmg")!,
                size: 42))
    }

    // MARK: - Sidebar rows

    /// The sidebar's vibrancy (NSVisualEffectView) doesn't survive offscreen
    /// cacheDisplay, so the REAL rows (`SettingsSidebarRow`, selection
    /// included) are also rendered in a plain context where every pixel is
    /// faithful — this is the proof the selected state actually draws.
    @MainActor
    private static func renderSidebarRows(into dir: URL) {
        let selection = SettingsWindowSelection()
        selection.tab = .dictation  // mid-list, so one selected row is visible
        let rows = VStack(alignment: .leading, spacing: VeloraSpacing.l) {
            ForEach(Array(SettingsTab.sidebarGroups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(group) { tab in
                        SettingsSidebarRow(tab: tab, selection: selection)
                    }
                }
            }
        }
        .padding(VeloraSpacing.m)
        .frame(width: 215)
        .background(Color(nsColor: .windowBackgroundColor))
        let view = NSHostingView(rootView: rows)
        snapshot(view, size: NSSize(width: 215, height: 480), name: "settings-sidebar-rows", dir: dir)
    }

    // MARK: - Settings

    @MainActor
    private static func renderSettingsPanes(into dir: URL) {
        let history = HistoryStore()
        let dictionary = DictionaryRepository()
        let sync = ICloudDictionarySync(repository: dictionary)
        let meetings = MeetingStore()
        let supervisor = EngineSupervisor()  // never started — status stays idle
        let processor = MeetingProcessor(supervisor: supervisor, store: meetings)
        let coordinator = MeetingCoordinator(
            store: meetings, processor: processor, sounds: SoundPlayer(),
            foregroundBusy: { true })
        let model = SettingsModel(
            supervisor: nil, dictionary: dictionary, dictionarySync: sync)
        model.updateCheckStatus =
            "Velora \(VeloraAppInfo.shortVersion) is up to date."
        NSLog("Velora: snapshot prefs — config.alwaysVisible=%d model.alwaysVisible=%d position=%@",
              AppConfig.shared.hudAlwaysVisible ? 1 : 0,
              model.hudAlwaysVisible ? 1 : 0,
              model.hudPosition.rawValue)
        let selection = SettingsWindowSelection()
        let root = SettingsRootView(
            model: model, selection: selection, supervisor: nil,
            history: history, meetings: meetings,
            meetingCoordinator: coordinator, meetingProcessor: processor)

        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        // Mirror the production shell (SettingsWindowController) — a default
        // window would hide layout regressions the custom chrome can introduce
        // (review finding; `.fullSizeContentView` died exactly here). One
        // deliberate exception: `titlebarAppearsTransparent` stays OFF —
        // it switches the window to backdrop-material compositing, which
        // offscreen cacheDisplay renders as an all-white detail column
        // (bisected). The flag only affects the titlebar strip, which these
        // contentView snapshots exclude anyway.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 820, height: 620))

        // Deterministic panes regardless of the user's persisted sidebar
        // state; the flag round-trips through AppConfig (selection persists
        // it), so the user's own value is restored at the end.
        let userCollapsed = selection.sidebarCollapsed
        selection.sidebarCollapsed = false

        for tab in SettingsTab.allCases {
            selection.tab = tab
            // Give SwiftUI a few runloop turns to swap the detail pane and run
            // its async onAppear loads before drawing.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
            guard let content = window.contentView else { continue }
            content.layoutSubtreeIfNeeded()
            write(view: content, to: dir.appendingPathComponent("settings-\(tab.rawValue).png"))
        }

        // The collapsed icon rail, once.
        selection.tab = .general
        selection.sidebarCollapsed = true
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
        if let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            write(view: content, to: dir.appendingPathComponent("settings-general-collapsed.png"))
        }
        selection.sidebarCollapsed = userCollapsed
    }

    @MainActor
    private static func renderMeetingNotes(
        into dir: URL, completion: @escaping () -> Void
    ) {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-meeting-snapshot-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingStore(
            url: fixtureRoot.appendingPathComponent("meetings.sqlite3"),
            filesRoot: fixtureRoot)
        let id = UUID().uuidString
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        store.insertProcessing(MeetingRecord(
            id: id, title: "Product review", startedAt: started,
            endedAt: started.addingTimeInterval(2_400), sourceApp: "Slack Huddle",
            status: .processing))
        store.appendSegment(MeetingSegment(
            meetingID: id, speaker: .me, chunkIndex: 0,
            startMs: 0, endMs: 30_000,
            text: "I will prepare the implementation plan."))
        store.appendSegment(MeetingSegment(
            meetingID: id, speaker: .them, chunkIndex: 0,
            startMs: 2_000, endMs: 32_000,
            text: "Please include the acceptance criteria."))
        store.complete(meetingID: id, notes: MeetingNotes(
            summary: "The review aligned on a focused implementation plan and clear acceptance criteria.",
            decisions: ["Keep the experience local and single-player"],
            actionItems: ["Me: prepare the implementation plan"]))

        let model = MeetingNotesWindowModel(store: store)
        model.show(meetingID: id)
        let deadline = Date().addingTimeInterval(2)
        func renderWhenLoaded() {
            guard model.record != nil || Date() >= deadline else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    renderWhenLoaded()
                }
                return
            }
            let view = NSHostingView(rootView: MeetingNotesWindowView(model: model))
            snapshot(
                view, size: NSSize(width: 760, height: 680),
                name: "meeting-notes-focused", dir: dir)
            try? FileManager.default.removeItem(at: fixtureRoot)
            completion()
        }
        renderWhenLoaded()
    }

    // MARK: - Rendering

    @MainActor
    private static func snapshot(_ view: NSView, size: NSSize, name: String, dir: URL) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .windowBackgroundColor
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        view.layoutSubtreeIfNeeded()
        write(view: view, to: dir.appendingPathComponent("\(name).png"))
    }

    @MainActor
    private static func write(view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("Velora: snapshot failed for %@ (no bitmap rep)", url.lastPathComponent)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        NSLog("Velora: snapshot wrote %@", url.path)
    }
}
