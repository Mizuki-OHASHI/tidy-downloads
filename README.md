# tidy-downloads

A small macOS daemon that keeps duplicate downloads tidy. Instead of letting
`report.pdf`, `report (1).pdf`, `report (2).pdf` pile up flat in `~/Downloads`,
it keeps the **newest at the top level** and files older versions away:

```
report.pdf              ← newest
report/
  report_1.pdf          ← older versions (append-only numbering)
  report_2.pdf
```

- **Different content** → the current top is archived into `name/name_N.pdf`, the new file becomes `name.pdf`.
- **Identical content** (a redundant re-download) → the old top is moved to the **Trash**, the newest copy is kept.
- **Safety**: it only acts when the base `name.pdf` already exists, so a legitimately-named `report-2.pdf` is never touched.
- Every move/trash is recorded in an append-only **JSONL ledger**, and nothing is ever hard-deleted (deletes go to `~/.Trash`).

## Build & install

```sh
swift build -c release                           # optimized, self-contained binary
cp .build/release/tidy-downloads ~/.local/bin/   # put it on your PATH
```

The binary is self-contained (Rainbow is linked in; the Swift runtime ships with
macOS), so `.build/` can be removed afterward. With `~/.local/bin` on your PATH,
`tidy-downloads` then works from anywhere.

To run it at login as a background daemon, run `install` **from the copied
binary** (so the LaunchAgent records the stable path, not `.build/...`):

```sh
tidy-downloads install
```

Update later with:

```sh
swift build -c release && cp .build/release/tidy-downloads ~/.local/bin/ && tidy-downloads install
```

## Usage

```sh
tidy-downloads run            # watch ~/Downloads in the foreground (also sweeps existing files at startup)
tidy-downloads run --dry-run  # watch and report what it WOULD do, changing nothing
tidy-downloads organize       # process files already in the folder once, then exit
tidy-downloads organize -n    # same, dry-run
tidy-downloads install        # install & start the background LaunchAgent (runs at login)
tidy-downloads uninstall      # stop & remove it
tidy-downloads status         # status dashboard
tidy-downloads log [N]        # recent activity (default 50; --all for everything)
tidy-downloads config         # path to the config file
```

`status` and `log` are colored; pipe through `less -R` to scroll
(`tidy-downloads log --all | less -R`). Use `--no-color` (or set `NO_COLOR`) to disable.

## Configuration

Config, ledger, and daemon logs live in:

```
~/Library/Application Support/tidy-downloads/
  config.json     # editable settings
  log.jsonl       # append-only operation ledger
  daemon.{out,err}.log
```

`config.json`:

| key | default | meaning |
|---|---|---|
| `watchedDirectory` | `~/Downloads` | directory to watch (non-recursive) |
| `extensions` | `["pdf"]` | file types to act on (lowercase, no dot) |
| `collisionPatterns` | see below | regexes matching browser dedup names |
| `debounceSeconds` | `1.0` | quiet period after a change before rescanning |

### Browser dedup patterns

Capture group 1 must be the base name. Defaults, verified against real downloads:

| browser | example | regex |
|---|---|---|
| Chromium (Chrome, Dia, Edge, Brave) | `name (1).pdf` | `^(.+) \((\d+)\)$` |
| Safari & Firefox | `name-1.pdf` | `^(.+)-(\d+)$` |

Chromium uses a space + parenthesized number; Safari and Firefox both use a
hyphen + number. The hyphen form is broad, so a match is acted on only when the
base file already exists — `covid-19.pdf` won't be touched unless `covid.pdf` is
right there next to it.

## How recovery works

Because every operation is in `log.jsonl` and deletes go to the Trash, the whole
history can be replayed in reverse to undo it (move each `to` back to its `from`,
restore dedup files from `trashPath`), newest-first. A built-in `undo` command is
a natural next step.

## Safety model

- Operations are recorded in the ledger **only after both filesystem steps
  succeed**, and a partial failure (e.g. the second move fails) **rolls back** to
  the original state — so the ledger always reflects what's actually on disk.
- Ledger write failures are logged loudly to the daemon error log (they don't
  silently disappear), though they don't abort the file operation itself.

## Notes / limitations

- macOS only. Single directory, non-recursive.
- Files are assumed complete once their final name appears (browsers download to a
  temp file and atomically rename on completion). Tools that write directly to the
  final name are guarded only by the debounce + non-empty check.
- **Case-insensitive volumes** (the APFS default): the canonical top-level name
  follows the new download's casing. If you had `Report.pdf` and a download
  produces `report (1).pdf`, the top may normalize to `report.pdf` — no data loss
  (the previous file is archived or trashed as usual).
- **Very long names** (> 255 bytes) and **symlinked** downloads are not
  special-cased; such a move may fail and is logged to the daemon error log
  rather than acting silently.
