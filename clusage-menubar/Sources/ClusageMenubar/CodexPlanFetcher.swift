/// CodexPlanFetcher.swift — fetches the monthly Codex spend-control state from
/// ChatGPT's internal usage endpoint (see ClusageCore.CodexPlanUsage).
///
/// Auth is zero-setup: the Codex CLI already maintains an OAuth access token in
/// ~/.codex/auth.json (tokens.access_token); we send it as a Bearer token, the
/// same way the CLI talks to this backend. The token is read fresh on every
/// fetch (Codex refreshes it as it runs), kept in memory only, never logged,
/// and never sent anywhere but chatgpt.com. CLUSAGE_CHATGPT_TOKEN overrides
/// for tests.
///
/// WHY no cookie paste here, unlike the Claude side: Codex's own credential is
/// a plain file the CLI keeps fresh, so there is no Keychain ACL problem to
/// route around and nothing for the user to copy.
///
/// Failure vocabulary: no_token / no_spend_control / http_401 / http_5xx /
/// network / bad_shape. A stale token (401) self-heals the next time the user
/// runs Codex.

import ClusageCore
import Foundation

enum CodexPlanState {
    case ok(CodexPlanUsage, updatedAt: Date)
    /// reasons: no_token / no_spend_control / http_401 / network / bad_shape
    case degraded(reason: String, updatedAt: Date)
}

private let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

final class CodexPlanFetcher: @unchecked Sendable {
    private let session: URLSession
    /// Called on the main thread with each new state.
    var onUpdate: ((CodexPlanState) -> Void)?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        // Bearer auth only — never let a Set-Cookie from chatgpt.com ride along.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config)
    }

    /// Fire-and-forget fetch; calls onUpdate on the main actor when done.
    /// Same @MainActor + plain Task rationale as UsageFetcher.fetchNow().
    @MainActor
    func fetchNow() {
        let s = session
        Task {
            let state = await Self.fetch(session: s)
            self.onUpdate?(state)
        }
    }

    /// Codex CLI OAuth access token: env override → ~/.codex/auth.json.
    private static func accessToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["CLUSAGE_CHATGPT_TOKEN"],
           !env.isEmpty {
            return env
        }
        let authURL = CodexScanner.codexHome().appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = doc["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    private static func fetch(session: URLSession) async -> CodexPlanState {
        let now = Date()
        guard let token = accessToken() else {
            return .degraded(reason: "no_token", updatedAt: now)
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
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
            // Matches UsageFetcher's vocabulary, where bad_shape means a decode
            // failure and http_5xx means the server said no.
            return .degraded(reason: "http_5xx", updatedAt: now)
        }

        guard let usage = CodexPlanUsage.parse(data) else {
            // Valid response, but this plan exposes no spend control.
            return .degraded(reason: "no_spend_control", updatedAt: now)
        }
        return .ok(usage, updatedAt: now)
    }
}
