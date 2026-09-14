/// CodexScanner.swift — filesystem scan of Codex CLI session logs.
///
/// Scans ~/.codex/sessions (and ~/.codex/archived_sessions when present) for
/// .jsonl files modified within the aggregation window — Codex names them
/// rollout-<date>-<uuid>.jsonl today, but the loop takes any .jsonl so a naming
/// change can't silently zero the numbers — extracts `turn_context` (model) and
/// `token_count` (tokens, rate limits) event lines, and hands the pure
/// aggregation to ClusageCore.
///
/// Archiving MOVES files (verified: zero basename overlap between the two roots),
/// so scanning both cannot double-count a session.
///
/// WHY mtime pre-filter: hundreds of historical session files accumulate; only
/// files touched within the last 32 days can contribute to the month windows,
/// so everything older is skipped without being opened. The margin over the
/// 30-day window absorbs timezone/rollover edges.
///
/// WHY the per-file cache: the in-window files total hundreds of MB. Session
/// files are append-only, so a (mtime, size) key is a reliable change signal —
/// after the first full scan, each refresh re-reads only the handful of files
/// that are actively being written to. The cache is persisted to Application
/// Support so app relaunches skip the full re-parse too.

import ClusageCore
import Foundation

enum CodexScanState {
    case ok(CodexSummary, updatedAt: Date)
    /// reasons: "no_sessions_dir"
    case degraded(reason: String, updatedAt: Date)
}

final class CodexScanner: @unchecked Sendable {

    static let shared = CodexScanner()

    /// Days of history the scan covers (30-day window + rollover margin).
    private static let windowDays: Double = 32

    private struct ParsedFile: Codable {
        let turns: [CodexTurn]
        /// Limit flags from the file's newest token_count line, with its timestamp
        /// so the scan can pick the globally newest across files.
        let limitStatus: CodexLimitStatus?
        let limitStatusAt: Date?
    }

    private struct CacheEntry: Codable {
        let mtime: Date
        let size: Int
        let parsed: ParsedFile
    }

    /// Guards `cache`. Scans run one at a time in practice (single refresh timer),
    /// but the lock keeps overlapping manual refreshes safe.
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var cacheLoaded = false
    /// Set when a scan inserts or prunes an entry. In the steady state (every
    /// file a cache hit, nothing aged out) the cache is unchanged, and rewriting
    /// it would mean JSON-encoding and atomically replacing megabytes on every
    /// refresh — as often as once a minute — for no benefit.
    private var cacheDirty = false

    // MARK: - Disk persistence

