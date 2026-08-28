/// ClaudeScanner.swift — filesystem scan of Claude Code local session logs.
///
/// Claude Code writes one JSONL file per session under ~/.claude/projects/<dir>/.
/// Assistant-message lines carry `message.usage` (input, cache write/read, output)
/// plus model and timestamp — enough to build the same cost history the Codex
/// scanner produces, so the trend styles can chart both tools together.
///
/// This is the app's third data lane: independent of the claude.ai limit gauges
/// (cookie-based) — those show percent-of-plan *now*; this shows local dollar
/// history. Same mtime-window + persisted (mtime,size) cache design as
/// CodexScanner; here the cache stores per-file day/hour cost buckets rather
/// than raw turns, which keeps it tiny.
///
/// Dedup within a file by (message.id, requestId) — streaming retries repeat
/// messages. Matches tools/ai_usage_snapshot.py, so app and ledger agree.

import ClodexCore
import Foundation

enum ClaudeLocalState {
    case ok(CostHistory, updatedAt: Date)
    /// reasons: "no_projects_dir"
    case degraded(reason: String, updatedAt: Date)
}

final class ClaudeScanner: @unchecked Sendable {

    static let shared = ClaudeScanner()

    /// Days of history the scan covers (30-day window + rollover margin).
    private static let windowDays: Double = 32

    private struct CacheEntry: Codable {
        let mtime: Date
        let size: Int
        let history: CostHistory
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var cacheLoaded = false

    static func projectsRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["CLODEX_CLAUDE_HOME"] {
            return URL(fileURLWithPath: override).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").appendingPathComponent("projects")
    }

    // MARK: - Disk persistence (same location as the Codex cache)

    private static func cacheFileURL() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("Clodex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("claude-scan-cache-v1.json")
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

    // MARK: - Scan

    /// Blocking scan — call off the main thread.
    func scan(now: Date = Date()) -> ClaudeLocalState {
        loadCacheIfNeeded()
        let fm = FileManager.default
        let root = Self.projectsRoot()
        guard fm.fileExists(atPath: root.path) else {
            return .degraded(reason: "no_projects_dir", updatedAt: now)
        }

        let cutoff = now.addingTimeInterval(-Self.windowDays * 24 * 3600)
        var merged = CostHistory.empty
        var seenPaths = Set<String>()

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .degraded(reason: "no_projects_dir", updatedAt: now)
        }

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
            merged.merge(cachedHistory(for: url, mtime: mtime, size: size))
        }

        lock.lock()
        cache = cache.filter { seenPaths.contains($0.key) }
        lock.unlock()
        persistCache()

        return .ok(merged, updatedAt: now)
    }

    private func cachedHistory(for url: URL, mtime: Date, size: Int) -> CostHistory {
        lock.lock()
        let hit = cache[url.path]
        lock.unlock()
        if let hit, hit.mtime == mtime, hit.size == size {
            return hit.history
        }

        let history = Self.parseFile(at: url)
        lock.lock()
        cache[url.path] = CacheEntry(mtime: mtime, size: size, history: history)
        lock.unlock()
        return history
    }

    /// Reduce one session file to day/hour cost buckets.
    private static func parseFile(at url: URL) -> CostHistory {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .empty
        }
        var history = CostHistory.empty
        var seen = Set<String>()
        content.enumerateLines { line, _ in
            guard line.contains("\"usage\"") else { return }
            guard let data = line.data(using: .utf8),
                  let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  doc["type"] as? String == "assistant",
                  let msg = doc["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let ts = parseCodexTimestamp(doc["timestamp"] as? String)
            else { return }

            // Streaming retries repeat messages; count each (id, requestId) once.
            if let msgId = msg["id"] as? String {
                let key = msgId + "|" + ((doc["requestId"] as? String) ?? "")
                if seen.contains(key) { return }
                seen.insert(key)
            }

            func num(_ key: String) -> Int {
                (usage[key] as? NSNumber)?.intValue ?? 0
            }
            let cacheWriteTotal = num("cache_creation_input_tokens")
            var write1h = 0
            var write5m = cacheWriteTotal
            if let cc = usage["cache_creation"] as? [String: Any] {
                write1h = (cc["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
                write5m = (cc["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue
                    ?? max(0, cacheWriteTotal - write1h)
            }

            let cost = costOfClaudeMessage(
                model: msg["model"] as? String,
                input: num("input_tokens"),
                cacheWrite5m: write5m,
                cacheWrite1h: write1h,
                cacheRead: num("cache_read_input_tokens"),
                output: num("output_tokens"))
            guard cost > 0 else { return }

            history.dailyCost[costHistoryDayKey(ts), default: 0] += cost
            history.hourlyCost[costHistoryHourKey(ts), default: 0] += cost
        }
        return history
    }
}
