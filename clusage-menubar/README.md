# Clusage — Claude usage in your macOS menu bar

<img src="assets/menubar-screenshot.png" alt="Clusage in the menu bar: 5H session gauge with reset time on the left, WK and F (Fable) weekly gauges on the right" width="654">

A Stats-style macOS menu bar app showing your Claude Code usage as a compact
two-column grid of mini progress bars, authenticated by your claude.ai session
cookie — paste it once, no keychain access, no API key setup.

**Left column:** 5-hour session gauge · `RESETS` time for that window (12 or 24h, follows your system setting)  
**Right column:** `WK` weekly usage across all models · `F` Fable weekly usage  
**Colors:** green <70% · yellow 70–89% · red ≥90%  
**Auto-refresh:** every 5 minutes by default (plus an immediate fetch on wake) — pick
1/2/3/5/8/13 minutes via **Refresh Every** in the dropdown; the choice persists in the
`com.mlg87.clusage-menubar` preferences domain under key `refresh_interval_minutes`.

---

## Install

### Quick install (recommended)

```sh
curl -fsSL https://raw.githubusercontent.com/mlg87/lcj/main/clusage-menubar/install.sh | bash
```

Downloads the latest release, installs to `/Applications` (or `~/Applications`
for non-admin users), and launches it — **no Gatekeeper prompts**. WHY: macOS
only blocks apps carrying the `com.apple.quarantine` attribute, which browsers
set on downloads; `curl`/`tar` never set it, and the ad-hoc signature satisfies
Apple Silicon's signed-code requirement.

On first launch a dialog explains how to copy your session cookie from claude.ai
(Settings → Usage → DevTools → Network → `usage` request → `Cookie` request header).
Paste and Save; the usage bars appear within a few seconds.

### Download the DMG (manual)

1. Download `ClusageMenubar-X.Y.Z.dmg` from [Releases](../../releases).
2. Open the DMG, drag **ClusageMenubar** to Applications.
3. **Gatekeeper blocks the first launch** — releases are ad-hoc signed, not
   notarized (no Apple Developer Program). Either:
   - System Settings → Privacy & Security → scroll to the block message →
     **Open Anyway** (macOS 15 removed the right-click → Open bypass), or
   - `xattr -d com.apple.quarantine /Applications/ClusageMenubar.app`
4. Launch it and follow the cookie dialog as above.

### Build from source

Prerequisites: macOS 13+, Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/mlg87/lcj.git
cd lcj/clusage-menubar
make dmg          # builds ClusageMenubar.app + ClusageMenubar-X.Y.Z.dmg
# or just:
make app          # builds build/ClusageMenubar.app (no DMG)
```

---

## How auth works

Clusage uses your **pasted claude.ai session cookie** — no Keychain access, no API key.

Resolution order:
1. **`CLUSAGE_COOKIE` environment variable** — overrides the stored value (tests/CI).
2. **UserDefaults** — stored in the `com.mlg87.clusage-menubar` preferences domain under
   key `session_cookie` after your first paste.

The cookie is stored **unencrypted** in the app's preferences plist — the same trust
level as the browser profile it was copied from. It is never logged and never sent
anywhere but `claude.ai`.

### Compliance / gray-area disclaimer

The usage data comes from `GET https://claude.ai/api/organizations/<orgId>/usage` — the
same internal API the claude.ai usage page calls. This is an **undocumented, internal
endpoint** and may change or disappear without notice. Clusage degrades gracefully
(shows "–" bars) whenever it becomes unavailable. Use is at your own discretion.

---

## Dev commands

```sh
make build    # swift build (debug)
make test     # swift run ClusageTests  (assertion-based; no XCTest needed)
make lint     # shellcheck all .sh scripts
make check    # build + test + lint
make app      # ./build.sh — release app bundle in build/
make dmg      # app + ./create_dmg.sh — DMG in clusage-menubar/
```

### Env vars

| Variable | Default | Purpose |
|---|---|---|
| `ARCHS` | `arm64 x86_64` | Architectures to build. Set to `arm64` if x86_64 CLT build fails. |
| `CODESIGN_IDENTITY` | `-` (ad-hoc) | `build.sh`: optional signing identity. Releases ship ad-hoc; only needed for local experiments with a real/self-signed cert. |
| `CLUSAGE_TARBALL` | *(unset)* | `install.sh`: path to a local `ClusageMenubar-*.tar.gz`; skips the download (script testing). |
| `SKIP_DMG_LAYOUT` | *(unset)* | Set to any value to skip the Finder AppleScript icon-layout step (used on headless CI). |
| `CLUSAGE_COOKIE` | *(unset)* | Overrides the stored session cookie at runtime (tests/CI). |

---

## Release procedure

Releases are fully automated by [release-please](https://github.com/googleapis/release-please)
+ [`clusage-menubar-release.yml`](../.github/workflows/clusage-menubar-release.yml).
Never create `clusage-menubar-v*` tags/releases or edit `version.txt` by hand — CI owns them.

1. Merge PRs whose commits follow [Conventional Commits](https://www.conventionalcommits.org/)
   (`fix:` → patch, `feat:` → minor, `feat!:`/`BREAKING CHANGE:` → major) touching `clusage-menubar/**`.
2. release-please maintains a release PR ("chore(main): release clusage-menubar X.Y.Z")
   that accumulates merged changes, bumping `version.txt` and `CHANGELOG.md`.
3. Merge that release PR when you want to ship. CI tags `clusage-menubar-vX.Y.Z`, builds the
   ad-hoc-signed universal app, uploads `ClusageMenubar-X.Y.Z.dmg` and
   `ClusageMenubar-X.Y.Z.tar.gz` (consumed by `install.sh`), and publishes the release.

Release builds need **no signing secrets** — artifacts are ad-hoc signed. The
release stays a draft until both assets upload; if the job fails, fix and re-run it.
---

## Troubleshooting

**No session cookie set** — use **Set Session Cookie…** in the menu bar dropdown.
Follow the in-app instructions to copy the `Cookie` header from DevTools on
claude.ai/settings/usage and paste it into the dialog.

**Cookie rejected or expired** — your session has expired. Log in to claude.ai again,
then copy a fresh cookie via the same DevTools steps and paste it with
**Set Session Cookie…**.

**Launch at Login doesn't work** — `SMAppService` requires the app to be in a stable
location (e.g. `/Applications`). It won't work when run via `swift run` or directly
from the build directory.
