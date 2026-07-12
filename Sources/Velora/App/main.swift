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

let migratedPreferenceCount = PreferencesDomainMigration.run()
if migratedPreferenceCount > 0 {
    NSLog("Velora: migrated %d preferences from the legacy bundle identifier",
          migratedPreferenceCount)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
