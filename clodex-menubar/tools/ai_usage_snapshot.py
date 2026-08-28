#!/usr/bin/env python3
"""ai_usage_snapshot.py — daily personal AI usage ledger.

Scans local logs from both AI coding tools:
  - Claude Code:  ~/.claude/projects/**/*.jsonl  (assistant messages carry usage)
  - Codex:        ~/.codex/sessions/**/*.jsonl + archived_sessions
                  (token_count events carry per-turn deltas)

and maintains, in the output directory (default ~/.clodex/ai-usage, override
with --out-dir or the AI_USAGE_DIR env var):
  - ledger.csv    one row per calendar day (upserted)
  - summary.md    regenerated dashboard view
  - .cache.json   per-file (mtime,size)-keyed aggregates, so only
                  actively-written files are re-parsed on each run

Costs are API-equivalent estimates at standard list prices — on
subscription/credit plans these represent the value extracted, not a bill.
Pricing checked 2026-08-26:
  Claude: platform.claude.com/docs/en/about-claude/pricing
  OpenAI: developers.openai.com/api/docs/pricing

Companion to the Clodex menu bar app, which shows the live view; this script
is the durable historical record. See tools/com.clodex.ai-usage.example.plist
for a launchd agent that keeps it current.

Usage:
  python3 ai_usage_snapshot.py                     # scan, upsert, summarize
  python3 ai_usage_snapshot.py --quiet             # one status line (launchd)
  python3 ai_usage_snapshot.py --out-dir ~/notes   # custom ledger location

No third-party dependencies; stdlib only.
"""

import argparse
import csv
import datetime as dt
import glob
import json
import os
import sys

HOME = os.path.expanduser("~")
CLAUDE_ROOT = os.environ.get(
    "AI_USAGE_CLAUDE_ROOT", os.path.join(HOME, ".claude", "projects"))
CODEX_HOME = os.environ.get("AI_USAGE_CODEX_HOME", os.path.join(HOME, ".codex"))
CODEX_ROOTS = [
    os.path.join(CODEX_HOME, "sessions"),
    os.path.join(CODEX_HOME, "archived_sessions"),
]
DEFAULT_OUT_DIR = os.environ.get(
    "AI_USAGE_DIR", os.path.join(HOME, ".clodex", "ai-usage"))

# Substrings that must never be scanned; extend for any private areas.
EXCLUDE_SUBSTRINGS = ["human-private"]

# --- Pricing: $ per 1M tokens ------------------------------------------------

# Claude: (input, cache_write_5m, cache_write_1h, cache_read, output)
CLAUDE_PRICES = {
    "claude-fable-5":  (10.0, 12.50, 20.0, 1.00, 50.0),
    "claude-mythos-5": (10.0, 12.50, 20.0, 1.00, 50.0),
    "claude-opus-5":   (5.0, 6.25, 10.0, 0.50, 25.0),
    "claude-opus-4":   (5.0, 6.25, 10.0, 0.50, 25.0),   # prefix: 4-8/4-7/4-6/4-5
    "claude-sonnet-5": (2.0, 2.50, 4.0, 0.20, 10.0),
    "claude-sonnet-4": (3.0, 3.75, 6.0, 0.30, 15.0),
    "claude-haiku-4":  (1.0, 1.25, 2.0, 0.10, 5.0),
}
CLAUDE_FALLBACK = CLAUDE_PRICES["claude-opus-5"]

# Codex: (input, cached_input, output) — keep in sync with
# Sources/ClodexCore/CodexPricing.swift
CODEX_PRICES = {
    "gpt-5.6-sol":   (4.00, 0.40, 20.00),
    "gpt-5.6-terra": (2.00, 0.20, 12.00),
    "gpt-5.6-luna":  (0.20, 0.02, 1.20),
    "gpt-5.4-mini":  (0.75, 0.075, 4.50),   # before gpt-5.4 for prefix matching
    "gpt-5.4":       (2.50, 0.25, 15.00),
    "gpt-5.3-codex": (1.75, 0.175, 14.00),
}
CODEX_FALLBACK = CODEX_PRICES["gpt-5.6-terra"]


def price_for(table, fallback, model):
    if not model:
        return fallback
    if model in table:
        return table[model]
    for name, p in table.items():
        if model.startswith(name):
            return p
    return fallback


# --- Per-file parsing (cached) -----------------------------------------------
# The cache maps file path -> {"mtime": float, "size": int, "days": {date: aggregate}}.
# Aggregates are plain dicts of numeric fields plus a per-model cost/token map,
# so cached files never need re-reading.


