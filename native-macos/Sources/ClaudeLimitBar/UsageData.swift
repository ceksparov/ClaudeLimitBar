import Foundation

// Nothing UI-related (menu bar, colors) lives in this file — just "read the
// file, compute the numbers" logic. Drawing on screen is AppDelegate.swift's
// job. This is a direct port of the JS logic in menubar/claude-usage.10s.js —
// same file, same math, same result.

struct RawUsage: Codable {
    let fh: Int  // 5-hour window usage percentage
    let sd: Int  // weekly (7-day) window usage percentage
}

struct RawSample: Codable {
    let t: Double     // when the sample was taken (milliseconds, Unix epoch)
    let u: RawUsage   // fh/sd values at that moment
}

struct RawHistory: Codable {
    let samples: [RawSample]  // every sample in the file
}

// The "limits" list below needs to run the same calculation functions
// (like estimateReset) for both fh and sd without duplicating them — a
// KeyPath lets "which field to look at" become a parameter instead.
struct LimitWindow {
    let id: String          // cache key; must match the API side
    let key: KeyPath<RawUsage, Int>
    let label: String       // name shown in the menu
    let windowMs: Double    // window length (5 hours or 7 days, in milliseconds)
}

let limits: [LimitWindow] = [
    LimitWindow(id: "fiveHour", key: \.fh, label: "Current session", windowMs: 5 * 60 * 60 * 1000),
    LimitWindow(id: "sevenDay", key: \.sd, label: "Weekly (7 days)", windowMs: 7 * 24 * 60 * 60 * 1000),
]

let staleMs: Double = 15 * 60 * 1000  // data older than this is considered "stale"

// Full path to the file the Claude desktop app writes its usage data to.
// NSHomeDirectory() returns the current user's home folder, so we don't
// need to hardcode a username.
let historyPath: String = {
    NSHomeDirectory() + "/Library/Application Support/Claude/plan-usage-history.json"
}()

enum UsageError: Error {
    case empty  // file exists but contains no samples
}

// The desktop app rewrites this file every ~5 minutes, but we consult it
// every 20 seconds — and re-reading plus re-decoding the whole thing each
// time costs a couple of milliseconds on the main thread for work that
// almost always produces the identical result. The file only grows, so that
// cost grows with it. Keeping the last parse around and reusing it until
// the file actually changes on disk removes it.
//
// Main-thread only, like every caller of loadHistory().
private struct HistoryCache {
    let modifiedAt: Date
    let size: Int
    let samples: [RawSample]
}
private var historyCache: HistoryCache?

func loadHistory() throws -> [RawSample] {
    // Size is checked alongside the timestamp because a rewrite landing in
    // the same second as the previous one wouldn't move the timestamp.
    let attributes = try? FileManager.default.attributesOfItem(atPath: historyPath)
    let modifiedAt = attributes?[.modificationDate] as? Date
    let size = attributes?[.size] as? Int

    if let cache = historyCache, let modifiedAt, let size,
        cache.modifiedAt == modifiedAt, cache.size == size
    {
        return cache.samples
    }

    let data = try Data(contentsOf: URL(fileURLWithPath: historyPath))
    let history = try JSONDecoder().decode(RawHistory.self, from: data)
    if history.samples.isEmpty { throw UsageError.empty }

    // Without both attributes there's nothing to invalidate against later,
    // so we'd rather re-read every time than serve a parse we can't tell
    // has gone stale.
    if let modifiedAt, let size {
        historyCache = HistoryCache(modifiedAt: modifiedAt, size: size, samples: history.samples)
    }
    return history.samples
}

