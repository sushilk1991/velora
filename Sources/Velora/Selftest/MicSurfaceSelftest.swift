// Test harness: compiled out of the DMG build (VELORA_DISTRIBUTION; see
// main.swift). Production code must not reference anything in Selftest/.
#if !VELORA_DISTRIBUTION
import AppKit
import Foundation

/// The two microphone surfaces a user meets before they dictate: the pill's
/// Microphone submenu (V-21) and the onboarding check card's diagnostics (V-30).
///
/// Everything here is a pure shape on purpose — the menu is data
/// (`HUDMicrophoneMenuBuilder`), the explanation is data
/// (`OnboardingMicDiagnostic`) and the level bar is arithmetic
/// (`OnboardingMicLevel`). No microphone is opened, no grant is required, and
/// the one AppKit check closes the window it creates.
enum MicSurfaceSelftest {
    static func run() {
        testMicrophoneMenuShape()
        testExclusionRules()
        testExclusionRoundTripsThroughSettings()
        testDiagnosticLine()
        testLevelMath()
        testPillMenuTopLevelUnchanged()
    }

    /// The shared failure counter. An alias rather than `extension Selftest`,
    /// so these tests stay in their own file while keeping call-site line
    /// numbers in the report.
    private static func expect(
        _ condition: Bool, _ message: String,
        file: String = #fileID, line: Int = #line
    ) {
        Selftest.expect(condition, message, file: file, line: line)
    }

    // MARK: - Fixtures

    private static func device(
        _ uid: String, _ name: String, id: UInt32 = 1, builtIn: Bool = false
    ) -> AudioInputDevices.Device {
        AudioInputDevices.Device(uid: uid, name: name, id: id, isBuiltIn: builtIn)
    }

    private static var builtIn: AudioInputDevices.Device {
        device("builtin", "MacBook Pro Microphone", id: 1, builtIn: true)
    }

    private static var airpods: AudioInputDevices.Device {
        device("airpods", "AirPods Pro", id: 2)
    }

    private static var studio: AudioInputDevices.Device {
        device("usb", "Studio Mic", id: 3)
    }

    // MARK: - V-21: the Microphone submenu

    private static func testMicrophoneMenuShape() {
        // Nothing chosen, system default resolving to the built-in mic: the
        // exclude action names the device that will actually be opened.
        let defaultPlan = HUDMicrophoneMenuBuilder.plan(
            devices: [builtIn, airpods], chosenUID: nil,
            excludedUIDs: [], resolvedUID: "builtin")
        expect(defaultPlan.rows.first?.kind == .systemDefault
                && defaultPlan.rows.first?.state == true,
               "System Default leads the submenu and is checked when nothing is chosen")
        expect(defaultPlan.rows.contains(where: { $0.kind == .device(uid: "builtin") }),
               "every connected microphone has a row")
        let excludeRow = defaultPlan.rows.last
        expect(excludeRow?.kind == .exclude(uid: "builtin")
                && excludeRow?.title == "Exclude MacBook Pro Microphone",
               "the exclude action names the resolved microphone (got \(excludeRow?.title ?? "none"))")
        expect(defaultPlan.excludedRows.isEmpty,
               "nothing is excluded, so there is no excluded group")

        // An explicit pick: the pick is checked and the exclude action follows
        // the user's choice, not the system default.
        let chosenPlan = HUDMicrophoneMenuBuilder.plan(
            devices: [builtIn, airpods], chosenUID: "airpods",
            excludedUIDs: [], resolvedUID: "airpods")
        expect(chosenPlan.rows.contains { $0.kind == .device(uid: "airpods") && $0.state },
               "the chosen microphone carries the checkmark")
        expect(chosenPlan.rows.last?.kind == .exclude(uid: "airpods"),
               "the exclude action follows an explicit pick")

        // One microphone left: no way to exclude the only thing that records.
        let single = HUDMicrophoneMenuBuilder.plan(
            devices: [builtIn], chosenUID: nil,
            excludedUIDs: [], resolvedUID: "builtin")
        expect(!single.rows.contains { if case .exclude = $0.kind { return true } else { return false } },
               "the only connected microphone offers no exclude action")

        // Excluding is reversible from the same menu.
        let excludedPlan = HUDMicrophoneMenuBuilder.plan(
            devices: [builtIn, studio], chosenUID: nil,
            excludedUIDs: ["usb"], resolvedUID: "builtin")
        expect(excludedPlan.excludedRows.count == 1
                && excludedPlan.excludedRows.first?.kind == .reenable(uid: "usb")
                && excludedPlan.excludedRows.first?.title == "Studio Mic",
               "an excluded, connected microphone is listed for one-click re-enabling")
        expect(excludedPlan.rows.contains { $0.kind == .excludedGroup && $0.title == "Excluded Microphones" },
               "the excluded group appears only when something is excluded")
        expect(!excludedPlan.rows.contains { $0.kind == .device(uid: "usb") }
                || excludedPlan.rows.contains { $0.kind == .reenable(uid: "usb") },
               "the excluded microphone stays reachable through the group")

        // An excluded device that is unplugged stays discoverable.
        let unplugged = HUDMicrophoneMenuBuilder.plan(
            devices: [builtIn, airpods], chosenUID: nil,
            excludedUIDs: ["usb"], resolvedUID: "builtin")
        expect(unplugged.excludedRows.first?.title == "Not Connected Microphone",
               "an excluded microphone that is unplugged is still listed so it can be allowed again")

        // A chosen microphone that is gone keeps its own disabled row.
        let missing = HUDMicrophoneMenuBuilder.plan(
            devices: [builtIn], chosenUID: "usb",
            excludedUIDs: [], resolvedUID: "builtin")
        expect(missing.rows.contains {
            $0.kind == .missingChosen(uid: "usb") && !$0.enabled
        }, "a chosen microphone that is unplugged keeps a disabled row")
    }

