import Foundation

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
            vm.select("Email")
            vm.draft.prompt = "Edited prompt"
            expect(vm.isDirty, "an edited draft is dirty")

            vm.requestSelect("Message")
            expect(vm.selectedID == "Email" && vm.draft.prompt == "Edited prompt",
                   "switching with unsaved edits keeps the draft")
            expect(vm.pendingChange == .select("Message"), "the switch waits for a decision")

            vm.saveAndContinue()
            expect(vm.selectedID == "Message" && vm.pendingChange == nil,
                   "saving completes the switch")
            let reread = ModesViewModel(supervisor: nil, directory: dir)
            expect(reread.modes.first { $0.name == "Email" }?.prompt == "Edited prompt",
                   "save-and-continue wrote the edit")

            vm.draft.prompt = "Throwaway"
            vm.requestNewMode()
            expect(vm.pendingChange == .newMode && vm.draft.prompt == "Throwaway",
                   "New Mode waits too")
            vm.discardAndContinue()
            expect(vm.selectedID?.hasPrefix("New Mode") == true,
                   "discarding completes the pending New Mode")
            expect(vm.modes.first { $0.name == "Message" }?.prompt != "Throwaway",
                   "discarded edits are gone")

            vm.requestSelect("Email")
            expect(vm.pendingChange == .select("Email"),
                   "an unsaved new mode also asks before it is dropped")
            vm.discardAndContinue()
            expect(!vm.modes.contains { $0.name.hasPrefix("New Mode") },
                   "discarding an unsaved new mode removes it")

            vm.draft.prompt = "Parked edit"
            vm.park()
            let returned = ModesViewModel(supervisor: nil, directory: dir)
            expect(returned.selectedID == "Email" && returned.draft.prompt == "Parked edit"
                    && returned.isDirty,
                   "leaving the pane parks the draft for the next visit")
        }
    }

    private static func testModesProtectionAndSymbols() {
        withTempDirectory { dir in
            let vm = ModesViewModel(supervisor: nil, directory: dir)
            vm.select("Default")
            expect(!vm.canDelete, "a protected built-in can't be deleted")
            vm.select("Email")
            expect(vm.canDelete, "a normal mode can be deleted")
        }
        let terminal = Mode(name: "Terminal", prompt: "", formatting: "off",
                            apps: [], vocabulary: [], replacements: [])
        expect(terminal.symbol == "terminal", "Terminal mode has its own symbol")
        expect(Mode.builtInTemplates.first { $0.name == "Code" }?.symbol
                == "chevron.left.forwardslash.chevron.right",
               "Code keeps its symbol")
    }

    // MARK: - Dictionary

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
            AutoVocabStore(url: auto).applyPortableSnapshot(.init(terms: ["Kubectl"], banned: []))
            repository.captureAutoVocabulary()
            guard let row = repository.rows.first(where: { $0.source == .automatic }) else {
                expect(false, "fixture seeds one auto-learned word")
                return
            }

            do {
                try DictionarySettingsLogic.promoteAutomatic(
                    row, rows: repository.rows,
                    add: { _ = try repository.add(writeAs: $0) },
                    remove: { try repository.remove(id: $0.id) })
            } catch {
                expect(false, "promoting an auto-learned word succeeds: \(error)")
            }
            expect(repository.rows.contains { $0.writeAs == "Kubectl" && $0.source == .added },
                   "the word becomes an added word")
            expect(!repository.rows.contains { $0.source == .automatic },
                   "the auto-learned copy is gone")

            AutoVocabStore(url: auto).applyPortableSnapshot(.init(terms: ["Kubectl"], banned: []))
            repository.captureAutoVocabulary()
            expect(!repository.rows.contains { $0.source == .automatic },
                   "the miner can't add the promoted word back")
        }
    }
}