// The Claude app occasionally reports a spurious zero in a single sample.
// You can spot one by looking at its neighbors: if the value jumps
// DIRECTLY back to the previous level right after a zero (rather than
// climbing back up gradually, as a real reset would), there was no real
// reset — just a momentary reporting glitch. We filter these out before
// using the data.
func withoutGlitches(_ samples: [RawSample], key: KeyPath<RawUsage, Int>) -> [RawSample] {
    samples.enumerated().filter { index, sample in
        // Only zero values are suspect; keep the first/last sample as-is since they have no neighbor to compare against.
        guard sample.u[keyPath: key] == 0, index > 0, index < samples.count - 1 else { return true }

        let before = samples[index - 1].u[keyPath: key]
        let after = samples[index + 1].u[keyPath: key]
        return !(before > 0 && after >= before)  // jumped back to the previous level -> bogus reading
    }
    .map(\.element)
}

// ESTIMATES when the current window will reset. (If signed in, this
// function isn't needed at all — the live API gives an exact time. This is
// only the fallback path.)
//
// Core idea: within a window, usage percentage only ever INCREASES, never
// decreases. So any decrease between two consecutive samples is evidence
// that a reset happened in between.
//
// The previous version only looked for boundaries at an actual 0 value,
// which was wrong: if usage continues right after a reset, the value may
// never appear as 0 in any sample (real example: 92% -> 3%). In that case
// the boundary is missed, the algorithm walks back to a much older
// boundary, and computes a time in the past, returning "unknown".
//
// The `key: KeyPath<RawUsage, Int>` parameter lets this ONE function work
// for both fh and sd — the caller passes \.fh or \.sd (see the usage in
// UsageData.fileSnapshot).
func estimateReset(
    samples: [RawSample], key: KeyPath<RawUsage, Int>, windowMs: Double, now: Double
) -> Double? {
    let samples = withoutGlitches(samples, key: key)

    guard let last = samples.last, last.u[keyPath: key] > 0 else { return nil }

    // Scan backward for the most recent decrease (i.e. the nearest reset).
    var boundary = 0  // if there's no decrease at all, look from the start of the file
    var i = samples.count - 1
    while i > 0 {
        if samples[i].u[keyPath: key] < samples[i - 1].u[keyPath: key] {
            boundary = i
            break
        }
        i -= 1
    }

    // The window starts not at the moment of the reset, but at the FIRST
    // ACTUAL USE after it. For example, if Claude wasn't used overnight,
    // there can be hours of gap between the reset and the first use.
    var start = boundary
    while start < samples.count && samples[start].u[keyPath: key] == 0 { start += 1 }
    guard start < samples.count else { return nil }

    let resetAt = samples[start].t + windowMs
    return resetAt > now ? resetAt : nil
}

// Converts milliseconds into a readable string like "4h 32m".
func formatDuration(_ ms: Double) -> String {
    if ms <= 0 { return "soon" }
    let totalMin = Int((ms / 60000).rounded())
    let days = totalMin / 1440
    let hours = (totalMin % 1440) / 60
    let mins = totalMin % 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(mins)m" }
    return "\(mins)m"
}

// Appends which day and time a duration like "4d 6h" actually falls on —
// "EEE h:mm a" = short weekday name + 12-hour clock, e.g. "Thu 3:00 AM",
// matching Claude's own desktop app.
private func weekdayClock(_ date: Date) -> String {
    let formatter = DateFormatter()
    // Pinned to English like the rest of the interface — otherwise "a"
    // would print the system language's own localized AM/PM symbols.
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE h:mm a"
    return formatter.string(from: date)
}

// Builds the text shown on the "Resets: ..." line in the menu. If the data
// came from the live API we show the server's exact time; if it came from
// the local file, we make clear to the user that it's our own estimate.
func resetLabel(percent: Int, resetAt: Date?, isEstimate: Bool, now: Date) -> String {
    if let resetAt {
        let interval = resetAt.timeIntervalSince(now)
        let text = formatDuration(interval * 1000)

        // Knowing the exact day/time is useful for a day-scale (weekly)
        // window; for the few-hour session window it already means "today",
        // so it would just be noise — hence only adding it past ~1 day out.
        var notes: [String] = []
        if interval > 20 * 60 * 60 { notes.append(weekdayClock(resetAt)) }
        if isEstimate { notes.append("estimated") }

        guard !notes.isEmpty else { return text }
        return "\(text) (\(notes.joined(separator: ", ")))"
    }
    if percent == 0 { return "no usage yet" }
    return "unknown"
}

