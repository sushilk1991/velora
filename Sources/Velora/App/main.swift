import AppKit

// Velora — open-source, local-first dictation for macOS.
// AppKit lifecycle (menubar accessory app); SwiftUI hosted where it shines
// (HUD, settings, onboarding). See docs/ARCHITECTURE.md.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
