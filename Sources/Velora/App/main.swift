import AppKit

// Velora — open-source, local-first dictation for macOS.
// AppKit lifecycle (menubar accessory app); SwiftUI hosted where it shines
// (HUD, settings, onboarding). See docs/ARCHITECTURE.md.

// Headless test mode: CommandLineTools ships neither XCTest nor swift-testing,
// so the pure-logic tests are compiled in and run with
// `.build/release/Velora --selftest` (exits non-zero on failure).
if CommandLine.arguments.contains("--selftest") {
    exit(Selftest.run())
}

// Headless UI snapshots: renders HUD states + Settings panes to PNGs in the
// given directory (offscreen — nothing appears on the user's display).
if let snapshotIndex = CommandLine.arguments.firstIndex(of: "--snapshot"),
   CommandLine.arguments.count > snapshotIndex + 1 {
    SnapshotRenderer.run(outputDir: CommandLine.arguments[snapshotIndex + 1])
}

// The app binary doubles as the bundled headless CLI through its exact
// `Resources/bin/velora` symlink (or explicitly with --cli). Do this before
// NSApplication so renamed copies of the GUI binary still launch the app.
if VeloraCLI.shouldRun(arguments: CommandLine.arguments) {
    exit(VeloraCLI.run())
}

let migratedPreferenceCount = PreferencesDomainMigration.run()
if migratedPreferenceCount > 0 {
    NSLog("Velora: migrated %d preferences from the legacy bundle identifier",
          migratedPreferenceCount)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
