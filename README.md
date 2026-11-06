# aika

A small Windows activity tracker and timeline viewer built with **Odin + native Win32/GDI**.

It follows the same core design as ManicTime:

- Poll `GetForegroundWindow()` once per second.
- Resolve the owning process, executable path, product name and window title.
- Record a new activity only when the app/title changes.
- Extend the current activity's end time on a heartbeat.
- Store everything in a SQLite database with ManicTime-shaped `Timeline`, `Group`
  and `Activity` tables.
- Import existing ManicTime history from its SQL Server Compact `.sdf` database.

The app is pure Odin at runtime. The only external piece is the one-way
PowerShell exporter used to read ManicTime's proprietary `.sdf` file.

> **Working on the code?** Start with [`AGENTS.md`](AGENTS.md), then read the
> focused docs in [`docs/`](docs/).

Tracking uses a monotonic clock for scheduling. Large system-clock adjustments
split tracking intervals rather than filling the clock jump; a running task stops
at its last saved endpoint. Backward jumps can leave separate intervals overlapping
in UTC—existing history is not moved or repaired automatically.

## Status

Working MVP:

- Foreground-window tracking at 1 Hz
- Idle/away detection (`GetLastInputInfo`, default 1 min without keyboard or mouse input)
- Tracking settings (top-right Settings button or tray menu): 1–500 minute idle timeout, saved per database
- ManicTime-style day view: tab strip, date navigation, full 24 h timeline with
  Tags / Computer Usage / Applications / Documents lanes
- Application timeline with live current-activity bar
- Computer usage lane (Active / Away)
- Time tagging: drag a range, search/select or create a tag, resize either edge
- Details list (Title / Start / End / Duration) for the selected lane
- Per-application totals with color chips and a grand total
- Filter box wired to the lists
- Date navigation
- Pause/resume tracking
- ManicTime `.sdf` → JSON → SQLite importer
- ManicTime-compatible date semantics (`StartLocalDate` = days since 2000-01-01)

Not implemented yet:

- Session lock / power-off events (`SessionSwitch`, `PowerModeChanged`)
- Document/URL tracking (browser plugins)
- Folders, statistics, general activity editing
- Multi-monitor / per-window tracking (ManicTime also only tracks the foreground window)
- Writing back to `.sdf` (not feasible without the SQL Server Compact engine)

## Build

Requirements:

- Windows
- Odin (tested with `dev-2025-11-nightly`)
- `vendor/sqlite/sqlite3.lib` (already built in this repo)

Run:

```bat
build.bat
run.bat
```

or:

```bat
odin build src -out:build\aika.exe -subsystem:windows
odin build src -out:build\aika-cli.exe
build\aika.exe
```

The UI is drawn with plain GDI (`user32` + `gdi32`, both system libraries), so no
windowing toolkit ships with the binary. A running GUI window uses about 6 MB
of private memory.

The app writes `data\aika.db` by default. Override with `--db`.

## Tagging time

Drag left-to-right or right-to-left on the **Tags** lane. Release to open the
tag picker, then search and select an existing tag (double-click or **Use tag**),
or type a new name and click **Create tag**. Enter uses the selected result, or
creates a tag if there are no matches. Escape/Cancel dismisses without saving.

Double-click empty space **between two tag blocks** to select the whole gap,
then choose a tag in the picker. The new block fits exactly between its neighbors.
Empty space before the first block or after the last block is not auto-filled.

Drag either border of a tag block to change its start or end; release to save.
For touching blocks, grab just inside the block whose border you want to resize.
Escape during a drag cancels the change. Selection uses the current zoom range,
without time snapping. Tags appear in the lane, details list, and totals, and
survive restarting the app. Tag blocks cannot overlap: a drag within a block is
a no-op, and dragging out of a block selects only the free time beyond its edge.
Selections stop at the next occupied block; resizing also stops at neighboring
blocks. Deleting/renaming tags and moving whole blocks are not yet
implemented.

Right-click a tag block and choose **Delete** to remove that time interval.
The tag name stays available in the picker for reuse.

## Importing existing ManicTime history

ManicTime uses SQL Server Compact 4.0 (`.sdf`). Pure Odin cannot read that format,
so the repo includes a read-only exporter that uses the SQL CE assemblies installed
with ManicTime.

Export the last 7 days:

```powershell
powershell -ExecutionPolicy Bypass -File tools\export-manictime.ps1 -Days 7 -SourceId home-manictime-1
```

Export only today:

```powershell
powershell -ExecutionPolicy Bypass -File tools\export-manictime.ps1 -Days 1 -SourceId home-manictime-1 -Out tools\manictime-today.json
```

Import into a fresh `aika` database:

```bat
build\aika-cli.exe --db data\aika.db --import tools\manictime-today.json --quiet
```

