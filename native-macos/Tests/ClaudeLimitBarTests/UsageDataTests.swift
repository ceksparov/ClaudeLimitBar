import XCTest
@testable import ClaudeLimitBar

final class FormatDurationTests: XCTestCase {
    func testShowsSoonForZeroOrNegative() {
        XCTAssertEqual(formatDuration(0), "soon")
        XCTAssertEqual(formatDuration(-1000), "soon")
    }

    func testShowsMinutesOnly() {
        XCTAssertEqual(formatDuration(5 * 60_000), "5m")
    }

    func testShowsHoursAndMinutes() {
        XCTAssertEqual(formatDuration(2 * 3_600_000 + 15 * 60_000), "2h 15m")
    }

    func testShowsDaysAndHours() {
        XCTAssertEqual(formatDuration(3 * 86_400_000 + 4 * 3_600_000), "3d 4h")
    }
}

final class ResetLabelTests: XCTestCase {
    func testNoResetAtAndZeroPercentMeansNoUsageYet() {
        XCTAssertEqual(resetLabel(percent: 0, resetAt: nil, isEstimate: false, now: Date()), "No usage yet")
    }

    func testNoResetAtAndNonZeroPercentMeansUnknown() {
        XCTAssertEqual(resetLabel(percent: 42, resetAt: nil, isEstimate: false, now: Date()), "Reset time unknown")
    }

    func testShortWindowHasNoClockTime() {
        let now = Date()
        let resetAt = now.addingTimeInterval(3 * 3600) // 3 hours out — same day
        XCTAssertEqual(resetLabel(percent: 50, resetAt: resetAt, isEstimate: false, now: now), "Resets in 3h 0m")
    }

    func testLongWindowIncludesClockTime() {
        let now = Date()
        let resetAt = now.addingTimeInterval(3 * 86400) // 3 days out
        let label = resetLabel(percent: 50, resetAt: resetAt, isEstimate: false, now: now)
        XCTAssertTrue(label.hasPrefix("Resets in 3d 0h ("), "expected a weekday/clock suffix, got: \(label)")
    }

    func testAResetAlreadyDueReadsAsHappeningNow() {
        let now = Date()
        XCTAssertEqual(
            resetLabel(percent: 50, resetAt: now.addingTimeInterval(-30), isEstimate: false, now: now),
            "Resetting now"
        )
    }

    func testSecondsAwayAvoidsSayingZeroMinutes() {
        let now = Date()
        XCTAssertEqual(
            resetLabel(percent: 50, resetAt: now.addingTimeInterval(20), isEstimate: false, now: now),
            "Resets in under a minute"
        )
    }

    func testEstimateIsNoted() {
        let now = Date()
        let resetAt = now.addingTimeInterval(3600)
        XCTAssertEqual(resetLabel(percent: 50, resetAt: resetAt, isEstimate: true, now: now), "Resets in 1h 0m (estimated)")
    }
}

final class WithoutGlitchesTests: XCTestCase {
    private func sample(_ fh: Int, at t: Double) -> RawSample {
        RawSample(t: t, u: RawUsage(fh: fh, sd: 0))
    }

    func testDropsAMomentaryZeroThatBouncesBackToTheSameLevel() {
        let samples = [sample(50, at: 0), sample(0, at: 1), sample(55, at: 2)]
        let cleaned = withoutGlitches(samples, key: \.fh)
        XCTAssertEqual(cleaned.map { $0.u.fh }, [50, 55])
    }

    func testKeepsARealResetWhereTheValueClimbsBackUpSlowly() {
        let samples = [sample(90, at: 0), sample(0, at: 1), sample(3, at: 2)]
        let cleaned = withoutGlitches(samples, key: \.fh)
        XCTAssertEqual(cleaned.map { $0.u.fh }, [90, 0, 3])
    }
}

final class EstimateResetTests: XCTestCase {
    private func sample(_ fh: Int, at t: Double) -> RawSample {
        RawSample(t: t, u: RawUsage(fh: fh, sd: 0))
    }

