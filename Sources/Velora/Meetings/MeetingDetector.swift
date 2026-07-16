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
}

struct MeetingCandidate: Equatable {
    let key: String
    let title: String
    let sourceApp: String?
    let calendarEventID: String?
    let confidence: Int
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
    var onCandidate: ((MeetingCandidate) -> Void)?

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
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        pollInFlight = false
    }

    func resetSuggestionDebounce() { lastCandidateKey = nil }

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
        guard suggestionsEnabled() else {
            lastCandidateKey = nil
            return
        }
        guard !pollInFlight else { return }
        pollInFlight = true
        generation += 1
        let currentGeneration = generation
        let calendarEnabled = self.calendarEnabled()
        pollQueue.async { [weak self] in
            guard let self else { return }
            let input = self.collectInput(calendarEnabled: calendarEnabled)
            let candidate = Self.candidate(from: input)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.pollInFlight = false
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
            calendarHasConferenceLink: calendar.map(Self.hasConferenceLink) ?? false)
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

    static func candidate(from input: MeetingDetectionInput) -> MeetingCandidate? {
        var appScore = 0
        var source: String?
        var appTitle: String?

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
                terms: ["zoom meeting", "meeting", "waiting room"])
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

        let browsers = [
            "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
            "com.microsoft.edgemac", "org.mozilla.firefox",
        ]
        for bundle in browsers where input.runningBundleIDs.contains(bundle) {
            if let title = (input.windowTitles[bundle] ?? []).first(where: {
                let value = $0.lowercased()
                return value.contains("google meet") || value.contains("meet.google")
                    || value.contains("zoom meeting") || value.contains("microsoft teams")
            }), appScore < 90 {
                appScore = 90
                source = title.lowercased().contains("google") ? "Google Meet" : "Browser meeting"
                appTitle = title
            }
        }

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
            calendarEventID: input.calendarEventID, confidence: min(100, confidence))
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
