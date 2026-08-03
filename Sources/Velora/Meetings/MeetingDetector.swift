import AppKit
import ApplicationServices
import EventKit
import Foundation

struct MeetingDetectionInput {
    let runningBundleIDs: Set<String>
    let windowTitles: [String: [String]]
    let calendarTitle: String?
    let calendarEventID: String?
    let calendarHasConferenceLink: Bool
    /// Bundle IDs holding an active microphone input stream (CoreAudio
    /// process objects), Velora's own capture excluded. nil means the probe
    /// failed — unknown, which is never the same as "nobody".
    var micCapturingBundleIDs: Set<String>? = []
}

struct MeetingCandidate: Equatable {
    let key: String
    let title: String
    let sourceApp: String?
    let calendarEventID: String?
    let confidence: Int
    /// True when a live call was confirmed by hard evidence — a call-specific
    /// window title (score >= 80) or the app holding the microphone — rather
    /// than "the app is merely running" or calendar-only inference. Only
    /// call-confirmed candidates can seed end-of-meeting watching.
    let callConfirmed: Bool
    /// True when the microphone confirmed the call. Mic-backed recordings can
    /// end automatically: the mic releasing is definitive, titles are not.
    let micBacked: Bool
}

/// One poll's answer to "is a call happening right now, and how do we know".
struct MeetingPresence: Equatable {
    let source: String
    let micBacked: Bool
}

/// Polls only local process/window metadata plus optional EventKit. Detection
/// can suggest capture; it never starts capture itself.
final class MeetingDetector {
    private let eventStore = EKEventStore()
    private let calendarEnabled: () -> Bool
    private let suggestionsEnabled: () -> Bool
    private let pollQueue = DispatchQueue(
        label: "com.velora.meetings.detector", qos: .utility)
    private var timer: Timer?
    private var generation = 0
    private var pollInFlight = false
    private var lastCandidateKey: String?
    private var endWatchActive = false
    private var micProbeFailureLogged = false
    private var lastLoggedMicSet: Set<String>?
    var onCandidate: ((MeetingCandidate) -> Void)?
    /// Reports call presence (nil when none) on every poll while an end
    /// watch is armed. Consumers own the debounce.
    var onActivity: ((MeetingPresence?) -> Void)?

    init(
        calendarEnabled: @escaping () -> Bool,
        suggestionsEnabled: @escaping () -> Bool = { true }
    ) {
        self.calendarEnabled = calendarEnabled
        self.suggestionsEnabled = suggestionsEnabled
    }

    func start() {
        guard timer == nil else { return }
        poll()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        pollInFlight = false
        // A stale armed flag would make a future start() poll at the watch
        // cadence and report activity into an idle coordinator.
        endWatchActive = false
    }

    /// While armed, polls run more often and report call presence even when
    /// suggestions are disabled — ending a recording the user already
    /// consented to is a separate concern from suggesting new ones.
    func setEndWatch(_ active: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard endWatchActive != active else { return }
        endWatchActive = active
        // New watch lifecycle: a snapshot collected before this transition
        // must not be delivered into it (it could latch stale mic evidence
        // or consume the first absence).
        generation += 1
        pollInFlight = false
        micProbeFailureLogged = false
        lastLoggedMicSet = nil
        guard timer != nil else { return }
        scheduleTimer()
        if active { poll() }
    }

    func resetSuggestionDebounce() { lastCandidateKey = nil }