`aika-cli.exe` is the console-subsystem build of the same code, intended for
imports and scripting. `aika.exe` is the GUI build.

The exporter opens `ManicTime.sdf` in read-only mode. ManicTime can usually keep
running, but close it if SQL CE reports a file-write lock.

Choose `SourceId` once per source database and reuse it for every export/date
range. Use a new ID after replacing/resetting that database; don't use export
filenames or timestamps as identities. New exports carry this ID in the JSON.
Legacy exports (including the checked-in sample) require an explicit ID:

```bat
build\aika-cli.exe --db data\import-test.db --import tools\manictime-today.json --import-source manictime-sample --quiet
```

Imports allocate local IDs, resolve groups by `(TimelineId, Key)`, and preserve
existing group names/colors. Reimporting the same source does not duplicate rows;
source changes update only mapped rows that have not changed locally. Conflicts
roll back the entire import, and locally deleted imported tags stay deleted.
Import failures return exit code 1; invalid CLI arguments return 2.

**Older imports have no provenance.** Back up an existing database before using
the new importer. It will not infer ownership from IDs or rewrite earlier rows:
importing that same legacy history again can create duplicates once. Use a fresh
database for a clean reimport, or review your existing history first. Earlier
overwrites/orphans are not automatically repaired.

## ManicTime schema compatibility

The SQLite schema mirrors the important ManicTime tables and columns:

```sql
Timeline(TimelineId, TypeName, DisplayName, DisplayOrder, UpdateInterval, ...)
"Group"(GroupId, TimelineId, DisplayName, Color, TextData, Key, ...)
Activity(ActivityId, TimelineId, DisplayName, GroupId,
         StartLocalDate, StartLocalTime, StartUtcTime,
         EndLocalDate, EndLocalTime, EndUtcTime,
         StartUtcMs, EndUtcMs, TextData, UpdatedTimestamp)
```

Important details:

- `StartLocalDate` / `EndLocalDate` are **days since 2000-01-01**, exactly like
  ManicTime.
- Local and UTC timestamps are both stored.
- `StartUtcMs` / `EndUtcMs` are an aika extension for fast timeline math; they do not
  change the ManicTime meaning of the other columns.
- `Group.Key` is `Base64(SHA256(lowercase(FileName + ";" + ProductName)))`, matching
  ManicTime's application identity.
- The application group `TextData` is the same
  `<ApplicationGroupTextData>...</ApplicationGroupTextData>` XML.

Timeline IDs seeded by aika:

```
1  ManicTime/Tags
2  ManicTime/ComputerUsage
3  ManicTime/Applications
4  ManicTime/Documents
```

## How it works

```
GetForegroundWindow (1 Hz)
  -> GetWindowThreadProcessId + QueryFullProcessImageNameW
  -> FileVersionInfo (ProductName, CompanyName, FileDescription)
  -> GetWindowTextW (title)
  -> compare (process id, title, document)
  -> ApplicationActivated
  -> activity row start/end
  -> heartbeat extends current row every 10 s
  -> UI loads the day and draws bars
```

Like ManicTime:

- Activities shorter than 5 seconds are merged backward instead of becoming bars.
- The current activity starts as an in-memory overlay and is persisted after 5 s.
- The app timeline is trimmed to the real idle start when the user goes away.
- The current bar grows while the day view is open.

## Layout

```
src/
  main.odin       entry point, native message loop, date navigation
  tracker.odin    foreground polling, idle/away state, activity lifecycle
  win32.odin      Win32 bindings, time helpers, version info, group identity
  db.odin         SQLite schema/repository, ManicTime-compatible dates
  sqlite.odin     SQLite C bindings
  winui.odin      native window: WndProc, timer, GDI helpers, double buffer, hit tests
  ui.odin         ManicTime-style day view (lanes, ruler, list, totals, tooltip)
  importer.odin   JSON import command
tools/
  export-manictime.ps1
vendor/
  sqlite/         SQLite 3.54.1 amalgamation + static lib
docs/
  ARCHITECTURE.md
  DATABASE.md
  MANICTIME.md
  DEVELOPMENT.md
  ROADMAP.md
```

## Documentation

| Document | Contents |
|---|---|
| [`AGENTS.md`](AGENTS.md) | Entry point for coding agents: invariants, commands, checklist |
| [`docs/ODIN-PITFALLS.md`](docs/ODIN-PITFALLS.md) | Odin compiler pitfalls hit during the native-UI rewrite (read before touching GDI/UI code) |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Tracker, persistence, and UI internals |
| [`docs/DATABASE.md`](docs/DATABASE.md) | Schema, date/group semantics, example queries |
| [`docs/MANICTIME.md`](docs/MANICTIME.md) | Reverse-engineering notes from the original app |
| [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) | Toolchain, build, debugging, common failures |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Next features and technical debt |
