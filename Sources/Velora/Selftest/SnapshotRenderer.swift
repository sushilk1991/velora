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
            renderSettingsPanes(into: dir)
            exit(0)
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
            ("hud-inserted", .inserted),
            ("hud-error", .error("Microphone disconnected")),
        ]
        for (name, state) in cases {
            let model = HUDModel()
            model.state = state
            model.edge = .trailing
            if state == .listening {
                model.recordingStart = Date(timeIntervalSinceNow: -6)
                model.sessionContext = HUDSessionContext(
                    appIcon: NSWorkspace.shared.icon(
                        forFile: "/System/Applications/Utilities/Terminal.app"),
                    modeName: "Terminal")
            }
            let view = NSHostingView(rootView: HUDView(model: model))
            snapshot(view, size: HUDPanel.panelSize, name: name, dir: dir)
        }
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
        snapshot(view, size: NSSize(width: 215, height: 420), name: "settings-sidebar-rows", dir: dir)
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
        window.setContentSize(NSSize(width: 820, height: 620))

        for tab in SettingsTab.allCases {
            selection.tab = tab
            // Give SwiftUI a few runloop turns to swap the detail pane and run
            // its async onAppear loads before drawing.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
            guard let content = window.contentView else { continue }
            content.layoutSubtreeIfNeeded()
            write(view: content, to: dir.appendingPathComponent("settings-\(tab.rawValue).png"))
        }
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