    func testReturnsNilWhenCurrentValueIsZero() {
        let samples = [sample(80, at: 0), sample(0, at: 1000)]
        XCTAssertNil(estimateReset(samples: samples, key: \.fh, windowMs: 100, now: 2000))
    }

    func testEstimatesFromTheMostRecentDecrease() {
        let windowMs = 5.0 * 60 * 60 * 1000
        let samples = [
            sample(80, at: 0),
            sample(10, at: 1000), // reset happened here
            sample(20, at: 2000),
        ]
        let resetAt = estimateReset(samples: samples, key: \.fh, windowMs: windowMs, now: 3000)
        XCTAssertEqual(resetAt, 1000 + windowMs)
    }

    func testReturnsNilOnceTheEstimatedResetIsInThePast() {
        let windowMs = 100.0
        let samples = [sample(80, at: 0), sample(10, at: 1000)]
        XCTAssertNil(estimateReset(samples: samples, key: \.fh, windowMs: windowMs, now: 5000))
    }
}

final class RecentActivityTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    // Replays a timeline into the tracker the way the app really feeds it:
    // one sample every 20 seconds (the live poll rate), from the oldest
    // given point up to `start`. Each entry is a breakpoint — the percentage
    // stays at that value until a newer breakpoint takes over.
    private func tracker(
        percentTimeline: [(minutesAgo: Double, percent: Int)]
    ) -> RecentActivityTracker {
        let breakpoints = percentTimeline.sorted { $0.minutesAgo > $1.minutesAgo }
        var tracker = RecentActivityTracker()

        // Counted in whole 20-second steps so the last one lands exactly on
        // `start`, rather than a hair above it from accumulated float drift.
        let pollSeconds = 20.0
        for step in stride(from: Int(breakpoints[0].minutesAgo * 60 / pollSeconds), through: 0, by: -1) {
            let secondsAgo = Double(step) * pollSeconds
            let percent = breakpoints.last { $0.minutesAgo * 60 >= secondsAgo }?.percent
                ?? breakpoints[0].percent
            tracker.record(percent: percent, at: start.addingTimeInterval(-secondsAgo), source: .api, resetAt: nil)
        }
        return tracker
    }

    // Nothing to describe in the first seconds, so the panel stays quiet.
    func testSaysNothingUntilThereIsAMinuteToDescribe() {
        let tracker = self.tracker(percentTimeline: [(0.5, 10), (0, 12)])
        XCTAssertEqual(tracker.activity(now: start), .unknown)
    }

    // Past a minute a figure appears, labelled with the span actually
    // watched — claiming the five-minute floor here would fold in three
    // minutes nobody observed.
    func testReportsTheSpanActuallyWatchedBeforeTheFloorIsEarned() {
        let tracker = self.tracker(percentTimeline: [(3, 10), (0, 12)])
        XCTAssertEqual(tracker.activity(now: start), .measured(deltaPercent: 2, elapsedMinutes: 3))
    }

    // Same for silence: three minutes of watching nothing happen is a real
    // answer, just a three-minute one.
    func testSilenceIsReportedOverTheSpanWatched() {
        let tracker = self.tracker(percentTimeline: [(3, 10), (0, 10)])
        XCTAssertEqual(tracker.activity(now: start), .measured(deltaPercent: 0, elapsedMinutes: 3))
    }

    // A reset the server announced needs no corroboration: the window is
    // gone the moment its reset time jumps forward.
    func testAnAnnouncedResetClearsTheWindowImmediately() {
        var tracker = RecentActivityTracker()
        let firstWindow = start.addingTimeInterval(600)
        for minutesAgo in stride(from: 30, through: 4, by: -1) {
            tracker.record(
                percent: 90, at: start.addingTimeInterval(-Double(minutesAgo) * 60),
                source: .api, resetAt: firstWindow
            )
        }

        // The window turns over and usage starts again in the new one.
        let secondWindow = firstWindow.addingTimeInterval(5 * 3600)
        for minutesAgo in stride(from: 3, through: 0, by: -1) {
            tracker.record(
                percent: 3 - minutesAgo, at: start.addingTimeInterval(-Double(minutesAgo) * 60),
                source: .api, resetAt: secondWindow
            )
        }
        XCTAssertEqual(tracker.activity(now: start), .measured(deltaPercent: 3, elapsedMinutes: 3))
    }

    // Both the API and the desktop app emit the occasional bad reading — a
    // lone 0 between two 12s. Wiping twenty minutes of history for one of
    // them was losing real windows, so a drop has to survive a poll first.
    func testALoneDipIsIgnoredRatherThanTakenAsAReset() {
        var tracker = RecentActivityTracker()
        for minutesAgo in stride(from: 12, through: 2, by: -1) {
            tracker.record(
                percent: 16, at: start.addingTimeInterval(-Double(minutesAgo) * 60),
                source: .api, resetAt: nil
            )
        }
        tracker.record(percent: 15, at: start.addingTimeInterval(-60), source: .api, resetAt: nil)
        tracker.record(percent: 17, at: start, source: .api, resetAt: nil)

        // Measured against the real history: +1, over the floor. Had the dip
        // been taken as a reset, the window would have restarted at 15 and
        // this would read "+2% last 1 min" — which is what it did before.
        XCTAssertEqual(tracker.activity(now: start), .measured(deltaPercent: 1, elapsedMinutes: 5))
    }

    // A drop that is still there on the next poll is real, whatever caused
    // it, and the window starts over.
    func testADropThatPersistsIsAccepted() {
        var tracker = RecentActivityTracker()
        for minutesAgo in stride(from: 12, through: 6, by: -1) {
            tracker.record(
                percent: 90, at: start.addingTimeInterval(-Double(minutesAgo) * 60),
                source: .api, resetAt: nil
            )
        }
        for minutesAgo in stride(from: 5, through: 0, by: -1) {
            tracker.record(
                percent: 5 - minutesAgo, at: start.addingTimeInterval(-Double(minutesAgo) * 60),
                source: .api, resetAt: nil
            )
        }
        XCTAssertEqual(tracker.activity(now: start), .measured(deltaPercent: 4, elapsedMinutes: 4))
    }

    func testUsesTheFiveMinuteFloorWhenThatIsAllWeHave() {
        let tracker = self.tracker(percentTimeline: [(5, 10), (0, 14)])
        XCTAssertEqual(tracker.activity(now: start), .measured(deltaPercent: 4, elapsedMinutes: 5))
    }

    // The point of stretching: activity that happened 8 minutes ago is real
    // and worth surfacing, so the window widens to cover it.
    func testStretchesPastTheFloorToIncludeOlderActivity() {
        let tracker = self.tracker(percentTimeline: [(10, 10), (8, 15), (0, 15)])
        XCTAssertEqual(tracker.activity(now: start), .measured(deltaPercent: 5, elapsedMinutes: 8))
    }

    // ...and it reaches back exactly as far as the activity, not as far as
    // it is allowed to. Usage that began 16 minutes ago is reported over 16
    // minutes, with the idle time before it left out.
    func testReportsHowLongAgoTheActivityActuallyStarted() {
        let tracker = self.tracker(percentTimeline: [(20, 10), (16, 15), (0, 15)])
        XCTAssertEqual(tracker.activity(now: start), .measured(deltaPercent: 5, elapsedMinutes: 16))
    }

    // Usage climbing without pause for half an hour still gets reported over
    // the ceiling, never beyond it.
    func testNeverReachesBeyondTheCeiling() {
        var tracker = RecentActivityTracker()
        for minutesAgo in stride(from: 30, through: 0, by: -1) {
            tracker.record(
                percent: 30 - minutesAgo,
                at: start.addingTimeInterval(-Double(minutesAgo) * 60), source: .api, resetAt: nil
            )
        }
        XCTAssertEqual(tracker.activity(now: start), .measured(deltaPercent: 20, elapsedMinutes: 20))
    }

    // The case that motivated the elastic logic: idle for the whole window,
    // so widening it would only make the same "+0%" look staler.
    func testFallsBackToTheFloorWhenTheWiderWindowFindsNoActivity() {
        let tracker = self.tracker(percentTimeline: [(20, 40), (12, 40), (0, 40)])
        XCTAssertEqual(tracker.activity(now: start), .measured(deltaPercent: 0, elapsedMinutes: 5))
    }

    // Activity older than the ceiling is out of view entirely, so what's left
    // is an idle window and it collapses back to the floor.
    func testActivityOlderThanTheCeilingIsNotReported() {
        let tracker = self.tracker(percentTimeline: [(30, 10), (25, 50), (0, 50)])
        XCTAssertEqual(tracker.activity(now: start), .measured(deltaPercent: 0, elapsedMinutes: 5))
    }

    // A single late drop is held back pending confirmation, so the figure
    // stays with the history it already has rather than going silent.
    func testASingleDropAtTheEndDoesNotBlankTheFigure() {
        let tracker = self.tracker(percentTimeline: [(8, 95), (6, 95), (0, 3)])
        XCTAssertEqual(tracker.activity(now: start), .measured(deltaPercent: 0, elapsedMinutes: 5))
    }
}

