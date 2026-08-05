import AppKit
import ApplicationServices
import CryptoKit
import EventKit
import Foundation

struct MeetingDetectionInput {
    let runningBundleIDs: Set<String>
    let windowTitles: [String: [String]]
    let calendarTitle: String?
    let calendarEventID: String?
    let calendarHasConferenceLink: Bool
    /// Provider and privacy-protected call identity parsed from the Calendar
    /// event, when available. They let Calendar name the same call without
    /// lending an unrelated overlapping event to whatever happens to use the
    /// browser microphone.
    var calendarSource: String? = nil
    var calendarConferenceKey: String? = nil
    /// Active browser documents exposed by Accessibility. Window titles are
    /// presentation and routinely collapse to a person's name; the document
    /// URL is the stable answer to "is this actually a Meet/Zoom/Teams tab?".
    var browserPages: [String: [MeetingBrowserPage]] = [:]
    /// Bundle IDs holding an active microphone input stream (CoreAudio
    /// process objects), Velora's own capture excluded. nil means the probe
    /// failed — unknown, which is never the same as "nobody".
    var micCapturingBundleIDs: Set<String>? = []
}

struct MeetingBrowserPage: Equatable {
    let title: String?
    let documentURL: String
}

/// Transport identity is deliberately separate from product copy. A Zoom tab
/// is still a browser call; treating the word "Zoom" as a native-app identity
/// makes end detection compare it with the wrong microphone process.
enum MeetingChannel: Equatable {
    case native(String)
    case browser(String?)
    case unknown
}

struct MeetingCandidate: Equatable {
    let key: String
    let title: String
    let sourceApp: String?
    let channel: MeetingChannel
    let calendarEventID: String?
    let confidence: Int
    /// True when a live call was confirmed by microphone activity, or by a
    /// call-specific surface correlated with the same Calendar conference.
    /// Calendar alone and lobby/tab metadata alone never prompt.
    let callConfirmed: Bool
    /// True when the microphone confirmed the call. The coordinator only uses
    /// this for automatic stop when `channel` is an attributable native app;
    /// browser microphone activity cannot identify one tab.
    let micBacked: Bool
}

/// One poll's answer to "is a call happening right now, and how do we know".
struct MeetingPresence: Equatable {
    let source: String
    let channel: MeetingChannel
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
    private var candidateAbsentPolls = 0
    private var endWatchActive = false
    private var micProbeFailureLogged = false
    private var lastLoggedMicSet: Set<String>?
    /// Discovery probes CoreAudio every five seconds, but Accessibility and
    /// EventKit only when the mic set changes or ten seconds have elapsed.
    /// These fields live exclusively on `pollQueue`.
    private var hasDiscoveryMicSample = false
    private var lastDiscoveryMicSet: Set<String>?
    private var lastFullDiscoveryAt = Date.distantPast
    var onCandidate: ((MeetingCandidate) -> Void)?
    /// Reports every scoped call presence (empty when none) on each full poll
    /// while an end watch is armed. Consumers own the debounce.
    var onActivity: (([MeetingPresence]) -> Void)?

    init(
        calendarEnabled: @escaping () -> Bool,
        suggestionsEnabled: @escaping () -> Bool = { true }
    ) {
        self.calendarEnabled = calendarEnabled
        self.suggestionsEnabled = suggestionsEnabled
    }

