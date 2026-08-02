import Foundation

// A client that talks to claude.ai's internal API — the same one its own
// usage settings page uses. Its big advantage over the local file: we don't
// have to ESTIMATE the reset time, the server tells us the exact moment.
//
// Note: this is not an API Anthropic officially documents — it's the
// internal endpoint the browser page itself calls. If it ever changes, the
// app falls back to the local file (see AppDelegate.refresh).
enum APIError: LocalizedError {
    case notSignedIn
    case unauthorized
    case badStatus(Int)
    case noOrganization
    // The server said "you're requesting too often". retryAfter is the
    // server's suggested wait time (Retry-After header); nil if it didn't give one.
    case rateLimited(retryAfter: TimeInterval?)
    // Cloudflare's bot check. Has NOTHING to do with the session — a temporary block.
    case blocked

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in"
        case .unauthorized: return "Session expired — sign in again"
        case .badStatus(let code): return "Server returned \(code)"
        case .noOrganization: return "No organization found for this account"
        case .rateLimited: return "Rate limited — backing off"
        case .blocked: return "Temporarily blocked by the site's bot check"
        }
    }
}

enum UsageAPI {
    private static let host = "https://claude.ai"

    // URLSession.shared uses its own cookie store and could override our
    // manually-set Cookie header. So we disable cookies entirely and manage
    // our own session — the Keychain's sessionKey is the single source of truth.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    // MARK: - Shape of the server's JSON

    private struct APIWindow: Decodable {
        let utilization: Double
        let resetsAt: String?
    }

    private struct APIUsage: Decodable {
        let fiveHour: APIWindow?
        let sevenDay: APIWindow?
    }

    private struct APIOrganization: Decodable {
        let uuid: String
        let name: String?
        let capabilities: [String]?
    }

    // The simplified type we expose outward so the menu can show an
    // organization picker (see AppDelegate.appendOrganizationMenu).
    struct Organization {
        let uuid: String
        let name: String
    }

    // MARK: - Generic request helper