def load_cache():
    try:
        with open(CACHE) as f:
            data = json.load(f)
            if data.get("version") == 2:
                return data
    except (OSError, ValueError):
        pass
    return {"version": 2, "claude": {}, "codex": {}}


def local_date(iso_ts):
    """ISO timestamp (usually ...Z) -> local calendar date string, or None."""
    try:
        d = dt.datetime.fromisoformat(iso_ts.replace("Z", "+00:00"))
        return d.astimezone().date().isoformat()
    except (ValueError, AttributeError):
        return None


def parse_claude_file(path):
    """Per-day aggregates for one Claude Code session file.

    Dedup: streaming retries can repeat an assistant message; key on
    (message.id, requestId) when present, matching ccusage's approach.
    """
    days = {}
    seen = set()
    try:
        fh = open(path, errors="ignore")
    except OSError:
        return days
    with fh:
        for line in fh:
            if '"usage"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("type") != "assistant":
                continue
            msg = d.get("message") or {}
            usage = msg.get("usage")
            if not isinstance(usage, dict):
                continue
            key = (msg.get("id"), d.get("requestId"))
            if key[0] and key in seen:
                continue
            seen.add(key)
            date = local_date(d.get("timestamp", ""))
            if not date:
                continue

            model = msg.get("model") or "unknown"
            inp = usage.get("input_tokens", 0) or 0
            cw = usage.get("cache_creation_input_tokens", 0) or 0
            cr = usage.get("cache_read_input_tokens", 0) or 0
            out = usage.get("output_tokens", 0) or 0
            # 5m vs 1h cache-write split when the API reports it.
            cc = usage.get("cache_creation") or {}
            cw_1h = cc.get("ephemeral_1h_input_tokens", 0) or 0
            cw_5m = cc.get("ephemeral_5m_input_tokens", cw - cw_1h) or 0

            p_in, p_w5, p_w1, p_rd, p_out = price_for(
                CLAUDE_PRICES, CLAUDE_FALLBACK, model)
            cost = (inp * p_in + cw_5m * p_w5 + cw_1h * p_w1
                    + cr * p_rd + out * p_out) / 1e6

            day = days.setdefault(date, {
                "input": 0, "cache_write": 0, "cache_read": 0,
                "output": 0, "cost": 0.0, "models": {}})
            day["input"] += inp
            day["cache_write"] += cw
            day["cache_read"] += cr
            day["output"] += out
            day["cost"] += cost
            m = day["models"].setdefault(model, {"tokens": 0, "cost": 0.0})
            m["tokens"] += inp + cw + cr + out
            m["cost"] += cost
    return days


def parse_codex_file(path):
    """Per-day aggregates for one Codex session file (mirrors ClodexCore)."""
    days = {}
    model = None
    try:
        fh = open(path, errors="ignore")
    except OSError:
        return days
    with fh:
        for line in fh:
            if '"turn_context"' in line or '"session_meta"' in line:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                t, p = d.get("type"), d.get("payload") or {}
                if t == "turn_context" and p.get("model"):
                    model = p["model"]
                elif t == "session_meta":
                    m = p.get("model") or ((p.get("base_instructions") or {})
                                           .get("provenance") or {}).get("model")
                    if m:
                        model = m
                continue
            if '"token_count"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            p = d.get("payload") or {}
            if p.get("type") != "token_count" or not p.get("info"):
                continue
            last = p["info"].get("last_token_usage") or {}
            date = local_date(d.get("timestamp", ""))
            if not date:
                continue

            inp = last.get("input_tokens", 0) or 0
            cch = last.get("cached_input_tokens", 0) or 0
            out = last.get("output_tokens", 0) or 0
            tot = last.get("total_tokens", 0) or 0
            p_in, p_cch, p_out = price_for(CODEX_PRICES, CODEX_FALLBACK, model)
            if inp == 0 and out == 0 and tot > 0:
                # Ambient component-less line: price total at the input rate.
                cost = tot * p_in / 1e6
            else:
                cost = (max(0, inp - cch) * p_in + cch * p_cch + out * p_out) / 1e6

            day = days.setdefault(date, {
                "tokens": 0, "output": 0, "cost": 0.0, "models": {}})
            day["tokens"] += tot
            day["output"] += out
            day["cost"] += cost
            mk = model or "unknown"
            m = day["models"].setdefault(mk, {"tokens": 0, "cost": 0.0})
            m["tokens"] += tot
            m["cost"] += cost
    return days