    func start() {
        guard timer == nil else { return }
        poll(forceFull: true)
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

    func resetSuggestionDebounce() {
        lastCandidateKey = nil
        candidateAbsentPolls = 0
    }

    private func scheduleTimer() {
        timer?.invalidate()
        // The cheap microphone probe runs at the responsive cadence. `poll()`
        // gates the bounded Accessibility/Calendar portion to mic changes or
        // every second tick while idle; end watching always takes a full pass.
        let interval: TimeInterval = 5
        let next = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        next.tolerance = endWatchActive ? 0.5 : 1
        RunLoop.main.add(next, forMode: .common)
        timer = next
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

    /// Re-checks a detected call at the moment the user consents. Suggestions
    /// can stay visible while somebody reads them; recording must not start
    /// from an 80-second-old microphone snapshot after the call already ended.
    func revalidate(
        _ expected: MeetingCandidate,
        completion: @escaping (MeetingCandidate?) -> Void
    ) {
        revalidate(expected, retriesRemaining: 2, completion: completion)
    }

    private func revalidate(
        _ expected: MeetingCandidate, retriesRemaining: Int,
        completion: @escaping (MeetingCandidate?) -> Void
    ) {
        let calendarEnabled = self.calendarEnabled()
        pollQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let input = self.collectInput(calendarEnabled: calendarEnabled)
            if expected.micBacked, input.micCapturingBundleIDs == nil,
               retriesRemaining > 0 {
                // CoreAudio occasionally fails one metadata sample during a
                // device transition. Neither accept downgraded title evidence
                // nor reject a live call from that one unknown sample.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { completion(nil); return }
                    self.revalidate(
                        expected, retriesRemaining: retriesRemaining - 1,
                        completion: completion)
                }
                return
            }
            let current = Self.candidate(from: input)
            let matched = current.flatMap {
                Self.revalidationMatches(expected: expected, current: $0) ? $0 : nil
            }
            DispatchQueue.main.async { completion(matched) }
        }
    }

    static func revalidationMatches(
        expected: MeetingCandidate, current: MeetingCandidate
    ) -> Bool {
        guard current.key == expected.key,
              channelsMatch(expected.channel, current.channel) else { return false }
        // Consent to a mic-confirmed call cannot be transferred to a weaker
        // title/Calendar snapshot that may be a post-call page.
        return !expected.micBacked || current.micBacked
    }

    private static func channelsMatch(
        _ expected: MeetingChannel, _ current: MeetingChannel
    ) -> Bool {
        switch (expected, current) {
        case (.browser(nil), .browser), (.browser, .browser(nil)):
            return true
        default:
            return expected == current
        }
    }

