import AppKit
import Foundation
import SwiftUI

/// Home, Stats, History, Dictionary and Modes: the store queries behind the
/// Swift Charts Stats pane and the content-pane fixes (locale times, the
/// Reprocess mode list, the Home → History hand-off, Modes drafts, promoting
/// auto-learned words).
extension Selftest {

    // MARK: - Suite entry point

    static func testContentPanes() {
        testStatsWindowComparisons()
        testStatsMonthlySeries()
        testStatsWeekdayHourGrid()
        testHomeWeekSummary()
        testStatsRangeSummary()
        testStatsPresentationMaths()
        testStatsHoursAcrossDST()
        testHistoryLocaleTimes()
        testHistoryReprocessModes()
        testHistoryRevealHandOff()
        testModesDraftGuard()
        testModesProtectionAndSymbols()
        testDictionaryPromoteAutomatic()
        testDictionarySourceLabels()
        testDictionaryBulkForgetCopy()
        testDictionarySelectionAfterChange()
        testDictionaryRowKeys()
        testDictionarySavedRowID()
        testDictionaryFilterMemo()
        testDictionaryPromotedRow()
        testDictionaryOpenAction()
        testDictionaryListWindowKeys()
        testDictionaryListClick()
        testDictionaryListRemove()
        testDictionaryListScrolling()
        testDictionaryListInactiveWindow()
        testDictionaryListRevealFromEmpty()
        testDictionaryListAccessibility()
    }

    // MARK: - Fixtures

    /// A throwaway store in its own temp directory.
    private static func withContentStore(_ body: (HistoryStore) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-content-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        body(HistoryStore(url: dir.appendingPathComponent("history.sqlite3")))
        try? FileManager.default.removeItem(at: dir)
    }

