/// ClaudeCodeAuth.swift — zero-setup Claude auth via the Claude Code CLI's own
/// OAuth token, mirroring how CodexPlanFetcher reuses the Codex CLI's auth.json.
///
/// Claude Code stores its OAuth credentials in the login Keychain (item
/// "Claude Code-credentials", secret = JSON with claudeAiOauth.accessToken) on
/// current versions, or in ~/.claude/.credentials.json on older ones. Claude
/// Code refreshes the token itself as it runs, so reading it fresh per fetch
/// means it never goes stale the way a pasted claude.ai cookie does.
///
/// The Keychain read shells out to /usr/bin/security because that is the tool
/// Claude Code used to create the item — it is already on the item's access
/// list, so the read is silent (no permission prompt), unlike a direct
/// SecItemCopyMatching from this ad-hoc-signed binary.
///
/// The token is kept in memory only, never logged, and sent only to
/// api.anthropic.com. CLODEX_CLAUDE_TOKEN overrides for tests.

import Foundation

enum ClaudeCodeAuth {
    /// Resolution order: env override → Keychain → ~/.claude/.credentials.json.
    static func accessToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["CLODEX_CLAUDE_TOKEN"],
           !env.isEmpty {
            return env
        }
        if let token = keychainToken() { return token }
        return credentialsFileToken()
    }

    static func hasToken() -> Bool { accessToken() != nil }

    /// Extract claudeAiOauth.accessToken from the credentials JSON blob.
    private static func parseToken(_ data: Data) -> String? {
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = doc["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    private static func keychainToken() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return parseToken(data)
    }

    private static func credentialsFileToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseToken(data)
    }
}
