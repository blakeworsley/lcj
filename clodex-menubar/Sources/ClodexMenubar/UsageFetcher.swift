/// UsageFetcher.swift — fetches Claude usage limits, preferring the Claude Code
/// CLI's OAuth token (zero setup) over a pasted claude.ai session cookie.
///
/// Primary: GET api.anthropic.com/api/oauth/usage with the Bearer token from
/// ClaudeCodeAuth — the same endpoint Claude Code's /usage command uses. Its
/// response carries the identical limits[] shape as the claude.ai endpoint, so
/// UsageSnapshot.parse handles both.
///
/// Fallback: the clusage-style cookie path against claude.ai (ported from
/// mlg87/lcj, itself ported from Artzainnn/ClaudeUsageBar). Headers copied
/// verbatim — claude.ai fronts with bot protection; a browser UA + Origin/Referer
/// passes it.
///
/// Failure vocabulary: no_auth / oauth_http_401 / oauth_bad_shape /
/// no_org_id / network / http_401 / http_5xx / bad_shape

import ClodexCore
import Foundation

// MARK: - State machine

/// Which credential produced a successful fetch.
enum ClaudeAuthSource {
    case claudeCode   // Claude Code CLI OAuth token (Keychain / credentials file)
    case cookie       // pasted claude.ai session cookie
}

/// The outcome of a Claude fetch cycle.
enum FetchState {
    case ok(UsageSnapshot, updatedAt: Date, via: ClaudeAuthSource)
    case degraded(reason: String, updatedAt: Date)
}

// MARK: - Fetcher

private let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

final class UsageFetcher: @unchecked Sendable {
    private let session: URLSession
    /// Called on the main thread with each new FetchState.
    var onUpdate: ((FetchState) -> Void)?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        // WHY disable cookie storage: we send the pasted Cookie header verbatim.
        // Default URLSession cookie storage would capture Set-Cookie responses and
        // merge/override our header on later requests, making behavior drift from
        // the pasted value. Disable both directions.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config)
    }

    /// Fire-and-forget fetch; calls onUpdate on the main actor when done.
    ///
    /// WHY @MainActor + plain Task (not Task.detached): Swift 6 strict concurrency forbids
    /// sending a non-Sendable closure (onUpdate) across task boundaries. A Task created from
    /// a @MainActor context inherits that context; after the awaited nonisolated fetch returns,
    /// control resumes on the main actor so onUpdate is safe to invoke directly.
    @MainActor
    func fetchNow() {
        let s = session
        Task {
            let state = await Self.fetch(session: s)
            // Back on the main actor after await — onUpdate access is safe.
            self.onUpdate?(state)
        }
    }

    /// Build a request with the browser headers claude.ai requires.
    private static func claudeRequest(url: URL, cookie: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        r.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        r.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("claude.ai", forHTTPHeaderField: "authority")
        return r
    }

    private static func fetch(session: URLSession) async -> FetchState {
        let now = Date()

        // -- Primary: Claude Code OAuth token --
        let oauthFailure = await oauthFetch(session: session, now: now)
        switch oauthFailure {
        case .success(let state):
            return state
        case .failure(let miss):
            // Fall through to the cookie path; if that also can't run, surface
            // the more actionable of the two reasons below.
            guard let cookie = CookieStore.load() else {
                return .degraded(reason: miss.reason ?? "no_auth", updatedAt: now)
            }
            return await cookieFetch(session: session, cookie: cookie, now: now)
        }
    }

    /// Try api.anthropic.com/api/oauth/usage with the Claude Code token.
    /// Returns .success(FetchState.ok) on a good fetch, otherwise .failure with
    /// an oauth_* reason (nil when there was simply no token to try).
    private static func oauthFetch(
        session: URLSession, now: Date
    ) async -> Result<FetchState, OAuthMiss> {
        guard let token = ClaudeCodeAuth.accessToken() else {
            return .failure(OAuthMiss(reason: nil))
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failure(OAuthMiss(reason: "network"))
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            return .failure(OAuthMiss(reason: "oauth_http_401"))
        default:
            return .failure(OAuthMiss(reason: "oauth_bad_shape"))
        }
        guard let snapshot = UsageSnapshot.parse(data) else {
            return .failure(OAuthMiss(reason: "oauth_bad_shape"))
        }
        return .success(.ok(snapshot, updatedAt: now, via: .claudeCode))
    }

    /// Why the OAuth path didn't produce a snapshot. reason == nil means no
    /// token was found (not an error — the user may be cookie-only).
    private struct OAuthMiss: Error {
        let reason: String?
    }

    private static func cookieFetch(
        session: URLSession, cookie: String, now: Date
    ) async -> FetchState {

        // Try to extract orgId from the cookie (free operation for devtools copies that
        // include lastActiveOrg=). Fall back to /api/bootstrap for cookies that omit it.
        var org = orgId(fromCookie: cookie)
        if org == nil {
            org = await Self.bootstrapOrgId(session: session, cookie: cookie)
        }
        guard let orgId = org else {
            return .degraded(reason: "no_org_id", updatedAt: now)
        }

        let usageURL = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage")!
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: claudeRequest(url: usageURL, cookie: cookie))
        } catch {
            return .degraded(reason: "network", updatedAt: now)
        }

        guard let http = response as? HTTPURLResponse else {
            return .degraded(reason: "network", updatedAt: now)
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            return .degraded(reason: "http_401", updatedAt: now)
        default:
            return .degraded(reason: "http_5xx", updatedAt: now)
        }

        guard let snapshot = UsageSnapshot.parse(data) else {
            return .degraded(reason: "bad_shape", updatedAt: now)
        }

        return .ok(snapshot, updatedAt: now, via: .cookie)
    }

    /// GET /api/bootstrap → account.lastActiveOrgId. Returns nil on any failure.
    private static func bootstrapOrgId(session: URLSession, cookie: String) async -> String? {
        let url = URL(string: "https://claude.ai/api/bootstrap")!
        guard let (data, resp) = try? await session.data(for: claudeRequest(url: url, cookie: cookie)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["account"] as? [String: Any],
              let id = account["lastActiveOrgId"] as? String, !id.isEmpty
        else { return nil }
        return id
    }
}
