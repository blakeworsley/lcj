/// CodexScanner.swift — filesystem scan of Codex CLI session logs.
///
/// Scans ~/.codex/sessions (and ~/.codex/archived_sessions when present) for
/// rollout-*.jsonl files modified within the aggregation window, extracts
/// `turn_context` (model) and `token_count` (tokens, rate limits) event lines,
/// and hands the pure aggregation to ClodexCore.
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

import ClodexCore
import Foundation

enum CodexScanState {
    case ok(CodexSummary, CostHistory, updatedAt: Date)
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

    // MARK: - Disk persistence

    private static func cacheFileURL() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("Clodex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        let snapshot = cache
        lock.unlock()
        guard let url = Self.cacheFileURL(),
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Roots to scan, in order. Overridable for tests via CLODEX_CODEX_HOME.
    static func sessionRoots() -> [URL] {
        let home: URL
        if let override = ProcessInfo.processInfo.environment["CLODEX_CODEX_HOME"] {
            home = URL(fileURLWithPath: override)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
        }
        return [
            home.appendingPathComponent("sessions"),
            home.appendingPathComponent("archived_sessions"),
        ]
    }

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
        cache = cache.filter { seenPaths.contains($0.key) }
        lock.unlock()
        persistCache()

        let summary = aggregateCodexUsage(
            turnsBySession: turnsBySession,
            limitStatus: newestLimit?.status,
            now: now)

        // Reduce turns to the day/hour cost buckets the trend styles chart.
        var history = CostHistory.empty
        for turns in turnsBySession.values {
            for t in turns where t.timestamp <= now {
                let cost = costOfTurn(t)
                history.dailyCost[costHistoryDayKey(t.timestamp), default: 0] += cost
                history.hourlyCost[costHistoryHourKey(t.timestamp), default: 0] += cost
            }
        }
        return .ok(summary, history, updatedAt: now)
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
        lock.unlock()
        return parsed
    }

    /// Extract turns (model-attributed) and the newest limit flags from one session
    /// file. Unreadable files contribute nothing — a live session's partially-written
    /// last line is expected and harmless.
    private static func parseFile(at url: URL) -> ParsedFile {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ParsedFile(turns: [], limitStatus: nil, limitStatusAt: nil)
        }
        var turns: [CodexTurn] = []
        var currentModel: String?
        var limitStatus: CodexLimitStatus?
        var limitStatusAt: Date?
        content.enumerateLines { line, _ in
            // Cheap substring pre-filters before JSON parsing; the interesting
            // lines are a small fraction of a session file. session_meta seeds
            // the model for ambient sessions that never write a turn_context.
            if line.contains("\"turn_context\"") || line.contains("\"session_meta\"") {
                if let model = parseCodexModelLine(line) {
                    currentModel = model
                }
                return
            }
            guard line.contains("\"token_count\"") else { return }
            if let turn = parseCodexTokenCountLine(line, model: currentModel) {
                turns.append(turn)
                // Lines are chronological, so the last parsed status wins.
                if let status = parseCodexLimitStatus(line) {
                    limitStatus = status
                    limitStatusAt = turn.timestamp
                }
            }
        }
        return ParsedFile(turns: turns, limitStatus: limitStatus, limitStatusAt: limitStatusAt)
    }
}
