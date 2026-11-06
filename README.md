# aika

A small Windows activity tracker and timeline viewer built with **Odin + raylib/raygui**.

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

## Status

Working MVP:

- Foreground-window tracking at 1 Hz
- Idle/away detection (`GetLastInputInfo`, 10 min threshold)
- Application timeline with live current-activity bar
- Computer usage lane (Active / Away)
- Auto-fit timeline with adaptive ruler ticks
- Per-application daily summary
- Date navigation
- Pause/resume tracking
- ManicTime `.sdf` → JSON → SQLite importer
- ManicTime-compatible date semantics (`StartLocalDate` = days since 2000-01-01)

Not implemented yet:

- Session lock / power-off events (`SessionSwitch`, `PowerModeChanged`)
- Document/URL tracking (browser plugins)
- Tags, folders, statistics, editing
- Multi-monitor / per-window tracking (ManicTime also only tracks the foreground window)
- Writing back to `.sdf` (not feasible without the SQL Server Compact engine)

## Build

Requirements:

- Windows
- Odin (tested with `dev-2025-11-nightly`)
- The bundled Odin `vendor:raylib` (includes raygui)
- `vendor/sqlite/sqlite3.lib` (already built in this repo)

Run:

```bat
build.bat
run.bat
```

or:

```bat
odin build src -out:build\aika.exe -define:RAYLIB_SHARED=true -subsystem:windows
odin build src -out:build\aika-cli.exe -define:RAYLIB_SHARED=true
copy vendor\raylib\raylib.dll build\
build\aika.exe
```

The app writes `data\aika.db` by default. Override with `--db`.

## Importing existing ManicTime history

ManicTime uses SQL Server Compact 4.0 (`.sdf`). Pure Odin cannot read that format,
so the repo includes a read-only exporter that uses the SQL CE assemblies installed
with ManicTime.

Export the last 7 days:

```powershell
powershell -ExecutionPolicy Bypass -File tools\export-manictime.ps1 -Days 7
```

Export only today:

```powershell
powershell -ExecutionPolicy Bypass -File tools\export-manictime.ps1 -Days 1 -Out tools\manictime-today.json
```

Import into a fresh `aika` database:

```bat
build\aika-cli.exe --db data\aika.db --import tools\manictime-today.json --quiet
```

`aika-cli.exe` is the console-subsystem build of the same code, intended for
imports and scripting. `aika.exe` is the GUI build.

The exporter opens `ManicTime.sdf` in read-only mode. ManicTime can usually keep
running, but close it if SQL CE reports a file-write lock.

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
  main.odin       entry point, window loop, date navigation
  tracker.odin    foreground polling, idle/away state, activity lifecycle
  win32.odin      Win32 bindings, time helpers, version info, group identity
  db.odin         SQLite schema/repository, ManicTime-compatible dates
  sqlite.odin     SQLite C bindings
  ui.odin         raygui/raylib timeline and summary
  importer.odin   JSON import command
tools/
  export-manictime.ps1
vendor/
  sqlite/         SQLite 3.54.1 amalgamation + static lib
  raylib/         raylib.dll for runtime
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
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Tracker, persistence, and UI internals |
| [`docs/DATABASE.md`](docs/DATABASE.md) | Schema, date/group semantics, example queries |
| [`docs/MANICTIME.md`](docs/MANICTIME.md) | Reverse-engineering notes from the original app |
| [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) | Toolchain, build, debugging, common failures |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Next features and technical debt |
