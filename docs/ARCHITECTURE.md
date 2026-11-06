# Architecture

This document describes how aika actually works. It is the detailed companion
to `AGENTS.md`.

## Process model

aika is a single-process, single-threaded Win32 GUI application built with Odin
and raylib/raygui.

```
main()
  db_open()
  tracker_init()
  load_day()
  InitWindow()
  loop:
    tracker_tick()        // throttled to 1 Hz inside
    maybe load_day()      // every 10 s or after date navigation
    draw_frame()
    free temp allocator
  tracker_shutdown()
  db_close()
```

There is no background thread. All SQLite access, Win32 polling, and UI drawing
happen on the main thread. This keeps the data model simple and avoids locking
issues.

## Time representation

Three representations are used:

| Representation | Meaning | Where |
|---|---|---|
| `i64` Unix milliseconds | UTC instant | `start_ms`, `end_ms`, UI math |
| `SYSTEMTIME` | Local or UTC wall-clock | conversion helpers in `win32.odin` |
| ManicTime date int | Days since 2000-01-01 | `StartLocalDate`, `EndLocalDate` |

Key helpers in `src/win32.odin`:

- `now_ms()` — current UTC Unix milliseconds.
- `unix_ms_to_local()` / `unix_ms_to_utc()`.
- `local_systemtime_to_unix_ms()` — respects the current DST rules.
- `manic_date_from_date_int()` / `date_int_from_manic_date()`.
- `day_bounds_ms(date_int)` — local midnight to next local midnight.

The local date is intentionally computed with the Windows timezone API rather
than by dividing UTC milliseconds by 86400000. This avoids off-by-one-day bugs
around midnight and DST.

## Focus tracking

### Entry point

`tracker_tick()` is called every frame but returns unless at least 1000 ms have
elapsed since `last_tick_ms`.

It first determines the usage state:

```odin
idle := idle_ms()
desired := .Away if idle >= idle_threshold_ms else .Active
```

`idle_ms()` uses `GetLastInputInfo` plus `GetTickCount64` and handles the 32-bit
tick-count wrap.

### Active state

`poll_focus()`:

1. `GetForegroundWindow()`
2. `GetWindowThreadProcessId()`
3. `QueryFullProcessImageNameW()` to get the executable path
4. `GetFileVersionInfoW` + `VerQueryValueW` to get:
   - `ProductName` (used as the group display name)
   - `CompanyName`
   - `FileDescription`
5. `GetWindowTextW()` to get the title
6. Fall back to `Process.MainWindowTitle`-style behavior if the title is empty
7. Build the group identity:
   ```
   key      = lowercase(file_name + ";" + product_name)
   key_hash = Base64(SHA256(key))
   textData = <ApplicationGroupTextData>...</ApplicationGroupTextData>
   ```
8. `db_ensure_group()` returns `(group_id, color)`.
9. Compare with `tracker.current`:
   - same `group_id` and same `title` → extend current activity, no new row
   - otherwise → finish current, start a new one

The tracker does **not** persist process IDs, window handles, class names, or
monitor IDs. The window title is the only per-window discriminator.

### Inactive state

When the user becomes idle:

- The transition time is backdated to `now - idle_threshold_ms`, matching
  ManicTime's "away" semantics.
- The current application activity is finished at that time.
- If it was shorter than 5 seconds, it is discarded and the next activity is
  backdated instead.
- The current ComputerUsage activity is finished and replaced with `Away`.

When input resumes:

- The `Away` usage activity is finished at `now`.
- A new `Active` usage activity starts at `now`.
- `poll_focus()` starts a new application activity at `now`.

Session lock and power-off are **not** implemented yet. `UsageKind` already has
`SessionLocked` and `PowerOff` values so the data model can support them later.

## Current activity lifecycle

`CurrentActivity` is the in-memory state:

```odin
CurrentActivity :: struct {
    active: bool,
    persisted_id: i64,
    group_id: i64,
    group_color: u32,
    app_name: string,
    title: string,
    exe_path: string,
    start_ms: i64,
    last_db_update_ms: i64,
}
```