final class RecentActivitySourceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    // The local file lags the live API, so a delta spanning both sources
    // would report usage that never happened. Switching sources starts over.
    func testSwitchingSourcesDiscardsTheOldBaseline() {
        var tracker = RecentActivityTracker()
        tracker.record(percent: 44, at: start.addingTimeInterval(-600), source: .api, resetAt: nil)
        tracker.record(percent: 44, at: start.addingTimeInterval(-300), source: .api, resetAt: nil)
        tracker.record(percent: 38, at: start, source: .localFile, resetAt: nil)  // stale file reading

        XCTAssertEqual(tracker.activity(now: start), .unknown)
    }

    func testResetForgetsEverything() {
        var tracker = RecentActivityTracker()
        tracker.record(percent: 10, at: start.addingTimeInterval(-300), source: .api, resetAt: nil)
        tracker.record(percent: 40, at: start, source: .api, resetAt: nil)
        XCTAssertEqual(tracker.activity(now: start), .measured(deltaPercent: 30, elapsedMinutes: 5))

        tracker.reset()
        XCTAssertEqual(tracker.activity(now: start), .unknown)
    }
}

final class TotalConsumedTests: XCTestCase {
    func testSumsAPlainClimb() {
        XCTAssertEqual(totalConsumed([30, 35, 44]), 14)
    }