    private static func testExclusionRules() {
        let chosen = HUDMicrophoneExclusion.State(chosenUID: "usb", excludedUIDs: [])
        let excluded = HUDMicrophoneExclusion.excluding("usb", from: chosen)
        expect(excluded.excludedUIDs == ["usb"],
               "excluding a microphone adds it to the excluded list")
        expect(excluded.chosenUID == nil,
               "excluding the chosen microphone clears the choice instead of pinning it")

        let other = HUDMicrophoneExclusion.excluding("usb", from: .init(
            chosenUID: "builtin", excludedUIDs: []))
        expect(other.chosenUID == "builtin",
               "excluding another microphone leaves the chosen one alone")
        expect(other.excludedUIDs == ["usb"],
               "excluding another microphone still records the exclusion")

        let again = HUDMicrophoneExclusion.excluding("usb", from: .init(
            chosenUID: nil, excludedUIDs: ["usb"]))
        expect(again.excludedUIDs == ["usb"],
               "excluding a microphone twice records it once")

        let blank = HUDMicrophoneExclusion.excluding("  ", from: chosen)
        expect(blank == chosen, "a blank uid changes nothing")

        let allowed = HUDMicrophoneExclusion.reenabling("usb", from: .init(
            chosenUID: nil, excludedUIDs: ["usb", "airpods"]))
        expect(allowed.excludedUIDs == ["airpods"],
               "allowing a microphone removes only that microphone")
        expect(allowed.chosenUID == nil,
               "allowing does not silently re-select the device")
    }

    /// The rule, applied the way the pill applies it. `--selftest` runs in a
    /// scratch home, so this never touches the owner's settings; the previous
    /// values are restored so the suite stays order-independent.
    private static func testExclusionRoundTripsThroughSettings() {
        let config = AppConfig.shared
        let chosenBefore = config.inputDeviceUID
        let excludedBefore = config.excludedInputDeviceUIDs
        defer {
            config.inputDeviceUID = chosenBefore
            config.excludedInputDeviceUIDs = excludedBefore
        }

        config.inputDeviceUID = "usb"
        config.excludedInputDeviceUIDs = []
        let next = HUDMicrophoneExclusion.excluding("usb", from: .init(
            chosenUID: config.inputDeviceUID,
            excludedUIDs: config.excludedInputDeviceUIDs))
        config.excludedInputDeviceUIDs = next.excludedUIDs
        if config.inputDeviceUID != next.chosenUID {
            config.inputDeviceUID = next.chosenUID
        }
        expect(config.excludedInputDeviceUIDs == ["usb"],
               "settings carry the exclusion after the pill action")
        expect(config.inputDeviceUID == nil,
               "settings fall back to System Default when the pick was excluded")

        let restored = HUDMicrophoneExclusion.reenabling("usb", from: .init(
            chosenUID: config.inputDeviceUID,
            excludedUIDs: config.excludedInputDeviceUIDs))
        config.excludedInputDeviceUIDs = restored.excludedUIDs
        expect(config.excludedInputDeviceUIDs.isEmpty,
               "allowing the microphone clears it from settings again")
    }

    // MARK: - V-30: the onboarding diagnostic

    private static func line(_ input: OnboardingMicDiagnostic.Input) -> OnboardingMicDiagnostic.Line {
        OnboardingMicDiagnostic.line(input)
    }

