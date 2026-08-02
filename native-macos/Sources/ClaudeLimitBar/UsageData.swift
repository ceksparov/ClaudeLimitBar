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

func loadHistory() throws -> [RawSample] {
    let data = try Data(contentsOf: URL(fileURLWithPath: historyPath))
    let history = try JSONDecoder().decode(RawHistory.self, from: data)
    if history.samples.isEmpty { throw UsageError.empty }
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