def scan_source(cache_section, files, parser):
    """Return (per_day_totals, per_day_sessions, per_day_models), using and
    refreshing the per-file cache."""
    parsed = reused = 0
    live = set()
    for path in files:
        if any(x in path for x in EXCLUDE_SUBSTRINGS):
            continue
        try:
            st = os.stat(path)
        except OSError:
            continue
        live.add(path)
        entry = cache_section.get(path)
        if entry and entry["mtime"] == st.st_mtime and entry["size"] == st.st_size:
            reused += 1
            continue
        cache_section[path] = {
            "mtime": st.st_mtime, "size": st.st_size, "days": parser(path)}
        parsed += 1
    # Drop deleted files.
    for path in list(cache_section):
        if path not in live:
            del cache_section[path]

    totals, sessions, models = {}, {}, {}
    for path, entry in cache_section.items():
        for date, day in entry["days"].items():
            t = totals.setdefault(date, {})
            for k, v in day.items():
                if k == "models":
                    continue
                t[k] = t.get(k, 0) + v
            sessions[date] = sessions.get(date, 0) + 1
            dm = models.setdefault(date, {})
            for mk, mv in day["models"].items():
                agg = dm.setdefault(mk, {"tokens": 0, "cost": 0.0})
                agg["tokens"] += mv["tokens"]
                agg["cost"] += mv["cost"]
    return totals, sessions, models, parsed, reused


# --- Ledger + summary ---------------------------------------------------------

FIELDS = ["date",
          "claude_sessions", "claude_input", "claude_cache_write",
          "claude_cache_read", "claude_output", "claude_cost",
          "codex_sessions", "codex_tokens", "codex_output", "codex_cost"]


def write_ledger(claude, claude_sessions, codex, codex_sessions):
    dates = sorted(set(claude) | set(codex))
    rows = []
    for date in dates:
        c = claude.get(date, {})
        x = codex.get(date, {})
        rows.append({
            "date": date,
            "claude_sessions": claude_sessions.get(date, 0),
            "claude_input": c.get("input", 0),
            "claude_cache_write": c.get("cache_write", 0),
            "claude_cache_read": c.get("cache_read", 0),
            "claude_output": c.get("output", 0),
            "claude_cost": round(c.get("cost", 0.0), 2),
            "codex_sessions": codex_sessions.get(date, 0),
            "codex_tokens": x.get("tokens", 0),
            "codex_output": x.get("output", 0),
            "codex_cost": round(x.get("cost", 0.0), 2),
        })
    with open(LEDGER, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)
    return rows


def fmt_tok(n):
    if n >= 1e9:
        return f"{n / 1e9:.1f}B"
    if n >= 1e6:
        return f"{n / 1e6:.1f}M"
    if n >= 1e3:
        return f"{n / 1e3:.1f}K"
    return str(n)