    func testNothingConsumedFromASingleReading() {
        XCTAssertEqual(totalConsumed([44]), 0)
    }

    // The case that motivated summing rises instead of subtracting the ends:
    // 41 → 95 is 54 spent, then the window resets and 3 more goes on the new
    // one. Subtracting first from last would have reported 3.
    func testKeepsWhatWasSpentBeforeAResetInTheTotal() {
        XCTAssertEqual(totalConsumed([41, 95, 3]), 57)
    }

    func testHandlesSeveralResetsInOneSeries() {
        XCTAssertEqual(totalConsumed([0, 75, 10, 84]), 75 + 10 + 74)
    }
}

final class TodayUsageTests: XCTestCase {
    private func sample(sd: Int, at date: Date) -> RawSample {
        RawSample(t: date.timeIntervalSince1970 * 1000, u: RawUsage(fh: 0, sd: sd))
    }

    // Anchored on the last reading before midnight, so usage that landed
    // while the Mac was asleep still counts toward the right day.
    func testCountsFromTheLastReadingBeforeMidnight() {
        // Derived from the calendar rather than hardcoded, so the boundary
        // is real local midnight wherever these tests run.
        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_785_628_800))
        let samples = [
            sample(sd: 30, at: midnight.addingTimeInterval(-7200)),  // 10 PM yesterday
            sample(sd: 41, at: midnight.addingTimeInterval(-600)),   // 11:50 PM yesterday
            sample(sd: 44, at: midnight.addingTimeInterval(3600)),   // 1 AM today
            sample(sd: 47, at: midnight.addingTimeInterval(7200)),   // 2 AM today
        ]
        let now = midnight.addingTimeInterval(9000)
        XCTAssertEqual(usageToday(samples: samples, now: now, calendar: .current), 6)
    }

    func testSurvivesAWeeklyResetPartwayThroughTheDay() {
        // Derived from the calendar rather than hardcoded, so the boundary
        // is real local midnight wherever these tests run.
        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_785_628_800))
        let samples = [
            sample(sd: 41, at: midnight.addingTimeInterval(-600)),  // 11:50 PM yesterday
            sample(sd: 95, at: midnight.addingTimeInterval(7200)),  // 2 AM today
            sample(sd: 3, at: midnight.addingTimeInterval(10800)),  // 3 AM — weekly window reset
        ]
        let now = midnight.addingTimeInterval(14400)
        XCTAssertEqual(usageToday(samples: samples, now: now, calendar: .current), 57)
    }

    func testNoFigureWhenHistoryStartsAfterMidnight() {
        // Derived from the calendar rather than hardcoded, so the boundary
        // is real local midnight wherever these tests run.
        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_785_628_800))
        let samples = [sample(sd: 44, at: midnight.addingTimeInterval(3600))]
        XCTAssertNil(usageToday(samples: samples, now: midnight.addingTimeInterval(7200)))
    }

    // A midnight baseline covers the whole day, so the label stays plain.
    func testLabelIsPlainWhenTheBaselineCoversTheWholeDay() {
        let now = Date(timeIntervalSince1970: 1_785_628_800 + 50_000)
        let midnight = Calendar.current.startOfDay(for: now)
        XCTAssertEqual(todayLabel((percent: 12, since: midnight), now: now), "+12%")
    }

    // A mid-day baseline can't see what was spent earlier, so it says so.
    func testLabelDisclosesAMidDayBaseline() {
        let now = Date(timeIntervalSince1970: 1_785_628_800 + 50_000)
        let since = Calendar.current.startOfDay(for: now).addingTimeInterval(15 * 3600)
        XCTAssertEqual(todayLabel((percent: 12, since: since), now: now), "+12% (since 3:00 PM)")
    }
}