    private static func testDiagnosticLine() {
        let denied = line(.init(
            accessGranted: false, accessDenied: true,
            devices: [builtIn], language: .english))
        expect(denied.text == "Microphone access required" && denied.kind == .noAccess,
               "a denied grant reads as access required")
        expect(denied.hint?.contains("System Settings") == true,
               "a denied grant points at System Settings")

        let notAsked = line(.init(
            accessGranted: false, accessDenied: false,
            devices: [builtIn], language: .english))
        expect(notAsked.text == "Microphone access required",
               "an ungranted microphone still says access is required")
        expect(notAsked.hint?.contains("Allow Access") == true,
               "before the prompt, the hint points at the button above")

        let none = line(.init(
            accessGranted: true, accessDenied: false,
            devices: [], language: .english))
        expect(none.text == "No microphone detected" && none.kind == .noDevices,
               "no connected microphone is its own answer")

        let chosen = line(.init(
            accessGranted: true, devices: [builtIn, airpods],
            chosenUID: "airpods", systemDefaultUID: "builtin",
            language: .english))
        expect(chosen.text == "Using AirPods Pro (selected)" && chosen.kind == .ready,
               "an explicit pick is named with its reason (got \(chosen.text))")
        expect(chosen.hint == nil, "a working explicit pick needs no advice")

        let byDefault = line(.init(
            accessGranted: true, devices: [builtIn, airpods],
            chosenUID: nil, systemDefaultUID: "builtin",
            language: .english))
        expect(byDefault.text == "Using MacBook Pro Microphone (system default)",
               "the system default is named as such (got \(byDefault.text))")
        expect(byDefault.hint == nil, "following the system default needs no advice")

        // The chosen microphone is gone: fall back, and say so.
        let disconnected = line(.init(
            accessGranted: true, devices: [builtIn],
            chosenUID: "usb", systemDefaultUID: "builtin",
            language: .english))
        expect(disconnected.text == "Using MacBook Pro Microphone (system default)",
               "a missing pick falls back to the system default")
        expect(disconnected.hint?.contains("not connected") == true,
               "the fallback explains that the chosen microphone is missing")

        // The chosen microphone is excluded: the ladder skips it, and the hint
        // says how to undo that.
        let excludedChosen = line(.init(
            accessGranted: true, devices: [builtIn, airpods],
            chosenUID: "airpods", systemDefaultUID: "builtin",
            excludedUIDs: ["airpods"], language: .english))
        expect(excludedChosen.text == "Using MacBook Pro Microphone (system default)",
               "an excluded pick is skipped by the ladder")
        expect(excludedChosen.hint?.contains("excluded") == true,
               "the fallback names the exclusion as the cause")

        let allExcluded = line(.init(
            accessGranted: true, devices: [builtIn],
            chosenUID: nil, systemDefaultUID: "builtin",
            excludedUIDs: ["builtin"], language: .english))
        expect(allExcluded.kind == .ready
                && allExcluded.text.contains("every microphone is excluded"),
               "excluding everything still resolves a device, and says why")
        expect(allExcluded.hint?.contains("Allow one") == true,
               "excluding everything explains how to undo it")
    }

    private static func testLevelMath() {
        expect(OnboardingMicLevel.target(rms: 0) == 0, "silence is an empty bar")
        expect(OnboardingMicLevel.target(rms: 0.000_01) == 0,
               "below the floor the bar stays empty")
        // 0.5 RMS sits a hair under the -6 dBFS ceiling, so "nearly full" is
        // the honest assertion rather than an exact 1.
        expect(OnboardingMicLevel.target(rms: 0.5) >= 0.95,
               "a loud signal nearly fills the bar")
        expect(OnboardingMicLevel.target(rms: 1) == 1,
               "the bar never exceeds full")
        let quiet = OnboardingMicLevel.target(rms: 0.001)
        let speech = OnboardingMicLevel.target(rms: 0.05)
        expect(quiet > 0 && quiet < speech && speech < 1,
               "speech sits between the floor and clipping (got \(quiet), \(speech))")

        let rise = OnboardingMicLevel.smoothed(previous: 0, target: 1)
        let fall = 1 - OnboardingMicLevel.smoothed(previous: 1, target: 0)
        expect(rise >= 0.5, "the bar rises in one or two steps (got \(rise))")
        expect(fall < rise / 2, "the bar falls more slowly than it rises")
        expect(fall < 0.2, "the bar falls slowly, so a pause does not read as broken")
        expect(OnboardingMicLevel.smoothed(previous: 0.4, target: 0.4) == 0.4,
               "a steady level does not drift")
    }

    // MARK: - The pill's top level is not this change's business

    /// The submenu grew; the top level must not have. The window this creates is
    /// closed again before the test returns, so the pill test's
    /// "exactly one new window" check is unaffected by order.
    private static func testPillMenuTopLevelUnchanged() {
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let panel = HUDPanel(pillEnabled: { false })
        let added = NSApplication.shared.windows.filter {
            !before.contains(ObjectIdentifier($0))
        }
        for window in added { window.alphaValue = 0 }
        defer { for window in added { window.close() } }

        let menu = panel.buildContextMenu()
        let titles = menu.items.map(\.title)
        expect(titles == ["Start Dictation", "", "Microphone", "", "Open Velora", "Hide Pill"],
               "the pill menu's top level is unchanged (got \(titles))")
        let mic = menu.items.first { $0.title == "Microphone" }
        expect(mic?.submenu?.items.first?.title == "System Default",
               "the Microphone row still opens on System Default")
        expect(mic?.submenu?.items.contains { $0.title == "Excluded Microphones" } == false,
               "with nothing excluded, the submenu has no excluded group")
    }
}
#endif
