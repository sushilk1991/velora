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
    /// The narrowest right column whose "Ways to talk" titles stay on one
    /// line (measured on screen); narrower, the grid stacks.
    private static let minimumWaysWidth: CGFloat = 300
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
                DictationButton(
                    activity: actions.dictation, hotkey: model.hotkey,
                    toggle: actions.toggleDictation)
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
        HeaderMenu(
            "Microphone", value: microphoneName, systemImage: "mic",
            selection: $model.inputDeviceUID
        ) {
            HomeMicrophoneRows(selected: model.inputDeviceUID, devices: inputDevices)
        }
    }

    private var microphoneName: String {
        HomeMicrophone.value(selected: model.inputDeviceUID, devices: inputDevices)
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
                        "Time saved", emphasis: .accent)
                    weekMetric(HistoryJournal.grouped(stats.count), "Dictations")
                }
                weekChart
            }
            .padding(VeloraSpacing.l)
        }
    }

    /// Label over value, as Stats' tiles read, so the same number carries
    /// the same name in both panes.
    private func weekMetric(_ value: String, _ label: String, emphasis: StatEmphasis = .plain) -> some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(emphasis == .accent ? AnyShapeStyle(VeloraBrand.accent) : AnyShapeStyle(.primary))
                .lineLimit(1)
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

    /// Two columns sized against the width the scroll view offers (no
    /// GeometryReader, so the grid keeps its natural height and never clips
    /// a tall column).
    private var grid: some View {
        HomeColumns(
            leadingShare: CGFloat(Self.recentColumnSpan) / CGFloat(Self.gridColumns),
            spacing: VeloraSpacing.m,
            stackSpacing: Self.sectionSpacing,
            minimumTrailing: Self.minimumWaysWidth
        ) {
            recentCard
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                waysToTalk
                meetingsCard
                learnedCard
            }
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
                    Button("Open Notes") { actions.openMeetingNotes(meeting.id) }
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

/// Home's Start Dictation, which reads Stop while listening. Its own view so
/// a phase change redraws the button, not the pane. Dictated from here, the
/// words go to the clipboard (Velora has no field in front), and the
/// tooltip says so before the pill does.
private struct DictationButton: View {
    @ObservedObject var activity: DictationActivity
    let hotkey: Hotkey
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: VeloraSpacing.s) {
                // Both titles laid out, one shown: the capsule keeps the
                // wider one's width, so the mic chooser beside it stays put
                // when Start turns to Stop.
                ZStack {
                    Text(HomeDictation.startTitle).hidden()
                    Text(HomeDictation.stopTitle).hidden()
                    Text(HomeDictation.title(for: activity.phase))
                }
                Text(hotkey.displayLabel)
                    .font(.system(size: 11))
                    .opacity(0.8)
            }
        }
        .buttonStyle(.primaryCapsule)
        .disabled(!HomeDictation.isEnabled(for: activity.phase))
        .help("Copies what you say to the clipboard. To type into an app, press \(hotkey.displayLabel) there.")
    }
}