    private static func get<T: Decodable>(_ path: String, sessionKey: String) async throws -> T {
        var request = URLRequest(url: URL(string: host + path)!)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The server can behave differently for requests that don't look
        // like they came from a browser, so we send a normal browser identity.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badStatus(0) }

        // 429 = "you're requesting too often". We need to recognize this
        // distinctly: continuing at the same rate could extend the block.
        // The caller should see this and stop sending requests for a while
        // (see AppDelegate.pauseUntil).
        if http.statusCode == 429 {
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw APIError.rateLimited(retryAfter: retryAfter)
        }

        // claude.ai sits behind Cloudflare. When its bot check kicks in, it
        // returns 403 with an HTML challenge page ("Just a moment..."),
        // while the real API always returns JSON.
        //
        // This distinction matters because treating every 403 as "session
        // invalid" would delete a user's PERFECTLY VALID session during a
        // temporary bot check. This app's own client isn't currently
        // hitting that check (verified — it was curl that triggered it), so
        // this isn't a fix for a known failure, it's a safeguard against
        // destroying a session if it ever does happen.
        //
        // A previous version built this split the OTHER way around — as
        // "if it's not JSON, assume it's Cloudflare". The problem: if
        // Cloudflare (or whatever WAF/CDN sits in front of it) ever serves
        // a challenge page with an "application/json" content type (some
        // providers do this for XHR requests), that check would mistake it
        // for a genuine "session expired" response and delete a valid key.
        // Instead we look POSITIVELY for actual signs Cloudflare left behind
        // (body text or its own header) — narrower, but more accurate.
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        let looksLikeCloudflareChallenge =
            http.value(forHTTPHeaderField: "cf-mitigated") != nil
            || bodyText.contains("Just a moment")
            || bodyText.contains("cf-chl")

        if looksLikeCloudflareChallenge && (http.statusCode == 401 || http.statusCode == 403) {
            throw APIError.blocked
        }

        // Only the server's ACTUAL response counts as an auth failure.
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Organization id
    //
    // The usage endpoint is /api/organizations/{ORG_ID}/usage, so an org id
    // is required. We cache it in UserDefaults so we don't fetch it every time.
    private static func organizationId(sessionKey: String) async throws -> String {
        if let cached = SessionStore.orgId { return cached }

        let orgs: [APIOrganization] = try await get("/api/organizations", sessionKey: sessionKey)

        // In order: the one the user explicitly picked (if they still have
        // access), then the first with chat capability, then just the first one.
        //
        // Trying the user's choice first matters: orgId can get cleared
        // during error recovery, landing us back here — if we don't
        // remember the preference here, the user's choice would silently
        // vanish on every transient error.
        let chosen = orgs.first { $0.uuid == SessionStore.preferredOrgId }
            ?? orgs.first { $0.capabilities?.contains("chat") == true }
            ?? orgs.first
        guard let uuid = chosen?.uuid else { throw APIError.noOrganization }

        SessionStore.orgId = uuid
        return uuid
    }

    // A key's status has THREE possible outcomes, and the distinction
    // matters. "Invalid" and "currently unreachable" are not the same
    // thing: conflating them would mean a one-second internet blip during
    // sign-in permanently marks the user's REAL key as "invalid" and
    // sign-in never completes. So we only treat an explicit server
    // rejection as invalid.
    enum KeyCheck {
        case valid        // the server accepted it
        case invalid      // the server explicitly rejected it (401/403)
        case unreachable  // inconclusive — network error, timeout, etc.
    }

    // Does a sessionKey actually work? The login window uses this to check
    // a cookie it captured before accepting it.
    //
    // Why this is needed: during sign-in, claude.ai may have left behind a
    // sessionKey cookie that isn't valid yet, or is left over from an old
    // session. So just checking "does a cookie exist" isn't enough — the
    // only reliable test is to actually make an API request with it and
    // look at the result.
    static func check(sessionKey: String) async -> KeyCheck {
        do {
            let orgs: [APIOrganization] = try await get("/api/organizations", sessionKey: sessionKey)
            return orgs.isEmpty ? .invalid : .valid
        } catch APIError.unauthorized {
            return .invalid
        } catch {
            // Network error, timeout, unexpected response shape... in all
            // of these we prefer to say "I don't know" and retry.
            return .unreachable
        }
    }

    // All organizations tied to the account. Most users have just one;
    // Team/Enterprise accounts can have several, in which case the user
    // needs to be able to pick which one they're looking at.
    static func organizations() async throws -> [Organization] {
        guard let key = SessionStore.sessionKey else { throw APIError.notSignedIn }
        let raw: [APIOrganization] = try await get("/api/organizations", sessionKey: key)
        // If the name comes back empty, show the id instead so the menu doesn't have a blank row.
        return raw.map { Organization(uuid: $0.uuid, name: $0.name ?? $0.uuid) }
    }

    // MARK: - Public entry points

    static func fetchSnapshot() async throws -> UsageSnapshot {
        guard let key = SessionStore.sessionKey else { throw APIError.notSignedIn }

        do {
            return try await snapshot(sessionKey: key)
        } catch APIError.unauthorized {
            // A 403 can mean one of two different things: "your session is
            // invalid" or "you don't have access to this organization" —
            // claude.ai returns 403 for both, we can't tell them apart.
            // Since the cached org id could be stale (the user may have
            // been removed from a team), we first drop JUST that and try
            // once more. This avoids forcing an unnecessary re-login when
            // the actual problem isn't the session at all.
            guard SessionStore.orgId != nil else { throw APIError.unauthorized }
            SessionStore.orgId = nil
            return try await snapshot(sessionKey: key)
        }
    }

    private static func snapshot(sessionKey key: String) async throws -> UsageSnapshot {
        let org = try await organizationId(sessionKey: key)
        let usage: APIUsage = try await get("/api/organizations/\(org)/usage", sessionKey: key)

        // The server gives each window in its own field; convert both into
        // the same "Window" shape and order them the way the menu expects.
        // compactMap drops any nils (e.g. if the account has no weekly
        // limit defined, that field comes back nil).
        let windows: [UsageSnapshot.Window] = [
            window(from: usage.fiveHour, id: "fiveHour", label: "Current session"),
            window(from: usage.sevenDay, id: "sevenDay", label: "Weekly (7 days)"),
        ].compactMap { $0 }

        return UsageSnapshot(windows: windows, capturedAt: Date(), source: .api)
    }

    private static func window(from raw: APIWindow?, id: String, label: String) -> UsageSnapshot.Window? {
        guard let raw else { return nil }
        let resetAt = raw.resetsAt.flatMap(parseTimestamp)

        // Cache the exact time: if we can't reach the API at some point,
        // we'll use this instead of estimating from the local file (see
        // SessionStore.cachedResetAt).
        SessionStore.setCachedResetAt(id, resetAt)

        return UsageSnapshot.Window(
            label: label,
            percent: Int(raw.utilization.rounded()),
            resetAt: resetAt,
            resetIsEstimate: false  // the API gives an exact time, not an estimate
        )
    }

    // The server sends time as "2026-07-31T11:10:00.271661+00:00". The
    // fractional seconds are 6 digits; Foundation's built-in ISO8601 parser
    // expects 3 by default and chokes on this. Sub-second precision is
    // unnecessary for us anyway (we show "4h 32m" in the menu), so we strip
    // the fractional part entirely before parsing — the most robust approach.
    static func parseTimestamp(_ text: String) -> Date? {
        var cleaned = text
        if let dot = cleaned.firstIndex(of: "."),
           let end = cleaned[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            cleaned.removeSubrange(dot..<end)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: cleaned)
    }
}