// MARK: - Today's share of the weekly quota

// Total consumed across a series of readings, in percentage points.
//
// Summing the rises rather than subtracting the ends is what makes this
// survive a reset. Usage percentage never falls on its own, so a drop means
// the window restarted — and everything showing after that drop was spent
// since it, so it counts too. Subtracting first from last would instead
// throw away everything spent before the reset: a day that reached 54% by
// 2 AM, reset, and climbed back to 3% would read as 3% rather than 57%.
func totalConsumed(_ readings: [Int]) -> Int {
    var total = 0
    for (index, reading) in readings.enumerated() where index > 0 {
        let previous = readings[index - 1]
        total += reading >= previous ? reading - previous : reading
    }
    return total
}

// How much of the weekly quota today accounts for, from the desktop app's
// history. The reading from just before midnight anchors the total, so
// usage that happened while the Mac was asleep still lands on the right day.
func usageToday(samples: [RawSample], now: Date, calendar: Calendar = .current) -> Int? {
    let startOfDay = calendar.startOfDay(for: now).timeIntervalSince1970 * 1000
    guard let anchorIndex = samples.lastIndex(where: { $0.t <= startOfDay }) else { return nil }
    return totalConsumed(samples[anchorIndex...].map(\.u.sd))
}

// The last weekly percentage recorded at or before `moment`, from the
// desktop app's history file. Used to learn what the weekly figure stood at
// when today began — including while the Mac was asleep overnight, where
// the honest baseline is the final reading from the night before.
func lastWeeklyPercent(atOrBefore moment: Date, in samples: [RawSample]) -> Int? {
    let ms = moment.timeIntervalSince1970 * 1000
    return samples.last { $0.t <= ms }?.u.sd
}

// "+12%" when the figure really does cover the whole day, "+12% (since 3:12
// PM)" when the baseline had to be taken mid-day and anything spent before
// that is invisible to us. Saying only "+12%" in that second case would
// imply a full day's total that we can't actually vouch for.
func todayLabel(_ today: (percent: Int, since: Date), now: Date, calendar: Calendar = .current) -> String {
    let text = "+\(today.percent)%"
    guard today.since > calendar.startOfDay(for: now) else { return text }

    let clock = DateFormatter()
    clock.locale = Locale(identifier: "en_US_POSIX")  // pinned to English, like the rest of the interface
    clock.dateFormat = "h:mm a"
    return "\(text) (since \(clock.string(from: today.since)))"
}

// MARK: - Our own record of daily usage

// A record we keep ourselves, rather than reading someone else's.
//
// The desktop app's history file only covers the times THAT app was running.
// We poll every 20 seconds whenever this app is running, which is a
// different — and for a menu bar app set to start at login, usually wider —
// window of coverage. Keeping our own tally means a day spent using Claude
// on the web or a phone still lands on the right day, and machines without
// the desktop app installed get a chart at all.
//
// Everything here is in weekly-quota percentage points, the same unit the
// chart is drawn in.
struct UsageLedger: Codable, Equatable {
    struct Day: Codable, Equatable {
        var consumed: Int
        // The first moment we observed this account that day. Anything spent
        // before it is invisible to us, so the menu can say so instead of
        // presenting a partial figure as a full day's total.
        var firstSeenAt: Date
        // True when we were already watching as this day began, which is the
        // only case where our figure for it is complete. Starting up at noon
        // also creates an entry, but one that missed the morning — without
        // this distinction the chart would trust that partial number over the
        // desktop app's file, which may well have watched the whole day.
        var fromDayStart: Bool
    }

    // Keyed "yyyy-MM-dd" so entries survive being written to disk and
    // compared across launches without timezone drift.
    var days: [String: Day] = [:]

