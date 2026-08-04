import AppKit
import Network
import ServiceManagement

// This file handles "what do we draw on screen": the menu bar icon, the
// dropdown menu, colors, click behavior. No calculation logic lives here —
// that's in UsageData.swift and UsageAPI.swift.

// Picks a color based on percentage. NSColor is built from "red/green/blue"
// as 0-1 decimals (the same as the #ff3b30 hex code, just divided by 255
// instead of written in hex — 255/255=1.00, 59/255=0.231, etc.).
func colorFor(_ pct: Int) -> NSColor {
    if pct >= 80 { return NSColor(red: 1.00, green: 0.231, blue: 0.188, alpha: 1) } // #ff3b30 red
    if pct >= 50 { return NSColor(red: 1.00, green: 0.624, blue: 0.039, alpha: 1) } // #ff9f0a orange
    return NSColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1) // #30d158 green
}

// .secondaryLabelColor is the system's own "muted gray" — it adapts to
// light/dark mode automatically, so we don't need to hardcode a hex value.
let grayText = NSColor.secondaryLabelColor
let warningColor = NSColor(red: 1.00, green: 0.624, blue: 0.039, alpha: 1) // #ff9f0a

// Each menu row isn't plain text, it's "colored text at a specific size",
// so we use NSAttributedString — a regular String with extra attributes
// (color, font) attached to it.
func attributed(_ text: String, color: NSColor, small: Bool = false) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .foregroundColor: color,
        .font: NSFont.menuFont(ofSize: small ? 11 : NSFont.systemFontSize),
    ])
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // statusItem is the icon itself in the menu bar. ".variableLength" means
    // its width auto-adjusts to the text inside it, rather than a fixed size.
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private let loginWindow = LoginWindowController()

    // Detects Wi-Fi/Ethernet drops and reconnects so we don't wait for the
    // next 20-second poll to notice — the menu itself only redraws once
    // it's closed (see shouldSkipRedraw), but this at least gets a fresh
    // fetch in flight the moment connectivity changes instead of up to
    // 20s later.
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "io.github.claudelimitbar.pathmonitor")
    private var lastNetworkStatus: NWPath.Status?

    // Rebuilding the menu while it's open would make it flicker/close under
    // the user's cursor. This flag lets us defer drawing while it's open.
    private var menuIsOpen = false

    // The panel currently inside the menu, so it can be repainted in place
    // while the menu is open (see UsagePanelView.update). Weak because the
    // menu owns it: once a rebuilt menu replaces it, this should go nil
    // rather than keep a detached view alive.
    private weak var panelView: UsagePanelView?

    // Set to true when we want to redraw immediately after the user
    // themselves just clicked a menu item (e.g. "Start at Login") — AppKit
    // doesn't guarantee the order in which "menu closed" and "action fired"
    // events arrive, so menuIsOpen could still read true and the update
    // would be silently skipped; the user checks the box but doesn't see it
    // reflected until the next periodic refresh.
    private var bypassMenuOpenGuardOnce = false

    private func shouldSkipRedraw() -> Bool {
        if bypassMenuOpenGuardOnce {
            bypassMenuOpenGuardOnce = false
            return false
        }
        return menuIsOpen
    }

    // If an API call failed and we fell back to the local file, we keep the
    // reason around to show it in the menu.
    private var apiError: Error?

    // Becomes true once the session expires and stays true until the user
    // signs in again. We keep this as a separate flag because we clear the
    // expired key right away, so apiError gets wiped on the next loop —
    // without this flag, the "please sign in again" warning would vanish
    // after 20 seconds and the user wouldn't understand why data stopped
    // coming in.
    private var needsReauth = false

    // Organizations tied to the account. Most people have just one; Team/
    // Enterprise accounts can have several, in which case the user needs to
    // be able to pick which one they're looking at (see appendOrganizationMenu).
    private var organizations: [UsageAPI.Organization] = []
    // When did we last fetch the organization list? Never refreshing it
    // means a user who just joined a new team wouldn't see it in the menu;
    // retrying every cycle would mean a pointless request every 20 seconds
    // for the common case of a single organization. Refreshing every half
    // hour is a reasonable middle ground.
    private var organizationsLoadedAt: Date?

    // If the server says "you're requesting too often" (429), we don't send
    // any request until this date. Continuing at the same rate could extend
    // the block; backing off is the right behavior for both us and the server.
    private var pauseUntil: Date?

    // Don't let more than one request be in flight at once. A request can
    // take up to 15 seconds; the timer fires every 20 seconds, and closing
    // the menu also triggers one. Without this guard, overlapping requests
    // would both waste bandwidth and could return out of order, leaving
    // stale data on screen.
    private var isFetching = false
    private var lastFetchAt: Date?

    // How many consecutive auth failures have we seen? Signing the user out
    // on a single failure is risky — a wrong call here destroys a session
    // that was actually still working. We only conclude the session is
    // really over after three failures in a row (i.e. roughly a minute).
    private var consecutiveAuthFailures = 0

    // If registering "Start at Login" failed, we keep the reason around to
    // show it in the menu. Logging alone isn't enough: in a packaged app,
    // stdout goes nowhere, so the user would never learn why the checkbox
    // didn't take.
    private var startAtLoginError: String?

    // The last data we rendered. We keep this so we can rebuild the menu
    // without hitting the network (e.g. there's no point calling the server
    // just to refresh the "Start at Login" checkmark).
    private var lastSnapshot: UsageSnapshot?

    // Answers "how much has the session percentage grown recently" for the
    // menu (see RecentActivityTracker in UsageData.swift).
    // Seeded from the log the last run left behind, so a relaunch picks up
    // where it stopped instead of owing the panel a silent stretch first.
    private var recentActivityTracker = RecentActivityTracker(state: SessionStore.recentActivity)

    // AppKit calls this automatically once NSApplication has finished
    // launching (similar to a "DOMContentLoaded"-style "I'm ready now" moment).
    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory = "don't show a Dock icon, just live in the menu bar".
        NSApp.setActivationPolicy(.accessory)

        // SF Symbols is Apple's built-in icon set; "bolt.fill" is our
        // lightning-bolt icon.
        statusItem.button?.image = NSImage(
            systemSymbolName: "bolt.fill", accessibilityDescription: "Claude Usage"
        )
        statusItem.button?.imagePosition = .imageLeading  // icon on the left, percentage text on the right

        // A one-line status log at launch. If a user reports an issue,
        // these are the first things worth knowing: which version, whether
        // it's running packaged, whether they're signed in. (The session
        // key itself is never logged.)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        log(
            "started — v\(version ?? "dev"), "
                + "\(isBundledApp ? "bundled" : "bare binary"), "
                + "signed in: \(SessionStore.sessionKey != nil)"
        )

        refresh()  // show something immediately once the app launches

        // Poll the live API every 20 seconds. Polling more often is
        // technically possible, but risks hitting a server-side rate limit;
        // 20 seconds is already far more current than the local file's
        // 5-minute write interval.
        //
        // "[weak self]" avoids a memory leak: the timer holds a weak
        // reference to AppDelegate, so if AppDelegate were ever deallocated,
        // the timer wouldn't be forced to keep it alive forever.
        let poll = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // A scheduled timer only runs in the default run loop mode, and
        // tracking an open menu switches the main run loop into event
        // tracking — so without this the polling stops for exactly as long as
        // the user is looking at the panel, which is when fresh figures
        // matter most. .common covers both modes.
        RunLoop.main.add(poll, forMode: .common)
        timer = poll

        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.handleNetworkPathChange(path.status)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    // Fires on every path update (e.g. switching from Wi-Fi to Ethernet),
    // not just real connectivity changes — only act when satisfied/
    // unsatisfied actually flips, otherwise we'd fetch on every interface
    // fluctuation. The first callback just records the baseline.
    private func handleNetworkPathChange(_ status: NWPath.Status) {
        defer { lastNetworkStatus = status }
        guard let previous = lastNetworkStatus, previous != status else { return }
        log("network status changed: \(previous) -> \(status)")
        // Not force: true — a network flap should still respect the 5s
        // throttle and, more importantly, any server-mandated rate-limit
        // backoff (pauseUntil). Bypassing that just because Wi-Fi blipped
        // would be exactly the wrong response to a 429.
        refresh()
    }

    // MARK: - Fetching data

    // If signed in, use the live API; otherwise read the local file
    // directly. This is the central point where the app manages both
    // sources. `force` is for refreshes triggered by the user's own click —
    // the rate limits below are meant for the background timer; when the
    // user signs in or switches organizations, they should see the result
    // IMMEDIATELY, not wait because "5 seconds haven't passed yet".
    private func refresh(force: Bool = false) {
        if !SessionStore.isSignedIn {
            apiError = nil
            organizations = []  // don't carry over the old list after signing out
            renderFromFile()
            return
        }

        // Don't start a second request if one is already in flight. This
        // guard applies even if the user triggered it — two concurrent
        // requests could return out of order and leave stale data on screen.
        guard !isFetching else { return }

        if !force {
            // If we're rate-limited, don't send any request until it lifts.
            if let pauseUntil, pauseUntil > Date() {
                renderFromFile()
                return
            }

            // We also refresh every time the menu closes; if the user opens
            // and closes it repeatedly, that could turn into several
            // requests in a single second. Enforce at least 5 seconds
            // between consecutive requests.
            if let lastFetchAt, Date().timeIntervalSince(lastFetchAt) < 5 { return }
        }

        // A network request can take seconds; awaiting it directly here
        // would freeze the menu bar. Task keeps the UI responsive.
        Task { await refreshFromAPI() }
    }

    // "@MainActor" means this function's body always runs on the main
    // (UI) thread. Anything touching AppKit MUST run on the main thread;
    // without this annotation there's a real risk of crashes/corruption.
    @MainActor
    private func refreshFromAPI() async {
        isFetching = true
        lastFetchAt = Date()
        defer { isFetching = false }  // runs no matter how the function exits

        do {
            let snapshot = try await UsageAPI.fetchSnapshot()
            apiError = nil
            pauseUntil = nil
            consecutiveAuthFailures = 0
            render(snapshot)
            await loadOrganizationsIfNeeded()

        } catch APIError.rateLimited(let retryAfter) {
            // Use the server's suggested wait time; default to 5 minutes if it didn't give one.
            let wait = retryAfter ?? 300
            pauseUntil = Date().addingTimeInterval(wait)
            log("rate limited — pausing for \(Int(wait))s")
            apiError = APIError.rateLimited(retryAfter: retryAfter)
            renderFromFile()

        } catch APIError.unauthorized where consecutiveAuthFailures < 2 {
            // Not sure yet — fall back to the local file without touching the key.
            consecutiveAuthFailures += 1
            apiError = APIError.unauthorized
            renderFromFile()

        } catch APIError.unauthorized {
            // The key is dead now (session expired, or revoked elsewhere).
            // There's no benefit to keeping it in the Keychain: we'd keep
            // sending a request every 20 seconds that we know will fail,
            // and the menu would keep saying "Sign Out" instead of "Sign
            // In". Clearing it lets the menu return to the sign-in state
            // on its own.
            log("session expired — key cleared, sign-in required")
            SessionStore.clear()
            SessionStore.orgId = nil
            organizations = []
            organizationsLoadedAt = nil
            needsReauth = true
            apiError = nil
            // Also drop the old API snapshot: redraw() would otherwise
            // redraw it and show stale usage data under "Source: claude.ai
            // (live)" while actually signed out.
            lastSnapshot = nil
            renderFromFile()

        } catch {
            // A transient problem (no internet, timeout, server error).
            // Rather than breaking the app, we quietly fall back to the
            // local file — the user still sees something, and the reason
            // is shown in the menu. We do NOT touch the key: forcing a
            // re-login over a temporary outage would be wrong.
            apiError = error
            renderFromFile()
        }
    }

    // We only fetch the organization list once; asking again every 20
    // seconds is pointless since this list almost never changes.
    @MainActor
    private func loadOrganizationsIfNeeded() async {
        if let loadedAt = organizationsLoadedAt, Date().timeIntervalSince(loadedAt) < 1800 {
            return
        }
        organizationsLoadedAt = Date()

        // On failure, KEEP the existing list. Using "?? []" instead would
        // make a transient error wipe the organization picker right in
        // front of the user.
        if let fetched = try? await UsageAPI.organizations() {
            organizations = fetched
        }
    }

    // Clearing the activity log has to reach the stored copy as well: it
    // outlives the process now, so forgetting it only in memory would let the
    // next launch restore the very samples we just decided no longer describe
    // the account being looked at.
    private func resetRecentActivity() {
        recentActivityTracker.reset()
        SessionStore.recentActivity = recentActivityTracker.state
    }

    // Rebuilds the menu from whatever data we already have, without hitting the server.
    private func redraw() {
        if let lastSnapshot {
            render(lastSnapshot)
        } else {
            renderFromFile()
        }
    }

    private func renderFromFile() {
        let now = Date().timeIntervalSince1970 * 1000  // "now", in milliseconds
        do {
            let samples = try loadHistory()
            render(fileSnapshot(samples: samples, now: now))
        } catch {
            renderError(error)
        }
    }

    // MARK: - Today's usage

    // Writes this reading into our own record. Called on every observation of
    // the weekly figure, whatever the source, so the ledger keeps covering
    // days the desktop app's history file never saw.
    private func recordInLedger(weeklyPercent: Int, now: Date, source: UsageSnapshot.Source) {
        let updated = recording(
            SessionStore.ledger, weeklyPercent: weeklyPercent, at: now, source: source
        )
        // A fortnight is well past anything the chart can show, and keeps the
        // stored record from growing forever.
        SessionStore.ledger = pruned(
            updated, before: Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
        )
    }

    // Combines the two records of the same thing, day by day.
    //
    // Ours wins for days it watched from the start, since it samples every 20
    // seconds and keeps going whether or not the desktop app is open. For
    // every other day the desktop app's file is the better bet: it may have
    // been watching while this app wasn't, and its figure for a day this app
    // only caught the tail of is the more complete one.
    private func mergedDays(weekStart: Date, now: Date) -> [DailyUsage] {
        let ledger = SessionStore.ledger
        let fromFile = (try? loadHistory()).map {
            dailyUsage(samples: $0, weekStart: weekStart, now: now)
        } ?? []

        return fromFile.map { day in
            DailyUsage(
                day: day.day,
                percent: dailyFigure(
                    ledger: ledger.days[ledgerDayKey(day.day)], fromFile: day.percent
                )
            )
        }
    }

    // How much of the weekly quota today accounts for, plus the moment that
    // figure actually starts from — midnight when a source covered the whole
    // day, otherwise when we first looked, which the menu discloses instead
    // of passing a partial number off as a full day.
    private func todayUsage(now: Date) -> (percent: Int, since: Date)? {
        let startOfToday = Calendar.current.startOfDay(for: now)
        let mine = SessionStore.ledger.days[ledgerDayKey(now)]
        let fromFile = (try? loadHistory()).flatMap { usageToday(samples: $0, now: now) }

        guard let percent = dailyFigure(ledger: mine, fromFile: fromFile) else { return nil }

        // Only a ledger entry that started mid-day leaves part of the day
        // unaccounted for; anything else covers it from midnight.
        let partial = !(mine?.fromDayStart ?? false) && fromFile == nil
        return (percent, partial ? (mine?.firstSeenAt ?? startOfToday) : startOfToday)
    }

    // MARK: - Drawing

    // The actual "what goes in the menu bar, what's in the dropdown" logic lives here.
    private func render(_ snapshot: UsageSnapshot) {
        // No windows means nothing to show. Displaying "0%" here would be
        // WRONG — the user would think they've used nothing. (The server
        // can return both windows empty for some account types; that means
        // we have no data, not zero usage.)
        guard !snapshot.windows.isEmpty else {
            renderNoData()
            return
        }

        lastSnapshot = snapshot
        let now = Date()
        let age = now.timeIntervalSince(snapshot.capturedAt) * 1000
        // Live API data is fresh by definition; staleness only makes sense for the local file.
        let stale = snapshot.source == .localFile && age > staleMs
        // The session window is what the menu bar shows and what "recent
        // activity" tracks. Accounts without one fall back to whatever
        // window they do have, so the icon still shows something.
        let sessionWindow = snapshot.windows.first { $0.id == "fiveHour" }
        let headline = (sessionWindow ?? snapshot.windows.first)?.percent ?? 0
        // Only the source that's actually authoritative right now feeds the
        // tracker. While signed in that's the API; a momentary failure drops
        // us onto the local file for display, but letting those readings in
        // would count as a source change and throw the window away over a
        // blip of network trouble.
        let authoritative = snapshot.source == .api || !SessionStore.isSignedIn
        if let sessionWindow, authoritative {
            recentActivityTracker.record(
                percent: sessionWindow.percent, at: now,
                source: snapshot.source, resetAt: sessionWindow.resetAt
            )
            SessionStore.recentActivity = recentActivityTracker.state
        }
        if let weekly = snapshot.windows.first(where: { $0.id == "sevenDay" }) {
            recordInLedger(weeklyPercent: weekly.percent, now: now, source: snapshot.source)
        }

        // The "⚡ 14%" text in the menu bar — this can update even while
        // the menu is open, since it isn't part of the menu itself.
        statusItem.button?.attributedTitle = attributed(
            " \(headline)%", color: stale ? .disabledControlTextColor : colorFor(headline)
        )

        // The menu itself can't be swapped out while the user has it open —
        // that would close it under their cursor. The panel inside it can
        // still be repainted, though, so the figures stay live rather than
        // freezing at whatever was true the moment it opened.
        guard !shouldSkipRedraw() else {
            _ = panelView?.update(model: panelModel(snapshot: snapshot, now: now))
            return
        }

        // NSMenu is the dropdown itself; each row is an NSMenuItem.
        let menu = NSMenu()
        menu.delegate = self

        // The whole display half of the menu is one drawn view rather than a
        // column of text rows — see UsagePanelView.
        let panel = NSMenuItem()
        let panelBody = UsagePanelView(model: panelModel(snapshot: snapshot, now: now))
        panel.view = panelBody
        panelView = panelBody
        menu.addItem(panel)

        menu.addItem(.separator())
        addRow(to: menu, sourceLine(snapshot: snapshot, age: age), color: grayText, small: true)

        if stale {
            addRow(
                to: menu, "⚠️ Data is stale — Claude may not be running",
                color: warningColor, small: true
            )
        }
        if needsReauth {
            addRow(to: menu, "⚠️ Session expired — please sign in again", color: warningColor, small: true)
        }
        if let apiError {
            addRow(
                to: menu, "⚠️ Live data: \(apiError.shortDescription)",
                color: warningColor, small: true
            )
        }

        appendFooter(to: menu)
        // This line is what actually attaches the menu to the icon —
        // AppKit opens this menu object automatically when the user clicks.
        statusItem.menu = menu
    }

    // We reached the server, but no limit info came back at all.
    private func renderNoData() {
        statusItem.button?.attributedTitle = attributed(" –", color: .disabledControlTextColor)
        guard !shouldSkipRedraw() else { return }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "No usage limits reported", action: nil, keyEquivalent: "")
        addRow(
            to: menu, "This account doesn't report session or weekly limits",
            color: grayText, small: true
        )
        appendFooter(to: menu)
        statusItem.menu = menu
    }

    // We tell the user plainly where the data came from — the "exact vs. estimated" distinction matters.
    private func sourceLine(snapshot: UsageSnapshot, age: Double) -> String {
        switch snapshot.source {
        case .api:
            return "Source: claude.ai (live)"
        case .localFile:
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            let clockStr = clock.string(from: snapshot.capturedAt)
            return "Source: local file · \(clockStr) (\(formatDuration(age)) ago)"
        }
    }

    // The menu shown when the JSON can't be read/is corrupt WHILE signed in.
    private func renderError(_ error: Error) {
        // If not signed in, there's no actual FAILURE here — the user just
        // hasn't connected yet. Showing this as an error screen would
        // needlessly alarm someone opening the app for the first time.
        // This is also the very first screen anyone who doesn't have the
        // Claude desktop app installed will see — so "I downloaded a
        // broken app" is exactly the impression that would form on first
        // contact.
        guard SessionStore.isSignedIn else {
            renderSignedOut()
            return
        }

        statusItem.button?.attributedTitle = attributed(" N/A", color: .disabledControlTextColor)
        guard !shouldSkipRedraw() else { return }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Couldn't read Claude usage data", action: nil, keyEquivalent: "")
        addRow(to: menu, "Error: \(error.localizedDescription)", color: grayText, small: true)
        if let apiError {
            addRow(to: menu, "Live data: \(apiError.shortDescription)", color: grayText, small: true)
        }
        appendFooter(to: menu)
        statusItem.menu = menu
    }

    // Not signed in yet (or the session dropped) and there's no local data
    // to show either. This isn't an error state, just a "ready to start"
    // state — so it gets its own calm screen instead.
    private func renderSignedOut() {
        statusItem.button?.attributedTitle = attributed(" –", color: .disabledControlTextColor)
        guard !shouldSkipRedraw() else { return }

        let menu = NSMenu()
        menu.delegate = self

        if needsReauth {
            menu.addItem(withTitle: "Session expired", action: nil, keyEquivalent: "")
            addRow(to: menu, "Sign in again to see your usage", color: grayText, small: true)
        } else {
            menu.addItem(withTitle: "Not signed in", action: nil, keyEquivalent: "")
            addRow(to: menu, "Sign in with Claude to see your usage limits", color: grayText, small: true)
        }

        appendFooter(to: menu)
        statusItem.menu = menu
    }

    // Turns a snapshot into everything the drawn panel needs, so the view
    // itself holds no knowledge of where any of it came from.
    private func panelModel(snapshot: UsageSnapshot, now: Date) -> UsagePanelModel {
        let windows = snapshot.windows.map { window in
            let reset = resetLabel(
                percent: window.percent, resetAt: window.resetAt,
                isEstimate: window.resetIsEstimate, now: now
            )

            // Each window gets the breakdown that suits its timescale: a
            // few-minute delta for the session window, a since-midnight total
            // for the weekly one. The reverse of either would be meaningless
            // — the weekly figure barely moves in 5 minutes, and a session
            // that resets every 5 hours has no "today".
            var detail = reset
            switch window.id {
            case "fiveHour":
                // Always stated (never just left out) so "no data yet" can't
                // be mistaken for a measured 0%.
                switch recentActivityTracker.activity(now: now) {
                case .measured(let delta, let elapsed):
                    detail += " · +\(delta)% last \(recentSpanLabel(elapsed))"
                case .unknown:
                    // Reached only just after a launch, or when the window
                    // reset moments ago. Saying "unknown" reads like a
                    // failure; this is a wait, and it ends on its own.
                    detail += " · measuring recent usage"
                }
            case "sevenDay":
                if let today = todayUsage(now: now) {
                    detail += " · \(todayLabel(today, now: now)) today"
                }
            default:
                break
            }

            return UsagePanelModel.Window(
                title: window.label, percent: window.percent, detail: detail
            )
        }

        // Only the running window is charted: days from the previous one are
        // quota that's already gone and can't be acted on. The window's start
        // comes from the server's exact reset time rather than a guess.
        var days: [UsagePanelModel.Day] = []
        if let resetAt = snapshot.windows.first(where: { $0.id == "sevenDay" })?.resetAt {
            let today = Calendar.current.startOfDay(for: now)
            let measured = mergedDays(weekStart: resetAt.addingTimeInterval(-7 * 24 * 60 * 60), now: now)
            let labels = dayLabels(for: measured.map(\.day))

            days = zip(measured, labels).map { day, label in
                UsagePanelModel.Day(label: label, percent: day.percent, isToday: day.day == today)
            }
        }

        return UsagePanelModel(
            windows: windows,
            days: days.contains { $0.percent != nil } ? days : [],
            weekTotal: snapshot.windows.first { $0.id == "sevenDay" }?.percent,
            unrecorded: SessionStore.ledger.unrecorded
        )
    }

    // A small helper so we don't repeat the same three lines (build the
    // title, set its color, add it to the menu) everywhere.
    private func addRow(to menu: NSMenu, _ text: String, color: NSColor, small: Bool = false) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = attributed(text, color: color, small: small)
        menu.addItem(item)
    }

    // The shared part appended to the bottom of every menu variant.
    private func appendFooter(to menu: NSMenu) {
        menu.addItem(.separator())

        appendOrganizationMenu(to: menu)

        // A single row depending on sign-in state: either offer to sign in, or offer to sign out.
        let signedIn = SessionStore.isSignedIn
        let authItem = NSMenuItem(
            title: signedIn ? "Sign Out" : "Sign In with Claude…",
            action: signedIn ? #selector(signOut) : #selector(signIn),
            keyEquivalent: ""
        )
        authItem.target = self
        menu.addItem(authItem)

        appendStartAtLoginItem(to: menu)

        // "Open Claude" is only shown if the Claude desktop app is actually
        // installed. It used to always be there, including for people who
        // never installed the desktop app — clicking it did nothing, and
        // that's exactly the likely position of anyone installing from a
        // release (the desktop app isn't required, signing in is enough).
        if claudeAppURL != nil {
            let openItem = NSMenuItem(title: "Open Claude", action: #selector(openClaude), keyEquivalent: "")
            openItem.target = self
            menu.addItem(openItem)
        }

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // If there's more than one organization, make it selectable which one
    // we're looking at. With a single organization (most users) we skip
    // this menu entirely — it would just be unnecessary clutter.
    private func appendOrganizationMenu(to menu: NSMenu) {
        guard organizations.count > 1 else { return }

        let parent = NSMenuItem(title: "Organization", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for org in organizations {
            let item = NSMenuItem(title: org.name, action: #selector(selectOrganization(_:)), keyEquivalent: "")
            item.target = self
            // representedObject holds arbitrary data attached to the menu
            // item; we read the selected organization's id from here when clicked.
            item.representedObject = org.uuid
            item.state = (org.uuid == SessionStore.orgId) ? .on : .off  // checkmark the selected one
            submenu.addItem(item)
        }

        parent.submenu = submenu
        menu.addItem(parent)
    }

    // The "start at login" toggle. SMAppService (macOS 13+) adds the app to
    // System Settings > General > Login Items on the user's behalf — no
    // need for them to go there manually.
    private func appendStartAtLoginItem(to menu: NSMenu) {
        // SMAppService only works from inside a real .app bundle; we don't
        // show this option at all for a bare binary run directly from
        // source, since clicking it would silently fail.
        guard isBundledApp else { return }

        let item = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        item.target = self
        item.state = startsAtLogin ? .on : .off
        menu.addItem(item)

        if let startAtLoginError {
            addRow(to: menu, "   \(startAtLoginError)", color: warningColor, small: true)
        }
    }

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private var startsAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - Menu open/close tracking (NSMenuDelegate)

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // Once the menu closes, apply the update we deferred while it was open.
        refresh()
    }

    // MARK: - Click behavior

    @objc private func signIn() {
        loginWindow.present { [weak self] sessionKey in
            SessionStore.save(sessionKey: sessionKey)
            // This may be a different account — don't carry over the previous account's reset times.
            SessionStore.clearAccountCaches()
            // This may be a different account — the cached org id/list should now be considered stale.
            SessionStore.orgId = nil
            self?.organizations = []
            self?.organizationsLoadedAt = nil
            self?.needsReauth = false
            self?.pauseUntil = nil
            // Samples collected before this belong to whoever was signed in
            // before — comparing across the two would invent activity.
            self?.resetRecentActivity()
            self?.refresh(force: true)
        }
    }

    @objc private func signOut() {
        SessionStore.clear()
        SessionStore.orgId = nil
        SessionStore.preferredOrgId = nil
        organizations = []
        organizationsLoadedAt = nil
        pauseUntil = nil
        apiError = nil
        needsReauth = false  // the user signed out on their own, no warning needed
        lastSnapshot = nil   // don't let stale live data get redrawn again
        resetRecentActivity()

        // Clearing the Keychain isn't enough: WebKit's persistent store
        // still holds the claude.ai session cookie, otherwise "signed out"
        // wouldn't actually be true (see LoginWindowController.clearStoredWebSession).
        LoginWindowController.clearStoredWebSession { [weak self] in
            self?.refresh(force: true)
        }
        refresh(force: true)  // update the UI right away, don't wait for cleanup to finish
    }

    @objc private func selectOrganization(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        SessionStore.orgId = uuid
        // Also save this as an explicit preference: orgId can get cleared
        // during error recovery, but the user's choice should persist.
        SessionStore.preferredOrgId = uuid
        lastSnapshot = nil  // now looking at a different organization
        resetRecentActivity()
        // Cached reset times belong to the PREVIOUS organization.
        SessionStore.clearAccountCaches()
        refresh(force: true)
    }

    @objc private func toggleStartAtLogin() {
        do {
            if startsAtLogin {
                try SMAppService.mainApp.unregister()
                log("start at login disabled")
            } else {
                try SMAppService.mainApp.register()
                log("start at login enabled")
            }
            startAtLoginError = nil
        } catch {
            // We don't break the app, but we don't stay silent either — the
            // user should see why the checkbox didn't change and know they
            // can add it manually.
            log("start at login failed: \(error.localizedDescription)")
            startAtLoginError = "Could not change — add it in System Settings › General › Login Items"
        }
        // The user JUST clicked this checkbox themselves — we don't want
        // the update silently skipped because of the menuIsOpen flag.
        bypassMenuOpenGuardOnce = true
        redraw()  // just refresh the checkmark in the menu — no need to hit the network
    }

    // Where the Claude desktop app lives — nil if it isn't installed. We
    // look it up by bundle identifier so it's found even if installed
    // somewhere other than /Applications.
    private var claudeAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")
    }

    @objc private func openClaude() {
        guard let url = claudeAppURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