    private func scheduleTimer() {
        timer?.invalidate()
        // Watching a live recording rides the cheap CoreAudio mic probe, so
        // it can afford a tight cadence; idle discovery stays relaxed.
        let interval: TimeInterval = endWatchActive ? 5 : 20
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    static var calendarAuthorization: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestCalendarAccess(_ completion: @escaping (Bool) -> Void) {
        pollQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            if #available(macOS 14, *) {
                self.eventStore.requestFullAccessToEvents { granted, _ in
                    DispatchQueue.main.async { completion(granted) }
                }
            } else {
                self.eventStore.requestAccess(to: .event) { granted, _ in
                    DispatchQueue.main.async { completion(granted) }
                }
            }
        }
    }

    private func poll() {
        dispatchPrecondition(condition: .onQueue(.main))
        let wantSuggestions = suggestionsEnabled()
        if !wantSuggestions { lastCandidateKey = nil }
        guard wantSuggestions || endWatchActive else { return }
        guard !pollInFlight else { return }
        pollInFlight = true
        generation += 1
        let currentGeneration = generation
        let calendarEnabled = self.calendarEnabled()
        pollQueue.async { [weak self] in
            guard let self else { return }
            let input = self.collectInput(calendarEnabled: calendarEnabled)
            let candidate = Self.candidate(from: input)
            let presence = Self.activePresence(from: input)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.pollInFlight = false
                if self.endWatchActive {
                    // Field-falsifiable attribution: which processes actually
                    // hold the mic is version-dependent per app, so log the
                    // set whenever it changes during a watch.
                    if let micSet = input.micCapturingBundleIDs,
                       micSet != self.lastLoggedMicSet {
                        self.lastLoggedMicSet = micSet
                        veloraLog("Velora: mic capture set: [\(micSet.sorted().joined(separator: ", "))]")
                    }
                    if presence == nil, input.micCapturingBundleIDs == nil {
                        // Absence built on a failed mic probe is not
                        // evidence; skip this poll rather than accrue it.
                        if !self.micProbeFailureLogged {
                            self.micProbeFailureLogged = true
                            veloraLog("Velora: mic probe unavailable — end-watch poll skipped")
                        }
                    } else {
                        self.onActivity?(presence)
                    }
                }
                guard self.suggestionsEnabled() else {
                    self.lastCandidateKey = nil
                    return
                }
                guard let candidate else {
                    // The call ended. Clearing here lets a later recurring
                    // meeting with the same title suggest again.
                    self.lastCandidateKey = nil
                    return
                }
                guard candidate.key != self.lastCandidateKey else { return }
                self.lastCandidateKey = candidate.key
                self.onCandidate?(candidate)
            }
        }
    }

    private func collectInput(calendarEnabled: Bool) -> MeetingDetectionInput {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let bundles = Set(apps.compactMap(\.bundleIdentifier))
        var titles: [String: [String]] = [:]
        for app in apps where Self.interestingBundle(app.bundleIdentifier) {
            guard let bundle = app.bundleIdentifier else { continue }
            titles[bundle] = Self.windowTitles(pid: app.processIdentifier)
        }
        let calendar = activeCalendarEvent(enabled: calendarEnabled)
        return MeetingDetectionInput(
            runningBundleIDs: bundles,
            windowTitles: titles,
            calendarTitle: calendar?.title,
            calendarEventID: calendar?.eventIdentifier,
            calendarHasConferenceLink: calendar.map(Self.hasConferenceLink) ?? false,
            micCapturingBundleIDs: MeetingMicActivity.bundleIDsCapturingMicrophone())
    }

    private func activeCalendarEvent(enabled: Bool) -> EKEvent? {
        guard enabled, Self.calendarAuthorization == .fullAccess else { return nil }
        let now = Date()
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-10 * 60),
            end: now.addingTimeInterval(10 * 60), calendars: nil)
        return eventStore.events(matching: predicate)
            .filter { $0.startDate <= now.addingTimeInterval(5 * 60)
                && $0.endDate >= now.addingTimeInterval(-5 * 60) }
            .sorted { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
            .first(where: Self.hasConferenceLink)
    }

    static let zoomBundles = ["us.zoom.xos"]
    static let teamsBundles = ["com.microsoft.teams2", "com.microsoft.teams"]
    static let slackBundles = ["com.tinyspeck.slackmacgap", "com.slack.Slack"]
    /// Processes that hold the mic on a browser's behalf. Chromium/Electron
    /// capture in "<app>.helper*" children (prefix-matched); Safari captures
    /// in the shared WebKit GPU process and Firefox in its plugin container.
    static let browserMicBundles = browserBundles
        + ["com.apple.WebKit.GPU", "org.mozilla.plugincontainer"]

    /// True when any of `targets` (or one of their helper children, e.g.
    /// "com.google.Chrome.helper") appears in the capturing set. The process
    /// on the mic is routinely a helper, not the main app. A failed probe
    /// (nil) matches nothing.
    static func anyMicMatch(_ targets: [String], _ captured: Set<String>?) -> Bool {
        guard let captured else { return false }
        return targets.contains { target in
            captured.contains { $0 == target || $0.hasPrefix(target + ".") }
        }
    }

    /// App-only evidence: (score, source, matched title, micBacked). A window
    /// title match scores >= 80; the app actually holding the microphone
    /// scores 95 and is the only evidence strong enough to end a recording
    /// automatically. A merely-running meeting app keeps its low base.
    static func appSignal(
        from input: MeetingDetectionInput
    ) -> (score: Int, source: String?, title: String?, micBacked: Bool) {
        var appScore = 0
        var source: String?
        var appTitle: String?
        var micBacked = false

        func inspect(_ bundle: String, sourceName: String, base: Int, terms: [String]) {
            guard input.runningBundleIDs.contains(bundle) else { return }
            let matching = (input.windowTitles[bundle] ?? []).first { title in
                let lower = title.lowercased()
                return terms.contains { lower.contains($0) }
            }
            let score = matching == nil ? base : max(80, base)
            if score > appScore {
                appScore = score
                source = sourceName
                appTitle = matching
            }
        }

        inspect("us.zoom.xos", sourceName: "Zoom", base: 40,
                terms: ["zoom meeting", "zoom webinar", "meeting", "waiting room"])
        inspect("com.microsoft.teams2", sourceName: "Microsoft Teams", base: 35,
                terms: ["meeting", "call"])
        inspect("com.microsoft.teams", sourceName: "Microsoft Teams", base: 35,
                terms: ["meeting", "call"])

        for bundle in ["com.tinyspeck.slackmacgap", "com.slack.Slack"]
        where input.runningBundleIDs.contains(bundle) {
            if let title = (input.windowTitles[bundle] ?? []).first(where: {
                let value = $0.lowercased()
                return value.contains("huddle") || value.contains("slack call")
            }), appScore < 90 {
                appScore = 90; source = "Slack Huddle"; appTitle = title
            }
        }

        for bundle in browserBundles where input.runningBundleIDs.contains(bundle) {
            if let title = (input.windowTitles[bundle] ?? []).first(where: {
                Self.titleIndicatesBrowserMeeting($0.lowercased())
            }), appScore < 90 {
                appScore = 90
                let lower = title.lowercased()
                source = (lower.contains("google") || Self.hasMeetTabPrefix(lower))
                    ? "Google Meet" : "Browser meeting"
                appTitle = title
            }
        }

        // Microphone evidence outranks titles. The dedicated apps hold an
        // input stream exactly for the duration of a call — mute included,
        // windows hidden or not.
        func micUpgrade(_ bundles: [String], sourceName: String) {
            guard Self.anyMicMatch(bundles, input.micCapturingBundleIDs) else { return }
            micBacked = true
            if appScore < 95 {
                if source != sourceName { appTitle = nil }
                appScore = 95
                source = sourceName
            }
        }
        micUpgrade(slackBundles, sourceName: "Slack Huddle")
        micUpgrade(zoomBundles, sourceName: "Zoom")
        micUpgrade(teamsBundles, sourceName: "Microsoft Teams")

        if !micBacked, Self.anyMicMatch(browserMicBundles, input.micCapturingBundleIDs) {
            if source == "Google Meet" || source == "Browser meeting" {
                micBacked = true
                appScore = max(appScore, 95)
            } else if appScore < 45 {
                // Any website can hold the mic, so alone this is a hint, not
                // a meeting — but paired with a conference-link calendar
                // event it crosses the suggestion threshold even though the
                // call tab's title is hidden behind another tab.
                appScore = 45
                source = "Browser meeting"
                micBacked = true
            }
        }

        return (appScore, source, appTitle, micBacked)
    }

    static let browserBundles = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "org.mozilla.firefox",
    ]

    static func titleIndicatesBrowserMeeting(_ lower: String) -> Bool {
        lower.contains("google meet") || lower.contains("meet.google")
            || lower.contains("zoom meeting") || lower.contains("microsoft teams")
            || hasMeetTabPrefix(lower)
    }

    /// Chrome/Safari title an active Meet tab "Meet – abc-defg-hij" (or the
    /// meeting name) — the bare product name never appears with "google" in
    /// it, so the dash separator is the stable signal.
    static func hasMeetTabPrefix(_ lower: String) -> Bool {
        for dash in ["–", "—", "-"] where lower.hasPrefix("meet \(dash) ") {
            return true
        }
        return false
    }

    /// Live-call presence for end-of-meeting watching. The microphone is
    /// authoritative and checked first; title fallbacks are deliberately
    /// stricter than suggestion scoring — a Teams window sitting on its
    /// Calls tab or a Zoom "Schedule Meeting" sheet contains "call"/"meeting"
    /// yet is not a call, and would pin every recording to "still in a
    /// meeting" forever. Calendar evidence never counts — an event cannot
    /// see a call that ended early.
    static func activePresence(from input: MeetingDetectionInput) -> MeetingPresence? {
        for (bundles, name) in [
            (slackBundles, "Slack Huddle"),
            (zoomBundles, "Zoom"),
            (teamsBundles, "Microsoft Teams"),
        ] where anyMicMatch(bundles, input.micCapturingBundleIDs) {
            return MeetingPresence(source: name, micBacked: true)
        }
        if anyMicMatch(browserMicBundles, input.micCapturingBundleIDs) {
            // Which site holds the mic is unknowable, so this sustains a
            // watch that stronger evidence armed; arming is the candidate
            // scorer's job.
            return MeetingPresence(source: "Browser meeting", micBacked: true)
        }

        func firstTitle(_ bundle: String, where matches: (String) -> Bool) -> String? {
            guard input.runningBundleIDs.contains(bundle) else { return nil }
            return (input.windowTitles[bundle] ?? []).first { matches($0.lowercased()) }
        }
        func containsAny(_ terms: [String]) -> (String) -> Bool {
            { lower in terms.contains { lower.contains($0) } }
        }

        for bundle in slackBundles
        where firstTitle(bundle, where: containsAny(["huddle", "slack call"])) != nil {
            return MeetingPresence(source: "Slack Huddle", micBacked: false)
        }
        if firstTitle(
            "us.zoom.xos",
            where: containsAny(["zoom meeting", "zoom webinar", "waiting room"])) != nil {
            return MeetingPresence(source: "Zoom", micBacked: false)
        }
        for bundle in teamsBundles
        where firstTitle(bundle, where: containsAny(
            ["meeting with", "meeting in", "call with", "call in progress"])) != nil {
            return MeetingPresence(source: "Microsoft Teams", micBacked: false)
        }
        for bundle in browserBundles {
            if let title = firstTitle(bundle, where: Self.titleIndicatesBrowserMeeting) {
                let lower = title.lowercased()
                let source = (lower.contains("google") || Self.hasMeetTabPrefix(lower))
                    ? "Google Meet" : "Browser meeting"
                return MeetingPresence(source: source, micBacked: false)
            }
        }
        return nil
    }

    static func candidate(from input: MeetingDetectionInput) -> MeetingCandidate? {
        let (appScore, source, appTitle, micBacked) = appSignal(from: input)
        let calendarScore = input.calendarHasConferenceLink ? 70 : 0
        let confidence = max(appScore, calendarScore)
            + (appScore > 0 && calendarScore > 0 ? 15 : 0)
        guard confidence >= 70 else { return nil }
        let title = input.calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenTitle = (title?.isEmpty == false ? title : nil)
            ?? appTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Meeting"
        let key = input.calendarEventID
            ?? "\(source ?? "meeting"):\(chosenTitle.lowercased())"
        return MeetingCandidate(
            key: key, title: chosenTitle, sourceApp: source,
            calendarEventID: input.calendarEventID, confidence: min(100, confidence),
            callConfirmed: appScore >= 80 || micBacked,
            micBacked: micBacked)
    }

    private static func interestingBundle(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        return bundle == "us.zoom.xos" || bundle.hasPrefix("com.microsoft.teams")
            || bundle == "com.tinyspeck.slackmacgap" || bundle == "com.slack.Slack"
            || bundle == "com.apple.Safari" || bundle == "com.google.Chrome"
            || bundle == "company.thebrowser.Browser" || bundle == "com.microsoft.edgemac"
            || bundle == "org.mozilla.firefox"
    }

    private static func windowTitles(pid: pid_t) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        let titles: [String] = windows.prefix(12).compactMap { window -> String? in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
            return title as? String
        }
        return titles.filter { !$0.isEmpty }.map { String($0.prefix(200)) }
    }

    private static func hasConferenceLink(_ event: EKEvent) -> Bool {
        let haystack = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
                "slack.com/huddle"].contains { haystack.contains($0) }
    }
}