    // Usage that appeared while we weren't watching, across a gap spanning
    // more than one day — we know it happened, but not on which day. Guessing
    // would put someone else's Tuesday on their Wednesday bar, so it's held
    // separately and shown as its own line.
    var unrecorded: Int = 0

    var lastSeenPercent: Int?
    var lastSeenAt: Date?
}

func ledgerDayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

// Folds one new reading into the ledger.
//
// Only live readings are recorded. The desktop app's file lags the API by up
// to 15 minutes, so mixing it in here would be read as usage moving backwards
// — i.e. as a weekly reset — and would replace a real day's total with the
// stale figure. Days spent signed out are covered by reading that file
// directly instead (see dailyUsage), which is what it's good at.
func recording(
    _ ledger: UsageLedger, weeklyPercent: Int, at now: Date,
    source: UsageSnapshot.Source, calendar: Calendar = .current
) -> UsageLedger {
    guard source == .api else { return ledger }

    var updated = ledger
    let key = ledgerDayKey(now, calendar: calendar)

    // Touch the day even when nothing was spent. An absent entry has to mean
    // "we weren't watching", not "watched, and nothing happened" — the chart
    // falls back to the desktop app's file for the former and must not do so
    // for the latter.
    //
    // A day is complete only if the previous reading came from the day before
    // with no meaningful gap, i.e. we were running as it turned over. One
    // poll interval plus slack is the tolerance.
    let watchedFromStart = ledger.lastSeenAt.map {
        !calendar.isDate($0, inSameDayAs: now) && now.timeIntervalSince($0) < 120
    } ?? false
    var day =
        updated.days[key]
        ?? UsageLedger.Day(consumed: 0, firstSeenAt: now, fromDayStart: watchedFromStart)

    if let lastPercent = ledger.lastSeenPercent, let lastAt = ledger.lastSeenAt {
        if weeklyPercent < lastPercent {
            // The weekly window reset. Whatever is on the clock now was spent
            // after it, and anything this day held before belonged to the
            // window that just ended.
            day.consumed = weeklyPercent
            updated.unrecorded = 0
        } else if weeklyPercent > lastPercent {
            let rise = weeklyPercent - lastPercent
            if calendar.isDate(lastAt, inSameDayAs: now) {
                day.consumed += rise
            } else {
                // The gap straddles a day boundary, so we can't say which day
                // this belongs to.
                updated.unrecorded += rise
            }
        }
    }

    updated.days[key] = day
    updated.lastSeenPercent = weeklyPercent
    updated.lastSeenAt = now
    return updated
}

// Drops entries too old for any chart to show, so the record can't grow
// without bound.
func pruned(_ ledger: UsageLedger, before cutoff: Date, calendar: Calendar = .current) -> UsageLedger {
    var updated = ledger
    let cutoffKey = ledgerDayKey(cutoff, calendar: calendar)
    updated.days = updated.days.filter { $0.key >= cutoffKey }  // ISO dates sort chronologically
    return updated
}

// MARK: - Day-by-day breakdown

// One day's share of the weekly quota. `percent` is nil when the history
// doesn't reach back that far — which is not the same as a day with no
// usage, and the chart draws the two differently.
struct DailyUsage {
    let day: Date
    let percent: Int?
}

