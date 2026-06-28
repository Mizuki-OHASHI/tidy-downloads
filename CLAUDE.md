# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`tidy-downloads` is a macOS-only Swift daemon (SwiftPM executable) that tidies duplicate
downloads in a watched directory. When a browser dedup file appears (e.g. `report (1).pdf`)
and the base `report.pdf` already exists, it either archives the old top into
`report/report_N.pdf` (different content) or trashes the redundant copy (identical content),
always keeping the newest as the top-level `report.pdf`.

## Build / run

- `swift build` — debug → `.build/debug/tidy-downloads`
- `swift build -c release` — optimized → `.build/release/tidy-downloads`
- `swift run tidy-downloads <command>` — build & run
- swift-tools-version is **5.9 on purpose** (v5 language mode) to sidestep Swift 6 strict
  concurrency around `DispatchSource` and global state.

Commands: `run` (foreground daemon), `organize` (one-shot sweep), `--dry-run`/`-n`,
`install`/`uninstall` (launchd LaunchAgent), `status`, `summary`, `log [N]`/`--all`, `config`.

### Installing the binary (gotcha)
Distribute to `~/.local/bin`. **Never `cp` over the running daemon's binary in place** — on
Apple Silicon the kernel SIGKILLs the new process (code-signing page mismatch). Always
`rm -f ~/.local/bin/tidy-downloads` first, then `cp`, then `tidy-downloads install` — and run
`install` from the installed copy, since it records the binary's absolute path via
`_NSGetExecutablePath`.

## Testing — ISOLATION IS MANDATORY

There is no XCTest suite; behavior is verified with throwaway shell scripts against an
**isolated** directory. The default config's `watchedDirectory` is the REAL `~/Downloads`, and
a non-dry `organize`/`run` acts immediately — a test that forgets to repoint the config will
reorganize real files (this has happened).

To test safely:
1. `export TIDY_DOWNLOADS_HOME=<scratch>` — relocates config/ledger/logs, but **NOT** the
   watched directory.
2. Write `<scratch>/config.json` with `watchedDirectory` set to a scratch dir and the same
   `collisionPatterns` as the app.
3. **Assert** the config points at the scratch dir (e.g. `grep`) before any non-dry run, and
   prefer `--dry-run` first.

Recovery if real files do get touched: every op is in the append-only ledger and all deletes
go to Trash, so replay the ledger in reverse (move each `to` → `from`, restore dedup from
`trashPath`), newest-first.

## Architecture

One executable; `main.swift` parses argv and dispatches commands.

Pipeline (shared by `run` and `organize`):
`Watcher` (DispatchSource vnode on the dir fd + debounce) → `DirectoryScanner.scan` (lists
candidates, mtime-sorted) → `CollisionResolver.process` (per file).

`CollisionResolver.process` is the core and holds the load-bearing invariants:
- **Pattern match** via `baseStem` (regexes from `Config.collisionPatterns`).
- **Safety rule**: act only if the base file actually exists — prevents mangling a
  legitimately-named `report-2.pdf`.
- **Decision** by streaming SHA-256 (`FileHasher`): identical → dedup (old top to Trash);
  different → version (archive old top to `base/base_N.ext`, append-only `nextIndex`).
- **Consistency invariant**: do the filesystem moves first with **rollback on partial
  failure**, and write the `Ledger` **only after both moves succeed**. Preserve this — the
  ledger must never describe an operation that didn't complete.

State vs history:
- **Filesystem is the source of truth** for current state — `summary` derives version groups
  by scanning for `base/` folders containing `base_N.ext` (non-`_N` files are ignored, so
  unrelated folders are skipped).
- **Ledger** (`log.jsonl`, append-only JSONL) is the operation history — shown by `log`.

Support files live under `~/Library/Application Support/tidy-downloads/` (`AppPaths`,
overridable via `TIDY_DOWNLOADS_HOME`): `config.json`, `log.jsonl`, daemon logs.

Presentation: `TUI.swift` (status + log, plus CJK-aware width helpers
`displayWidth`/`padTo`/`truncateTo`), `Summary.swift` (`summary`), and `Present`
(organize/run lines) all render via **Rainbow**. Display commands
(`status`/`log`/`summary`/`organize`) force color on through `configureColors` so
`| less -R` / `| tee` stay colored (`--no-color` / `NO_COLOR` opt out); `run` leaves color
auto-detected so the launchd log file stays plain.

Conventions worth knowing:
- Browser dedup patterns (verified against real downloads): Chromium `name (1)`, Safari &
  Firefox `name-1` — in `Config.defaultPatterns`. The hyphen form is broad; the safety rule
  is what keeps it safe.
- Type names `FileHasher` and `DirectoryScanner` are deliberately not `Hasher` / `Scanner` to
  avoid shadowing `Swift.Hasher` / `Foundation.Scanner`.
- launchd label and `DispatchQueue` labels use the `jp.m-ohashi.tidy-downloads` prefix.
