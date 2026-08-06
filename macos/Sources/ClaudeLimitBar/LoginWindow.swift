import AppKit
import OSLog
import WebKit

// The sign-in flow passes through several windows and redirects, so when
// something goes wrong it's hard to tell where it got stuck. That's why we
// log every step of the flow.
//
// Why os_log: in a packaged app, print() output goes NOWHERE — there's no
// one reading stdout. So when a user says "I can't sign in", we'd have no
// data at all. os_log writes to the system's log store instead; the user
// can view it from Console.app or with this command:
//
//   log show --predicate 'subsystem == "io.github.claudelimitbar"' --last 1h
//
// privacy: .public — there is NO sensitive value in these log lines (only
// the host+path portion of URLs is written, the session key is never
// logged). Without marking this explicitly, the system masks the text as
// <private> and the log becomes useless.
private let appLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ClaudeLimitBar", category: "app"
)

func log(_ message: String) {
    // .notice was chosen deliberately: .info and .debug are kept in memory
    // only, never written to disk — meaning "log show" would find nothing
    // after the fact (verified). The record needs to be persistent so the
    // user can send us logs later.
    appLog.notice("\(message, privacy: .public)")

    // Also show it directly when run from a terminal (during development).
    let clock = DateFormatter()
    clock.dateFormat = "HH:mm:ss"
    print("[\(clock.string(from: Date()))] \(message)")
    // Flush immediately so it doesn't sit buffered.
    fflush(stdout)
}

// We deliberately do NOT log query parameters (like ?code=...) when logging
// URLs — OAuth codes and similar secrets travel there.
private func safeURL(_ url: URL?) -> String {
    guard let url else { return "?" }
    return "\(url.host ?? "?")\(url.path)"
}

// Exact match or a real subdomain, never a substring — plain "contains"
// would also accept a cookie set by "notclaude.ai.example.com". Cookie
// domains can carry a leading dot per RFC 6265 (a "domain cookie"), so
// that's stripped before comparing.
//
// A value that passes this still needs to survive real API validation
// before being trusted (see `validate` below) — this check exists as
// defense in depth regardless, matching the same reasoning already applied
// next to `reorderLoginFormScript` and `clearStoredWebSession`.
func isClaudeDomain(_ rawDomain: String) -> Bool {
    let domain = rawDomain.hasPrefix(".") ? String(rawDomain.dropFirst()) : rawDomain
    return domain == "claude.ai" || domain.hasSuffix(".claude.ai")
}