final class DailyUsageTests: XCTestCase {
    private let calendar = Calendar.current

    private func sample(sd: Int, at date: Date) -> RawSample {
        RawSample(t: date.timeIntervalSince1970 * 1000, u: RawUsage(fh: 0, sd: sd))
    }

    private func day(_ offset: Int, from now: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    // The property the whole design rests on: each day is a slice of the
    // same weekly quota, so the slices add back up to the weekly figure the
    // menu shows. If this ever fails, the chart is lying.
    func testDaysAddUpToTheWeeklyTotal() {
        let now = Date(timeIntervalSince1970: 1_785_628_800)
        let weekStart = day(-3, from: now).addingTimeInterval(3 * 3600)
        let samples = [
            sample(sd: 0, at: weekStart.addingTimeInterval(3600)),
            sample(sd: 8, at: day(-3, from: now).addingTimeInterval(20 * 3600)),
            sample(sd: 26, at: day(-2, from: now).addingTimeInterval(12 * 3600)),
            sample(sd: 41, at: day(-1, from: now).addingTimeInterval(12 * 3600)),
            sample(sd: 48, at: day(0, from: now).addingTimeInterval(3600)),
        ]
        let result = dailyUsage(samples: samples, weekStart: weekStart, now: now, calendar: calendar)

        XCTAssertEqual(result.map(\.percent), [8, 18, 15, 7])
        XCTAssertEqual(result.compactMap(\.percent).reduce(0, +), 48)
    }

    // A spurious single 0 followed by a bounce straight back is a reporting
    // glitch, not a window reset. Counting the bounce as fresh usage is what
    // once inflated a day from 18% to 30%.
    func testASpuriousZeroDoesNotInflateADay() {
        let now = Date(timeIntervalSince1970: 1_785_628_800)
        let weekStart = day(-1, from: now).addingTimeInterval(3 * 3600)
        let samples = [
            sample(sd: 0, at: weekStart.addingTimeInterval(600)),
            sample(sd: 12, at: day(0, from: now).addingTimeInterval(3600)),
            sample(sd: 0, at: day(0, from: now).addingTimeInterval(7200)),   // glitch
            sample(sd: 12, at: day(0, from: now).addingTimeInterval(10800)),
            sample(sd: 18, at: day(0, from: now).addingTimeInterval(14400)),
        ]
        let result = dailyUsage(samples: samples, weekStart: weekStart, now: now, calendar: calendar)

        XCTAssertEqual(result.last?.percent, 18)
    }

    // Nothing before the reset belongs to this window, so it must not leak
    // into the first day's bar.
    func testUsageBeforeTheResetIsExcluded() {
        let now = Date(timeIntervalSince1970: 1_785_628_800)
        let weekStart = day(0, from: now).addingTimeInterval(3 * 3600)
        let samples = [
            sample(sd: 90, at: day(0, from: now).addingTimeInterval(3600)),  // previous window
            sample(sd: 0, at: weekStart),
            sample(sd: 5, at: day(0, from: now).addingTimeInterval(4 * 3600)),
        ]
        let result = dailyUsage(samples: samples, weekStart: weekStart, now: now, calendar: calendar)

        XCTAssertEqual(result.map(\.percent), [5])
    }

    func testStartsOnTheResetDayNotSevenDaysBack() {
        let now = Date(timeIntervalSince1970: 1_785_628_800)
        let weekStart = day(-2, from: now).addingTimeInterval(3 * 3600)
        let samples = [sample(sd: 0, at: weekStart), sample(sd: 4, at: day(0, from: now))]
        let result = dailyUsage(samples: samples, weekStart: weekStart, now: now, calendar: calendar)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.first?.day, day(-2, from: now))
        XCTAssertEqual(result.last?.day, day(0, from: now))
    }
}