    /// A temp directory removed after `body`.
    private static func withTempDirectory(_ body: (URL) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-content-dir-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        body(dir)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Added words named by their ids, for the Dictionary list's logic.
    private static func dictionaryRows(_ ids: String...) -> [DictionaryRow] {
        ids.map {
            DictionaryRow(
                id: $0, writeAs: $0, heardAs: nil,
                source: .added, isSoftCorrection: false, modifiedAt: Date())
        }
    }

    /// Local wall-clock time `daysAgo` calendar days back, at `hour`:`minute`.
    private static func localTime(daysAgo: Int, hour: Int, minute: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    /// A dictation of `words` tokens at `timestamp`.
    private static func contentRecord(
        at timestamp: Date, words: Int, durationMs: Int = 6_000,
        app: String = "TestApp", mode: String = "Default", bundle: String = "com.test.app"
    ) -> DictationRecord {
        let text = Array(repeating: "word", count: words).joined(separator: " ")
        return DictationRecord(
            timestamp: timestamp, bundleID: bundle, appName: app,
            raw: text, final: text, mode: mode, durationMs: durationMs, cleanupMs: nil)
    }

    private static func daysAgo(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -n, to: Date())!
    }

    // MARK: - Store queries

    /// Tiles compare each range with the equal-length window just before it:
    /// yesterday, days 7–13 back, days 30–59 back.
    private static func testStatsWindowComparisons() {
        withContentStore { store in
            store.insert(contentRecord(at: daysAgo(0), words: 1))
            store.insert(contentRecord(at: daysAgo(1), words: 10, durationMs: 4_000))
            store.insert(contentRecord(at: daysAgo(8), words: 100))
            store.insert(contentRecord(at: daysAgo(13), words: 200))
            store.insert(contentRecord(at: daysAgo(14), words: 400))
            store.insert(contentRecord(at: daysAgo(35), words: 1_000))
            store.insert(contentRecord(at: daysAgo(60), words: 2_000))

            let insights = store.insights()
            expect(insights.yesterday.words == 10 && insights.yesterday.count == 1,
                   "yesterday window holds only yesterday, got \(insights.yesterday.words)")
            expect(insights.previousWeek.words == 300,
                   "previous 7 days are days 7–13 back, got \(insights.previousWeek.words)")
            expect(insights.previousMonth.words == 1_000,
                   "previous 30 days are days 30–59 back, got \(insights.previousMonth.words)")
            expect(insights.activeDayCount == 7,
                   "active days count every distinct day, got \(insights.activeDayCount)")
            let key = DateFormatter()
            key.locale = Locale(identifier: "en_US_POSIX")
            key.dateFormat = "yyyy-MM-dd"
            expect(insights.firstDay == key.string(from: daysAgo(60)),
                   "first day is the oldest active day, got \(String(describing: insights.firstDay))")
            expect(insights.daily.first { $0.words == 10 }?.spokenMs == 4_000,
                   "daily samples carry speaking time for the time-saved sparkline")
        }
    }

    /// All time charts one bar per month from the first dictation.
    private static func testStatsMonthlySeries() {
        withContentStore { store in
            let dates = [daysAgo(0), daysAgo(1), daysAgo(70), daysAgo(400)]
            for (index, date) in dates.enumerated() {
                store.insert(contentRecord(at: date, words: 10 * (index + 1), durationMs: 1_000))
            }
            let monthKey = DateFormatter()
            monthKey.locale = Locale(identifier: "en_US_POSIX")
            monthKey.dateFormat = "yyyy-MM"
            var expected: [String: Int] = [:]
            for (index, date) in dates.enumerated() {
                expected[monthKey.string(from: date), default: 0] += 10 * (index + 1)
            }

            let monthly = store.insights().monthly
            expect(Dictionary(uniqueKeysWithValues: monthly.map { ($0.month, $0.words) }) == expected,
                   "monthly words group by local calendar month, got \(monthly)")
            expect(monthly.map(\.month) == monthly.map(\.month).sorted(),
                   "monthly samples ascend")
            expect(monthly.reduce(0) { $0 + $1.spokenMs } == 4_000,
                   "monthly samples carry speaking time")
        }
    }

    /// The heatmap buckets words by local weekday and hour, bounded by range.
    private static func testStatsWeekdayHourGrid() {
        withContentStore { store in
            let morning = localTime(daysAgo: 2, hour: 9)
            store.insert(contentRecord(at: morning, words: 10))
            store.insert(contentRecord(at: morning.addingTimeInterval(600), words: 5))
            store.insert(contentRecord(at: localTime(daysAgo: 2, hour: 21), words: 7))
            store.insert(contentRecord(at: localTime(daysAgo: 10, hour: 9), words: 100))

            let weekday = Calendar.current.component(.weekday, from: morning)
            let week = store.weekdayHourWords(daysBack: 6)
            expect(week.first { $0.weekday == weekday && $0.hour == 9 }?.words == 15,
                   "one weekday × hour cell sums its rows, got \(week)")
            expect(week.first { $0.weekday == weekday && $0.hour == 21 }?.words == 7,
                   "evening rows land in their own hour")
            expect(week.reduce(0) { $0 + $1.words } == 22,
                   "a 7-day grid leaves out older rows")
            let all = store.weekdayHourWords(daysBack: nil)
            expect(all.reduce(0) { $0 + $1.words } == 122, "all time covers every row")
            expect(all.allSatisfy { (1...7).contains($0.weekday) && (0..<24).contains($0.hour) },
                   "weekdays are 1–7 (Sunday first) and hours 0–23")
        }
    }

    /// Home's "Last 7 days" card reads only the 7-day window and its days.
    private static func testHomeWeekSummary() {
        withContentStore { store in
            store.insert(contentRecord(at: daysAgo(0), words: 4, durationMs: 2_000))
            store.insert(contentRecord(at: daysAgo(3), words: 6, durationMs: 3_000))
            store.insert(contentRecord(at: daysAgo(10), words: 50))

            let summary = store.weekSummary()
            expect(summary.week.words == 10 && summary.week.count == 2 && summary.week.spokenMs == 5_000,
                   "week summary covers the last 7 days, got \(summary.week.words)")
            expect(summary.daily.count == 2 && summary.daily.last?.words == 4,
                   "week summary lists its active days, today last")
            expect(HomeWeek.bars(summary.daily, now: Date()).count == 7,
                   "the Home card always draws seven days")
        }
    }

    /// A range's apps, modes, hours and ready times come from SQL over
    /// every row in the window. There is no scan cap, so all time reaches
    /// the oldest row, the same population as the headline.
    private static func testStatsRangeSummary() {
        withContentStore { store in
            var old = contentRecord(at: localTime(daysAgo: 400, hour: 9), words: 30, app: "Mail", mode: "email")
            old.finalizationMs = 3_000
            store.insert(old)
            var morning = contentRecord(
                at: localTime(daysAgo: 1, hour: 9), words: 10, durationMs: 2_000,
                app: "Slack", mode: "", bundle: "com.old.slack")
            morning.finalizationMs = 800
            store.insert(morning)
            var evening = contentRecord(
                at: localTime(daysAgo: 0, hour: 21), words: 5, durationMs: 1_000,
                app: "Slack", mode: "message", bundle: "com.new.slack")
            evening.finalizationMs = 1_200
            store.insert(evening)
            store.insert(contentRecord(at: localTime(daysAgo: 0, hour: 22), words: 7, app: "", mode: "message", bundle: ""))

            let month = store.rangeSummary(daysBack: 29)
            expect(month.apps.map(\.name) == ["Slack", "Unknown app"] && month.apps.first?.words == 15,
                   "30-day apps skip older rows and name blank apps, got \(month.apps)")
            expect(month.appBundles["Slack"] == "com.new.slack",
                   "an app's icon comes from its newest bundle id, got \(month.appBundles)")
            expect(month.readyMs == [800, 1_200],
                   "ready times ascend and skip rows without one, got \(month.readyMs)")
            expect(month.hours.first { $0.hour == 21 }?.words == 5
                    && month.hours.first { $0.hour == 9 }?.spokenMs == 2_000,
                   "hours bucket by local wall-clock hour, got \(month.hours)")

            let detail = StatsRangeDetail.make(summary: month)
            expect(detail.modes.map(\.name) == ["Message", "Default"] && detail.modes.first?.words == 12,
                   "modes fold to display names, most words first, got \(detail.modes)")
            expect(detail.hourlyWords[21] == 5 && detail.hourlyCounts[22] == 1,
                   "hour samples fill the 24 buckets")
            expect(detail.readyMedianMs == 800 && detail.readySlowestMs == 1_200,
                   "percentiles read the SQL ready times")

            let all = store.rangeSummary(daysBack: nil)
            expect(all.apps.contains { $0.name == "Mail" } && all.readyMs == [800, 1_200, 3_000],
                   "all time covers the oldest row, got \(all.apps) / \(all.readyMs)")
        }
    }

    // MARK: - Stats presentation

    private static func testStatsPresentationMaths() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.firstWeekday = 2
        // Tuesday 8 September 2026, 14:30 local.
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 8, hour: 14, minute: 30))!

        // Pace headline: words per speaking minute against the typing speed.
        expect(StatsHeadline.pace(words: 32_739, spokenMs: 262 * 60_000, typingWPM: 40)
                == "You speak at 125 wpm, 3.1× your typing speed",
               "pace headline, got \(String(describing: StatsHeadline.pace(words: 32_739, spokenMs: 262 * 60_000, typingWPM: 40)))")
        expect(StatsHeadline.pace(words: 1_200, spokenMs: 10 * 60_000, typingWPM: 40)
                == "You speak at 120 wpm, 3× your typing speed",
               "a whole multiple drops the decimal")
        expect(StatsHeadline.pace(words: 400, spokenMs: 10 * 60_000, typingWPM: 40)
                == "You speak at 40 wpm",
               "no multiple when speaking is no faster than typing")
        expect(StatsHeadline.pace(words: 50, spokenMs: 20_000, typingWPM: 40) == nil,
               "under a minute of speech is too little to quote a pace")

        // Deltas against the previous window.
        expect(StatsFormat.delta(32_739, 30_016, range: .thirtyDays) == "↑ 9% vs previous 30 days",
               "rising delta")
        expect(StatsFormat.delta(269, 331, range: .sevenDays) == "↓ 19% vs previous 7 days",
               "falling delta")
        expect(StatsFormat.delta(5, 5, range: .today) == "Same as yesterday", "flat delta")
        expect(StatsFormat.delta(5, 0, range: .today) == nil, "no baseline, no delta")
        expect(StatsFormat.delta(5, 4, range: .allTime) == nil, "all time has no previous window")

        // All time: a bar per month from the first month, zero-filled.
        var insights = HistoryStore.Insights()
        insights.monthly = [
            HistoryStore.MonthSample(month: "2026-06", count: 3, words: 100, spokenMs: 0),
            HistoryStore.MonthSample(month: "2026-09", count: 1, words: 50, spokenMs: 0),
        ]
        let months = StatsSeries.bars(
            range: .allTime, insights: insights, detail: StatsRangeDetail(), now: now, calendar: calendar)
        expect(months.map(\.words) == [100, 0, 0, 50],
               "all time charts every month since the first, got \(months.map(\.words))")
        expect(StatsSeries.bars(range: .today, insights: insights, detail: StatsRangeDetail(),
                                now: now, calendar: calendar).count == 24,
               "today charts 24 hours")
        expect(StatsSeries.bars(range: .thirtyDays, insights: insights, detail: StatsRangeDetail(),
                                now: now, calendar: calendar).count == 30,
               "30 days charts 30 days")
        expect(StatsSeries.bestCaption(bars: months, range: .allTime)?.hasPrefix("Best month") == true,
               "all time names its best month")
        expect(StatsSeries.average(months) == 37.5, "average spans every bar, empty ones included")

        // Ready-in histogram: 1 s bins with a 10 s+ overflow.
        let bins = StatsLatency.bins([400, 900, 1_500, 2_200, 12_000, 30_000])
        expect(bins.count == StatsLatency.binCount && bins.map(\.count).reduce(0, +) == 6,
               "every sample lands in one bin")
        expect(bins[0].count == 2 && bins[1].count == 1 && bins.last?.count == 2,
               "sub-second, 1–2 s and 10 s+ bins, got \(bins.map(\.count))")

        // Modes: the top three by words, the rest folded into Other.
        let modeShares = StatsModes.shares([
            HistoryStore.BreakdownSlice(name: "Default", count: 1, words: 600),
            HistoryStore.BreakdownSlice(name: "Terminal", count: 1, words: 200),
            HistoryStore.BreakdownSlice(name: "Message", count: 1, words: 100),
            HistoryStore.BreakdownSlice(name: "Email", count: 1, words: 60),
            HistoryStore.BreakdownSlice(name: "Note", count: 1, words: 40),
        ])
        expect(modeShares.map(\.name) == ["Default", "Terminal", "Message", "Other"],
               "modes fold the tail into Other, got \(modeShares.map(\.name))")
        expect(modeShares.map(\.percent) == [60, 20, 10, 10], "mode shares are of all words")

        // Calendar: twelve weekday-aligned columns ending today.
        let daily = [HistoryStore.DaySample(day: "2026-09-08", count: 1, words: 9)]
        let cells = StatsCalendar.cells(daily: daily, now: now, calendar: calendar)
        expect(cells.count == HistoryStore.heatmapDays, "one cell per day of the 12 weeks")
        expect(cells.last?.words == 9 && cells.last?.row == 1,
               "today is the last cell, on Tuesday's row when weeks start Monday")
        expect(Set(cells.map(\.column)).count == 13 && cells.first?.row == 2,
               "84 days starting on a Wednesday span 13 week columns")
        expect(StatsWeekdays.order(calendar: calendar).first == 2,
               "heatmap rows start on the locale's first weekday")

        // Active days read against the range length (all time: since the first day).
        insights.activeDayCount = 63
        insights.firstDay = "2026-06-11"
        insights.daily = (0..<5).map { HistoryStore.DaySample(day: "2026-09-0\($0 + 1)", count: 1, words: 1) }
        expect(StatsActivity.activeDays(range: .thirtyDays, insights: insights, now: now, calendar: calendar)
                == StatsActivity.Days(active: 5, total: 30),
               "30-day active days count the daily series")
        expect(StatsActivity.activeDays(range: .allTime, insights: insights, now: now, calendar: calendar)
                == StatsActivity.Days(active: 63, total: 90),
               "all-time active days run from the first day, inclusive")

        // Shares use largest-remainder rounding, so they total exactly 100
        // (plain rounding gives 335/335/330 → 34 + 34 + 33 = 101).
        let thirds = [335, 335, 330].enumerated().map {
            HistoryStore.BreakdownSlice(name: "M\($0.offset)", count: 1, words: $0.element)
        }
        let modeThirds = StatsModes.shares(thirds).map(\.percent)
        expect(modeThirds == [34, 33, 33], "mode shares total 100, got \(modeThirds)")
        let appThirds = StatsTopApps.shares(thirds).map(\.percent)
        expect(appThirds.reduce(0, +) == 100, "app shares total 100, got \(appThirds)")
        let sevenths = (0..<7).map { HistoryStore.BreakdownSlice(name: "M\($0)", count: 1, words: 1) }
        let modeSevenths = StatsModes.shares(sevenths).map(\.percent)
        expect(modeSevenths.reduce(0, +) == 100 && modeSevenths.last == 57,
               "top three plus Other total 100 with repeating sevenths, got \(modeSevenths)")

        // All time draws at most 24 months; a longer history says so.
        var long = HistoryStore.Insights()
        long.monthly = [HistoryStore.MonthSample(month: "2024-01", count: 1, words: 1, spokenMs: 0)]
        expect(StatsSeries.title(range: .allTime, insights: long, now: now, calendar: calendar)
                == "Words per month, last 24 months",
               "a history past 24 months labels the cut")
        long.monthly = [HistoryStore.MonthSample(month: "2025-12", count: 1, words: 1, spokenMs: 0)]
        expect(StatsSeries.title(range: .allTime, insights: long, now: now, calendar: calendar) == "Words per month",
               "a shorter history needs no label")
        expect(StatsSeries.title(range: .sevenDays, insights: long, now: now, calendar: calendar) == "Words per day",
               "day ranges chart words per day")

        // The Active days tile's dot strip: one flag per day, oldest first,
        // today last. Today and 7 days draw a week; 30 days and all time
        // draw the last 30 days (the daily series holds 84 days, too many
        // dots for a tile).
        let week = StatsActivity.strip(range: .sevenDays, insights: insights, now: now, calendar: calendar)
        expect(week == [true, true, true, true, false, false, false],
               "7-day strip runs Sep 2 through today, got \(week)")
        expect(StatsActivity.strip(range: .today, insights: insights, now: now, calendar: calendar) == week,
               "the Streak tile draws the same week")
        let month = StatsActivity.strip(range: .thirtyDays, insights: insights, now: now, calendar: calendar)
        expect(month.count == 30 && month.filter { $0 }.count == 5 && month.suffix(3) == [false, false, false],
               "30-day strip holds 30 days with the 5 active ones, got \(month)")
        expect(StatsActivity.strip(range: .allTime, insights: insights, now: now, calendar: calendar) == month,
               "all time draws the last 30 days")
    }

    /// Today's hour bars follow SQLite's wall-clock %H buckets. On the
    /// spring-forward day 01:00 doesn't exist, so the chart has 23 bars and
    /// each bar starts at its own wall-clock hour, not midnight + n hours.
    private static func testStatsHoursAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        // Sunday 29 March 2026: clocks go from 01:00 GMT to 02:00 BST.
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12))!
        var detail = StatsRangeDetail()
        detail.hourlyWords[3] = 10

        let bars = StatsSeries.bars(
            range: .today, insights: HistoryStore.Insights(), detail: detail, now: now, calendar: calendar)
        let hours = bars.map { calendar.component(.hour, from: $0.date) }
        expect(bars.count == 23 && !hours.contains(1),
               "spring-forward day skips the missing 01:00, got \(hours)")
        expect(bars.first { $0.words == 10 }.map { calendar.component(.hour, from: $0.date) } == 3,
               "03:00 words sit on the 03:00 bar")
        expect(Set(bars.map(\.date)).count == bars.count, "hour bars never share a start")
    }

    // MARK: - History

    /// The time gutter follows the locale's hour cycle.
    private static func testHistoryLocaleTimes() {
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "Europe/London")!
        calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 13, minute: 21))!
        let us = HistoryJournal.time(date, locale: Locale(identifier: "en_US"), timeZone: zone)
        let uk = HistoryJournal.time(date, locale: Locale(identifier: "en_GB"), timeZone: zone)
        expect(us.hasPrefix("1:21") && us.contains("PM"), "12-hour locale reads 1:21 PM, got \(us)")
        expect(uk == "13:21", "24-hour locale reads 13:21, got \(uk)")
    }

    /// Reprocess offers every mode the Modes pane has, not a fixed six.
    private static func testHistoryReprocessModes() {
        withTempDirectory { dir in
            for (file, name) in [("terminal.json", "Terminal"), ("standup.json", "Standup Notes")] {
                let data = try! JSONSerialization.data(withJSONObject: ["name": name, "prompt": "p"])
                try! data.write(to: dir.appendingPathComponent(file))
            }
            withContentStore { store in
                let vm = HistoryViewModel(history: store, supervisor: nil, modesDirectory: dir)
                expect(vm.modeNames.contains("Terminal") && vm.modeNames.contains("Standup Notes"),
                       "reprocess lists modes from the modes directory, got \(vm.modeNames)")
                expect(vm.modeNames.contains("Default") && vm.modeNames.contains("Raw"),
                       "built-in modes stay listed without files")
                expect(vm.modeNames.first == "Default", "Default leads the reprocess list")
            }
        }
    }

    /// A Home Recent row opens History with that entry expanded.
    private static func testHistoryRevealHandOff() {
        withContentStore { store in
            store.insert(contentRecord(at: daysAgo(0).addingTimeInterval(-120), words: 3))
            store.insert(contentRecord(at: daysAgo(0), words: 4))
            let drained = DispatchSemaphore(value: 0)
            store.drain { drained.signal() }
            drained.wait()
            let target = store.recent(limit: 2).last!.id

            HistoryViewModel.requestReveal(target)
            let vm = HistoryViewModel(history: store, supervisor: nil)
            vm.reload()
            vm.revealPending()
            expect(vm.expandedID == target, "the requested entry opens expanded")

            vm.reload()
            vm.revealPending()
            expect(vm.expandedID == nil, "the reveal is one-shot")
        }
    }

    // MARK: - Modes

    /// Switching modes or adding one never drops unsaved edits silently.
    private static func testModesDraftGuard() {
        withTempDirectory { dir in
            let vm = ModesViewModel(supervisor: nil, directory: dir)
            vm.select("email")
            vm.draft.prompt = "Edited prompt"
            expect(vm.isDirty, "an edited draft is dirty")

            vm.requestSelect("message")
            expect(vm.selectedID == "email" && vm.draft.prompt == "Edited prompt",
                   "switching with unsaved edits keeps the draft")
            expect(vm.pendingChange == .select("message"), "the switch waits for a decision")

            vm.saveAndContinue()
            expect(vm.selectedID == "message" && vm.pendingChange == nil,
                   "saving completes the switch")
            let reread = ModesViewModel(supervisor: nil, directory: dir)
            expect(reread.modes.first { $0.name == "Email" }?.prompt == "Edited prompt",
                   "save-and-continue wrote the edit")

            vm.draft.prompt = "Throwaway"
            vm.requestNewMode()
            expect(vm.pendingChange == .newMode && vm.draft.prompt == "Throwaway",
                   "New Mode waits too")
            vm.discardAndContinue()
            expect(vm.selectedName?.hasPrefix("New Mode") == true,
                   "discarding completes the pending New Mode")
            expect(vm.modes.first { $0.name == "Message" }?.prompt != "Throwaway",
                   "discarded edits are gone")

            vm.requestSelect("email")
            expect(vm.pendingChange == .select("email"),
                   "an unsaved new mode also asks before it is dropped")
            vm.discardAndContinue()
            expect(!vm.modes.contains { $0.name.hasPrefix("New Mode") },
                   "discarding an unsaved new mode removes it")

            vm.draft.prompt = "Parked edit"
            vm.park()
            let returned = ModesViewModel(supervisor: nil, directory: dir)
            expect(returned.selectedID == "email" && returned.draft.prompt == "Parked edit"
                    && returned.isDirty,
                   "leaving the pane parks the draft for the next visit")
        }
    }

    private static func testModesProtectionAndSymbols() {
        withTempDirectory { dir in
            let vm = ModesViewModel(supervisor: nil, directory: dir)
            vm.select("default")
            expect(!vm.canDelete, "a protected built-in can't be deleted")
            vm.select("email")
            expect(!vm.canDelete, "a mode Velora ships resets instead of deleting")
            vm.newMode()
            vm.save()
            expect(vm.canDelete, "a mode you made can be deleted")
        }
        let terminal = Mode(name: "Terminal", prompt: "", formatting: "off",
                            apps: [], vocabulary: [], replacements: [])
        expect(terminal.symbol == "terminal", "Terminal mode has its own symbol")
        let code = Mode(name: "Code", prompt: "", formatting: "light",
                        apps: [], vocabulary: [], replacements: [])
        expect(code.symbol == "chevron.left.forwardslash.chevron.right", "Code keeps its symbol")
    }

    // MARK: - Dictionary

    /// A row says where it came from in words, not "Auto" or "Learned",
    /// and search finds a row by the words it shows.
    private static func testDictionarySourceLabels() {
        func row(_ id: String, _ source: DictionarySource, soft: Bool = false) -> DictionaryRow {
            DictionaryRow(
                id: id, writeAs: "Term \(id)", heardAs: nil,
                source: source, isSoftCorrection: soft, modifiedAt: Date())
        }
        let found = row("1", .automatic)
        let edit = row("2", .learned)
        let softEdit = row("3", .learned, soft: true)
        let added = row("4", .added)

        expect(DictionarySettingsLogic.sourceLabel(found) == "Found in your dictations",
               "an auto-learned word reads as found in your dictations")
        expect(DictionarySettingsLogic.sourceLabel(edit) == "From your edit",
               "a learned correction reads as from your edit")
        expect(DictionarySettingsLogic.sourceLabel(softEdit) == "From your edit · Context-aware",
               "a context-aware correction keeps its qualifier")
        expect(DictionarySettingsLogic.sourceLabel(added) == "Added",
               "an added word still reads Added")

        let rows = [found, edit, softEdit, added]
        expect(DictionarySettingsLogic.filtered(rows, query: "dictations").map(\.id) == ["1"],
               "searching the shown origin finds auto-learned words")
        expect(DictionarySettingsLogic.filtered(rows, query: "your edit").map(\.id) == ["2", "3"],
               "searching the shown origin finds learned corrections")
        expect(DictionarySettingsLogic.filtered(rows, query: "auto").map(\.id) == ["1"],
               "the old source name still finds auto-learned words")
    }

    /// The ⋯ menu forgets learned words in bulk, in the rows' own terms:
    /// each confirmation repeats its rows' caption, the items read as
    /// menu commands, and no copy promises more than the remove does
    /// (bans are capped, so a forgotten word can come back).
    private static func testDictionaryBulkForgetCopy() {
        typealias Logic = DictionarySettingsLogic
        expect(Logic.BulkForget.allCases.map(\.source) == [.learned, .automatic],
               "only learned words are forgotten in bulk; added words go one at a time")

        let stale = ["Auto", "auto-learned", "Learned", "learned", "miner"]
        let permanence = ["again", "never", "won’t", "won't", "permanent"]
        for kind in Logic.BulkForget.allCases {
            let caption = Logic.sourceLabel(DictionaryRow(
                id: "x", writeAs: "x", heardAs: nil,
                source: kind.source, isSoftCorrection: false, modifiedAt: Date()))
            let item = Logic.bulkForgetItem(kind)
            let title = Logic.bulkForgetTitle(kind)
            let message = Logic.bulkForgetMessage(kind)
            let originWord = caption.split(separator: " ").last.map(String.init) ?? caption

            expect(item.hasPrefix("Forget ") && item.hasSuffix("…"),
                   "\(item) is a Forget command that opens a confirmation")
            expect(item.localizedCaseInsensitiveContains(originWord),
                   "\(item) names the rows' origin (\(originWord))")
            expect(title.hasSuffix("?") && title.localizedCaseInsensitiveContains(caption),
                   "\(title) repeats the rows' caption \(caption)")
            expect(!permanence.contains { message.contains($0) },
                   "\(message) says only what the remove does now")
            for text in [item, title, message] {
                expect(!stale.contains { text.contains($0) }, "bulk forget copy drops the old source names: \(text)")
            }
        }
        expect(Set(Logic.BulkForget.allCases.map(Logic.bulkForgetItem)).count == Logic.BulkForget.allCases.count,
               "each bulk forget item is distinct")
    }

    /// When the rows change (⌫, the ⋯ menu, a context menu, Make Permanent,
    /// sync, a search), the selection stays on its row while that row is
    /// listed, else moves to the nearest row still listed, next first, not
    /// back to the top. With none of its neighbours left, the first row,
    /// but only in a focused list: without focus, nothing.
    private static func testDictionarySelectionAfterChange() {
        let rows = dictionaryRows("a", "b", "c", "d")
        func keep(_ ids: String...) -> [DictionaryRow] {
            rows.filter { ids.contains($0.id) }
        }
        func after(
            _ selected: String?, _ new: [DictionaryRow],
            _ focus: DictionarySettingsLogic.ListFocus = .focused
        ) -> String? {
            DictionarySettingsLogic.selectionAfterChange(selected, from: rows, to: new, focus: focus)
        }

        expect(after("b", keep("a", "c", "d")) == "c", "a removed row hands the selection to the next row")
        expect(after("d", keep("a", "b", "c")) == "c", "removing the last row moves the selection up")
        expect(after("b", keep("a", "d")) == "d", "a bulk remove skips rows that left too")
        expect(after("c", keep("a")) == "a", "with nothing after it, the selection goes to the nearest row before")
        expect(after("b", keep("b", "c")) == "b", "a selected row that is still listed stays selected")
        expect(after(nil, keep("a")) == nil, "no selection, nothing to move")
        expect(after("b", []) == nil, "an emptied list has nothing to select")
        expect(after("gone", keep("a")) == "a", "a selection that was never listed falls back to the first row")
        expect(after("b", dictionaryRows("x", "y")) == "x",
               "a sync that replaced every row selects the first new row, so a focused list keeps a selection")
        // The editor selects a saved entry before the rows change; an edit
        // gives it a new id at the top of the list.
        expect(after("b2", dictionaryRows("b2") + keep("a", "c", "d")) == "b2",
               "an edited entry selected under its new id stays selected, not b's old neighbour")

        // A search from "a" to "z" in a list without focus replaces every
        // row; it must not select one the user never picked.
        expect(after("b", dictionaryRows("x", "y"), .unfocused) == nil,
               "without focus, a list whose rows were all replaced selects nothing")
        expect(after("b", keep("a", "c", "d"), .unfocused) == "c",
               "without focus, a removed row still hands the selection to its neighbour")
    }

    /// The list answers keys like a native table, on its selection: ⌫ and
    /// ⌦ ask to remove the selected row, the arrows move the selection and
    /// stop at the ends, and Return opens it as a double-click does. Focus
    /// lands on the selection while it is listed, unless a click brought it.
    private static func testDictionaryRowKeys() {
        let rows = dictionaryRows("a", "b", "c")
        func command(_ key: KeyEquivalent, _ id: String?) -> DictionarySettingsLogic.RowCommand? {
            DictionarySettingsLogic.rowCommand(
                for: key, on: id, in: rows, page: DictionarySettingsLogic.defaultPageRows)
        }

        expect(command(.delete, "b") == .confirmDelete(rows[1]),
               "⌫ asks to remove the selected row")
        expect(command(.deleteForward, "b") == .confirmDelete(rows[1]),
               "⌦ asks to remove the selected row")
        expect(command(.downArrow, "a") == .select("b") && command(.upArrow, "c") == .select("b"),
               "the arrows select the neighbouring row")
        expect(command(.upArrow, "a") == nil && command(.downArrow, "c") == nil,
               "the arrows stop at the first and last rows")
        expect(command(.return, "b") == .open(rows[1]), "Return opens the selected row")
        expect(command(.space, "b") == nil, "Space passes through, as in a native table")
        expect(command(.downArrow, nil) == .select("a") && command(.upArrow, "gone") == .select("a"),
               "with no listed selection, an arrow selects the first row")
        expect(command(.delete, "gone") == nil && command(.return, nil) == nil && command(.tab, "b") == nil,
               "⌫ and Return need a listed selection, and other keys pass through")

        // Home and End go to the ends, Page Up and Down move a page of
        // rows (3 here); each stops at the ends, where it passes through.
        let long = dictionaryRows("r0", "r1", "r2", "r3", "r4", "r5", "r6")
        func paged(_ key: KeyEquivalent, _ id: String?) -> DictionarySettingsLogic.RowCommand? {
            DictionarySettingsLogic.rowCommand(for: key, on: id, in: long, page: 3)
        }
        expect(paged(.home, "r4") == .select("r0") && paged(.end, "r2") == .select("r6"),
               "Home and End select the first and last rows")
        expect(paged(.pageDown, "r1") == .select("r4") && paged(.pageUp, "r4") == .select("r1"),
               "Page Down and Page Up move the selection a page of rows")
        expect(paged(.pageDown, "r5") == .select("r6") && paged(.pageUp, "r1") == .select("r0"),
               "a page move stops at the first and last rows")
        expect(paged(.home, "r0") == nil && paged(.pageUp, "r0") == nil
                   && paged(.end, "r6") == nil && paged(.pageDown, "r6") == nil,
               "at the ends the page keys pass through, as the arrows do")
        expect(paged(.end, nil) == .select("r6") && paged(.home, "gone") == .select("r0")
                   && paged(.pageDown, nil) == .select("r0") && paged(.pageUp, nil) == .select("r0"),
               "with no listed selection, End selects the last row and the other page keys the first")
        expect(DictionarySettingsLogic.pageRows(viewport: 260, listHeight: 5_000, count: 100) == 5,
               "a page is the rows that fit in the visible height")
        expect(DictionarySettingsLogic.pageRows(viewport: 20, listHeight: 5_000, count: 100) == 1,
               "a page is at least one row")
        expect(DictionarySettingsLogic.pageRows(viewport: 0, listHeight: 0, count: 0) == nil
                   && DictionarySettingsLogic.defaultPageRows == 10,
               "until the list is measured, a page is 10 rows")

        let keys = DictionarySettingsLogic.rowKeys
        let openKeys = DictionarySettingsLogic.openKeys
        expect(keys == [.deleteForward, .upArrow, .downArrow, .home, .end, .pageUp, .pageDown],
               "the list takes ⌦, the arrows and the page keys, repeating while held")
        expect(openKeys == [.return], "Return is the list's one open key, taken without autorepeat")
        expect(!keys.union(openKeys).contains(.space), "Space is not a list key")
        expect(!keys.contains(.delete),
               "⌫ is not a list key: it reaches the list only as the Delete command")

        expect(DictionarySettingsLogic.selectionOnFocus(nil, in: rows) == "a",
               "focus with no selection selects the first row")
        expect(DictionarySettingsLogic.selectionOnFocus("c", in: rows) == "c",
               "focus keeps a listed selection")
        expect(DictionarySettingsLogic.selectionOnFocus("gone", in: rows) == "a",
               "a removed or filtered-out selection gives way to the first row")
        expect(DictionarySettingsLogic.selectionOnFocus(nil, in: []) == nil,
               "an empty list selects nothing")

        func pointer(_ event: NSEvent.EventType?, buttons: Int = 0) -> Bool {
            DictionarySettingsLogic.isPointerFocus(event, buttons: buttons)
        }
        expect(pointer(.leftMouseDown) && pointer(.leftMouseUp),
               "focus arriving during a click comes from the pointer")
        expect(pointer(.leftMouseDragged) && pointer(.pressure) && pointer(.otherMouseDown),
               "focus arriving during a drag, a Force Touch press or another button's click comes from the pointer")
        expect(pointer(.keyDown, buttons: 1) && pointer(nil, buttons: 1),
               "focus arriving while a mouse button is held comes from the pointer, whatever the event")
        expect(!pointer(.keyDown) && !pointer(nil),
               "focus from Tab, or with no event, is keyboard focus")

        // As in the sidebar, a list shows focus only in the key window.
        typealias Focus = DictionarySettingsLogic.ListFocus
        expect(Focus(listFocused: true, window: .key) == .focused,
               "a focused list in the key window shows focus")
        expect(Focus(listFocused: true, window: .active) == .unfocused
                   && Focus(listFocused: true, window: .inactive) == .unfocused
                   && Focus(listFocused: false, window: .key) == .unfocused,
               "a list keeps no focus mark once its window resigns key, nor without focus")

        let idle = DictionarySyncPresentation(.idle)
        expect(!idle.privacyDetail.contains("on this Mac"),
               "the idle footer says \"on this Mac\" once, in its title")
    }

    /// The row a saved editor selects: the entry that is new in the rows
    /// (an add, an edit that changed the entry's key, Make Permanent…),
    /// else the edited entry, which kept its id and moved to the top.
    private static func testDictionarySavedRowID() {
        let before = dictionaryRows("a", "b")
        func saved(_ editing: String?, _ after: [DictionaryRow]) -> String? {
            DictionarySettingsLogic.savedRowID(editing: editing, before: before, after: after)
        }

        expect(saved(nil, dictionaryRows("n", "a", "b")) == "n", "an added entry is selected")
        expect(saved("b", dictionaryRows("b2", "a")) == "b2",
               "an edit that changed the entry's key selects its new id")
        expect(saved("b", dictionaryRows("b", "a")) == "b", "an edit that kept its key keeps its id")
        expect(saved(nil, before) == nil, "no new entry and no edited one selects nothing")
    }

    /// The pane's filter memo answers as `filtered(_:query:)` does and runs
    /// again when the rows or the query change, so a search or a sync is
    /// never answered from the previous list.
    private static func testDictionaryFilterMemo() {
        let memo = DictionarySettingsLogic.FilterMemo()
        let rows = dictionaryRows("alpha", "beta")
        expect(memo.rows(rows, query: "").map(\.id) == ["alpha", "beta"], "an empty query lists every row")
        expect(memo.rows(rows, query: "").map(\.id) == ["alpha", "beta"], "the same input gives the same rows")
        expect(memo.rows(rows, query: "al").map(\.id) == ["alpha"], "a new query filters again")
        expect(memo.rows(rows + dictionaryRows("alps"), query: "al").map(\.id) == ["alpha", "alps"],
               "changed rows filter again under the same query")
    }

    // MARK: - Dictionary list in a window

    /// The state around a real `DictionaryEntryList`: its rows, search and
    /// selection, the rows it opened, and the window frames of the rows the
    /// lazy stack has built.
    private final class DictionaryListProbe: ObservableObject {
        @Published var rows: [DictionaryRow]
        @Published var query = ""
        @Published var selection: DictionaryRow.ID?
        @Published var reveal = false
        @Published var pending: DictionaryRow?
        /// The window state the list sees. The tests never make their
        /// window key, so the host hands the list this one instead.
        @Published var windowState: ControlActiveState = .key
        var opened: [DictionaryRow.ID] = []
        var frames: [DictionaryRow.ID: CGRect] = [:]

        init(rows: [DictionaryRow]) {
            self.rows = rows
        }

        /// Added words "Word 0"… with ids "row 0"….
        convenience init(words count: Int) {
            self.init(rows: (0..<count).map {
                DictionaryRow(
                    id: "row \($0)", writeAs: "Word \($0)", heardAs: nil,
                    source: .added, isSoftCorrection: false, modifiedAt: Date())
            })
        }
    }

    /// The Entries list as the pane hosts it: real rows under a search box,
    /// with the pane's delete confirmation, whose Remove drops the row. As
    /// in the pane, the list exists only while it has rows to show.
    private struct DictionaryListHost: View {
        @ObservedObject var probe: DictionaryListProbe

        var body: some View {
            let rows = DictionarySettingsLogic.filtered(probe.rows, query: probe.query)
            let content = VStack(spacing: 0) {
                TextField("Search", text: $probe.query)
                ScrollView {
                    if rows.isEmpty {
                        Text("No entries")
                    } else {
                        DictionaryEntryList(
                            label: "Entries",
                            rows: rows,
                            selection: $probe.selection,
                            reveal: $probe.reveal,
                            onOpen: { probe.opened.append($0.id) },
                            onEdit: { _ in },
                            onPromote: { _ in },
                            onDelete: { probe.pending = $0 },
                            rowFrame: { id, frame in probe.frames[id] = frame })
                    }
                }
            }
            .modifier(DictionaryDeleteConfirmation(row: $probe.pending) { row in
                probe.rows.removeAll { $0.id == row.id }
            })
            .environment(\.controlActiveState, probe.windowState)
            // A click reaches SwiftUI's gestures in a window that isn't key
            // only with activation events allowed; the tests never make
            // their window key.
            if #available(macOS 15, *) {
                content.allowsWindowActivationEvents(true)
            } else {
                content
            }
        }
    }

    /// A key: its key code, the character it types and its modifiers.
    private typealias DictionaryListKey = (code: Int, character: Int, flags: NSEvent.ModifierFlags)

    private static let dictionaryArrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]
    private static let dictionaryTab: DictionaryListKey = (48, 9, [])
    private static let dictionaryDown: DictionaryListKey = (125, NSDownArrowFunctionKey, dictionaryArrowFlags)
    private static let dictionaryReturn: DictionaryListKey = (36, 13, [])
    private static let dictionaryBackspace: DictionaryListKey = (51, 127, [])
    private static let dictionaryForwardDelete: DictionaryListKey = (117, NSDeleteFunctionKey, [.function])
    private static let dictionaryHome: DictionaryListKey = (115, NSHomeFunctionKey, [.function])
    private static let dictionaryEnd: DictionaryListKey = (119, NSEndFunctionKey, [.function])
    private static let dictionaryPageUp: DictionaryListKey = (116, NSPageUpFunctionKey, [.function])
    private static let dictionaryPageDown: DictionaryListKey = (121, NSPageDownFunctionKey, [.function])

    /// The host in a 600 × 300 window, ordered in but transparent. Nothing
    /// makes it key or activates the app.
    private static func dictionaryListWindow(_ probe: DictionaryListProbe) -> NSWindow {
        let window = MainWindowController.makeShellWindow(
            rootView: DictionaryListHost(probe: probe), title: "Selftest",
            size: NSSize(width: 600, height: 300), minimumSize: NSSize(width: 300, height: 150))
        window.alphaValue = 0
        window.orderFrontRegardless()
        waitUntil(timeout: 0.4) { false }
        return window
    }

    private static func dictionaryListViews<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else {
            return []
        }
        let own = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { dictionaryListViews(type, in: $0) }
    }

    /// Delivers `event` as a real one arrives: through the app's queue, so
    /// `NSApp.currentEvent` is this event while the window handles it.
    private static func dictionaryListSend(_ event: NSEvent, to window: NSWindow) {
        let app = NSApplication.shared
        app.postEvent(event, atStart: true)
        let mask = NSEvent.EventTypeMask(rawValue: 1 << UInt64(event.type.rawValue))
        guard let queued = app.nextEvent(matching: mask, until: Date(), inMode: .default, dequeue: true) else {
            return
        }
        window.sendEvent(queued)
    }

    private static func dictionaryListPress(
        _ window: NSWindow, _ key: DictionaryListKey, isARepeat: Bool = false, settle: TimeInterval = 0.2
    ) {
        let text = String(UnicodeScalar(UInt32(key.character)).map(Character.init) ?? " ")
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: key.flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text,
            isARepeat: isARepeat, keyCode: UInt16(key.code)) else {
            return
        }
        dictionaryListSend(event, to: window)
        waitUntil(timeout: settle) { false }
    }

    /// A left click at `point`, in the window's content view coordinates
    /// (top-left origin, as the rows' frames are).
    private static func dictionaryListClick(_ window: NSWindow, at point: CGPoint) {
        guard let content = window.contentView else {
            return
        }
        let location = content.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                return
            }
            dictionaryListSend(event, to: window)
            waitUntil(timeout: 0.1) { false }
        }
        waitUntil(timeout: 0.3) { false }
    }

    /// Tab past the search box until the list takes focus, which selects
    /// a row. Tab moves focus only once something in the key loop has it,
    /// so the first key view takes it directly.
    private static func dictionaryListTabIn(_ window: NSWindow, _ probe: DictionaryListProbe) {
        window.selectNextKeyView(nil)
        waitUntil(timeout: 0.2) { false }
        for _ in 0..<4 where probe.selection == nil {
            dictionaryListPress(window, dictionaryTab)
        }
    }

    /// The list's scroll view, and its visible rect in content coordinates.
    private static func dictionaryListScroller(_ window: NSWindow) -> (view: NSScrollView, visible: CGRect)? {
        let scrollers = dictionaryListViews(NSScrollView.self, in: window.contentView)
        guard let scroller = scrollers.max(by: { $0.frame.height < $1.frame.height }),
              let content = window.contentView else {
            return nil
        }
        return (scroller, content.convert(scroller.bounds, from: scroller))
    }

    /// Scrolls the document so `y` points down from its top sit above the
    /// view, as a trackpad would, without touching focus or selection.
    private static func dictionaryListScroll(_ scroller: NSScrollView, to y: CGFloat) {
        guard let document = scroller.documentView else {
            return
        }
        let clip = scroller.contentView
        let bottom = document.frame.height - clip.bounds.height
        let target = min(max(y, 0), bottom)
        clip.scroll(to: NSPoint(x: 0, y: document.isFlipped ? target : bottom - target))
        scroller.reflectScrolledClipView(clip)
        waitUntil(timeout: 0.4) { false }
    }

    /// Answers the confirmation the list opened with the button titled
    /// `button`, and returns the confirmation's texts (none if it never
    /// showed). The sheet is made transparent as it appears.
    private static func dictionaryListAnswer(_ window: NSWindow, _ button: String) -> [String] {
        guard waitUntil(timeout: 1, { window.attachedSheet != nil }), let sheet = window.attachedSheet else {
            return []
        }
        sheet.alphaValue = 0
        let texts = dictionaryListViews(NSTextField.self, in: sheet.contentView).map(\.stringValue)
        dictionaryListViews(NSButton.self, in: sheet.contentView).first { $0.title == button }?.performClick(nil)
        waitUntil(timeout: 1) { window.attachedSheet == nil }
        waitUntil(timeout: 0.2) { false }
        return texts
    }

    /// The colours `view` draws at `points`, in its own top-left points.
    private static func dictionaryListColors(_ view: NSView, at points: [CGPoint]) -> [NSColor?] {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return points.map { _ in nil }
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return points.map {
            rep.colorAt(x: Int($0.x * scale), y: Int($0.y * scale))?.usingColorSpace(.sRGB)
        }
    }

    /// The largest difference between two colours' channels, premultiplied
    /// by alpha, and alphas: the host draws no card, so a tint is a colour
    /// at low alpha over nothing. 1 when either is missing.
    private static func dictionaryListDistance(_ a: NSColor?, _ b: NSColor?) -> CGFloat {
        guard let a, let b else {
            return 1
        }
        func channels(_ color: NSColor) -> [CGFloat] {
            let alpha = color.alphaComponent
            return [color.redComponent * alpha, color.greenComponent * alpha, color.blueComponent * alpha, alpha]
        }
        return zip(channels(a), channels(b)).map { abs($0 - $1) }.max() ?? 1
    }

    /// The Entries list in a real window keeps its selection as a native
    /// table does while the lazy stack builds and drops rows around it: ↓
    /// walks past the fold, the selection outlives being scrolled away, a
    /// held Return opens once, and no row's ⋯ button is ever a key view.
    ///
    ///     ┌ Search ─────────┐
    ///     │ Word 0          │
    ///     │ Word 1          │  ↓ × 29: Word 29 built and in view
    ///     └ …  2,000 rows  ─┘  scrolled to the end, ↓ selects Word 30
    private static func testDictionaryListWindowKeys() {
        let probe = DictionaryListProbe(words: DictionaryDocument.maximumEntries)
        let window = dictionaryListWindow(probe)
        defer {
            window.orderOut(nil)
            window.close()
        }
        expect(probe.frames.count < 100,
               "the lazy list builds only rows near the visible ones (\(probe.frames.count) of 2,000)")
        guard let (scroller, visible) = dictionaryListScroller(window) else {
            expect(false, "the host has a scroll view")
            return
        }
        func inView(_ id: String) -> Bool {
            guard let frame = probe.frames[id] else {
                return false
            }
            return frame.minY >= visible.minY - 1 && frame.maxY <= visible.maxY + 1
        }

        dictionaryListTabIn(window, probe)
        expect(probe.selection == "row 0", "Tab into the list selects the first row (got \(probe.selection ?? "nil"))")
        for _ in 1...29 {
            dictionaryListPress(window, dictionaryDown, settle: 0.03)
        }
        waitUntil(timeout: 0.4) { false }
        expect(probe.selection == "row 29", "↓ × 29 walks the selection past the fold (got \(probe.selection ?? "nil"))")
        expect(inView("row 29"),
               "the selected row is built and scrolled into view (\(probe.frames["row 29"] ?? .zero) in \(visible))")

        // Scroll the selection far out of the built range, as a trackpad
        // would; ↓ still moves on from it and brings the next row back.
        dictionaryListScroll(scroller, to: .greatestFiniteMagnitude)
        expect(probe.frames["row 29"] == nil, "scrolling to the end drops the selected row from the lazy stack")
        dictionaryListPress(window, dictionaryDown)
        waitUntil(timeout: 0.4) { false }
        expect(probe.selection == "row 30",
               "↓ after scrolling the selection away selects the next row (got \(probe.selection ?? "nil"))")
        expect(inView("row 30"), "the newly selected row scrolls back into view")

        dictionaryListPress(window, dictionaryReturn)
        expect(probe.opened == ["row 30"], "Return opens the selected row (opened \(probe.opened))")
        dictionaryListPress(window, dictionaryReturn, isARepeat: true)
        expect(probe.opened == ["row 30"], "a held Return's autorepeat doesn't open it again (opened \(probe.opened))")

        // End and Home go to the ends of the list; Page Down and Up move a
        // page, the rows that fit in view. Each brings its row into view.
        dictionaryListPress(window, dictionaryEnd)
        waitUntil(timeout: 0.4) { false }
        expect(probe.selection == "row 1999" && inView("row 1999"),
               "End selects the last row and scrolls it into view (got \(probe.selection ?? "nil"))")
        dictionaryListPress(window, dictionaryHome)
        waitUntil(timeout: 0.4) { false }
        expect(probe.selection == "row 0" && inView("row 0"),
               "Home selects the first row and scrolls it into view (got \(probe.selection ?? "nil"))")
        let fits = probe.frames.filter { inView($0.key) }.count
        dictionaryListPress(window, dictionaryPageDown)
        waitUntil(timeout: 0.4) { false }
        let paged = probe.selection.flatMap { Int($0.dropFirst("row ".count)) } ?? 0
        expect(paged > 1 && abs(paged - fits) <= 1 && probe.selection.map(inView) == true,
               "Page Down moves a page of rows (\(paged), \(fits) fit) and keeps the row in view")
        dictionaryListPress(window, dictionaryPageUp)
        waitUntil(timeout: 0.4) { false }
        expect(probe.selection == "row 0", "Page Up moves back a page (got \(probe.selection ?? "nil"))")

        // Under Full Keyboard Access every control that accepts first
        // responder is a Tab stop, the hidden ⋯ buttons included. None
        // does, so Tab walks past them all.
        let popups = dictionaryListViews(NSPopUpButton.self, in: window.contentView)
        expect(!popups.isEmpty && popups.allSatisfy { !$0.acceptsFirstResponder },
               "no row's ⋯ button can take keyboard focus (\(popups.count) buttons)")
        var stops: [String] = []
        for _ in 0..<6 {
            window.selectNextKeyView(nil)
            waitUntil(timeout: 0.05) { false }
            stops.append(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
        }
        expect(!stops.contains { $0.contains("PopUpButton") }, "Tab never stops on a ⋯ button (stops \(stops))")
    }

    /// A click on a row after scrolling selects that row and leaves the
    /// view where it is. The list takes focus on the click's mouse-down,
    /// before its tap: selecting on focus then picked the old row (or the
    /// first) and scrolled the clicked row away before the tap landed.
    private static func testDictionaryListClick() {
        guard #available(macOS 15, *) else {
            print("  skip: Dictionary list clicks need macOS 15 activation events")
            return
        }
        let probe = DictionaryListProbe(words: 200)
        let window = dictionaryListWindow(probe)
        defer {
            window.orderOut(nil)
            window.close()
        }
        guard let (scroller, visible) = dictionaryListScroller(window),
              let first = probe.frames["row 0"], let second = probe.frames["row 1"] else {
            expect(false, "the host lists rows in a scroll view")
            return
        }
        let pitch = second.minY - first.minY

        // Nothing selected, no focus: scroll row 60 into view.
        dictionaryListScroll(scroller, to: 58 * pitch)
        guard let target = probe.frames["row 60"], visible.contains(target) else {
            expect(false, "row 60 scrolls into view (\(probe.frames["row 60"] ?? .zero) in \(visible))")
            return
        }
        let origin = scroller.contentView.bounds.origin
        dictionaryListClick(window, at: CGPoint(x: target.minX + 120, y: target.midY))
        expect(probe.selection == "row 60",
               "a click after scrolling selects the clicked row (got \(probe.selection ?? "nil"))")
        expect(scroller.contentView.bounds.origin == origin,
               "the click leaves the view where it was scrolled (\(origin) → \(scroller.contentView.bounds.origin))")
    }

    /// ⌫ and ⌦ open the pane's confirmation for the selected row; Cancel
    /// keeps it, Remove drops it and selects the next. Typing in the search
    /// box never pulls focus into the list.
    private static func testDictionaryListRemove() {
        let probe = DictionaryListProbe(rows: ["Alpha", "Bravo", "Charlie", "Delta", "Echo"].enumerated().map {
            DictionaryRow(
                id: "row \($0.offset)", writeAs: $0.element, heardAs: nil,
                source: .added, isSoftCorrection: false, modifiedAt: Date())
        })
        let window = dictionaryListWindow(probe)
        defer {
            window.orderOut(nil)
            window.close()
        }
        dictionaryListTabIn(window, probe)
        dictionaryListPress(window, dictionaryDown)
        expect(probe.selection == "row 1", "↓ selects the second row (got \(probe.selection ?? "nil"))")

        dictionaryListPress(window, dictionaryBackspace)
        let asked = dictionaryListAnswer(window, "Cancel")
        expect(asked.contains("Remove “Bravo”?"), "⌫ asks to remove the selected row (asked \(asked))")
        expect(probe.rows.count == 5 && probe.selection == "row 1",
               "Cancel keeps the row and its selection (\(probe.rows.count) rows, \(probe.selection ?? "nil"))")

        dictionaryListPress(window, dictionaryBackspace)
        _ = dictionaryListAnswer(window, "Remove")
        expect(probe.rows.map(\.writeAs) == ["Alpha", "Charlie", "Delta", "Echo"],
               "Remove drops the selected row (rows \(probe.rows.map(\.writeAs)))")
        expect(probe.selection == "row 2", "the selection lands on the next row (got \(probe.selection ?? "nil"))")

        dictionaryListPress(window, dictionaryForwardDelete)
        let forward = dictionaryListAnswer(window, "Remove")
        expect(forward.contains("Remove “Charlie”?") && probe.selection == "row 3" && probe.rows.count == 3,
               "⌦ asks too, and Remove selects the next row (asked \(forward), got \(probe.selection ?? "nil"))")

        // A row's ⋯ menu asks about its own row, whichever row is selected.
        let echoActions = dictionaryListViews(NSPopUpButton.self, in: window.contentView)
            .first { $0.accessibilityLabel() == "Actions for Echo" }
        let removeItem = echoActions?.menu?.items.firstIndex { $0.title == "Remove" }
        if let echoActions, let removeItem {
            echoActions.menu?.performActionForItem(at: removeItem)
        }
        let fromMenu = dictionaryListAnswer(window, "Cancel")
        expect(fromMenu.contains("Remove “Echo”?") && probe.rows.count == 3,
               "the ⋯ menu's Remove asks about its own row (asked \(fromMenu))")

        // Typing in the search box filters the selected row out; focus
        // stays in the box for every key.
        guard let field = dictionaryListViews(NSTextField.self, in: window.contentView).first else {
            expect(false, "the host has a search field")
            return
        }
        window.makeFirstResponder(field)
        waitUntil(timeout: 0.2) { false }
        let letters: [DictionaryListKey] = [(14, 101, []), (8, 99, []), (4, 104, [])]
        for letter in letters {
            dictionaryListPress(window, letter)
        }
        let editor = window.firstResponder as? NSTextView
        expect(editor?.isFieldEditor == true && editor?.delegate === field,
               "typing in search keeps focus in the search box (first responder \(String(describing: window.firstResponder)))")
        expect(probe.query == "ech", "every key reaches the search box (query \(probe.query))")
    }

    /// Without focus the list scrolls only when asked: a sync that moves the
    /// selection leaves the view where the user scrolled it, and a save in
    /// the editor brings its entry into view once.
    private static func testDictionaryListScrolling() {
        let probe = DictionaryListProbe(words: 200)
        let window = dictionaryListWindow(probe)
        defer {
            window.orderOut(nil)
            window.close()
        }
        guard let (scroller, visible) = dictionaryListScroller(window),
              let first = probe.frames["row 0"], let second = probe.frames["row 1"] else {
            expect(false, "the host lists rows in a scroll view")
            return
        }
        let pitch = second.minY - first.minY
        probe.selection = "row 5"
        waitUntil(timeout: 0.2) { false }
        dictionaryListScroll(scroller, to: 58 * pitch)
        let shown = probe.frames["row 60"]

        // The scroll view keeps the rows in view where they were as a row
        // above them leaves; a scroll to the new selection would drop them.
        probe.rows.removeAll { $0.id == "row 5" }
        waitUntil(timeout: 0.4) { false }
        expect(probe.selection == "row 6", "a sync hands the selection to the next row (got \(probe.selection ?? "nil"))")
        let still = probe.frames["row 60"]
        expect(shown != nil && still.map { abs($0.minY - shown!.minY) <= 1 } == true,
               "a sync without focus leaves the view where it was (row 60 \(shown ?? .zero) → \(still ?? .zero))")

        probe.selection = "row 150"
        probe.reveal = true
        waitUntil(timeout: 0.4) { false }
        let saved = probe.frames["row 150"]
        expect(saved.map { visible.insetBy(dx: 0, dy: -1).contains($0) } == true && !probe.reveal,
               "a save scrolls its entry into view once (\(saved ?? .zero) in \(visible))")

        // A search that lists none of the rows it listed before (rows 15
        // and 150–159, then 7 and 70–79) selects nothing in a list without
        // focus; no row the user never picked turns grey.
        probe.query = "Word 15"
        waitUntil(timeout: 0.3) { false }
        probe.query = "Word 7"
        waitUntil(timeout: 0.4) { false }
        expect(probe.selection == nil,
               "a search without focus doesn't select a row in place of the one it hid (got \(probe.selection ?? "nil"))")
    }

    /// A list that keeps focus while its window resigns key shows its
    /// selection as a list without focus does, grey with no accent edge,
    /// and a sync that moves the selection leaves the view where it was,
    /// as the sidebar does.
    ///
    ///      key                 resigned key
    ///     ▐▌Word 0 ░░░░░░      ▒▒Word 0 ▒▒▒▒▒▒
    ///      └ accent edge        └ one grey fill
    private static func testDictionaryListInactiveWindow() {
        let probe = DictionaryListProbe(words: 200)
        let window = dictionaryListWindow(probe)
        defer {
            window.orderOut(nil)
            window.close()
        }
        guard let content = window.contentView, let (scroller, _) = dictionaryListScroller(window),
              let first = probe.frames["row 0"], let second = probe.frames["row 1"] else {
            expect(false, "the host lists rows in a scroll view")
            return
        }
        let pitch = second.minY - first.minY
        /// The selected row's mark at its edge (5 pt in: the focus mark's
        /// 2 pt edge, 4 pt inside the card), inside it, and a plain row
        /// at the same place.
        func marks() -> (edge: NSColor?, fill: NSColor?, plain: NSColor?) {
            guard let selected = probe.frames["row 0"], let plain = probe.frames["row 2"] else {
                return (nil, nil, nil)
            }
            let colors = dictionaryListColors(content, at: [
                CGPoint(x: selected.minX + 5, y: selected.midY),
                CGPoint(x: selected.minX + 9, y: selected.midY),
                CGPoint(x: plain.minX + 9, y: plain.midY),
            ])
            return (colors[0], colors[1], colors[2])
        }

        dictionaryListTabIn(window, probe)
        let focused = marks()
        expect(probe.selection == "row 0" && dictionaryListDistance(focused.edge, focused.fill) > 0.1,
               "a focused list in the key window marks its selection with an accent edge (edge \(String(describing: focused.edge)), fill \(String(describing: focused.fill)))")

        probe.windowState = .inactive
        waitUntil(timeout: 0.3) { false }
        let resigned = marks()
        expect(dictionaryListDistance(resigned.edge, resigned.fill) < 0.02
                   && dictionaryListDistance(resigned.fill, resigned.plain) > 0.02,
               "once the window resigns key, the selection is one grey fill (edge \(String(describing: resigned.edge)), fill \(String(describing: resigned.fill)))")

        dictionaryListScroll(scroller, to: 58 * pitch)
        let shown = probe.frames["row 60"]
        probe.rows.removeAll { $0.id == "row 0" }
        waitUntil(timeout: 0.4) { false }
        let still = probe.frames["row 60"]
        expect(probe.selection == "row 1", "a sync hands the selection to the next row (got \(probe.selection ?? "nil"))")
        expect(shown != nil && still.map { abs($0.minY - shown!.minY) <= 1 } == true,
               "a sync while the window isn't key leaves the view where it was (row 60 \(shown ?? .zero) → \(still ?? .zero))")
    }

    /// The pane builds the list only once it has rows, so the first add to
    /// an empty dictionary (or under a search with no results) creates the
    /// list with a reveal already asked for. It clears that one too, so
    /// the next save still scrolls to its entry.
    private static func testDictionaryListRevealFromEmpty() {
        let probe = DictionaryListProbe(rows: [])
        let window = dictionaryListWindow(probe)
        defer {
            window.orderOut(nil)
            window.close()
        }
        func word(_ id: String) -> DictionaryRow {
            DictionaryRow(
                id: id, writeAs: id.capitalized, heardAs: nil,
                source: .added, isSoftCorrection: false, modifiedAt: Date())
        }

        probe.rows = [word("new 0")]
        probe.selection = "new 0"
        probe.reveal = true
        waitUntil(timeout: 0.4) { false }
        expect(!probe.reveal, "the first add clears its reveal as the list appears")

        // A sync fills the list, the user scrolls to its end, and the next
        // add lands at the top.
        probe.rows += (0..<200).map { word("row \($0)") }
        waitUntil(timeout: 0.3) { false }
        guard let (scroller, visible) = dictionaryListScroller(window) else {
            expect(false, "the host has a scroll view")
            return
        }
        dictionaryListScroll(scroller, to: .greatestFiniteMagnitude)
        probe.rows.insert(word("new 1"), at: 0)
        probe.selection = "new 1"
        probe.reveal = true
        waitUntil(timeout: 0.4) { false }
        let saved = probe.frames["new 1"]
        expect(saved.map { visible.insetBy(dx: 0, dy: -1).contains($0) } == true,
               "the next add, made while scrolled down, scrolls its entry into view (\(saved ?? .zero) in \(visible))")
    }

    /// VoiceOver reads the list as one group named Entries holding exactly
    /// two elements per row: the row, a button named for its word with its
    /// caption as value, selected state and every ⋯ action; then its ⋯
    /// button, named "Actions for <word>". Pressing a row opens it. Needs
    /// the SwiftUI accessibility tree, so an untrusted process skips it.
    ///
    /// Without focus, the selected row keeps a grey tint.
    private static func testDictionaryListAccessibility() {
        let rows = [
            DictionaryRow(
                id: "a", writeAs: "Kubectl", heardAs: "cube control",
                source: .added, isSoftCorrection: false, modifiedAt: Date()),
            DictionaryRow(
                id: "b", writeAs: "Sushil Kumar", heardAs: "social kumar",
                source: .learned, isSoftCorrection: false, modifiedAt: Date()),
            DictionaryRow(
                id: "c", writeAs: "Velora", heardAs: nil,
                source: .automatic, isSoftCorrection: false, modifiedAt: Date()),
        ]
        let probe = DictionaryListProbe(rows: rows)
        probe.selection = "b"
        // Never ordered on screen, so it can't take a click from anyone.
        let hosting = NSHostingView(rootView: DictionaryListHost(probe: probe))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        defer {
            window.contentView = nil
        }

        // The selected row's grey sits in the gap before its symbol, where
        // an unselected row shows the card.
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
           let selected = probe.frames["b"], let plain = probe.frames["c"] {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
            func tint(_ frame: CGRect) -> NSColor? {
                rep.colorAt(x: Int((frame.minX + 9) * scale), y: Int(frame.midY * scale))?.usingColorSpace(.sRGB)
            }
            let grey = tint(selected)
            let card = tint(plain)
            let difference = zip(
                [grey?.redComponent, grey?.greenComponent, grey?.blueComponent],
                [card?.redComponent, card?.greenComponent, card?.blueComponent]
            ).map { abs(($0 ?? 0) - ($1 ?? 0)) }.max() ?? 0
            expect(grey != nil && difference > 0.02,
                   "the selected row keeps a grey tint without focus (\(String(describing: grey)) vs \(String(describing: card)))")
        } else {
            expect(false, "the list renders its rows")
        }

        guard enableSwiftUIAccessibilityTree() else {
            print("  skip: Dictionary list accessibility needs an Accessibility-trusted process")
            return
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        func children(_ element: AnyObject) -> [AnyObject] {
            ((element.accessibilityChildren?() ?? nil) ?? []).map { $0 as AnyObject }
        }
        /// The first element labelled `label` that holds others: the list,
        /// a lazy stack, reports its own group role.
        func find(_ label: String, in element: AnyObject) -> AnyObject? {
            if element.accessibilityLabel?() == label, !children(element).isEmpty {
                return element
            }
            return children(element).lazy.compactMap { find(label, in: $0) }.first
        }
        /// An element as VoiceOver reads it: a row button's name, value,
        /// selected state and custom actions (in any order); a ⋯ button's
        /// name.
        func reading(_ element: AnyObject) -> String {
            let role = element.accessibilityRole?() ?? .unknown
            let name = (element.accessibilityLabel?() ?? nil) ?? ""
            guard role == .button else {
                return "\(role.rawValue) \(name)"
            }
            let value = (element.accessibilityValue?() ?? nil).map { "\($0)" } ?? ""
            let selected = (element.isAccessibilitySelected?() ?? false) ? " selected" : ""
            let actions = ((element.accessibilityCustomActions?() ?? nil) ?? []).map(\.name).sorted()
            return "\(role.rawValue) \(name) = \(value)\(selected) \(actions)"
        }

        guard let list = find("Entries", in: hosting) else {
            expect(false, "VoiceOver finds the list as one group named Entries")
            return
        }
        func caption(_ row: DictionaryRow) -> String {
            let origin = DictionarySettingsLogic.sourceLabel(row)
            return row.heardAs.map { "When Velora hears “\($0)” · \(origin)" } ?? origin
        }
        let expected = rows.flatMap { row -> [String] in
            let actions = (row.source == .added ? ["Edit", "Remove"] : ["Make Permanent", "Forget"]).sorted()
            let selected = row.id == probe.selection ? " selected" : ""
            return [
                "AXButton \(row.writeAs) = \(caption(row))\(selected) \(actions)",
                "AXMenuButton Actions for \(row.writeAs)",
            ]
        }
        let read = children(list).map(reading)
        expect(read == expected, "each row reads as its button, then its ⋯ button, nothing else (read \(read))")

        let rowButton = children(list).first { ($0.accessibilityLabel?() ?? nil) == "Kubectl" }
        _ = rowButton?.accessibilityPerformPress?()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(probe.opened == ["a"], "pressing a row with VoiceOver opens it, as Return does (opened \(probe.opened))")
    }

    /// "Make Permanent" on an auto-learned word turns it into an added word
    /// and stops the miner from re-adding it.
    private static func testDictionaryPromoteAutomatic() {
        withTempDirectory { dir in
            let auto = dir.appendingPathComponent("auto_learned.json")
            let repository = DictionaryRepository(
                stateURL: dir.appendingPathComponent("dictionary_sync.json"),
                configURL: dir.appendingPathComponent("config.json"),
                learnedURL: dir.appendingPathComponent("learned.json"),
                autoURL: auto,
                deviceID: "mac-a",
                now: { Date(timeIntervalSince1970: 100) })
            AutoVocabStore(url: auto).applyPortableSnapshot(.init(terms: ["Kubectl", "Grafana"], banned: []))
            repository.captureAutoVocabulary()
            guard let row = repository.rows.first(where: { $0.writeAs == "Kubectl" && $0.source == .automatic }),
                  let other = repository.rows.first(where: { $0.writeAs == "Grafana" && $0.source == .automatic }) else {
                expect(false, "fixture seeds two auto-learned words")
                return
            }
            func promote(_ row: DictionaryRow, as draft: DictionaryDraft) {
                do {
                    try DictionarySettingsLogic.promoteAutomatic(
                        row, as: draft, rows: repository.rows,
                        add: { _ = try repository.add(writeAs: $0.writeAs, heardAs: $0.heardAs) },
                        remove: { try repository.remove(id: $0.id) })
                } catch {
                    expect(false, "promoting an auto-learned word succeeds: \(error)")
                }
            }

            // The ⋯ menu's Make Permanent adds the word as found.
            promote(row, as: DictionaryDraft(writeAs: row.writeAs, heardAs: nil))
            expect(repository.rows.contains { $0.writeAs == "Kubectl" && $0.heardAs == nil && $0.source == .added },
                   "the word becomes an added word")
            expect(!repository.rows.contains { $0.writeAs == "Kubectl" && $0.source == .automatic },
                   "the auto-learned copy is gone")

            // Make Permanent confirmed in the editor adds what it confirmed.
            promote(other, as: DictionaryDraft(writeAs: "Grafana Cloud", heardAs: "graph ana"))
            expect(repository.rows.contains {
                       $0.writeAs == "Grafana Cloud" && $0.heardAs == "graph ana" && $0.source == .added
                   },
                   "a word confirmed in the editor is added as confirmed (\(repository.rows.map(\.writeAs)))")
            expect(!repository.rows.contains { $0.source == .automatic },
                   "the confirmed word's auto-learned copy is gone")

            AutoVocabStore(url: auto).applyPortableSnapshot(.init(terms: ["Kubectl", "Grafana"], banned: []))
            repository.captureAutoVocabulary()
            expect(!repository.rows.contains { $0.source == .automatic },
                   "the miner can't add the promoted words back")
        }
    }

    /// Make Permanent on an auto-learned word selects the added word it
    /// leaves: the one it adds, or an identical one already there, which
    /// it keeps. Never the auto row's old neighbour.
    ///
    ///     Kubectl  (auto, newest)  ──▶ removed
    ///     Bravo                        its neighbour: not selected
    ///     Kubectl  (added)         ◀── selected
    private static func testDictionaryPromotedRow() {
        let auto = DictionaryRow(
            id: "auto", writeAs: "Kubectl", heardAs: nil,
            source: .automatic, isSoftCorrection: false, modifiedAt: Date())
        func added(_ id: String, _ writeAs: String, heardAs: String? = nil) -> DictionaryRow {
            DictionaryRow(
                id: id, writeAs: writeAs, heardAs: heardAs,
                source: .added, isSoftCorrection: false, modifiedAt: Date())
        }
        let rows = [auto, added("rule", "Kubectl", heardAs: "cube control"), added("word", "kubectl")]
        let word = DictionaryDraft(writeAs: auto.writeAs, heardAs: nil)
        expect(DictionarySettingsLogic.promotedRowID(word, in: rows) == "word",
               "the promoted word is the added one spelled the same, ignoring case and heard-as rules")
        expect(DictionarySettingsLogic.promotedRowID(
                   DictionaryDraft(writeAs: "Kubectl", heardAs: "Cube Control"), in: rows) == "rule",
               "a word confirmed with a heard-as rule is the added rule, ignoring case")
        expect(DictionarySettingsLogic.promotedRowID(word, in: [auto]) == nil, "none before it is added")

        withTempDirectory { dir in
            let autoURL = dir.appendingPathComponent("auto_learned.json")
            var clock: TimeInterval = 100
            let repository = DictionaryRepository(
                stateURL: dir.appendingPathComponent("dictionary_sync.json"),
                configURL: dir.appendingPathComponent("config.json"),
                learnedURL: dir.appendingPathComponent("learned.json"),
                autoURL: autoURL,
                deviceID: "mac-a",
                now: {
                    clock += 1
                    return Date(timeIntervalSince1970: clock)
                })
            var adds = 0
            do {
                _ = try repository.add(writeAs: "Kubectl")
                _ = try repository.add(writeAs: "Alpha")
                _ = try repository.add(writeAs: "Bravo")
            } catch {
                expect(false, "fixture adds three words: \(error)")
            }
            AutoVocabStore(url: autoURL).applyPortableSnapshot(.init(terms: ["Kubectl"], banned: []))
            repository.captureAutoVocabulary()
            let before = repository.rows
            guard let row = before.first(where: { $0.source == .automatic }),
                  let existing = before.first(where: { $0.writeAs == "Kubectl" && $0.source == .added }) else {
                expect(false, "fixture holds an added and an auto-learned Kubectl")
                return
            }

            let draft = DictionaryDraft(writeAs: row.writeAs, heardAs: nil)
            do {
                try DictionarySettingsLogic.promoteAutomatic(
                    row, as: draft, rows: before,
                    add: { _ in adds += 1 },
                    remove: { try repository.remove(id: $0.id) })
            } catch {
                expect(false, "promoting an auto-learned word succeeds: \(error)")
            }
            let after = repository.rows
            let neighbour = DictionarySettingsLogic.selectionAfterChange(
                row.id, from: before, to: after, focus: .focused)
            expect(adds == 0, "an identical added word is kept, not added again")
            expect(DictionarySettingsLogic.promotedRowID(draft, in: after) == existing.id && neighbour != existing.id,
                   "Make Permanent selects the added word already there, not the auto row's neighbour \(neighbour ?? "nil")")
        }
    }

    /// A row's default action (Return, a double-click, VoiceOver's press,
    /// Voice Control's "Click") changes nothing without a confirm step: it
    /// opens the editor. Making an auto-learned word permanent forgets the
    /// auto copy, which bans the miner from it, so a stray Return mustn't.
    private static func testDictionaryOpenAction() {
        func row(_ source: DictionarySource) -> DictionaryRow {
            DictionaryRow(
                id: source.rawValue, writeAs: "Kubectl", heardAs: nil,
                source: source, isSoftCorrection: false, modifiedAt: Date())
        }
        expect(DictionarySettingsLogic.openAction(for: row(.added)) == .edit,
               "opening an added word edits it")
        expect(DictionarySettingsLogic.openAction(for: row(.learned)) == .confirmPromotion,
               "opening a learned correction asks to confirm it in Make Permanent")
        expect(DictionarySettingsLogic.openAction(for: row(.automatic)) == .confirmPromotion,
               "opening an auto-learned word asks to confirm it in Make Permanent, not promote it at once")
    }
}
