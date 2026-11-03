import AppKit

// Velora — open-source, local-first dictation for macOS.
// AppKit lifecycle (menubar accessory app); SwiftUI hosted where it shines
// (HUD, settings, onboarding). See docs/ARCHITECTURE.md.

// The DMG build (make-app.sh with VELORA_DISTRIBUTION=1) compiles out the
// test harness in Sources/Velora/Selftest. Its flags exit with usage there
// rather than falling through to launch the app.
#if VELORA_DISTRIBUTION
func exitHarnessUnavailable(_ flag: String) -> Never {
    FileHandle.standardError.write(Data(
        "Velora: \(flag) is not in distribution builds; rebuild without VELORA_DISTRIBUTION (swift build, or ./scripts/make-app.sh release none) and run that\n".utf8))
    exit(EX_USAGE)
}
#endif

// Headless test mode: CommandLineTools ships neither XCTest nor swift-testing,
// so the pure-logic tests are compiled in and run with
// `.build/release/Velora --selftest` (exits non-zero on failure). Runs in
// the snapshot harnesses' scratch home and defaults suite, debug and release
// alike (every build but the DMG): tests that write AppConfig.shared (the
// pill's visibility) must never reach the owner's settings.json, even when a
// run is killed mid-test. The gate re-execs in place, so the launched pid is
// the run: its signals and exit status are the tests'.
if CommandLine.arguments.contains("--selftest") {
    #if VELORA_DISTRIBUTION
    exitHarnessUnavailable("--selftest")
    #else
    WindowSnapshot.enterScratchHome(label: "selftest")
    exit(Selftest.run())
    #endif
}

// Real bundled-engine integration must enter its fresh home before any
// preferences or lifecycle objects are created. Never ship this fixture.
if let index = CommandLine.arguments.firstIndex(of: "--sandbox-e2e") {
    #if VELORA_DISTRIBUTION
    exitHarnessUnavailable("--sandbox-e2e")
    #else
    guard CommandLine.arguments.count > index + 2 else {
        print("usage: Velora --sandbox-e2e <speech.wav> <report.json>")
        exit(EX_USAGE)
    }
    exit(DictationE2E.run(audio: CommandLine.arguments[index + 1],
                         report: CommandLine.arguments[index + 2]))
    #endif
}

// Real-window design QA: shows the shell windows, onboarding and the pill on
// screen without activating, and captures each one. Debug builds only; runs
// in a scratch home before any path below can touch preferences. A missing
// directory exits with usage rather than launching the app, and a release
// build refuses the flag rather than launching the app on the user's data.
// See WindowSnapshot.
if let windowSnapshotIndex = CommandLine.arguments.firstIndex(of: "--window-snapshot") {
    #if DEBUG && !VELORA_DISTRIBUTION
    guard CommandLine.arguments.count > windowSnapshotIndex + 1 else {
        print("usage: Velora --window-snapshot <output-dir>")
        exit(EX_USAGE)
    }

    WindowSnapshot.run(outputDir: CommandLine.arguments[windowSnapshotIndex + 1])
    #else
    FileHandle.standardError.write(Data(
        "Velora: --window-snapshot needs a debug build; run .build/debug/Velora --window-snapshot <output-dir>\n".utf8))
    exit(EX_USAGE)
    #endif
}

// Headless UI snapshots: renders HUD states + Settings panes to PNGs in the
// given directory (offscreen — nothing appears on the user's display). Debug
// builds only, in --window-snapshot's scratch home, before any path below can
// touch preferences. A release build refuses the flag rather than launching
// the app on the user's data. See SnapshotRenderer.
if let snapshotIndex = CommandLine.arguments.firstIndex(of: "--snapshot") {
    #if DEBUG && !VELORA_DISTRIBUTION
    guard CommandLine.arguments.count > snapshotIndex + 1 else {
        print("usage: Velora --snapshot <output-dir>")
        exit(EX_USAGE)
    }

    SnapshotRenderer.run(outputDir: CommandLine.arguments[snapshotIndex + 1])
    #else
    FileHandle.standardError.write(Data(
        "Velora: --snapshot needs a debug build; run .build/debug/Velora --snapshot <output-dir>\n".utf8))
    exit(EX_USAGE)
    #endif
}

// Migrate before any headless path can instantiate AppConfig.shared and create
// settings.json from defaults. Selftest stays first so it never touches the
// user's preference domains.
let migratedPreferenceCount = PreferencesDomainMigration.run()
if migratedPreferenceCount > 0 {
    NSLog("Velora: migrated %d preferences from the legacy bundle identifier",
          migratedPreferenceCount)
}

// Updater end-to-end: check → download → verify → stage. With --install,
// start the real app lifecycle in a disposable bundle to test quit/relaunch.
// See UpdateE2E; point VELORA_UPDATE_FEED_URL at a local feed to drive.
if CommandLine.arguments.contains("--update-e2e") {
    exit(UpdateE2E.run(install: CommandLine.arguments.contains("--install")))
}

// Headless Stream Typing end-to-end: feeds a scripted partial sequence through
// the real StreamTypingSession against a real app window and reports what the
// target reported back. Needs Accessibility. See StreamE2E.
if let streamIndex = CommandLine.arguments.firstIndex(of: "--stream-e2e") {
    exit(StreamE2E.run(
        arguments: Array(CommandLine.arguments.dropFirst(streamIndex + 1))))
}

// Read-only Accessibility survey of the running apps for Action Mode design
// (tree sizes, settable attributes, background menu bars). Launch through
// `open -n` so the bundle's own Accessibility grant applies. See ActionAXProbe.
#if VELORA_DISTRIBUTION
if CommandLine.arguments.contains("--action-probe") {
    exitHarnessUnavailable("--action-probe")
}
#else
if let probeIndex = CommandLine.arguments.firstIndex(of: "--action-probe") {
    exit(ActionAXProbe.run(
        arguments: Array(CommandLine.arguments.dropFirst(probeIndex + 1))))
}
#endif

// The app binary doubles as the bundled headless CLI through its exact
// `Resources/bin/velora` symlink (or explicitly with --cli). Do this before
// NSApplication so renamed copies of the GUI binary still launch the app.
if VeloraCLI.shouldRun(arguments: CommandLine.arguments) {
    exit(VeloraCLI.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
