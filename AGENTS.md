# lcj — agent guide

Monorepo of personal Claude Code tooling. Every project is self-contained in its
own top-level directory; each project's README is the source of truth for
install and development. Read it before working in that directory.

## Repo rules
- Never commit or push to `main` — all changes land via PR; never bypass branch protection.
- One PR per logical change. Branch prefixes: `feat/`, `fix/`, `chore/`.
- Run the relevant linter after every file change (`make lint` where a Makefile exists).
- Comments explain WHY, not what; reference issues/PRD sections where relevant.

## Projects
| Dir | What | Dev commands |
|---|---|---|
| `clud/` | iTerm2 Claude HUD panel (Python) | see `clud/README.md` |
| `clusage-menubar/` | macOS menu bar Claude (+ Codex) usage app (Swift 6, AppKit) | `make -C clusage-menubar check` |

## Releasing clusage-menubar (fully automated — never release manually)
- NEVER create `clusage-menubar-v*` tags or GitHub releases by hand, and NEVER edit
  `clusage-menubar/version.txt` or its CHANGELOG version sections manually —
  release-please + CI own them.
- To ship: merge PRs with conventional-commit messages (`fix:`/`feat:`/…) touching
  `clusage-menubar/**`, then merge the auto-maintained release PR
  ("chore(main): release clusage-menubar X.Y.Z"). CI tags, builds an ad-hoc-signed
  DMG + tar.gz (no Apple Developer Program or signing secrets needed), uploads them,
  and publishes the release (draft until the assets are attached).
- `.github/workflows/clusage-menubar-release.yml` runs on every push to `main` touching
  `clusage-menubar/**`: always runs `make check`; the artifact job runs only when
  release-please cut a new tag. Users install via `clusage-menubar/install.sh`
  (curl/tar → no Gatekeeper quarantine) or the DMG (requires Open Anyway).