    /// WHY `creatingDirectory` is opt-in: reads must not create the directory.
    /// Otherwise a Claude-only Mac — which never scans anything — still grows an
    /// Application Support folder the pre-Codex app never touched.
    private static func cacheFileURL(creatingDirectory: Bool = false) -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("Clusage", isDirectory: true)
        if creatingDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("codex-scan-cache-v1.json")
    }

    private func loadCacheIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let url = Self.cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: CacheEntry].self, from: data)
        else { return }
        cache = stored
    }

    private func persistCache() {
        lock.lock()
        let dirty = cacheDirty
        let snapshot = cache
        if dirty { cacheDirty = false }
        lock.unlock()
        guard dirty else { return }
        guard let url = Self.cacheFileURL(creatingDirectory: true),
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Roots

    /// The Codex home directory (~/.codex), overridable via CLUSAGE_CODEX_HOME
    /// so tests and CI can point at a fixture tree.
    static func codexHome() -> URL {
        if let override = ProcessInfo.processInfo.environment["CLUSAGE_CODEX_HOME"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    /// Roots to scan, in order.
    static func sessionRoots() -> [URL] {
        let home = codexHome()
        return [
            home.appendingPathComponent("sessions"),
            home.appendingPathComponent("archived_sessions"),
        ]
    }

    /// True when Codex has ever written a session here — the signal that
    /// decides whether the Codex column is worth showing at all.
    static func isCodexInstalled() -> Bool {
        sessionRoots().contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Scan

    /// Blocking scan — call off the main thread.
    func scan(now: Date = Date()) -> CodexScanState {
        loadCacheIfNeeded()
        let fm = FileManager.default
        let roots = Self.sessionRoots().filter { fm.fileExists(atPath: $0.path) }
        guard !roots.isEmpty else {
            return .degraded(reason: "no_sessions_dir", updatedAt: now)
        }

        let cutoff = now.addingTimeInterval(-Self.windowDays * 24 * 3600)
        var turnsBySession: [String: [CodexTurn]] = [:]
        var newestLimit: (status: CodexLimitStatus, at: Date)?
        var seenPaths = Set<String>()

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                guard let values = try? url.resourceValues(
                        forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let mtime = values.contentModificationDate,
                      mtime >= cutoff
                else { continue }
                let size = values.fileSize ?? 0

                seenPaths.insert(url.path)
                let parsed = cachedParse(for: url, mtime: mtime, size: size)
                if !parsed.turns.isEmpty {
                    turnsBySession[url.path] = parsed.turns
                }
                if let status = parsed.limitStatus, let at = parsed.limitStatusAt {
                    if newestLimit == nil || at > newestLimit!.at {
                        newestLimit = (status, at)
                    }
                }
            }
        }

        // Drop cache entries for files that aged out of the window or were deleted.
        lock.lock()
        let before = cache.count
        cache = cache.filter { seenPaths.contains($0.key) }
        if cache.count != before { cacheDirty = true }
        lock.unlock()
        persistCache()

        let summary = aggregateCodexUsage(
            turnsBySession: turnsBySession,
            limitStatus: newestLimit?.status,
            now: now)
        return .ok(summary, updatedAt: now)
    }

    /// Return cached parse when (mtime, size) match; otherwise parse and cache.
    private func cachedParse(for url: URL, mtime: Date, size: Int) -> ParsedFile {
        lock.lock()
        let hit = cache[url.path]
        lock.unlock()
        if let hit, hit.mtime == mtime, hit.size == size {
            return hit.parsed
        }

        let parsed = Self.parseFile(at: url)
        lock.lock()
        cache[url.path] = CacheEntry(mtime: mtime, size: size, parsed: parsed)
        cacheDirty = true
        lock.unlock()
        return parsed
    }

    // The three line markers, as UTF-8 bytes. See byteSearch below for why.
    private static let turnContextMarker = Array(#""turn_context""#.utf8)
    private static let sessionMetaMarker = Array(#""session_meta""#.utf8)
    private static let tokenCountMarker  = Array(#""token_count""#.utf8)

    /// Extract turns (model-attributed) and the newest limit flags from one session
    /// file.
    ///
    /// WHY bytes rather than String line-by-line: the interesting lines are a
    /// small fraction of a session file, so the pre-filter runs over everything
    /// and dominates the scan. `String.contains` is grapheme-aware (Unicode
    /// canonical equivalence) and was measured at ~9.7 s per pattern over 200k
    /// lines; comparing UTF-8 code units directly does the same job roughly 11x
    /// faster. The markers are ASCII JSON keys, so byte equality is exact.
    ///
    /// Decoding per line also contains damage: a String(contentsOf:) of the whole
    /// file is all-or-nothing, so one invalid byte — including a half-written
    /// multi-byte character at the tail of the file Codex is actively appending
    /// to — discarded every turn in it, and that empty result was then cached
    /// under the current (mtime, size) until the file changed again. Now only the
    /// offending line is skipped, which is what the "partially-written last line
    /// is expected and harmless" promise always meant.
    private static func parseFile(at url: URL) -> ParsedFile {
        // .mappedIfSafe avoids copying hundreds of MB. Safe here because session
        // files are append-only: they grow and are moved, never truncated.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return ParsedFile(turns: [], limitStatus: nil, limitStatusAt: nil)
        }
        var turns: [CodexTurn] = []
        var currentModel: String?
        var limitStatus: CodexLimitStatus?
        var limitStatusAt: Date?

        for lineBytes in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            let isModelLine = byteSearch(lineBytes, turnContextMarker)
                || byteSearch(lineBytes, sessionMetaMarker)
            let isTokenLine = !isModelLine && byteSearch(lineBytes, tokenCountMarker)
            guard isModelLine || isTokenLine else { continue }
            // Only matching lines are turned into Strings; an undecodable one is
            // skipped on its own.
            guard let line = String(data: Data(lineBytes), encoding: .utf8) else { continue }

            if isModelLine {
                // session_meta seeds the model for ambient sessions that never
                // write a turn_context.
                if let model = parseCodexModelLine(line) { currentModel = model }
                continue
            }
            // One JSON decode yields both halves, and the limit status is read
            // even when the line carries no turn (a limits-only token_count event
            // has payload.info null but still reports spend_control_reached).
            guard let parsed = parseCodexLine(line, model: currentModel) else { continue }
            if let turn = parsed.turn { turns.append(turn) }
            if let status = parsed.limitStatus {
                // Lines are chronological, so the last parsed status wins.
                limitStatus = status
                limitStatusAt = parsed.turn?.timestamp ?? limitStatusAt
            }
        }
        return ParsedFile(turns: turns, limitStatus: limitStatus, limitStatusAt: limitStatusAt)
    }

    /// Naive UTF-8 substring search over a Data slice.
    private static func byteSearch(_ haystack: Data, _ needle: [UInt8]) -> Bool {
        let n = needle.count
        guard n > 0, haystack.count >= n else { return false }
        return haystack.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            let first = needle[0]
            var i = 0
            let last = raw.count - n
            while i <= last {
                if base[i] == first {
                    var j = 1
                    while j < n, base[i + j] == needle[j] { j += 1 }
                    if j == n { return true }
                }
                i += 1
            }
            return false
        }
    }
}
