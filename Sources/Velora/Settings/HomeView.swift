import AppKit
import Charts
import SwiftUI

/// The Home pane: a serif welcome, the "Last 7 days" card, then a 1.6 : 1
/// grid — recent dictations on the left, the "Ways to talk" toggles, the
/// latest meeting and (when fresh) the latest learned term on the right.
///
///     Home                               [🎤 MacBook Mic] [Start Dictation ⌥]
///     Ready when you are.
///     Press ⌥ and talk…
///     ┌ Last 7 days ────────────────────────────────── Open Stats ┐
///     │ 3,120 words   1 h 2 m saved   48 dictations    ▂▅▃▇▂▁█   │
///     └──────────────────────────────────────────────────────────┘
///     ┌ Recent ──────────────────┐ ┌ WAYS TO TALK ────────┐
///     │ ▣ Slack   Message · 42 w │ │ ⌨ Stream Typing  [⌃⇧S] ●│
///     │   "text…"           2m   │ │ ✦ Voice Edit     [⌥⇧E] ●│
///     │ …                        │ └──────────────────────┘
///     │                          │ ┌ MEETINGS ────────────┐
///     └──────────────────────────┘ └──────────────────────┘
struct HomeView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var selection: MainWindowSelection
    let history: HistoryStore
    let meetings: MeetingStore
    let actions: MainWindowActions

    @State private var latestMeeting: MeetingRecord?
    @State private var inputDevices: [AudioInputDevices.Device] = []
    /// Bumped on every reload so the Recent list (which loads on appear)
    /// re-reads the store after dictating elsewhere.
    @State private var reloadToken = UUID()
    /// The "Last 7 days" card's numbers: one small query, not the Stats
    /// pane's full insights set (Home reloads on every app activation).
    @State private var week = HistoryStore.WeekSummary()
    @State private var weekLoaded = false
    /// A reload mid-query must not let the older result land.
    @State private var weekGeneration = 0

    /// Body spacing between the headline, the tiles and the grid.
    private static let sectionSpacing: CGFloat = 18
    /// Recent : right column = 8 : 5 (1.6 : 1) of `gridColumns`.
    private static let gridColumns = 13
    private static let recentColumnSpan = 8
    private static let recentLimit = 5
    /// The week chart's height and bar corner radius.
    private static let weekChartHeight: CGFloat = 96
    private static let weekBarRadius: CGFloat = 3
    /// Earlier days of the week sit a step lighter than today.
    private static let pastDayOpacity = 0.75
    /// A learned term older than this no longer earns a card.
    private static let learnedFreshness: TimeInterval = 24 * 60 * 60

    init(
        model: SettingsModel, selection: MainWindowSelection, history: HistoryStore,
        meetings: MeetingStore, actions: MainWindowActions
    ) {
        self.model = model
        self.selection = selection
        self.history = history
        self.meetings = meetings
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            PaneHeader(title: MainPane.home.title) {
                microphoneMenu
                Button(action: actions.toggleDictation) {
                    HStack(spacing: VeloraSpacing.s) {
                        Text("Start Dictation")
                        Text(model.hotkey.displayLabel)
                            .font(.system(size: 11))
                            .opacity(0.8)
                    }
                }
                .buttonStyle(.primaryCapsule)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    headline
                    weekCard
                    grid
                }
                .padding(.bottom, VeloraSpacing.s)
            }
        }
        .onAppear(perform: reload)
        // Coming back to the window after dictating elsewhere refreshes the
        // numbers without a history-changed notification.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .veloraMeetingsChanged)) { _ in
            reloadMeeting()
        }
        .onReceive(NotificationCenter.default.publisher(for: .veloraAudioInputDevicesChanged)) { _ in
            inputDevices = AudioInputDevices.displayList()
        }
    }

    // MARK: Header controls

    /// Current microphone as a capsule; the menu switches it (the same
    /// binding as Settings › Dictation and the pill's Microphone submenu).
    private var microphoneMenu: some View {
        Menu {
            Button("System Default") { model.inputDeviceUID = nil }
            Divider()
            ForEach(inputDevices, id: \.uid) { device in
                Button(device.name) { model.inputDeviceUID = device.uid }
            }
        } label: {
            Label(microphoneName, systemImage: "mic")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.capsule)
        .fixedSize()
    }

    private var microphoneName: String {
        guard let uid = model.inputDeviceUID else { return "System Default" }
        return inputDevices.first { $0.uid == uid }?.name ?? "Microphone not connected"
    }

    // MARK: Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            SerifHeadline("Ready when you are", size: .hero)
            (Text("Press ")
                + Text(model.hotkey.displayLabel).fontWeight(.medium)
                + Text(" and talk, anywhere you can type. Your voice never leaves this Mac."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Last 7 days

    /// Three numbers and the last seven days in one card. Ranges and the
    /// rest of the charts live in Stats, one click away.
    private var weekCard: some View {
        let stats = week.week
        let typingWPM = AppConfig.shared.typingWPM
        return GroupCard(header: "Last 7 days", headerLink: ("Open Stats", { selection.pane = .stats })) {
            HStack(alignment: .bottom, spacing: VeloraSpacing.xl) {
                HStack(alignment: .top, spacing: VeloraSpacing.xl) {
                    weekMetric(HistoryJournal.grouped(stats.words), "Words")
                    weekMetric(
                        StatsFormat.clock(minutes: stats.minutesSaved(typingWPM: typingWPM)),
                        "Saved vs typing", emphasis: .accent)
                    weekMetric(HistoryJournal.grouped(stats.count), "Dictations")
                }
                .fixedSize()
                weekChart
            }
            .padding(14)
        }
    }

    private func weekMetric(_ value: String, _ label: String, emphasis: StatEmphasis = .plain) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(emphasis == .accent ? AnyShapeStyle(VeloraBrand.accent) : AnyShapeStyle(.primary))
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Seven day bars under narrow weekday letters, today in full accent.
    private var weekChart: some View {
        let bars = HomeWeek.bars(week.daily, now: Date())
        let today = Calendar.current.startOfDay(for: Date())
        return StatsChartBox(height: Self.weekChartHeight) {
            Chart(bars) { bar in
                BarMark(x: .value("Day", bar.date, unit: .day), y: .value("Words", bar.words))
                    .foregroundStyle(VeloraBrand.accent.opacity(bar.date == today ? 1 : Self.pastDayOpacity))
                    .cornerRadius(Self.weekBarRadius)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                }
            }
            .chartYAxis(.hidden)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Grid

    /// Two columns sized against the scroll view's width (no GeometryReader,
    /// so the grid keeps its natural height and never clips a tall column).
    private var grid: some View {
        let gap = VeloraSpacing.m
        return HStack(alignment: .top, spacing: gap) {
            recentCard
                .containerRelativeFrame(
                    .horizontal, count: Self.gridColumns, span: Self.recentColumnSpan, spacing: gap)
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                waysToTalk
                meetingsCard
                learnedCard
            }
            .containerRelativeFrame(
                .horizontal, count: Self.gridColumns,
                span: Self.gridColumns - Self.recentColumnSpan, spacing: gap)
        }
    }

    // MARK: Recent

    /// Same uppercase section header as the cards beside it; the title used
    /// to sit inside the card and read as a third header style.
    private var recentCard: some View {
        GroupCard(header: "Recent", headerLink: ("Open History", { selection.pane = .history })) {
            HistoryRecentList(history: history, limit: Self.recentLimit) { record in
                HistoryViewModel.requestReveal(record.id)
                selection.pane = .history
            }
            .id(reloadToken)
                .padding(.horizontal, 14)
                .padding(.vertical, VeloraSpacing.m)
        }
    }

    // MARK: Ways to talk

    private var waysToTalk: some View {
        GroupCard(header: "Ways to talk") {
            wayRow(
                symbol: "text.cursor", title: "Stream Typing", sub: "Words land as you speak.",
                hotkey: model.streamTypingHotkey, enabled: $model.streamTypingEnabled)
            GroupDivider()
            wayRow(
                symbol: "wand.and.stars", title: "Voice Edit", sub: "Edit the selection aloud.",
                hotkey: model.editHotkey, enabled: $model.voiceEdit)
            GroupDivider()
            wayRow(
                symbol: "text.badge.checkmark", title: "Proofread", sub: "Fix the selection, no mic.",
                hotkey: model.proofreadHotkey, enabled: $model.proofreadEnabled)
            GroupDivider()
            wayRow(
                symbol: "sparkles", title: "Action Mode", sub: "Say what you want done.",
                hotkey: model.actionHotkey, enabled: $model.actionsEnabled)
        }
    }

    private func wayRow(
        symbol: String, title: String, sub: String, hotkey: Hotkey, enabled: Binding<Bool>
    ) -> some View {
        HStack(spacing: VeloraSpacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(enabled.wrappedValue ? AnyShapeStyle(VeloraBrand.accent) : AnyShapeStyle(.secondary))
                .frame(width: 22)
                .accessibilityHidden(true)
            GroupRow(label: title, sub: sub) {
                KeycapsLabel(hotkey: hotkey)
                Toggle(title, isOn: enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .padding(.leading, -14)  // the symbol takes the row's leading inset
        }
        .padding(.leading, 14)
    }

    // MARK: Meetings

    /// A row that says what meeting notes do, with Start on its trailing
    /// edge, then the latest meeting. A lone button in a card read as empty.
    private var meetingsCard: some View {
        GroupCard(header: "Meetings") {
            GroupRow(label: "Meeting notes", sub: "Records the room, writes notes at the end.") {
                Button("Start…", action: actions.startMeeting)
                    .buttonStyle(.capsule)
                    .accessibilityLabel("Start Meeting Notes")
            }
            if let meeting = latestMeeting {
                GroupDivider()
                GroupRow(label: meeting.title, sub: HomeFormat.meetingMeta(meeting)) {
                    Button("Open notes") { actions.openMeetingNotes(meeting.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(VeloraBrand.link)
                }
            }
        }
    }

    // MARK: Learned

    /// The most recent learned dictionary term, only while it is under a day
    /// old. `DictionaryRow` records no source app, so the card names the term
    /// and the edit, not the app.
    private var freshLearnedTerm: DictionaryRow? {
        let learned = model.dictionaryRows
            .filter { $0.source == .learned }
            .max { $0.modifiedAt < $1.modifiedAt }
        guard let learned,
              Date().timeIntervalSince(learned.modifiedAt) < Self.learnedFreshness
        else { return nil }
        return learned
    }

    @ViewBuilder
    private var learnedCard: some View {
        if let learned = freshLearnedTerm {
            HStack(alignment: .firstTextBaseline, spacing: VeloraSpacing.m) {
                (Text("Learned ") + Text(learned.writeAs).bold() + Text(" from your edit."))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Dictionary") { selection.pane = .dictionary }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(VeloraBrand.link)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous)
                    .fill(VeloraBrand.warm.opacity(0.12)))
            .overlay(
                RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous)
                    .strokeBorder(VeloraBrand.warm.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: Loading

    private func reload() {
        reloadToken = UUID()
        reloadWeek()
        AudioInputDevices.beginObserving()
        inputDevices = AudioInputDevices.displayList()
        reloadMeeting()
    }

    /// Off the main thread, except the offscreen snapshot's first load,
    /// whose nested runloop never drains main-queue blocks.
    private func reloadWeek() {
        if !weekLoaded, IntelligenceViewModel.loadsFirstReloadInline {
            week = history.weekSummary()
            weekLoaded = true
            return
        }

        weekGeneration += 1
        let generation = weekGeneration
        let history = history
        DispatchQueue.global(qos: .userInitiated).async {
            let summary = history.weekSummary()
            DispatchQueue.main.async {
                guard generation == weekGeneration else {
                    return
                }
                week = summary
                weekLoaded = true
            }
        }
    }

    private func reloadMeeting() {
        let meetings = meetings
        DispatchQueue.global(qos: .userInitiated).async {
            let latest = meetings.recentMetadata(limit: 1).first
            DispatchQueue.main.async { latestMeeting = latest }
        }
    }
}

/// Meeting meta formatting for the Home pane.
enum HomeFormat {
    /// "Yesterday · 42 min · 3 action items".
    static func meetingMeta(_ meeting: MeetingRecord) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        let when = formatter.localizedString(for: meeting.startedAt, relativeTo: Date())
        let minutes = max(1, meeting.durationMs / 60_000)
        let items = meeting.notes.actionItems.count
        return [
            when.prefix(1).uppercased() + when.dropFirst(),
            "\(minutes) min",
            items == 1 ? "1 action item" : "\(items) action items",
        ].joined(separator: " · ")
    }
}

/// The "Last 7 days" card's bars.
enum HomeWeek {
    static let days = 7

    /// The last seven calendar days ending today, zero-filled.
    static func bars(_ daily: [HistoryStore.DaySample], now: Date, calendar: Calendar = .current) -> [StatsBar] {
        StatsSeries.days(count: days, daily: daily, now: now, calendar: calendar)
    }
}