Rules in `src/tracker.odin`:

- `start_new_current()` stores cloned strings. It may merge with the last
  persisted row if the same app/title was just active.
- `finish_current(end_ms, force_save)`:
  - duration < 5 s and not forced → discard, return old start time
  - duration ≥ 5 s and not yet persisted → insert one row
  - already persisted → update end time
- `extend_current(now)`:
  - if not persisted and duration ≥ 5 s → insert
  - if persisted and 10 s since last write → update end time
- `tracker_shutdown()` calls `finish_current(..., force_save = true)`.

The UI draws the unpersisted current activity as an overlay, so the bar grows
even before the 5-second threshold.

## Persistence layer

`src/db.odin` is a small synchronous SQLite repository.

Important functions:

| Function | Purpose |
|---|---|
| `db_open` | Open/create DB, WAL, schema, seed |
| `db_insert_activity` | Insert a normal activity, return row id |
| `db_update_activity_end` | Update end local/UTC/ms fields |
| `db_delete_activity` | Delete one row (used by future merge logic) |
| `db_last_activity` | Most recent row for a timeline |
| `db_load_activities` | Load a day for timelines 2 and 3 |
| `db_ensure_group` | Lookup/insert group by `(timeline, key hash)` |
| `db_usage_group` | Get the seeded Active/Away/etc. group id |
| `db_import_group` | Import a group preserving ids/colors |
| `db_insert_activity_full` | Import an activity with explicit id |

Timeline IDs:

```
1  ManicTime/Tags
2  ManicTime/ComputerUsage
3  ManicTime/Applications
4  ManicTime/Documents
```

The UI currently loads **2** and **3** only.

## UI

`src/ui.odin` is immediate-mode raygui plus raylib drawing.

### Timeline

`draw_timeline()`:

- Gets day bounds via `day_bounds_ms()`.
- Gets an auto-fit view range via `compute_view_range()`:
  - includes all activities, current activity, current usage, and now
  - adds 15 minutes of padding
  - enforces a minimum 2-hour window
  - clamps to the selected day
- Draws a ruler with an adaptive step:
  - ≤ 2 h → 15 min
  - ≤ 4 h → 30 min
  - ≤ 8 h → 1 h
  - ≤ 14 h → 2 h
  - otherwise 3 h
- Draws application bars at one fixed lane height.
- Draws computer usage bars below.
- Draws a red "now" line on today.
- Shows a tooltip for the activity under the mouse.

### Summary

`draw_summary()` aggregates Activities from timeline 3 by `group_id`, clamps
each interval to the day, and sums durations. It includes the unpersisted
current activity. Top 10 apps are listed.

### Header and footer

- Date navigation (`<`, Today, `>`).
- Tracking pause/resume.
- Current window label.
- Activity count / idle time.
- DB path.

## Import pipeline

```
ManicTime.sdf
  -> tools/export-manictime.ps1   (read-only SQL CE)
  -> JSON { groups, activities }
  -> aika-cli.exe --import
  -> json.unmarshal into ImportFile
  -> db_import_group / db_insert_activity_full
```

The exporter converts `StartUtcTime`/`EndUtcTime` to Unix milliseconds. The
importer recomputes local date/time fields from those instants using the current
Windows timezone. This is correct when importing history on the same machine and
timezone.

## Deliberate design choices

- **Polling instead of hooks.** No global injection, no DLL, robust across
  hung apps. The cost is a 1-second blind spot.
- **Foreground only.** Matches ManicTime and avoids multi-monitor complexity.
- **SQLite instead of SQL CE.** SQL CE has no native API and is discontinued.
  SQLite is embedded, stable, and easy to query.
- **One-way import instead of `.sdf` writes.** Writing SQL CE without its engine
  is not realistic.
- **Odin + raygui.** Small native binary, immediate-mode UI, no .NET runtime.
