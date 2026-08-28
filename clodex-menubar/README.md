# Clodex — Claude + Codex usage in one macOS menu bar app

Combined usage monitor patterned on [clusage-menubar](https://github.com/mlg87/lcj/tree/main/clusage-menubar)
(Mason Goetz's Claude usage app), extended with a Codex column:

```
5H  ▓▓░░ 42%  │  WK ▓░░░ 17%  │  1D  26.6M
RESETS 9:00 PM │  F  ▓▓▓░ 90%  │  7D   123M
```

- **Left + middle columns (Claude):** 5-hour session gauge with reset time, weekly
  all-models gauge, Fable weekly gauge. Zero setup if Claude Code is installed —
  Clodex reuses its OAuth token against `api.anthropic.com/api/oauth/usage` (the
  same endpoint Claude Code's `/usage` command uses). A pasted claude.ai session
  cookie remains available as a fallback (same mechanism as clusage).
- **Right column (Codex):** estimated dollar cost today (`1D`) and over the last
  rolling 7 days (`7D`), parsed locally from `~/.codex/sessions/**/*.jsonl` — no
  network, no auth. Switchable to raw token counts via **Codex Column Shows** in
  the dropdown. Codex business/credit plans expose no percent-of-limit windows and
  no credit balance (`rate_limits.primary/secondary` and `credits.balance` are null
  in every session log), so cost-from-tokens is the honest usage signal; that's why
  these are estimates, not gauges.

The dropdown shows full-precision numbers, output-token splits, sessions active
today, refresh controls, cookie management, and Launch at Login.

## Menu bar styles

**Menu Bar Style** in the dropdown switches the visual live (persisted in the
`menubar_style` preference). Every style keeps the two priority signals visible:
the **5h reset time** and the **Codex monthly budget barometer**.

- **Grid** (default) — clusage-style 2-row grid: Claude gauges + reset time,
  Codex `1D`/`7D` costs on top and a `MO` month-to-date budget gauge below
- **Split Lanes** — one tool per row with lane icons: 🦀 lane (Claude: 5H/WK/F
  gauges + reset time) on top, OpenAI-blossom lane (Codex: 1D/7D costs + MO
  budget gauge) below; the blossom is drawn as vector petals, no emoji exists
- **Compact** — one text line (`5H 42%  RST 9:00PM  WK 17%  F 90%  MO $78.7`),
  percents tinted by limit band, `MO` tinted by budget band; narrowest footprint
- **Rings** — four circular gauges (5h / week / Fable / `$` = month vs budget)
  + reset time and `1D`/`MO` costs
- **Mini Bars** — same four gauges as vertical bars + the same text column
- **Today Pulse / Week Trend / Month Trend** — stacked history sparkbars
  (hourly ×12 / daily ×7 / daily ×30): Claude in neutral gray, Codex in the
  system accent color, scaled to the window max with the current bucket at full
  opacity. The window totals beside the chart are tinted in their bar colors
  (implicit legend), with the 5H percent + reset time pinned below. History is
  deliberately never traffic-light colored — trends aren't alarms.

The trend styles chart **both** tools from local logs: Codex from the session
scanner, Claude from a third scan lane over `~/.claude/projects/**/*.jsonl`
(same 32-day window and persisted cache pattern; per-file day/hour cost buckets
keyed by (mtime, size); dedup by message id + request id, matching the COS
ledger script). The dropdown's Claude section shows the resulting
today / 7d / 30d value estimates.

## Codex monthly limit (percent gauge)

When the workspace has ChatGPT **spend controls** enabled, Clodex fetches the
real monthly credit limit from `https://chatgpt.com/backend-api/wham/usage` —
the same internal endpoint the ChatGPT Codex usage page calls — and the `MO`
slot becomes a true percent-of-limit gauge (standard green/yellow/red limit
bands), matching how the Claude column works. The dropdown shows the detail:
`Monthly limit: 84% — 3,604 / 4,300 credits — resets Mon 1:40 AM`, with a ⚠︎
row when the limit is reached.

Auth is zero-setup: the Bearer token is read fresh on each fetch from the
Codex CLI's own `~/.codex/auth.json` (never logged, never sent anywhere but
chatgpt.com). A stale token (401) self-heals the next time Codex runs. Same
gray-area disclaimer as the Claude endpoint: undocumented and may change;
Clodex degrades to the dollar-budget barometer below when it's unavailable.

## Codex monthly budget (fallback barometer)

**Codex Monthly Budget** in the dropdown (default **$100/month**, persisted in
`codex_monthly_budget`) frames month-to-date Codex cost as a gauge:
**green** at or under budget · **yellow** up to 2× · **red** beyond 2×
(i.e. with the default, over $200/month reads as heavy usage). The dropdown
shows today / 7-day / 30-day / month-to-date costs with the budget percent.
The scanner covers a 32-day window and persists its parse cache to
`~/Library/Application Support/Clodex/`, so only the first-ever scan is slow.

## Install / update

```sh
make install     # builds Clodex.app and copies it to ~/Applications, then launches
```

Ad-hoc signed; installed via `cp` so no Gatekeeper quarantine attribute is set.

## Auth (Claude column only)

### Primary: Claude Code sign-in (zero setup)

If the Claude Code CLI is installed and signed in, Clodex reuses its OAuth token —
no cookie, no pasting, and the token never goes stale because Claude Code refreshes
it as it runs. Token resolution order:

1. `CLODEX_CLAUDE_TOKEN` env var (tests)
2. The login Keychain item `Claude Code-credentials` (current Claude Code versions;
   read by shelling out to `/usr/bin/security`, which is already on the item's
   access list, so there is no permission prompt)
3. `~/.claude/.credentials.json` (older Claude Code versions)

The token is read fresh on every fetch, kept in memory only, never logged, and
sent only to `api.anthropic.com`. The dropdown shows "Signed in via Claude Code"
when this path is active. If the token is ever rejected, running `claude` once
refreshes it.

### Fallback: session cookie

Without a Claude Code sign-in, the clusage-style cookie path is used instead.
Cookie resolution order:

1. `CLODEX_COOKIE` env var (tests)
2. Clodex's own preferences (`com.clodex.menubar` / `session_cookie`),
   set via **Set Session Cookie (fallback)…** in the dropdown
3. **Fallback: clusage's stored cookie** (`com.mlg87.clusage-menubar` domain) — if you
   already ran clusage, Clodex works with zero setup. The dropdown shows
   "Cookie shared from Clusage" when this fallback is active.

The cookie is stored unencrypted in UserDefaults (same trade-off and rationale as
clusage: Keychain ACLs break on every ad-hoc rebuild). It is never logged and never
sent anywhere but claude.ai. Both usage endpoints are undocumented/internal and may
change; the Claude column degrades to "–" bars when they do.

## Codex scanning details

- Scans `~/.codex/sessions` and `~/.codex/archived_sessions` for `.jsonl` files
  modified in the last 8 days (1-day margin over the 7-day window).
- Sums `payload.info.last_token_usage` from `token_count` event lines — the per-turn
  delta, so totals are correct across sessions spanning midnight.
- Per-file `(mtime, size)` cache: the first scan reads everything in the window
  (~hundreds of MB, a few seconds); every refresh after that re-reads only actively
  written files.
- "Today" follows the local calendar day; "7D" is a rolling window including today.

## Cost estimation

Tokens are priced at OpenAI's **standard API tier** (`Sources/ClodexCore/CodexPricing.swift`,
rates from developers.openai.com/api/docs/pricing, checked 2026-08-26):
uncached input at the input rate, cached input at the cached rate, output at the
output rate. Model attribution comes from each session's `turn_context` lines
(falling back to `session_meta.base_instructions.provenance.model` for ambient
Codex Desktop sessions). Unknown models (e.g. `codex-auto-review`) use terra
rates as a mid-tier guess. Ambient sessions emit component-less token lines
(total only); those are priced at the input rate.

Caveats: credit-plan internal rates may differ from API list prices, and
`gpt-5.4` long-context requests bill higher than the short-context rate used
here — treat the numbers as API-equivalent estimates, not a bill. Update the
table in CodexPricing.swift when prices move.

## Limit detection

The scanner also mirrors the newest `rate_limits` payload. Today OpenAI reports
nothing for business/credit plans (the dropdown says "No limit/balance reported"),
but if the backend ever populates `credits.balance`, a `primary` window
percentage, `spend_control_reached`, or `rate_limit_reached_type`, the dropdown
surfaces it automatically — including a ⚠︎ line when usage is actively limited.

## Dev

```sh
make build      # swift build (debug)
make test       # swift run ClodexTests (assertion-based, no XCTest)
make app        # ./build.sh — release bundle in build/Clodex.app
make clean
```

Targets: `ClodexCore` (pure Foundation: parsing, aggregation, formatting — all
unit-tested), `ClodexMenubar` (AppKit app), `ClodexTests` (assertion runner).

## Optional: daily usage ledger

`tools/ai_usage_snapshot.py` (stdlib-only) maintains the durable historical
record the menu bar app doesn't: a daily ledger of **both** Claude Code and
Codex usage with API-equivalent cost estimates (ledger.csv + summary.md).
Output goes to `~/.clodex/ai-usage/` by default — point it anywhere (e.g. a
notes vault) with `--out-dir` or the `AI_USAGE_DIR` env var. A per-file cache
(.cache.json) keeps repeat runs under a second. To keep it current
automatically, install the launchd agent from
`tools/com.clodex.ai-usage.example.plist` (instructions inside). Claude
pricing lives in the script; Codex pricing must be kept in sync with
`Sources/ClodexCore/CodexPricing.swift`.

## Relationship to clusage

The Claude fetch/parse/render code is ported from clusage-menubar with attribution
in each file header. If you run Clodex, quit clusage (its Claude gauges are
duplicated here); Clodex reads its cookie either way.