// Splits the CURRENT weekly window into days, oldest first.
//
// Scoped to the window that's actually running, so every bar is quota the
// user still has on the clock — and the bars add up to the weekly figure
// shown a few rows above. That reconciliation is the whole reason for
// measuring in weekly-quota percentage instead of session windows.
//
// Two details make the total come out right:
//
// - Glitches are filtered first. The desktop app occasionally writes a
//   single spurious 0 (see withoutGlitches); left in, totalConsumed reads
//   the bounce back off it as a fresh window's worth of usage and inflates
//   that day. This is what made an earlier version report 30% on a day that
//   really cost 18%.
// - Days after the first are anchored on the last reading before they
//   began, so a rise spanning midnight lands on the day it happened. The
//   first day needs no anchor: nothing before the reset belongs to this
//   window.
func dailyUsage(
    samples: [RawSample], weekStart: Date, now: Date, calendar: Calendar = .current
) -> [DailyUsage] {
    let clean = withoutGlitches(samples, key: \.sd)
    let firstDay = calendar.startOfDay(for: weekStart)
    let today = calendar.startOfDay(for: now)

    var result: [DailyUsage] = []
    var day = firstDay
    while day <= today {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? now
        // Readings before the reset belong to the previous window, so the
        // first day starts at the reset rather than at midnight.
        let from = max(day, weekStart).timeIntervalSince1970 * 1000
        let inside = clean.filter { $0.t >= from && $0.t < dayEnd.timeIntervalSince1970 * 1000 }

        if day == firstDay {
            result.append(DailyUsage(day: day, percent: totalConsumed(inside.map(\.u.sd))))
        } else if let anchor = clean.last(where: { $0.t <= day.timeIntervalSince1970 * 1000 }) {
            result.append(
                DailyUsage(day: day, percent: totalConsumed([anchor.u.sd] + inside.map(\.u.sd)))
            )
        } else {
            result.append(DailyUsage(day: day, percent: nil))
        }

        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
        day = next
    }
    return result
}

// A proportional bar, scaled so the busiest day in view fills the width.
// Anything above zero gets at least one block: a day with real usage
// shouldn't render as an empty row indistinguishable from an idle one.
func usageBar(percent: Int, peak: Int, width: Int = 10) -> String {
    guard percent > 0, peak > 0 else { return "" }
    let filled = max(1, Int((Double(percent) / Double(peak) * Double(width)).rounded()))
    return String(repeating: "█", count: min(filled, width))
}

func weekdayLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")  // pinned to English, like the rest of the interface
    formatter.dateFormat = "EEE"
    return formatter.string(from: date)
}

// Tracks how much the 5-hour session percentage has grown "recently", from
// a rolling in-memory log of samples. Deliberately NOT persisted to disk —
// it describes recent activity, not a long-term history, so starting empty
// on every launch is fine.
struct RecentActivityTracker {
    // Distinguishes "we checked and it's genuinely 0%" from "we can't
    // honestly say" — collapsing both into a plain "0%" would make someone
    // who just woke their Mac up (no baseline yet) think we measured zero
    // recent activity, when really we just have no data.
    //
    // `elapsedMinutes` is the ACTUAL age of the baseline sample, not a fixed
    // number. While signed in (a fresh sample every 20s) it lands almost
    // exactly on the window; while reading the local file (which the Claude
    // desktop app only writes every ~5 minutes, at no fixed cadence) the
    // closest baseline might really be 6 or 8 minutes old. Rather than
    // mislabel that, we report whatever the real gap turned out to be.
    enum Result: Equatable {
        case unknown
        case measured(deltaPercent: Int, elapsedMinutes: Int)
    }

    // The window is elastic between these two bounds, and reaches back only
    // as far as it needs to. Usage that started 16 minutes ago is reported
    // over 16 minutes rather than padded out to the ceiling, and an idle
    // stretch collapses to the floor — widening past the activity would only
    // relabel the same figure as covering longer, which reads as a staler
    // answer to the same question.
    let minWindow: TimeInterval
    let maxWindow: TimeInterval

    private var samples: [(date: Date, percent: Int)] = []
    private var recordedSource: UsageSnapshot.Source?

    init(minWindow: TimeInterval = 5 * 60, maxWindow: TimeInterval = 20 * 60) {
        self.minWindow = minWindow
        self.maxWindow = maxWindow
    }

