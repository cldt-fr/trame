# Contributing to Trame

Thanks for your interest! Trame is young and moving fast — issues and PRs are
welcome.

## Getting started

1. Install Xcode 16+ and the [Claude Code](https://claude.com/claude-code) CLI.
2. `open Trame.xcodeproj` and run the `Trame` scheme.
3. The app spawns its own daemon (`Trame --daemon`) on first launch; kill it
   with `pkill -f "Trame --daemon"` if you need a clean slate. Support files
   live in `~/Library/Application Support/Trame/`.

## Before opening a PR

- `cd TrameCore && swift test` must pass.
- `swift build && .build/debug/trame-smoke` must stay green — it covers the
  daemon end to end (session survival, scrollback, hooks, attention).
- New daemon/protocol behavior belongs in `TrameCore` with a test; UI-only
  changes don't need one.
- Bump `Daemon.version` whenever the wire protocol changes — the app restarts
  outdated daemons automatically (running sessions are snapshotted and
  restored).
- All user-facing strings are in English.

## Architecture notes

- The app never talks to the `claude` CLI directly: sessions are shell
  commands run by the daemon in PTYs, and state comes from Claude Code hooks +
  JSONL transcripts. Keep it that way — no terminal scraping.
- Secrets never touch disk: Keychain + `${VAR}` env indirection
  (see `MCPStore`/`MCPConfigBuilder`).
- Trame never writes into user repos except `.claude/settings.local.json`
  (merged, marker-guarded, git-excluded via `.git/info/exclude`).
