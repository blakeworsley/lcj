# lcj

Monorepo for personal Claude Code skills, plugins, and related tooling.

## Projects

| Directory | What it is |
|---|---|
| [`clud/`](./clud/) | **Claude HUD** — an iTerm2 toolbelt panel that mirrors live Claude Code session state (todos, current tool, model, project) for whichever Claude tab is focused. |
| [`clusage-menubar/`](./clusage-menubar/) | **Clusage** — a macOS menu bar app showing Claude 5h / weekly / Fable usage as a compact grid of progress bars, authenticated by your claude.ai session cookie — plus a Codex column (estimated cost + monthly limit gauge from local session logs) when the Codex CLI is installed. |

More to come.

## Layout

Each project lives in its own top-level directory and is self-contained: its own README, install steps, tests, and (where it makes sense) its own dev venv. There's no shared build system at the root yet — when one of these grows enough to need one, we'll add it.

## Conventions

- One PR per logical change; never commit directly to `main`.
- Each project's README is the source of truth for how to install and develop it. Read the project README first.
- Self-documenting code with comments explaining **why** (not what); reference issue numbers or PRD sections where relevant.