final class UsageBarTests: XCTestCase {
    func testBusiestDayFillsTheWidth() {
        XCTAssertEqual(usageBar(percent: 20, peak: 20, width: 10).count, 10)
    }

    func testBarIsProportionalToThePeak() {
        XCTAssertEqual(usageBar(percent: 10, peak: 20, width: 10).count, 5)
    }

    // A day with real usage must never render as an empty row — that would
    // be indistinguishable from an idle day.
    func testTinyUsageStillGetsABlock() {
        XCTAssertEqual(usageBar(percent: 1, peak: 90, width: 10).count, 1)
    }

    func testIdleDayHasNoBar() {
        XCTAssertEqual(usageBar(percent: 0, peak: 20, width: 10), "")
    }
}

final class UsageLedgerTests: XCTestCase {
    private let calendar = Calendar.current
    private let noon = Date(timeIntervalSince1970: 1_785_628_800)

    private func at(_ hoursFromNoon: Double, dayOffset: Int = 0) -> Date {
        calendar.date(byAdding: .day, value: dayOffset, to: noon)!
            .addingTimeInterval(hoursFromNoon * 3600)
    }

    private func key(_ date: Date) -> String { ledgerDayKey(date, calendar: calendar) }

    func testFirstReadingAttributesNothing() {
        let ledger = recording(UsageLedger(), weeklyPercent: 40, at: noon, source: .api, calendar: calendar)
        XCTAssertEqual(ledger.days[key(noon)]?.consumed, 0)
        XCTAssertEqual(ledger.lastSeenPercent, 40)
    }

    func testRisesWithinADayAccumulate() {
        var ledger = recording(UsageLedger(), weeklyPercent: 40, at: noon, source: .api, calendar: calendar)
        ledger = recording(ledger, weeklyPercent: 43, at: at(1), source: .api, calendar: calendar)
        ledger = recording(ledger, weeklyPercent: 48, at: at(2), source: .api, calendar: calendar)

        XCTAssertEqual(ledger.days[key(noon)]?.consumed, 8)
        XCTAssertEqual(ledger.unrecorded, 0)
    }