def write_summary(rows, claude_models, codex_models, now):
    today = now.date().isoformat()
    week_dates = {(now.date() - dt.timedelta(days=i)).isoformat() for i in range(7)}
    month_dates = {(now.date() - dt.timedelta(days=i)).isoformat() for i in range(30)}

    def window(dates):
        sel = [r for r in rows if r["date"] in dates]
        return {
            "claude_cost": sum(r["claude_cost"] for r in sel),
            "codex_cost": sum(r["codex_cost"] for r in sel),
            "claude_tok": sum(r["claude_input"] + r["claude_cache_write"]
                              + r["claude_cache_read"] + r["claude_output"] for r in sel),
            "codex_tok": sum(r["codex_tokens"] for r in sel),
            "days_active": sum(1 for r in sel
                               if r["claude_sessions"] or r["codex_sessions"]),
        }

    w7, w30 = window(week_dates), window(month_dates)

    def model_rollup(models_by_date, dates):
        agg = {}
        for date in dates:
            for mk, mv in models_by_date.get(date, {}).items():
                a = agg.setdefault(mk, {"tokens": 0, "cost": 0.0})
                a["tokens"] += mv["tokens"]
                a["cost"] += mv["cost"]
        return sorted(agg.items(), key=lambda kv: -kv[1]["cost"])

    lines = [
        "# AI Usage — personal ledger",
        "",
        f"Updated {now.strftime('%Y-%m-%d %H:%M')} by "
        "`clodex-menubar/tools/ai_usage_snapshot.py`. "
        "Costs are API-equivalent estimates at standard list prices — on "
        "subscription/credit plans, read these as value extracted, not "
        "a bill. Data: local session logs only.",
        "",
        "## Windows",
        "",
        "| Window | Claude est. | Codex est. | Total | Tokens (C / X) | Active days |",
        "| --- | --- | --- | --- | --- | --- |",
        f"| Last 7 days | ${w7['claude_cost']:.2f} | ${w7['codex_cost']:.2f} "
        f"| **${w7['claude_cost'] + w7['codex_cost']:.2f}** "
        f"| {fmt_tok(w7['claude_tok'])} / {fmt_tok(w7['codex_tok'])} | {w7['days_active']} |",
        f"| Last 30 days | ${w30['claude_cost']:.2f} | ${w30['codex_cost']:.2f} "
        f"| **${w30['claude_cost'] + w30['codex_cost']:.2f}** "
        f"| {fmt_tok(w30['claude_tok'])} / {fmt_tok(w30['codex_tok'])} | {w30['days_active']} |",
        "",
        "## Last 14 days",
        "",
        "| Date | Claude est. | Codex est. | Total | Sessions (C / X) |",
        "| --- | --- | --- | --- | --- |",
    ]
    for r in rows[-14:][::-1]:
        marker = " ← today" if r["date"] == today else ""
        lines.append(
            f"| {r['date']}{marker} | ${r['claude_cost']:.2f} | ${r['codex_cost']:.2f} "
            f"| ${r['claude_cost'] + r['codex_cost']:.2f} "
            f"| {r['claude_sessions']} / {r['codex_sessions']} |")

    lines += ["", "## By model (last 7 days)", "", "### Claude", ""]
    for mk, mv in model_rollup(claude_models, week_dates):
        lines.append(f"- {mk}: ${mv['cost']:.2f} — {fmt_tok(mv['tokens'])} tokens")
    lines += ["", "### Codex", ""]
    for mk, mv in model_rollup(codex_models, week_dates):
        lines.append(f"- {mk}: ${mv['cost']:.2f} — {fmt_tok(mv['tokens'])} tokens")
    lines += [
        "",
        "## Method notes",
        "",
        "- Claude: `~/.claude/projects/**/*.jsonl` assistant-message usage; "
        "uncached input, 5m/1h cache writes, cache reads, and output priced "
        "separately per model.",
        "- Codex: `~/.codex/{sessions,archived_sessions}/**/*.jsonl` "
        "`token_count` per-turn deltas; model from turn_context/session_meta; "
        "component-less ambient lines priced at the input rate.",
        "- Full daily data in [ledger.csv](ledger.csv). Live view: Clodex menu "
        "bar app.",
        "",
    ]
    with open(SUMMARY, "w") as f:
        f.write("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quiet", action="store_true",
                    help="single status line (for launchd)")
    ap.add_argument("--out-dir", default=DEFAULT_OUT_DIR,
                    help="ledger output directory "
                         "(default: $AI_USAGE_DIR or ~/.clodex/ai-usage)")
    args = ap.parse_args()

    global OUT_DIR, LEDGER, SUMMARY, CACHE
    OUT_DIR = os.path.expanduser(args.out_dir)
    LEDGER = os.path.join(OUT_DIR, "ledger.csv")
    SUMMARY = os.path.join(OUT_DIR, "summary.md")
    CACHE = os.path.join(OUT_DIR, ".cache.json")

    os.makedirs(OUT_DIR, exist_ok=True)
    now = dt.datetime.now().astimezone()
    cache = load_cache()

    claude_files = glob.glob(os.path.join(CLAUDE_ROOT, "**", "*.jsonl"),
                             recursive=True)
    codex_files = []
    for root in CODEX_ROOTS:
        codex_files += glob.glob(os.path.join(root, "**", "*.jsonl"),
                                 recursive=True)

    c_tot, c_sess, c_models, c_parsed, c_reused = scan_source(
        cache["claude"], claude_files, parse_claude_file)
    x_tot, x_sess, x_models, x_parsed, x_reused = scan_source(
        cache["codex"], codex_files, parse_codex_file)

    rows = write_ledger(c_tot, c_sess, x_tot, x_sess)
    write_summary(rows, c_models, x_models, now)

    with open(CACHE, "w") as f:
        json.dump(cache, f)

    today = now.date().isoformat()
    trow = next((r for r in rows if r["date"] == today), None)
    status = (f"{now.strftime('%Y-%m-%d %H:%M')} ok — today "
              f"claude=${trow['claude_cost']:.2f} codex=${trow['codex_cost']:.2f} "
              if trow else f"{now.strftime('%Y-%m-%d %H:%M')} ok — no activity today ")
    status += (f"(parsed {c_parsed}+{x_parsed} files, "
               f"cached {c_reused}+{x_reused}, {len(rows)} ledger days)")
    print(status)
    if not args.quiet:
        print(f"ledger:  {LEDGER}\nsummary: {SUMMARY}")


if __name__ == "__main__":
    sys.exit(main())
