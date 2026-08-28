/// CookieAuth.swift — pure helpers for cookie-based claude.ai session authentication.
/// Ported from mlg87/lcj clusage-menubar.
///
/// WHY cookie-paste instead of Keychain / credentials file:
///   Keychain ACL binds to the app's ad-hoc code signature. Every rebuild issues a new
///   signature, which invalidates the ACL → "Always Allow" prompt re-appears on every
///   build. The user pastes the full Cookie request-header value from the "usage"
///   request on claude.ai/settings/usage; we send it verbatim to claude.ai's own usage
///   endpoint. Result: zero Keychain interaction, zero prompts, ever.

import Foundation

/// Normalize a pasted cookie string: trim whitespace/newlines and strip a leading
/// "Cookie:" label (users sometimes copy the header name along with the value).
public func sanitizeCookie(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.lowercased().hasPrefix("cookie:") {
        s = String(s.dropFirst("cookie:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return s
}

/// Extract the org UUID from the `lastActiveOrg=` part of a full cookie string.
/// Returns nil when the key is absent — caller falls back to the /api/bootstrap lookup.
public func orgId(fromCookie cookie: String) -> String? {
    for part in cookie.components(separatedBy: ";") {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("lastActiveOrg=") {
            let value = String(trimmed.dropFirst("lastActiveOrg=".count))
            return value.isEmpty ? nil : value
        }
    }
    return nil
}