    // Appends a sample and drops anything too old to still serve as a
    // baseline. The extra 60s past the cap guarantees a sample remains just
    // beyond it to compare against, even though new data points only arrive
    // every 20s (or every ~5 min from the local file).
    //
    // Samples from the two sources can't be subtracted from one another: the
    // local file lags the live API by up to 15 minutes, so switching to it
    // during an outage and back again would read as a drop and then a spike
    // that never happened. On a source change we start over instead.
    mutating func record(percent: Int, at date: Date, source: UsageSnapshot.Source) {
        if source != recordedSource {
            recordedSource = source
            samples.removeAll()
        }
        samples.append((date, percent))
        let cutoff = date.addingTimeInterval(-maxWindow - 60)
        samples.removeAll { $0.date < cutoff }
    }

    // Forgets everything recorded so far — for when the samples describe an
    // account or organization the user is no longer looking at.
    mutating func reset() {
        samples.removeAll()
        recordedSource = nil
    }

    // `.unknown` covers two cases: there isn't even `minWindow` of history
    // yet (app just launched, or the Mac woke from sleep and the old samples
    // aged out), or the session window reset in between the baseline and now
    // — a percentage DROP means a new 5-hour window started, not negative
    // usage, and there's no honest number to show for it.
    func activity(now: Date) -> Result {
        guard let currentPercent = samples.last?.percent, let oldest = samples.first else {
            return .unknown
        }
        guard now.timeIntervalSince(oldest.date) >= minWindow else { return .unknown }

        // Look no further back than the ceiling; if we have less history than
        // that, however much we do have is the honest limit.
        let horizon = now.addingTimeInterval(-maxWindow)
        let inRange = samples.filter { $0.date >= horizon }
        guard let earliest = inRange.first else { return .unknown }

        let delta = currentPercent - earliest.percent
        // A drop means the 5-hour window reset in between; that isn't
        // negative usage, and there's no honest figure to report for it.
        guard delta >= 0 else { return .unknown }

        // Flat across the whole horizon: nothing to reach back for, so the
        // answer is the most current one the floor can give.
        guard delta > 0 else {
            return .measured(deltaPercent: 0, elapsedMinutes: Int(minWindow / 60))
        }

        // The window ends at the last reading still sitting at the pre-rise
        // level — the moment right before usage started climbing. That's what
        // makes "16 min" mean the activity really did span 16 minutes, rather
        // than being the ceiling with idle time padded onto the front.
        let baseline = inRange.last { $0.percent == earliest.percent } ?? earliest
        let elapsed = Int((now.timeIntervalSince(baseline.date) / 60).rounded())

        // Everything older than the baseline sits at the same level, so
        // widening to the floor cannot change the figure — only its label.
        return .measured(deltaPercent: delta, elapsedMinutes: max(Int(minWindow / 60), elapsed))
    }
}

// Converts the raw samples read from the local file into the same
// UsageSnapshot shape the live API uses. This lets AppDelegate draw both
// sources with a single rendering path (see UsageSnapshot.swift).
func fileSnapshot(samples: [RawSample], now: Double) -> UsageSnapshot {
    guard let last = samples.last else {
        return UsageSnapshot(windows: [], capturedAt: Date(), source: .localFile)
    }

    let windows = limits.map { limit in
        // If we already learned an EXACT time from the API and it's still
        // in the future, use it — no need to estimate, since that moment
        // hasn't changed. This is especially valuable for the weekly
        // window: since the reset is days away, the cached value stays
        // correct for days.
        let cached = SessionStore.cachedResetAt(limit.id)
        let cachedIsUsable = (cached?.timeIntervalSinceNow ?? -1) > 0

        // estimateReset returns milliseconds; convert to Date.
        let estimated = estimateReset(
            samples: samples, key: limit.key, windowMs: limit.windowMs, now: now
        ).map { Date(timeIntervalSince1970: $0 / 1000) }

        return UsageSnapshot.Window(
            id: limit.id,
            label: limit.label,
            percent: last.u[keyPath: limit.key],
            resetAt: cachedIsUsable ? cached : estimated,
            resetIsEstimate: !cachedIsUsable
        )
    }

    return UsageSnapshot(
        windows: windows,
        capturedAt: Date(timeIntervalSince1970: last.t / 1000),
        source: .localFile
    )
}