/// Home's two top-aligned columns: the offered width, less the gap, split
/// `leadingShare : rest`. It reports the offered width as its own.
/// containerRelativeFrame measured the scroll view instead: its full width,
/// so a visible scroller covered the right card's edge, and before the
/// scroll view had a size, the window's width, which pushed Home 252 pt
/// (the rail and its insets) past the window. When the right column would
/// get less than `minimumTrailing`, the columns stack at full width so a
/// narrow window reflows instead of breaking the right column's titles.
///
///     wide:   ├──────────── offered width ────────────┤
///             ┌ Recent ─────────────┐ gap ┌ Ways ─────┐
///             │ leadingShare        │     │ rest      │
///             └─────────────────────┘     └───────────┘
///     narrow: ┌ Recent ───────────────────────────────┐
///             └───────────────────────────────────────┘
///             ┌ Ways, Meetings ───────────────────────┐
///             └───────────────────────────────────────┘
private struct HomeColumns: Layout {
    let leadingShare: CGFloat
    let spacing: CGFloat
    let stackSpacing: CGFloat
    let minimumTrailing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // An ideal-size query (no width) gets the columns' own ideal widths.
        let width = proposal.width
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(spacing, +)
        let height = columnFrames(width: width, subviews: subviews).map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for (subview, frame) in zip(subviews, columnFrames(width: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    /// Each column's frame at its natural height: side by side, or stacked
    /// at full width when the right column would be too narrow.
    private func columnFrames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let available = max(width - spacing, 0)
        let leading = (available * leadingShare).rounded(.down)
        let trailing = available - leading

        guard trailing >= minimumTrailing else {
            var y: CGFloat = 0
            return subviews.map { subview in
                let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                defer { y += height + stackSpacing }
                return CGRect(x: 0, y: y, width: width, height: height)
            }
        }

        var x: CGFloat = 0
        return zip(subviews, [leading, trailing]).map { subview, columnWidth in
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            defer { x += columnWidth + spacing }
            return CGRect(x: x, y: 0, width: columnWidth, height: height)
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

/// Home's microphone chooser: the capsule's value, and the row that keeps
/// an unplugged chosen mic selected. Without that row no menu item carries
/// the selection's tag, so nothing is checked and SwiftUI logs an invalid
/// selection; Settings › Dictation and the pill keep the same row.
enum HomeMicrophone {
    static let unpluggedRowTitle = "Chosen Microphone (Not Connected)"

    static func value(selected uid: String?, devices: [AudioInputDevices.Device]) -> String {
        guard let uid else {
            return "System Default"
        }

        return devices.first { $0.uid == uid }?.name ?? "Microphone Not Connected"
    }

    /// The chosen mic's id when it is not connected, for its own row.
    static func unplugged(selected uid: String?, devices: [AudioInputDevices.Device]) -> String? {
        guard let uid, !devices.contains(where: { $0.uid == uid }) else {
            return nil
        }

        return uid
    }
}

/// The chooser's rows, each tagged with the `String?` its binding holds:
/// System Default (nil), every connected mic, and the chosen one while it
/// is unplugged. A tag of any other type never selects.
struct HomeMicrophoneRows: View {
    /// One row's title and the microphone id it selects.
    struct Row: Equatable {
        let title: String
        let uid: String?
    }

    static let systemDefault = Row(title: "System Default", uid: nil)

    let selected: String?
    let devices: [AudioInputDevices.Device]

    /// The rows below the divider: every connected mic, then the chosen
    /// one while it is unplugged.
    ///
    ///     System Default                          nil
    ///     ──────────────
    ///     MacBook Pro Microphone                  "builtin"
    ///     Chosen Microphone (Not Connected)       "usb-gone"
    static func choices(selected: String?, devices: [AudioInputDevices.Device]) -> [Row] {
        var rows = devices.map { Row(title: $0.name, uid: $0.uid) }
        if let uid = HomeMicrophone.unplugged(selected: selected, devices: devices) {
            rows.append(Row(title: HomeMicrophone.unpluggedRowTitle, uid: uid))
        }
        return rows
    }

    var body: some View {
        Text(Self.systemDefault.title).tag(Self.systemDefault.uid)
        Divider()
        ForEach(Self.choices(selected: selected, devices: devices), id: \.uid) { row in
            Text(row.title).tag(row.uid)
        }
    }
}

/// Home's Start Dictation button, which follows the dictation phase like
/// the menubar item: Stop while listening, and disabled while a take is
/// written up, when the toggle does nothing.
enum HomeDictation {
    static let startTitle = "Start Dictation"
    static let stopTitle = "Stop Dictation"

    static func title(for phase: DictationController.Phase) -> String {
        switch phase {
        case .starting, .recording:
            return stopTitle
        case .idle, .transcribing, .editing:
            return startTitle
        }
    }

    static func isEnabled(for phase: DictationController.Phase) -> Bool {
        switch phase {
        case .idle, .starting, .recording:
            return true
        case .transcribing, .editing:
            return false
        }
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
