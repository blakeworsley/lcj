/// CookieStore.swift — UserDefaults-backed persistence for the pasted session cookie.
///
/// WHY UserDefaults (not Keychain): Keychain ACL binds to the ad-hoc code signature,
/// so every rebuild re-prompts "Always Allow". UserDefaults (the app's own preferences
/// domain) survives rebuilds and reinstalls because the domain is per-user, not
/// per-signature. The value is stored unencrypted in the app's preferences plist —
/// same trust level as the browser profile it was copied from; it is never logged
/// and never sent anywhere but claude.ai.
///
/// Zero-setup migration: when this app has no cookie of its own, it falls back to
/// the one clusage-menubar (com.mlg87.clusage-menubar) already stores, so existing
/// clusage users see Claude gauges immediately without re-pasting.

import ClodexCore
import Foundation

/// Pasted-cookie persistence via UserDefaults.
enum CookieStore {
    static let defaultsKey = "session_cookie"
    /// clusage-menubar's preferences domain, read-only fallback.
    static let clusageDomain = "com.mlg87.clusage-menubar"

    /// Resolution order: CLODEX_COOKIE env var → own UserDefaults → clusage's
    /// UserDefaults domain. Returns nil when no source yields a non-empty
    /// sanitized string. Re-called on every fetch so updates take effect live.
    static func load() -> String? {
        if let env = ProcessInfo.processInfo.environment["CLODEX_COOKIE"] {
            let s = sanitizeCookie(env)
            if !s.isEmpty { return s }
        }
        if let stored = UserDefaults.standard.string(forKey: defaultsKey) {
            let s = sanitizeCookie(stored)
            if !s.isEmpty { return s }
        }
        if let clusage = UserDefaults(suiteName: clusageDomain)?.string(forKey: defaultsKey) {
            let s = sanitizeCookie(clusage)
            if !s.isEmpty { return s }
        }
        return nil
    }

    /// True when the active cookie is borrowed from clusage's domain rather than
    /// stored here — surfaced in the dropdown so the fallback isn't invisible.
    static func isUsingClusageFallback() -> Bool {
        if ProcessInfo.processInfo.environment["CLODEX_COOKIE"] != nil { return false }
        if let own = UserDefaults.standard.string(forKey: defaultsKey),
           !sanitizeCookie(own).isEmpty { return false }
        if let clusage = UserDefaults(suiteName: clusageDomain)?.string(forKey: defaultsKey),
           !sanitizeCookie(clusage).isEmpty { return true }
        return false
    }

    /// Sanitizes `raw` before storing — never persists the "Cookie:" label if the
    /// user copies the full header line instead of just the value.
    static func save(_ raw: String) {
        UserDefaults.standard.set(sanitizeCookie(raw), forKey: defaultsKey)
    }
}