// The "Sign In with Claude" window.
//
// Why it's built this way: on Windows, we used to try decrypting the
// Claude desktop app's encrypted cookie database from the outside — a
// fragile approach since it depends on another app's internal storage
// format. Here we instead open claude.ai's REAL login page in our own
// window; the user signs in as usual, and we read the resulting session
// cookie from our own WebView's cookie store. This way we don't depend on
// any app's internal structure.
//
// WKWebView is macOS's embedded WebKit (Safari) engine — so this window is
// a real browser tab.
//
// "WKUIDelegate" is the protocol that routes UI requests from the page to
// us — opening a new window (window.open), showing an alert, etc. Signing
// in with Google works exactly this way (the OAuth flow opens in a separate
// window), so we have to implement this — otherwise WKWebView silently
// ignores the popup request and sign-in fails "for no reason".
final class LoginWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?

    // The second window opened by the Google/SSO flow.
    private var popupWindow: NSWindow?
    private var popupWebView: WKWebView?

    // Timer that polls for the cookie (see below for why this is needed).
    private var pollTimer: Timer?

    // The key currently being validated, and keys that already turned out
    // invalid — so we don't ask the server about the same value over and over each second.
    private var validatingKey: String?
    private var rejectedKeys: Set<String> = []

    // Called when sign-in succeeds. Optional because there isn't one while the window is closed.
    private var onFinish: ((String) -> Void)?

    // Called when signing out. Deleting the Keychain key alone is NOT
    // enough: WKWebView's persistent cookie store keeps the claude.ai
    // session cookie on disk. Without this cleanup, "Sign Out" would be
    // misleading — the user thinks they signed out, but a valid cookie
    // granting account access remains on disk, and the next "Sign In"
    // silently returns to the same session without asking anything.
    //
    // Why claude.ai ONLY: the first version wiped all site data, but that
    // also took out the Google session. The result: the next sign-in
    // required Google to re-authenticate from scratch, which fell back to
    // a passkey — and passkeys DON'T work inside an embedded WKWebView
    // (Touch ID access requires an entitlement only signed apps get).
    // So over-aggressive cleanup put the user on a path where sign-in was
    // impossible.
    //
    // Clearing only claude.ai's data already satisfies the security goal:
    // the Claude session cookie is fully gone. This also matches how
    // browsers behave — signing out of one site doesn't sign you out of
    // your Google account.
    static func clearStoredWebSession(completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()

        // First get the list of "which sites have data stored", then pick only claude.ai's.
        store.fetchDataRecords(ofTypes: types) { records in
            // Looking for an exact match / real subdomain instead of
            // "contains" — otherwise an unrelated domain that happens to
            // contain the substring "claude.ai" (e.g. "notclaude.ai.example.com")
            // could get deleted here too.
            let claudeRecords = records.filter {
                $0.displayName == "claude.ai" || $0.displayName.hasSuffix(".claude.ai")
            }

            store.removeData(ofTypes: types, for: claudeRecords) {
                log("cleared claude.ai web data (\(claudeRecords.count) records)")
                completion()
            }
        }
    }

    func present(onFinish: @escaping (String) -> Void) {
        self.onFinish = onFinish

        // If the window is already open, don't open a second one — bring the existing one forward.
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let configuration = WKWebViewConfiguration()
        // .default() = a PERSISTENT cookie store (written to disk). Picking
        // .nonPersistent() would wipe the session every time the app
        // closes, forcing the user to sign in over and over.
        configuration.websiteDataStore = .default()

        // The script is only added HERE, to our own configuration. Popups
        // use the configuration WebKit hands us (see createWebViewWith) and
        // there's no need to touch that — there's nothing to reorder on
        // Google's own page.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.reorderLoginFormScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let webView = makeWebView(configuration: configuration)
        self.webView = webView

        let window = makeWindow(for: webView, title: "Sign In with Claude")
        self.window = window

        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        window.makeKeyAndOrderFront(nil)
        // .accessory apps don't come to the foreground on their own; this
        // line brings the window in front of the user and gives it keyboard focus.
        NSApp.activate(ignoringOtherApps: true)

        startPolling()
    }

    // Split out since we set up a WebView + window in two places (main window + popup).
    private func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: configuration
        )
        // These two lines wire the page's events to us: navigationDelegate
        // for page loads, uiDelegate for window-opening requests.
        webView.navigationDelegate = self
        webView.uiDelegate = self
        return webView
    }

    // The hint banner sitting above the window.
    //
    // The order here is deliberate: the path we KNOW WORKS first, then the
    // warning. A previous version had Google looking like the default
    // path and email as more of an escape hatch — but real usage showed
    // the opposite: the Google path hits a passkey wall, falls through to
    // the password step, and repeated attempts also run into a sign-in
    // rate limit.
    //
    // Why the passkey warning is necessary: passkeys CANNOT work inside an
    // embedded WKWebView (Apple requires the app to have an "Associated
    // Domains" relationship with the relevant domain for WebAuthn in
    // WKWebView — google.com isn't our domain, so this isn't possible). If
    // we don't say so upfront, the user gets all the way to the passkey
    // screen and hits a confusing error there.
    private static let hintText =
        "Easiest way: sign in with your email — Claude sends you a code. "
        + "If you'd rather use Google, note that passkeys don't work in this "
        + "window: when the passkey prompt appears, choose \"Try another way\" "
        + "and use your password."

    // A small script that moves the email option above Google's on
    // claude.ai's login form. Just changing the hint text to "email first"
    // wasn't enough on its own — the Google button still sits at the top of
    // the page, so the eye goes there first, meaning the path we're
    // recommending would still come second in practice.
    //
    // We don't restructure the DOM — we only adjust CSS "order" values.
    // This way we never touch the buttons themselves, their event
    // handlers, or the form logic; only their visual order changes.
    //
    // Written defensively: if it can't find the elements it's looking for,
    // it does NOTHING. If the page's structure changes, the only
    // consequence is the ordering reverting to default — sign-in still works.
    private static let reorderLoginFormScript = """
    (function () {
      // Note: "endsWith" alone would be wrong here — a domain like
      // "evilclaude.ai" would also pass that check. We require an exact
      // match or a real subdomain (one with a dot before it).
      if (location.hostname !== 'claude.ai' && !location.hostname.endsWith('.claude.ai')) return;

      function reorder() {
        var buttons = Array.prototype.slice.call(document.querySelectorAll('button'));
        var google = buttons.filter(function (b) {
          return /continue with google/i.test(b.textContent || '');
        })[0];
        var email = document.querySelector('input[type="email"], input[name="email"]');
        if (!google || !email) return false;

        // Find the nearest container that holds both
        var box = google;
        while (box && !box.contains(email)) box = box.parentElement;
        if (!box) return false;
        if (getComputedStyle(box).display.indexOf('flex') === -1) return false;

        Array.prototype.forEach.call(box.children, function (child) {
          // email section first, Google last, "or" in between
          child.style.order = child.contains(email) ? '0' : (child === google ? '2' : '1');
        });
        return true;
      }

      // The page is an SPA: the form may not exist until after scripts
      // run. So we try once immediately, then watch the DOM briefly if
      // that doesn't work.
      if (reorder()) return;
      var observer = new MutationObserver(function () {
        if (reorder()) observer.disconnect();
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });
      setTimeout(function () { observer.disconnect(); }, 15000);
    })();
    """

    private func makeHintLabel() -> NSTextField {
        // wrappingLabelWithString produces a non-selectable, line-wrapping
        // label (not an editable text field).
        let label = NSTextField(wrappingLabelWithString: Self.hintText)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeWindow(for webView: WKWebView, title: String) -> NSWindow {
        // The window's content is no longer just the WebView: we build a
        // container with the hint banner on top and the WebView below.
        let hint = makeHintLabel()
        webView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 760))
        container.addSubview(hint)
        container.addSubview(webView)

        // Auto Layout: keeps the banner pinned to the top and lets the
        // WebView fill the remaining space when the window is resized.
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            webView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = container
        window.center()
        // Our app runs in .accessory mode (no Dock icon), so we don't want
        // the window deallocated when closed.
        window.isReleasedWhenClosed = false
        // Get notified if the user closes the window themselves, so we can stop the timer (see windowWillClose).
        window.delegate = self
        return window
    }

    // MARK: - Capturing the cookie
    //
    // Why the cookie check is tied to a timer: sign-in isn't a single page
    // load. During the email/code steps, the Google popup, and the
    // post-sign-in SPA redirects, the "page loaded" (didFinish) event may
    // never fire at all. Polling at a regular interval works regardless of
    // which path the flow completes through — far more robust.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.captureSessionKey()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // WebKit calls this whenever a page load finishes — in addition to the
    // timer, so we can react immediately right after sign-in.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let which = webView === popupWebView ? "popup" : "main"
        log("\(which) window loaded: \(safeURL(webView.url))")
        updateTitle(for: webView)
        captureSessionKey()
    }

    // Fires when the page actually starts changing (before content
    // arrives); updating the title here keeps the address looking correct
    // during a redirect too.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateTitle(for: webView)
    }

    // This window can ask the user for a password (e.g. Google sign-in),
    // but an embedded WebView has no address bar — meaning the user
    // normally can't see WHICH site they're typing their password into.
    // That's a classic setup for phishing. As a mitigation, we show the
    // current domain and whether the connection is encrypted in the window title.
    private func updateTitle(for webView: WKWebView) {
        let host = webView.url?.host ?? "?"
        // If it ever drops to an http (unencrypted) address, that should be obvious.
        let mark = webView.url?.scheme == "https" ? "🔒" : "⚠️ NOT SECURE —"
        let title = "\(mark) \(host)"

        if webView === popupWebView {
            popupWindow?.title = title
        } else {
            window?.title = title
        }
    }

    // If a page fails to load, let's see why.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("load failed: \(safeURL(webView.url)) — \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        log("connection failed: \(safeURL(webView.url)) — \(error.localizedDescription)")
    }

    private func captureSessionKey() {
        // If sign-in already completed (onFinish was consumed), don't do pointless work.
        guard onFinish != nil, let webView else { return }

        // getAllCookies takes a completion handler: it's called once the
        // cookies are ready (this isn't instant, since it's a disk operation).
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            guard
                let cookie = cookies.first(where: {
                    $0.name == "sessionKey" && isClaudeDomain($0.domain)
                }),
                !cookie.value.isEmpty
            else { return }

            let key = cookie.value
            // Don't keep trying to validate the same key over and over — the timer runs every 1.5 seconds.
            guard key != self.validatingKey, !self.rejectedKeys.contains(key) else { return }

            self.validatingKey = key
            log("sessionKey cookie found, validating…")
            Task { await self.validate(key) }
        }
    }

    // A cookie existing alone does NOT mean "sign-in succeeded": during the
    // claude.ai sign-in flow, a sessionKey cookie that isn't valid yet, or
    // is left over from an old session, may be present. So before
    // accepting the key, we make a real API request with it and look at the result.
    //
    // A previous version instead used a shortcut rule like "accept if the
    // main window's URL isn't /login"; since Google sign-in completes in a
    // separate window while the main window stays on /login, that rule
    // also filtered out valid sign-ins.
    private func validate(_ key: String) async {
        let result = await UsageAPI.check(sessionKey: key)

        // Anything touching the UI must run on the main thread.
        await MainActor.run {
            self.validatingKey = nil

            switch result {
            case .valid:
                log("sessionKey valid — sign-in complete")
                self.finish(with: key)

            case .invalid:
                // The server explicitly rejected it; don't try this value
                // again, but leave the window open — once the user
                // completes sign-in, the cookie will update to a new value
                // and we'll validate that one.
                log("sessionKey rejected — sign-in still in progress")
                self.rejectedKeys.insert(key)

            case .unreachable:
                // Inconclusive. We do NOT blacklist the key — just leave it
                // and move on; the timer will try again shortly.
                log("validation inconclusive (network?) — will retry")
            }
        }
    }

    private func finish(with sessionKey: String) {
        // Setting onFinish to nil prevents us from reacting to the same
        // sign-in more than once (the timer checks every second).
        guard let onFinish else { return }
        self.onFinish = nil

        stopPolling()
        closePopup()
        window?.close()
        window = nil
        webView = nil

        onFinish(sessionKey)
    }

    // MARK: - Popup (Google/SSO) support — WKUIDelegate

    // WebKit asks this function when the page calls window.open: "are you
    // going to open this new window?". Returning nil means the popup never
    // opens at all — which is exactly why Google sign-in used to fail
    // silently. Returning a new WKWebView means "yes, open it".
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // IMPORTANT: we must use WebKit's given "configuration" object
        // exactly as-is. If we built our own instead, the popup wouldn't
        // share the same session (and cookies) as the page that opened it,
        // and the OAuth flow would break again.
        log("popup opened: \(safeURL(navigationAction.request.url))")

        let popup = makeWebView(configuration: configuration)
        let popupWindow = makeWindow(for: popup, title: "Signing in…")

        self.popupWebView = popup
        self.popupWindow = popupWindow

        popupWindow.makeKeyAndOrderFront(nil)
        return popup
    }

    // When OAuth finishes, the popup wants to close itself (window.close).
    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popupWebView else { return }
        log("popup closed")
        closePopup()
        // Sign-in may have completed by the time the popup closes; check right away.
        captureSessionKey()
    }

    private func closePopup() {
        popupWindow?.delegate = nil  // don't let our own close trigger windowWillClose
        popupWindow?.close()
        popupWindow = nil
        popupWebView = nil
    }

    // MARK: - Window closing — NSWindowDelegate

    // If the user closes the window without completing sign-in, don't leave the timer running pointlessly.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        stopPolling()
        closePopup()
        onFinish = nil
        window = nil
        webView = nil
    }
}
