import Foundation

// Mirrors menubar/claude-usage.10s.js — same file, same fields, same
// reset-estimate algorithm, so the two versions always agree.

struct RawUsage: Codable {
    let fh: Int
    let sd: Int
}

struct RawSample: Codable {
    let t: Double
    let u: RawUsage
}

struct RawHistory: Codable {
    let samples: [RawSample]
}

struct LimitWindow {
    let key: KeyPath<RawUsage, Int>
    let label: String
    let windowMs: Double
}

let limits: [LimitWindow] = [
    LimitWindow(key: \.fh, label: "5 Saatlik Oturum", windowMs: 5 * 60 * 60 * 1000),
    LimitWindow(key: \.sd, label: "Haftalık (7 gün)", windowMs: 7 * 24 * 60 * 60 * 1000),
]

let staleMs: Double = 15 * 60 * 1000

let historyPath: String = {
    NSHomeDirectory() + "/Library/Application Support/Claude/plan-usage-history.json"
}()

enum UsageError: Error {
    case empty
}

func loadHistory() throws -> [RawSample] {
    let data = try Data(contentsOf: URL(fileURLWithPath: historyPath))
    let history = try JSONDecoder().decode(RawHistory.self, from: data)
    if history.samples.isEmpty { throw UsageError.empty }
    return history.samples
}

// Mevcut pencerenin baslangici: son ornekten geriye dogru, degerin 0
// olmadigi ardisik serinin basi. Pencere deger zaten 0'ken sifirlanabildigi
// icin (0 -> 0 gecisi gorunmez) "dususu ara" yaklasimindan daha guvenilir.
func estimateReset(
    samples: [RawSample], key: KeyPath<RawUsage, Int>, windowMs: Double, now: Double
) -> Double? {
    guard let last = samples.last else { return nil }
    if last.u[keyPath: key] == 0 { return nil }

    var i = samples.count - 1
    while i > 0 && samples[i - 1].u[keyPath: key] != 0 { i -= 1 }
    let windowStart: Double =
        i > 0 ? (samples[i - 1].t + samples[i].t) / 2 : samples[i].t

    let resetAt = windowStart + windowMs
    return resetAt > now ? resetAt : nil
}

func formatDuration(_ ms: Double) -> String {
    if ms <= 0 { return "birazdan" }
    let totalMin = Int((ms / 60000).rounded())
    let days = totalMin / 1440
    let hours = (totalMin % 1440) / 60
    let mins = totalMin % 60
    if days > 0 { return "\(days)g \(hours)s" }
    if hours > 0 { return "\(hours)s \(mins)dk" }
    return "\(mins)dk"
}

func resetLabel(pct: Int, resetAt: Double?, now: Double) -> String {
    if pct == 0 { return "henüz kullanım yok" }
    if let resetAt { return formatDuration(resetAt - now) }
    return "bilinmiyor"
}