    // A day this app watched must be distinguishable from one it didn't, even
    // when nothing was spent — otherwise the chart can't tell whether to fall
    // back to the desktop app's file for it.
    func testAWatchedButIdleDayStillGetsAnEntry() {
        var ledger = recording(UsageLedger(), weeklyPercent: 40, at: noon, source: .api, calendar: calendar)
        ledger = recording(ledger, weeklyPercent: 40, at: at(3), source: .api, calendar: calendar)

        XCTAssertNotNil(ledger.days[key(noon)])
        XCTAssertEqual(ledger.days[key(noon)]?.consumed, 0)
    }

    // Usage that appeared across a gap spanning days can't be placed on one,
    // so it's held aside instead of inflating whichever day we came back on.
    func testUsageAcrossAMultiDayGapIsNotAttributedToADay() {
        var ledger = recording(UsageLedger(), weeklyPercent: 40, at: at(10), source: .api, calendar: calendar)
        ledger = recording(ledger, weeklyPercent: 45, at: at(-3, dayOffset: 2), source: .api, calendar: calendar)

        XCTAssertEqual(ledger.unrecorded, 5)
        XCTAssertEqual(ledger.days[key(at(-3, dayOffset: 2))]?.consumed, 0)
    }

    func testAWeeklyResetStartsTheDayOverAtTheNewFigure() {
        var ledger = recording(UsageLedger(), weeklyPercent: 90, at: noon, source: .api, calendar: calendar)
        ledger = recording(ledger, weeklyPercent: 95, at: at(1), source: .api, calendar: calendar)
        ledger = recording(ledger, weeklyPercent: 3, at: at(2), source: .api, calendar: calendar)  // window reset

        XCTAssertEqual(ledger.days[key(noon)]?.consumed, 3)
        XCTAssertEqual(ledger.unrecorded, 0)
    }

    // Starting up mid-day creates an entry, but one that missed the morning.
    // Marking it incomplete is what stops the chart from trusting it over the
    // desktop app's file, which may have watched the whole day.
    func testADayFirstSeenMidWayThroughIsMarkedIncomplete() {
        let ledger = recording(UsageLedger(), weeklyPercent: 40, at: noon, source: .api, calendar: calendar)
        XCTAssertEqual(ledger.days[key(noon)]?.fromDayStart, false)
    }

    // Running as the day turns over is the one case where our figure for it
    // is complete.
    func testADayWatchedAcrossMidnightIsMarkedComplete() {
        let lateLastNight = calendar.startOfDay(for: noon).addingTimeInterval(-20)
        var ledger = recording(UsageLedger(), weeklyPercent: 40, at: lateLastNight, source: .api, calendar: calendar)
        ledger = recording(
            ledger, weeklyPercent: 40, at: calendar.startOfDay(for: noon),
            source: .api, calendar: calendar
        )

        XCTAssertEqual(ledger.days[key(noon)]?.fromDayStart, true)
    }

    // Coming back after the machine was off is not continuous coverage, even
    // though the previous reading happens to be from the day before.
    func testReturningAfterALongGapDoesNotCountAsWatchingFromTheStart() {
        var ledger = recording(UsageLedger(), weeklyPercent: 40, at: at(-4), source: .api, calendar: calendar)
        ledger = recording(ledger, weeklyPercent: 40, at: at(2, dayOffset: 1), source: .api, calendar: calendar)

        XCTAssertEqual(ledger.days[key(at(2, dayOffset: 1))]?.fromDayStart, false)
    }