    private func poll(forceFull: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        let wantSuggestions = suggestionsEnabled()
        if !wantSuggestions { lastCandidateKey = nil }
        guard wantSuggestions || endWatchActive else { return }
        guard !pollInFlight else { return }
        pollInFlight = true
        generation += 1
        let currentGeneration = generation
        let calendarEnabled = self.calendarEnabled()
        let watchActive = endWatchActive
        pollQueue.async { [weak self] in
            guard let self else { return }
            let micSet = MeetingMicActivity.bundleIDsCapturingMicrophone()
            let micChanged = !self.hasDiscoveryMicSample
                || micSet != self.lastDiscoveryMicSet
            self.hasDiscoveryMicSample = true
            self.lastDiscoveryMicSet = micSet
            let now = Date()
            let needsFullPoll = forceFull || watchActive || micChanged
                || now.timeIntervalSince(self.lastFullDiscoveryAt) >= 10
            guard needsFullPoll else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == currentGeneration else { return }
                    self.pollInFlight = false
                }
                return
            }
            self.lastFullDiscoveryAt = now
            let input = self.collectInput(
                calendarEnabled: calendarEnabled,
                micCapturingBundleIDs: micSet)
            let candidate = Self.candidate(from: input)
            let presences = Self.activePresences(from: input)
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
                    if !Self.endWatchSampleIsReliable(input) {
                        // Neither title presence nor absence is enough once a
                        // recording has latched microphone evidence and the
                        // microphone probe itself is unknown. Skip the entire
                        // sample rather than accidentally accrue an absence.
                        if !self.micProbeFailureLogged {
                            self.micProbeFailureLogged = true
                            veloraLog("Velora: mic probe unavailable — end-watch poll skipped")
                        }
                    } else {
                        self.onActivity?(presences)
                    }
                }
                guard self.suggestionsEnabled() else {
                    self.lastCandidateKey = nil
                    self.candidateAbsentPolls = 0
                    return
                }
                guard let candidate else {
                    // One missing AX/CoreAudio sample must not re-arm a prompt
                    // the user just declined. Require sustained absence before
                    // the same provider/call can be suggested as a new episode.
                    if self.lastCandidateKey != nil {
                        self.candidateAbsentPolls += 1
                        if self.candidateAbsentPolls >= 3 {
                            self.lastCandidateKey = nil
                            self.candidateAbsentPolls = 0
                        }
                    }
                    return
                }
                self.candidateAbsentPolls = 0
                guard candidate.key != self.lastCandidateKey else { return }
                self.lastCandidateKey = candidate.key
                self.onCandidate?(candidate)
            }
        }
    }

    static func endWatchSampleIsReliable(_ input: MeetingDetectionInput) -> Bool {
        input.micCapturingBundleIDs != nil
    }

    private func collectInput(
        calendarEnabled: Bool,
        micCapturingBundleIDs: Set<String>? = MeetingMicActivity.bundleIDsCapturingMicrophone()
    ) -> MeetingDetectionInput {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let bundles = Set(apps.compactMap(\.bundleIdentifier))
        var titles: [String: [String]] = [:]
        var browserPages: [String: [MeetingBrowserPage]] = [:]
        for app in apps where Self.interestingBundle(app.bundleIdentifier) {
            guard let bundle = app.bundleIdentifier else { continue }
            let windows = Self.windowMetadata(pid: app.processIdentifier)
            titles[bundle, default: []].append(contentsOf: windows.compactMap(\.title))
            if Self.browserBundles.contains(bundle) {
                browserPages[bundle, default: []].append(contentsOf: windows.compactMap { window in
                    guard let documentURL = window.documentURL else { return nil }
                    return MeetingBrowserPage(title: window.title, documentURL: documentURL)
                })
            }
        }
        let visibleConferenceKeys = Set(browserPages.values.flatMap { pages in
            pages.compactMap {
                Self.browserConference(documentURL: $0.documentURL)?.key
            }
        })
        let calendar = activeCalendarEvent(
            enabled: calendarEnabled,
            preferredConferenceKeys: visibleConferenceKeys)
        let calendarConference = calendar.flatMap(Self.calendarConference)
        return MeetingDetectionInput(
            runningBundleIDs: bundles,
            windowTitles: titles,
            calendarTitle: calendar?.title,
            calendarEventID: calendar?.eventIdentifier,
            calendarHasConferenceLink: calendarConference != nil,
            calendarSource: calendarConference?.source,
            calendarConferenceKey: calendarConference?.key,
            browserPages: browserPages,
            micCapturingBundleIDs: micCapturingBundleIDs)
    }

    private func activeCalendarEvent(
        enabled: Bool, preferredConferenceKeys: Set<String>
    ) -> EKEvent? {
        guard enabled, Self.calendarAuthorization == .fullAccess else { return nil }
        let now = Date()
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-10 * 60),
            end: now.addingTimeInterval(10 * 60), calendars: nil)
        let candidates = eventStore.events(matching: predicate)
            .filter { $0.startDate <= now.addingTimeInterval(5 * 60)
                && $0.endDate >= now.addingTimeInterval(-5 * 60) }
            .sorted { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
            .filter(Self.hasConferenceLink)
        if !preferredConferenceKeys.isEmpty,
           let exact = candidates.first(where: {
                guard let key = Self.calendarConference($0)?.key else { return false }
                return preferredConferenceKeys.contains(key)
           }) {
            return exact
        }
        return candidates.first
    }

    static let zoomBundles = ["us.zoom.xos"]
    static let teamsBundles = ["com.microsoft.teams2", "com.microsoft.teams"]
    static let slackBundles = ["com.tinyspeck.slackmacgap", "com.slack.Slack"]
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

    /// App-only evidence. `channel` is transport identity; `source` is display
    /// copy. Keeping those separate is essential for browser-hosted Zoom,
    /// Teams, and Webex calls.
    static func appSignal(
        from input: MeetingDetectionInput
    ) -> (
        score: Int, source: String?, title: String?, channel: MeetingChannel,
        micBacked: Bool, keyHint: String?
    ) {
        var appScore = 0
        var source: String?
        var appTitle: String?
        var channel: MeetingChannel = .unknown
        var micBacked = false
        var keyHint: String?

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
                channel = .native(sourceName)
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
                appScore = 90
                source = "Slack Huddle"
                appTitle = title
                channel = .native("Slack Huddle")
            }
        }

        for bundle in browserBundles where input.runningBundleIDs.contains(bundle) {
            let browserMic = Self.browserMicMatch(
                bundle: bundle, captured: input.micCapturingBundleIDs)
            let conferences: [(
                page: MeetingBrowserPage, source: String, key: String
            )] = (input.browserPages[bundle] ?? []).compactMap { page in
                guard let conference = Self.browserConference(
                    documentURL: page.documentURL) else { return nil }
                return (page, conference.source, conference.key)
            }

            // A browser microphone belongs to a process, not a tab. Prefer an
            // exact Calendar identity, then an unambiguous conference window,
            // then one call-specific title. Never assign an arbitrary first
            // tab when two meeting pages are open.
            var selected: (page: MeetingBrowserPage, source: String, key: String)?
            if let calendarKey = input.calendarConferenceKey {
                selected = conferences.first { $0.key == calendarKey }
            }
            if selected == nil, conferences.count == 1 {
                selected = conferences.first
            }
            if selected == nil {
                let titleBacked = conferences.filter {
                    $0.page.title.map {
                        Self.titleIndicatesBrowserMeeting($0.lowercased())
                    } ?? false
                }
                if titleBacked.count == 1 { selected = titleBacked.first }
            }

            if let selected {
                let titleBacked = selected.page.title.map {
                    Self.titleIndicatesBrowserMeeting($0.lowercased())
                } ?? false
                // URL alone can be a lobby. Microphone activity is live-call
                // evidence; title metadata becomes enough only when Calendar
                // independently points at this same conference identity.
                let score = browserMic ? 100 : (titleBacked ? 80 : 60)
                if score > appScore || (score == appScore && keyHint == nil) {
                    appScore = score
                    source = selected.source
                    appTitle = selected.page.title
                    channel = .browser(bundle)
                    micBacked = browserMic
                    keyHint = selected.key
                }
            } else if browserMic, !conferences.isEmpty, appScore < 95 {
                let providers = Set(conferences.map(\.source))
                source = providers.count == 1 ? providers.first : "Browser meeting"
                appTitle = nil
                channel = .browser(bundle)
                micBacked = true
                appScore = 95
                keyHint = "browser-ambiguous:\(protectedIdentity(bundle + ":" + (source ?? "meeting")))"
            } else if let title = (input.windowTitles[bundle] ?? []).first(where: {
                Self.titleIndicatesBrowserMeeting($0.lowercased())
            }) {
                let lower = title.lowercased()
                let titleSource = Self.sourceForBrowserTitle(lower)
                let score = browserMic ? 95 : 80
                if score > appScore {
                    appScore = score
                    source = titleSource
                    appTitle = title
                    channel = .browser(bundle)
                    micBacked = browserMic
                }
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
                channel = .native(sourceName)
            }
        }
        micUpgrade(slackBundles, sourceName: "Slack Huddle")
        micUpgrade(zoomBundles, sourceName: "Zoom")
        micUpgrade(teamsBundles, sourceName: "Microsoft Teams")

        let activeBrowsers = browserBundles.filter {
            input.runningBundleIDs.contains($0)
                && Self.browserMicMatch(bundle: $0, captured: input.micCapturingBundleIDs)
        }
        if !micBacked, !activeBrowsers.isEmpty, appScore < 45 {
            // Any website can hold the mic, so alone this is a hint, not a
            // meeting — but paired with a conference-link calendar event it
            // crosses the threshold even when the call tab is backgrounded.
            appScore = 45
            source = "Browser meeting"
            channel = .browser(activeBrowsers.count == 1 ? activeBrowsers[0] : nil)
            micBacked = true
        }

        return (appScore, source, appTitle, channel, micBacked, keyHint)
    }

    static let browserBundles = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.mozilla.firefox",
    ]

    static func titleIndicatesBrowserMeeting(_ lower: String) -> Bool {
        lower.contains("google meet") || lower.contains("meet.google")
            || lower.contains("zoom meeting") || lower.contains("microsoft teams")
            || lower.contains("webex meeting")
            || hasMeetTabPrefix(lower)
    }

    static func sourceForBrowserTitle(_ lower: String) -> String {
        if lower.contains("google meet") || lower.contains("meet.google")
            || hasMeetTabPrefix(lower) { return "Google Meet" }
        if lower.contains("zoom meeting") { return "Zoom" }
        if lower.contains("microsoft teams") { return "Microsoft Teams" }
        if lower.contains("webex meeting") { return "Webex" }
        return "Browser meeting"
    }

    /// Resolves each microphone process to one browser owner. Some browser
    /// bundle identifiers are prefixes of another browser (stable Chrome and
    /// Chrome Canary), so first-match prefix tests can attribute one helper to
    /// both. Longest-match ownership keeps the evidence single-valued.
    static func capturedBrowserBundles(_ captured: Set<String>?) -> Set<String> {
        guard let captured else { return [] }
        var owners: Set<String> = []
        for process in captured {
            if process == "com.apple.WebKit.GPU" {
                owners.insert("com.apple.Safari")
                continue
            }
            if process == "org.mozilla.plugincontainer" {
                owners.insert("org.mozilla.firefox")
                continue
            }
            if let owner = browserBundles
                .filter({ process == $0 || process.hasPrefix($0 + ".") })
                .max(by: { $0.count < $1.count }) {
                owners.insert(owner)
            }
        }
        return owners
    }

    static func browserMicMatch(bundle: String, captured: Set<String>?) -> Bool {
        capturedBrowserBundles(captured).contains(bundle)
    }

    /// Recognizes only join-style conference URLs and strips queries/fragments
    /// from the in-memory debounce key. A provider homepage is not a call, and
    /// invitation tokens never enter logs or persisted meeting metadata.
    static func browserConference(
        documentURL raw: String
    ) -> (source: String, key: String)? {
        guard let components = URLComponents(string: raw),
              let hostValue = components.host?.lowercased() else { return nil }
        let host = hostValue.hasPrefix("www.") ? String(hostValue.dropFirst(4)) : hostValue
        let path = components.percentEncodedPath.lowercased()
        func hostMatches(_ root: String) -> Bool {
            host == root || host.hasSuffix("." + root)
        }
        let source: String
        if host == "meet.google.com", googleMeetPathIsCall(path) {
            source = "Google Meet"
        } else if hostMatches("zoom.us"),
                  ["/j/", "/wc/", "/w/"].contains(where: path.contains) {
            source = "Zoom"
        } else if (host == "teams.microsoft.com" || host == "teams.live.com"),
                  ["/l/meetup-join/", "/meet/", "/v2/"].contains(where: path.contains) {
            source = "Microsoft Teams"
        } else if hostMatches("webex.com"),
                  ["/meet/", "/join/", "/wbxmjs/"].contains(where: path.contains) {
            source = "Webex"
        } else if hostMatches("slack.com"), path.contains("/huddle") {
            source = "Slack Huddle"
        } else {
            return nil
        }
        // The call code/path is useful only for in-process correlation. Keep a
        // per-launch HMAC instead of retaining or logging a join URL.
        let identity = String("\(host)\(path)".prefix(500))
        return (source, "browser:\(source.lowercased()):\(protectedIdentity(identity))")
    }

    private static let identityKey = SymmetricKey(size: .bits256)

    private static func protectedIdentity(_ value: String) -> String {
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data(value.utf8), using: identityKey)
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func googleMeetPathIsCall(_ path: String) -> Bool {
        let pieces = path.split(separator: "/").map(String.init)
        guard let first = pieces.first else { return false }
        if looksLikeGoogleMeetCode(first) { return true }
        return first == "lookup" && pieces.dropFirst().first?.isEmpty == false
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

    /// Returns every observable call presence. A scalar "first match" lets an
    /// unrelated Slack mic hide a live Meet (or vice versa), so the coordinator
    /// filters this set against the exact transport it armed.
    static func activePresences(from input: MeetingDetectionInput) -> [MeetingPresence] {
        var result: [MeetingPresence] = []

        func append(_ presence: MeetingPresence) {
            guard !result.contains(presence) else { return }
            result.append(presence)
        }
        func firstTitle(_ bundle: String, where matches: (String) -> Bool) -> String? {
            guard input.runningBundleIDs.contains(bundle) else { return nil }
            return (input.windowTitles[bundle] ?? []).first { matches($0.lowercased()) }
        }
        func containsAny(_ terms: [String]) -> (String) -> Bool {
            { lower in terms.contains { lower.contains($0) } }
        }

        for (bundles, name) in [
            (slackBundles, "Slack Huddle"),
            (zoomBundles, "Zoom"),
            (teamsBundles, "Microsoft Teams"),
        ] where anyMicMatch(bundles, input.micCapturingBundleIDs) {
            append(MeetingPresence(
                source: name, channel: .native(name), micBacked: true))
        }

        for bundle in browserBundles where input.runningBundleIDs.contains(bundle) {
            if browserMicMatch(bundle: bundle, captured: input.micCapturingBundleIDs) {
                // Bundle-level evidence intentionally remains generic: it can
                // confirm a suggestion, but never claims which tab owns it.
                append(MeetingPresence(
                    source: "Browser meeting", channel: .browser(bundle),
                    micBacked: true))
            }
            for page in input.browserPages[bundle] ?? [] {
                guard let conference = browserConference(documentURL: page.documentURL),
                      page.title.map({ titleIndicatesBrowserMeeting($0.lowercased()) }) == true
                else { continue }
                append(MeetingPresence(
                    source: conference.source, channel: .browser(bundle),
                    micBacked: false))
            }
            if let title = firstTitle(bundle, where: titleIndicatesBrowserMeeting) {
                let lower = title.lowercased()
                let name = sourceForBrowserTitle(lower)
                append(MeetingPresence(
                    source: name, channel: .browser(bundle), micBacked: false))
            }
        }

        for bundle in slackBundles
        where firstTitle(bundle, where: containsAny(["huddle", "slack call"])) != nil {
            append(MeetingPresence(
                source: "Slack Huddle", channel: .native("Slack Huddle"),
                micBacked: false))
        }
        if firstTitle(
            "us.zoom.xos",
            where: containsAny(["zoom meeting", "zoom webinar", "waiting room"])) != nil {
            append(MeetingPresence(
                source: "Zoom", channel: .native("Zoom"), micBacked: false))
        }
        for bundle in teamsBundles
        where firstTitle(bundle, where: containsAny(
            ["meeting with", "meeting in", "call with", "call in progress"])) != nil {
            append(MeetingPresence(
                source: "Microsoft Teams", channel: .native("Microsoft Teams"),
                micBacked: false))
        }
        return result
    }

    /// Compatibility helper for focused callers/tests. End watching consumes
    /// `activePresences(from:)` and therefore never loses simultaneous calls.
    static func activePresence(from input: MeetingDetectionInput) -> MeetingPresence? {
        activePresences(from: input).first
    }

    static func candidate(from input: MeetingDetectionInput) -> MeetingCandidate? {
        let (appScore, rawSource, appTitle, channel, micBacked, rawKeyHint) = appSignal(
            from: input)
        var source = rawSource
        var keyHint = rawKeyHint
        if micBacked, case .browser = channel, source == "Browser meeting",
           let calendarSource = input.calendarSource {
            source = calendarSource
            keyHint = input.calendarConferenceKey
        }
        let calendarRelevant: Bool = {
            guard input.calendarHasConferenceLink else { return false }
            if let keyHint, let calendarKey = input.calendarConferenceKey {
                return keyHint == calendarKey
            }
            if let source, let calendarSource = input.calendarSource {
                return source == calendarSource || rawSource == "Browser meeting"
            }
            return false
        }()
        let calendarScore = input.calendarHasConferenceLink ? 70 : 0
        let confidence = max(appScore, calendarScore)
            + (appScore > 0 && calendarRelevant ? 15 : 0)
        let callConfirmed = micBacked || (appScore >= 80 && calendarRelevant)
        // Calendar names the same likely call; it cannot prove somebody joined.
        // A browser/native lobby or title also cannot prove it alone.
        guard confidence >= 70, callConfirmed else { return nil }
        let title = calendarRelevant ? sanitizedMeetingTitle(input.calendarTitle) : nil
        let chosenTitle = (title?.isEmpty == false ? title : nil)
            ?? cleanedMeetingTitle(appTitle, source: source)
            ?? defaultMeetingTitle(source: source)
        let channelIdentity: String
        switch channel {
        case .native(let name): channelIdentity = "native:\(name.lowercased())"
        case .browser(let bundle): channelIdentity = "browser:\(bundle ?? "unknown")"
        case .unknown: channelIdentity = "unknown:\(source ?? "meeting")"
        }
        let key = keyHint
            ?? (calendarRelevant ? input.calendarConferenceKey : nil)
            ?? "episode:\(protectedIdentity(channelIdentity))"
        return MeetingCandidate(
            key: key, title: chosenTitle, sourceApp: source, channel: channel,
            calendarEventID: input.calendarEventID, confidence: min(100, confidence),
            callConfirmed: callConfirmed,
            micBacked: micBacked)
    }

    static func defaultMeetingTitle(source: String?) -> String {
        switch source {
        case "Google Meet", "Zoom", "Microsoft Teams", "Slack Huddle", "Webex":
            return source ?? "Meeting"
        default:
            return "Meeting"
        }
    }

    /// One sanitizer for browser, app, and Calendar copy. Invisible controls
    /// and bidirectional overrides have no place in a floating system HUD;
    /// whitespace and length stay bounded before anything reaches UI/storage.
    static func sanitizedMeetingTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let bidi = CharacterSet(charactersIn:
            "\u{061C}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        let disallowed = CharacterSet.controlCharacters.union(bidi)
        let visible = raw.unicodeScalars
            .filter { !disallowed.contains($0) }
            .map(String.init)
            .joined()
        let collapsed = visible.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(80))
    }

    /// Browser titles contain product/browser chrome and sometimes only a Meet
    /// code. Keep a human meeting name when one exists; otherwise use the
    /// provider default instead of persisting implementation noise.
    static func cleanedMeetingTitle(_ raw: String?, source: String?) -> String? {
        guard var value = sanitizedMeetingTitle(raw) else { return nil }

        func stripSuffixes(_ suffixes: [String]) {
            for suffix in suffixes {
                guard value.lowercased().hasSuffix(suffix) else { continue }
                value.removeLast(suffix.count)
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
        }
        stripSuffixes([
            " - google chrome", " – google chrome", " — google chrome",
            " - safari", " – safari", " — safari", " - microsoft edge",
            " – microsoft edge", " — microsoft edge", " - firefox",
        ])
        stripSuffixes([
            " - google meet", " – google meet", " — google meet",
            " | microsoft teams", " - microsoft teams", " – microsoft teams",
            " — microsoft teams", " - zoom", " – zoom", " — zoom",
            " - webex", " – webex", " — webex",
        ])

        let lower = value.lowercased()
        if hasMeetTabPrefix(lower) {
            let separators = [" – ", " — ", " - "]
            if let separator = separators.first(where: lower.contains),
               let range = value.range(of: separator) {
                let remainder = String(value[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                value = looksLikeGoogleMeetCode(remainder) ? "" : remainder
            }
        }

        let generic = [
            "", "meet", "google meet", "zoom", "zoom meeting", "microsoft teams",
            "browser meeting", "meeting", "webex", "webex meeting",
        ]
        guard !generic.contains(value.lowercased()) else { return nil }
        return sanitizedMeetingTitle(value)
    }

    static func looksLikeGoogleMeetCode(_ value: String) -> Bool {
        let pieces = value.lowercased().split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.map(\.count) == [3, 4, 3] else { return false }
        return pieces.allSatisfy { $0.allSatisfy { $0.isLetter } }
    }

    private static func interestingBundle(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        return bundle == "us.zoom.xos" || bundle.hasPrefix("com.microsoft.teams")
            || bundle == "com.tinyspeck.slackmacgap" || bundle == "com.slack.Slack"
            || browserBundles.contains(bundle)
    }

    private struct WindowMetadata {
        let title: String?
        let documentURL: String?
    }

    private static func windowMetadata(pid: pid_t) -> [WindowMetadata] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.prefix(12).map { window in
            WindowMetadata(
                title: stringAttribute(kAXTitleAttribute as CFString, from: window, limit: 200),
                documentURL: stringAttribute(
                    kAXDocumentAttribute as CFString, from: window, limit: 500))
        }
    }

    private static func stringAttribute(
        _ attribute: CFString, from element: AXUIElement, limit: Int
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        let string: String?
        if let value = value as? String {
            string = value
        } else if let value = value as? URL {
            string = value.absoluteString
        } else {
            string = nil
        }
        guard let string, !string.isEmpty else { return nil }
        return String(string.prefix(limit))
    }

    private static func calendarConference(
        _ event: EKEvent
    ) -> (source: String, key: String)? {
        if let direct = event.url?.absoluteString,
           let conference = browserConference(documentURL: direct) {
            return conference
        }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        guard !text.isEmpty,
              let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            guard let raw = match.url?.absoluteString,
                  let conference = browserConference(documentURL: raw) else { continue }
            return conference
        }
        return nil
    }

    private static func hasConferenceLink(_ event: EKEvent) -> Bool {
        calendarConference(event) != nil
    }
}
