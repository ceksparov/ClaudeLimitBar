import Foundation

// There are now two sources of data: the live API (claude.ai) and the
// desktop app's local file. This struct normalizes both into the SAME
// shape, so the code that draws the menu never has to think about "where
// did this data come from" — a single rendering path works for both
// sources. (In software this is usually called an "adapter" or "common
// model" approach: converting different sources into one internal representation.)
struct UsageSnapshot {
    enum Source {
        case api        // fetched live from claude.ai — reset time is EXACT
        case localFile  // from the desktop app's file — reset time is an ESTIMATE
    }

    struct Window {
        let label: String       // name shown in the menu, e.g. "Current session"
        let percent: Int        // usage percentage
        let resetAt: Date?      // reset moment; nil if unknown
        let resetIsEstimate: Bool  // true means we tell the user it's "(estimated)"
    }

    let windows: [Window]
    let capturedAt: Date    // when this data was produced (can be old for the local file)
    let source: Source
}
