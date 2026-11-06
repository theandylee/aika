# Architecture

This document describes how aika actually works. It is the detailed companion
to `AGENTS.md`.

## Process model

aika is a single-process, single-threaded Win32 GUI application built with Odin
and native Win32/GDI drawing (no windowing toolkit, no OpenGL).

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
| `db_load_activities` | Load a day for timelines 1, 2 and 3 |
| `db_load_tags` / `db_ensure_tag` | List tags / reuse or create a tag group |
| `db_resize_tag` | Update both bounds and all timestamp fields of a tag |
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

The UI loads **1**, **2**, and **3**.

## UI

The GUI is split across two files:

- `src/winui.odin` — the native window layer: window class + `wnd_proc`, a 500 ms
  `WM_TIMER`, a double-buffered memory DC (all painting happens offscreen and is
  `BitBlt`-ed once), the filter EDIT control, mouse/keyboard hit-testing, and
  small GDI helpers (`fill_rect`, `line_v`/`line_h`, `draw_string` with ClearType
  text and ellipsis truncation).
- `src/ui.odin` — the ManicTime-style Day view renderer: tab strip, toolbar
  (prev/next/Today, Start/Stop task, Day start / Day end / Duration boxes), a
  full 24 h ruler, four lanes (Tags, Computer Usage, Applications, Documents),
  the details list, the totals panel, tooltips, filter row and status bar.

Layout constants (`TAB_H`, `TOOLBAR_H`, `LANE_*`, `LIST_*`, ...) live at the top
of `src/ui.odin`; `compute_layout()` derives every rect from the client size, so
the window resizes correctly. Repaints are on-demand: the timer invalidates
every 500 ms (which also drives the 1 Hz tracker sampling inside
`tracker_tick`), and mouse movement/hover invalidates too. Palette constants
are `COLORREF` literals (`0x00BBGGRR`).

Odin note: `wnd_proc` uses a non-default calling convention, which makes it
contextless; it starts with `context = rt.default_context()`. All paint-time
allocations (UTF-16 text conversions, row lists) use `context.temp_allocator`
and are released by the `free_all` after each message in `main`.

### Timeline

Closing the main window hides it to the system tray; its timer keeps tracking.
Click the tray icon or choose **Open aika** to restore it. The tray menu's
**Exit** destroys the window, removes the icon and flushes tracking through the
normal shutdown path. Explorer restart notifications re-register the icon.
If icon registration fails, the window stays accessible instead of hiding.

`draw_day()`:

- Uses the full local day 00:00–24:00 as the fixed axis (ManicTime-style);
  `x_for_ms()` maps a timestamp to a pixel position.
- Draws Tags, Computer Usage and Applications lanes. The selected lane gets the
  orange ManicTime frame and drives the details list and totals panel.
- Draws application bars (stored/exported group colors) and computer usage bars
  (green = Active, orange = Away).
- Draws the live current-activity overlay and the growing usage bar.
- Draws a red "now" line when the selected date is today.
- Shows a tooltip for the innermost bar under the mouse.

### Time tags

`src/tags.odin` owns drag state and the native tag-picker window. Dragging in the
Tags lane previews a range mapped through the visible zoom bounds; either drag
direction works. Release opens a searchable EDIT/LISTBOX picker with Use tag,
Create tag and Cancel buttons. The owner is disabled while the picker is open,
but its timer continues sampling. The main message loop routes picker keyboard
input through `tag_picker_key` and `IsDialogMessageW`.

Tags use timeline 1, one group per tag and one activity per block. Creation of a
new group and block is transactional. The picker reuses names case-insensitively,
including imported groups. Resize handles have a six-pixel hit tolerance;
clipped edges are not handles. Captured drags preview in memory and update the
database only on release; Escape or loss of capture discards the preview.
Ranges do not snap; crossing edges is prevented. New selections use the first
contiguous free interval in the drag direction: wholly occupied drags do
nothing, drags starting inside a block begin at its exit edge, and selections
stop at the next block. Resize edges stop at neighbors. Creation checks for
overlaps within its transaction; resize uses an atomic SQL overlap guard.
Imported overlaps are left untouched. No schema migration is required.

The main window enables `CS_DBLCLKS`. Double-clicking empty space between two
tags selects the complete bounded gap and opens the same tag picker; the exact
neighboring timestamps are used, even when the view is zoomed. Occupied space
and gaps without a block on both sides are not auto-filled. Cancel still saves
nothing, and creation uses the normal transactional overlap check.

Right-clicking a tag block opens a native popup menu with Delete. Hit testing
uses rendered pixel bounds (including clipped and one-pixel blocks). Deletion
is restricted to timeline 1, removes only the selected activity, preserves its
group for reuse, and reloads the list/totals. The menu retains an activity ID,
not a pointer into the day cache, since timer reloads can occur in its nested
message loop. Cancelling the menu makes no changes.

### Running tasks

The toolbar's **Start task** opens the same searchable tag picker (including
tag creation). Accepting starts a new Tags block at the current time and
selects today's Tags lane. Cancelling does not start anything. The button
becomes **Stop task** with an elapsed `h:mm:ss` timer; application tracking
continues independently.

`src/task.odin` persists the block every second and updates its cached endpoint
for the timeline, details, tooltips and totals. Stop and graceful exit flush the
final endpoint; hiding in the tray keeps the task running. A forced kill leaves
the last saved endpoint, and tasks do not automatically resume on restart.
Active task blocks cannot be resized or deleted until stopped. Existing future
tags stop the task at their boundary rather than allowing overlapping blocks.

### Details list and totals

`build_rows()` (temp-allocated) builds the row list for the selected lane,
respects the filter string, and includes the unpersisted current activity.
`draw_list()` renders Title / Start / End / Duration columns with vertical-wheel
scrolling. `build_totals()` aggregates timeline activities by `group_id` for the
selected lane, sorted by duration; `draw_totals()` renders the totals panel with
color chips and a pinned `Total: h:mm:ss` line.

`src/panes.odin` provides captured drag splitters below the timeline zoom bar
and between the list and totals. The horizontal divider changes all three lane
heights together; the vertical divider trades list width for totals width.
Sizes are retained for the current session and clamped to usable minimums on
window resize. Escape or capture loss restores the sizes from before the drag.

### Header and footer

- Date navigation (`<`, Today, `>`).
- Start/Stop task with elapsed timer.
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
- **Odin + native Win32/GDI.** Small native binary, immediate-style painting, no
  .NET runtime, and no OpenGL driver cost — a running window uses roughly 6 MB
  of private memory.
