import Foundation
import Security

// sessionKey is a real credential that grants full access to the Claude
// account — writing it to a plain file (like .env) would mean anyone with
// access to the machine could take over the account. The macOS Keychain is
// the OS's encrypted vault: it keeps data encrypted on disk and only hands
// it back to the app that's allowed to read it. That's why we store the key there.
//
// This enum has no cases, only static functions — that's deliberate, so it
// can't accidentally be instantiated (`SessionStore()` isn't valid). It's
// just a namespace grouping related functions together.
enum SessionStore {
    // Keychain entries are addressed by a "service + account" pair; these
    // labels distinguish our entry from everyone else's.
    private static let service = "ClaudeLimitBar"
    private static let account = "sessionKey"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static var sessionKey: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true      // return the value, not just whether it exists
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func save(sessionKey: String) {
        // The Keychain requires a separate call to "update" an existing
        // entry; deleting then adding is shorter and less error-prone.
        SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = Data(sessionKey.utf8)
        // kSecAttrAccessibleWhenUnlocked = the key can only be read while
        // the user's device is unlocked. Written explicitly instead of
        // relying on the default, so the intent is visible in the code.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        // Synchronizable = false: this key must NOT sync to other devices
        // via iCloud Keychain. It belongs to a single machine and is
        // short-lived; copying it elsewhere would be an unnecessary risk.
        query[kSecAttrSynchronizable as String] = false
        SecItemAdd(query as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    // The organization id isn't sensitive (just a UUID), so it doesn't need
    // the Keychain. UserDefaults is macOS's simple settings store — think
    // of it as the equivalent of a browser's localStorage. We cache this so
    // we don't have to re-fetch the organization list on every usage query.
    static var orgId: String? {
        get { UserDefaults.standard.string(forKey: "orgId") }
        set { UserDefaults.standard.set(newValue, forKey: "orgId") }
    }

    // The organization the user EXPLICITLY picked from the menu.
    //
    // Kept separate from orgId because orgId can get cleared automatically
    // during error recovery (on the assumption it might be stale). The
    // user's choice, on the other hand, is a preference — it shouldn't
    // silently disappear because of a transient server error. If access is
    // genuinely lost, it simply won't be found in the list and the
    // automatic pick takes over.
    static var preferredOrgId: String? {
        get { UserDefaults.standard.string(forKey: "preferredOrgId") }
        set { UserDefaults.standard.set(newValue, forKey: "preferredOrgId") }
    }

    // Our own day-by-day record of weekly-quota usage (see UsageLedger).
    //
    // It has to outlive the process — its whole purpose is to remember days
    // this app watched but the desktop app's history file never saw. Stored
    // as JSON rather than as loose keys because it's a growing structure, not
    // a fixed handful of values. Nothing in it is sensitive: dates and
    // percentages, no account identifiers.
    static var ledger: UsageLedger {
        get {
            guard let data = UserDefaults.standard.data(forKey: "usageLedger"),
                let decoded = try? JSONDecoder().decode(UsageLedger.self, from: data)
            else { return UsageLedger() }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: "usageLedger")
        }
    }

    // Caches the EXACT reset times we learned from the API.
    //
    // Why: a reset time is an absolute moment ("July 31, 7:10 PM"). Once
    // learned, it doesn't change even if the internet drops or the session
    // expires — it stays correct until it passes. Without caching it, the
    // moment we couldn't reach the API we'd throw away this exact
    // information and fall back to estimating from the local file; that's
    // exactly why the app used to show a number that didn't match reality.
    static func cachedResetAt(_ id: String) -> Date? {
        let seconds = UserDefaults.standard.double(forKey: "resetAt.\(id)")
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // Called when the viewed account or organization changes. Everything
    // cached here describes the PREVIOUS organization: keeping the reset
    // times would let us present another organization's figure as "exact"
    // while the API is unreachable, and keeping the ledger would blend two
    // different accounts' usage into the same days.
    static func clearAccountCaches() {
        for id in ["fiveHour", "sevenDay"] { setCachedResetAt(id, nil) }
        UserDefaults.standard.removeObject(forKey: "usageLedger")
    }

    static func setCachedResetAt(_ id: String, _ date: Date?) {
        let key = "resetAt.\(id)"
        if let date {
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