    // Signing out drops us onto the desktop app's file, which trails the
    // live API by up to 15 minutes. Folding that in would look like usage
    // running backwards — a weekly reset — and would overwrite a real day's
    // total with the stale figure.
    func testStaleFileReadingsAreNotRecorded() {
        var ledger = recording(UsageLedger(), weeklyPercent: 49, at: noon, source: .api, calendar: calendar)
        ledger = recording(ledger, weeklyPercent: 50, at: at(1), source: .api, calendar: calendar)
        let live = ledger

        ledger = recording(ledger, weeklyPercent: 47, at: at(2), source: .localFile, calendar: calendar)

        XCTAssertEqual(ledger, live, "a stale file reading must leave the ledger untouched")
        XCTAssertEqual(ledger.days[key(noon)]?.consumed, 1)
    }

    func testPruningDropsDaysPastTheCutoff() {
        var ledger = recording(
            UsageLedger(), weeklyPercent: 10, at: at(0, dayOffset: -20),
            source: .api, calendar: calendar
        )
        ledger = recording(ledger, weeklyPercent: 20, at: noon, source: .api, calendar: calendar)
        XCTAssertEqual(ledger.days.count, 2)

        let kept = pruned(
            ledger, before: calendar.date(byAdding: .day, value: -14, to: noon)!, calendar: calendar
        )
        XCTAssertEqual(kept.days.count, 1)
        XCTAssertNotNil(kept.days[key(noon)])
    }

    func testSurvivesBeingSavedAndLoaded() throws {
        var ledger = recording(UsageLedger(), weeklyPercent: 10, at: noon, source: .api, calendar: calendar)
        ledger = recording(ledger, weeklyPercent: 18, at: at(1), source: .api, calendar: calendar)

        let data = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(UsageLedger.self, from: data), ledger)
    }
}

final class DayLabelTests: XCTestCase {
    private let calendar = Calendar.current

    private func days(from start: Date, count: Int) -> [Date] {
        (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    func testUsesWeekdayNamesWhenTheyAreUnique() {
        let labels = dayLabels(
            for: days(from: calendar.startOfDay(for: Date(timeIntervalSince1970: 1_785_628_800)), count: 7),
            calendar: calendar
        )
        XCTAssertEqual(labels.count, 7)
        XCTAssertEqual(Set(labels).count, 7)
        XCTAssertTrue(labels.allSatisfy { $0.count == 3 }, "expected weekday names, got \(labels)")
    }

    // An eighth day means the window wrapped onto the weekday it began on, so
    // "Thu" would appear at both ends with no way to tell them apart.
    func testFallsBackToDayNumbersWhenAWeekdayRepeats() {
        let labels = dayLabels(
            for: days(from: calendar.startOfDay(for: Date(timeIntervalSince1970: 1_785_628_800)), count: 8),
            calendar: calendar
        )
        XCTAssertEqual(Set(labels).count, 8, "every column must be distinguishable: \(labels)")
        XCTAssertTrue(labels.allSatisfy { Int($0) != nil }, "expected day numbers, got \(labels)")
    }
}

final class RecentActivityScenarioTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000)

    // Replays a real session at the live poll rate: a burst, an idle spell,
    // then a second burst. Both bursts fall inside the ceiling, so the window
    // reaches back to just before the first one and reports the pair
    // together — the idle time between them is part of the span, not a reason
    // to forget the earlier usage.
    func testTwoBurstsSeparatedByIdleAreReportedTogether() {
        var tracker = RecentActivityTracker()

        func percent(atSecond second: Double) -> Int {
            switch second {
            case ..<0: return 30                                        // steady before it begins
            case 0...300: return 30 + Int((12 * second / 300).rounded())  // 5 min spending 12%
            case 300...600: return 42                                   // 5 min idle
            default: return 42 + Int((6 * (second - 600) / 180).rounded())  // 3 min spending 6%
            }
        }

        for step in stride(from: -600.0, through: 780.0, by: 20) {
            tracker.record(
                percent: percent(atSecond: step), at: start.addingTimeInterval(step), source: .api,
                resetAt: nil
            )
        }

        let now = start.addingTimeInterval(780)
        XCTAssertEqual(tracker.activity(now: now), .measured(deltaPercent: 18, elapsedMinutes: 13))
    }
}
