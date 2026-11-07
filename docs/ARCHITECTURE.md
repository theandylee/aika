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
  ui_bootstrap()          // checked; partial failure unwinds
  GetMessage/dispatch:
    WM_TIMER -> tracker_tick() / task_tick() / maybe load_day()
    WM_PAINT -> draw_frame()
    each native callback owns independent scoped scratch
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
- `monotonic_ms()` — `GetTickCount64` milliseconds for scheduling (not a date).
- `unix_ms_to_local()` / `unix_ms_to_utc()`.
- `local_systemtime_to_unix_ms()` — respects the current DST rules.
- `manic_date_from_date_int()` / `date_int_from_manic_date()`.
- `day_bounds_ms(date_int)` — local midnight to next local midnight.

Intervals and days are half-open `[start, end)`: next midnight is the exclusive
day end, with no minus-one-millisecond adjustment. Day queries require UTC overlap
(`start < day_end && end > day_start`) as well as the local-date prefilter.
Repository activity insertion and endpoint updates reject `end < start`; tag
ranges remain strictly nonempty. Existing invalid history is not repaired, and
this is a repository contract, not a new SQL CHECK constraint/schema migration.

The local date is intentionally computed with the Windows timezone API rather
than by dividing UTC milliseconds by 86400000. This avoids off-by-one-day bugs
around midnight and DST.

## Focus tracking

### Entry point

`tracker_tick()` is called every frame but returns unless at least 1000 ms have
elapsed on its injected monotonic clock since the last sample. Five-second live
insertion and ten-second write throttles also use monotonic elapsed time. The
day reload timer and task save throttle use monotonic time too; stored endpoints
remain UTC wall-clock instants.

A UTC delta differing from monotonic elapsed time by more than two seconds is a
clock discontinuity. The tracker closes the old application/usage at the previous
observed UTC instant and starts a new spell at the new instant, without filling
the jump. Pause/Exit apply the same check even before the next timer. Backward
jumps can therefore leave distinct spells overlapping in UTC; prior history is
not shifted, deduplicated or rewritten to pretend UTC never changed. DST alone
does not cause such a jump because stored time is UTC. Sleep/delayed timers with
matching elapsed clocks are not classified as clock changes.

A running task stops at its last acknowledged endpoint on a discontinuity rather
than stretching a tag across it; the user can start another task afterward.

It first determines the usage state:

```odin
idle := idle_ms()
desired := .Away if idle >= idle_threshold_ms else .Active
```

`idle_ms()` uses `GetLastInputInfo` plus `GetTickCount64` and handles the 32-bit
tick-count wrap. The default idle threshold is 60 seconds without keyboard or mouse
input. `src/settings.odin` provides a native Settings window (top-right button or
tray menu) with a Tracking page and a validated 1–500 minute timeout. OK saves the
integer minute value in `<database path>.settings` and applies it on the next
tracker tick; Cancel, Escape and window close discard edits. Missing or invalid
preferences fall back to one minute. The owner is disabled while settings is open,
but its timer continues tracking. Tab, Enter and Escape are handled through the
main message loop, without a separate modal loop. The window follows the palette.

### Active state

`poll_focus()`:

1. `GetForegroundWindow()`
2. `GetWindowThreadProcessId()`
3. `GetWindowTextW()` to get a fresh title; the title is never cached
4. Open a limited-query process handle, read creation time with
   `GetProcessTimes`, and close it; PID alone cannot identify a cached process
5. On cache miss/expiry, `QueryFullProcessImageNameW()` gets the executable path,
   followed by `GetFileVersionInfoW` + `VerQueryValueW` to get:
   - `ProductName` (used as the group display name)
   - `CompanyName`
   - `FileDescription`
6. Fall back to the resolved application name when the title is empty.
7. On cache miss/expiry, build the group identity:
   ```
   key      = lowercase(file_name + ";" + product_name)
   key_hash = Base64(SHA256(key))
   textData = <ApplicationGroupTextData>...</ApplicationGroupTextData>
   ```
8. Resolve `(group_id, color)` once per cache entry with `db_ensure_group()`;
   a failed lookup retries on the next sample without rereading valid metadata.
9. Compare with `tracker.current`:
   - same `group_id` and same `title` → extend current activity, no new row
   - otherwise → finish current, start a new one

The tracker does **not** persist process IDs, window handles, class names, or
monitor IDs. The window title is the only per-window discriminator.

### Foreground metadata cache

`src/focus_cache.odin` retains one process instance, not an unbounded PID map or
multi-process executable cache. Every 1 Hz sample reads the foreground window,
PID and title, and independently opens/closes a process handle to validate its
creation FILETIME. A changed PID or creation stamp invalidates the entry. Changing
windows/titles in the same process does not require metadata I/O. Conversely,
different processes with the same application identity/title remain the same
activity: the final comparison is still `(group_id, title)`, not PID or HWND.

Metadata and group ID/color refresh after 60 monotonic seconds (including changes
to version resources or group colors). Switching to another process replaces the
one entry; returning to the earlier process reads it again. The metadata reader
validates the creation stamp again on its own handle before reading the path,
preventing a PID-reuse race between the initial probe and a miss. No handles are
retained. Group IDs are scoped to the associated SQLite connection.

The entry owns path/filename/product/company/description, the group hash and XML;
window handles and titles are borrowed only for a sample. Successful shutdown or
final tracker release frees the entry. Pause can retain it, but resume still probes
the process and checks expiry. Test callbacks can inject each stage independently;
the older full-WindowInfo callback deliberately bypasses the cache for lifecycle
tests.

Missing optional version resources/strings are a legitimate cacheable filename
fallback. Process/path/version I/O failures and unverified identities are not
cacheable: existing fallback tracking continues uncached and retries at the next
sample. DB failures retain valid metadata/hash/XML but never cache failed group
IDs. There is no new hook, per-window tracking scope, sampling rate, group-key
algorithm or persistent schema change.

### Inactive state

When the user becomes idle:

- The transition time is backdated to `now - idle_threshold_ms`, matching
  ManicTime's "away" semantics.
- The cutoff is clamped to the current Active spell's start, never an earlier
  session. The transition uses one `BEGIN IMMEDIATE` transaction: replay pending
  writes using tentative IDs, persist the current portion before the cutoff,
  trim earlier owned application rows that cross it, delete owned rows beginning
  within the Away interval, finish Active, and insert Away through the observation.
- Ownership is explicit: application IDs inserted by this tracker spell are
  retained in memory, and pending writes retain their spell identity. Imported,
  legacy, previous-session and previous-clock-spell rows are never adopted just
  because their timestamps overlap. The ID list is released on Away, a new Active
  spell, or successful shutdown; it uses one ID per application row in the spell.
- Any write/commit failure rolls back the entire transition. Live state, queue
  ownership and acknowledged IDs remain unchanged; sampling is held while the
  frozen transition retries. Normal Exit cannot bypass it. Queue contents and
  frozen transitions remain memory-only and can be lost on forced termination.
- A current activity beginning at/after the cutoff is discarded, not finalized
  with a negative duration. A positive portion before the cutoff is retained even
  if shorter than five seconds; idle reconciliation is not a transient switch.

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
  - duration < 5 s and not forced → extend the immediately adjacent predecessor
    within this Active spell (including a queued predecessor); return the actual
    switch time, never backdate the next activity
  - if there is no predecessor, omit the short sample without bridging a gap;
    if the lookup fails, retain it as a standalone sample instead of losing it
  - duration ≥ 5 s and not yet persisted → insert one row
  - already persisted → update end time
- `extend_current(now)`:
  - if not persisted and duration ≥ 5 s → insert
  - if persisted and 10 s since last write → update end time
- `tracker_shutdown()` calls `finish_current(..., force_save = true)`.

Quick-return reuse is limited to rows owned by this spell and nonnegative gaps
of at most one second, with no pending writes. It never adopts imported rows or
bridges pause/Away/clock boundaries.

The UI projects the current interval into a shared day snapshot, so every view
grows before and after the 5-second persistence threshold, without a separate
bar-only overlay.

### Effective day snapshot

`src/activity_snapshot.odin` owns the presentation contract. Once per Day paint,
`draw_frame` captures UTC/monotonic time and builds a scratch-allocated
`Day_Snapshot`. Bars, details, flat/tree totals, tooltips, overview and day-span
boxes all consume that same snapshot. The builder performs no database queries,
clock reads or source-state mutation; input strings remain borrowed for the draw.

It starts with the selected-day cache, overlays queued writes by activity ID,
then overlays the live application, ComputerUsage and running task. Missing live
rows are added even when persisted but not yet loaded. Unsaved intervals get
distinct negative presentation-only IDs, never database IDs; unresolved usage
groups get distinct synthetic identities until the repository resolves them.
Rows are ordered by full start/ID, preserving distinct switches with identical
titles/groups. The snapshot rejects empty/reversed displayed intervals and clips
by overlap, not by the activity's start date. Full source bounds remain available
separately from selected-day bounds. Zoom clips geometry only, not daily totals.

The live endpoint is frozen at the last observed instant on an unprocessed clock
jump, or at the frozen observation while an idle transaction is held for retry.
Tasks use their acknowledged endpoint rather than guessing growth beyond a future
tag neighbor. The task owns its name/group/color for snapshots missing its cached
row; `task_clear` releases that metadata on every stop/error path.

Successful tracker/task writes update the selected-day cache immediately with
owned metadata and acknowledged endpoints. Completed intervals therefore do not
disappear between a queue/current transition and the next 10-second reload.
An idle transaction suspends cache writes until COMMIT, then publishes its staged
writes and owned-row trims/deletions together; rollback leaves the cache alone.
Periodic reads replace the cache only on success and never fabricate live ends.
The initial cache date is established before the first read so subsequent local
writes remain presentable even if that historical baseline read fails.

Details/list times, totals and tooltip durations use displayed-day bounds; the
exclusive end of a full day is labeled `24:00`. Tooltip/tag hit tests use the same
half-open pixel rectangles and paint order, including one-pixel bars. An active
tag drag is intentionally a separate, uncommitted bar preview; it does not change
saved/list totals before confirmation. Filtering retains its existing per-view
title/group-name behavior.

This is a correctness projection, not a derived-view cache: snapshot arrays/maps
are rebuilt per paint, and new write-through cache rows currently copy the day
array. Their lifetime is bounded by the paint callback's independent scratch scope.
Derived-view caching and array-capacity changes remain deferred pending
measurements. Step 6 optimized latest-row/task-neighbor queries; the later
follow-ups split the day load into a start-time seek plus the partial
`IX_Activity_Long` index (audit #14), reuse prepared statements on measured
hot paths (audit #17), and add the bounded foreground metadata/group cache
above (audit #13).

## Persistence layer

`src/db.odin` is a small synchronous SQLite repository.

`src/db_tags.odin` owns tag/task business transactions; UI and task lifecycle code
do not issue SQL, bind parameters or manage BEGIN/COMMIT/ROLLBACK. Timestamp writes
share `db_bind_time` in `src/db_time.odin`, which binds local day/time, UTC time and
UTC milliseconds from one instant. Explicit column mappings support normal
insertion, end-only updates, tag resizing and guarded import insert/update layouts;
every binding result is checked before stepping the statement.

Failed opens close their handle and owned path before returning an empty DB.
Cleanup is idempotent. The additive `(TimelineId, StartUtcMs, ActivityId)` index
supports latest-row ordering and task-boundary seeks, and day overlap reads
(`LOAD_ACTIVITIES_SQL`): ordinary rows by a bounded start-time seek, rows longer
than `LONG_ACTIVITY_MS` through the small partial index `IX_Activity_Long`, merged
with `UNION ALL`. Day-load cost follows the day's size, not history age; the
older date-index query survives only as a test oracle. See `DATABASE.md`.

Measured hot statements (importer group/row paths, tracker insert and end-time
update) borrow prepared statements from a fixed-slot cache (`Stmt_Slot`,
`db_lease`/`db_release` in `src/db.odin`). The cache is a heap object reached
through `DB.cache`, valid only while `cache.handle == db.handle`, so copied `DB`
values share it and a foreign handle never uses it. Each lease is reset and
cleared on release, a re-entered slot falls back to a one-off statement, and
`db_close` finalizes every slot before closing the connection. All other
statements still use `db_prepare` + `sqlite3_finalize`.

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
| `db_create_tag_block` / `db_start_task` | Atomically resolve tag identity/color and create a nonoverlapping block |
| `db_extend_task_until_boundary` | Validate the task owner, find neighbors and resize within one transaction |
| `db_ensure_group` | Lookup/insert group by `(timeline, key hash)` |
| `db_usage_group` | Get the seeded Active/Away/etc. group id |
| `db_import_group` | Resolve group by timeline/key; preserve existing metadata |
| `db_import_activity` | Allocate/map local IDs; guard source updates against local edits |

### Persistence failures and retries

Tracker activity writes and the day/tag/latest/group reads return `DB_Result`:
`Ok`, `Not_Found`, `Busy`, or `Failed`. Successful empty lists are `Ok`.
Activity insert/update success requires an affected row; acknowledgments advance
only after success. Day/tag list readers discard partial results on error.
`load_day` replaces the cache only after a complete read; failed navigation keeps
the previous loaded date and data. Automatic failed-read retries are limited to
once per second.

Tag/task repository operations return `DB_Tag_Result`: `Ok`, `Overlap`, `Invalid`,
`Not_Found`, `Busy`, or `Failed`. A storage failure is not evidence of occupied
time. Block creation acquires `BEGIN IMMEDIATE`, checks overlap, creates/reuses a
case-insensitive tag name or validates a selected Tags group, reads its color,
inserts and commits. Its returned ID/metadata are zero on failure. The picker
retains its selection on storage failure; actual overlaps keep the prior
dismiss/reload behavior.

Task extension holds the same writer transaction for reading the saved task and
nearest future tag, checking the resulting interval and resizing all timestamp
fields. A stale start, non-Tag ID or request to overwrite a newer saved endpoint
is rejected. Failed writes or COMMIT leave both task acknowledgement and cached
endpoints unchanged. The lifecycle still handles monotonic throttling, clock
jumps, metadata ownership and cache publication after the repository succeeds.
Exact-boundary acknowledgement leaves the task active until a later request
passes that boundary, preserving the existing behavior. No schema change or
automatic edits to unrelated/imported overlaps are introduced.

The GUI disables SQLite's busy sleep after DB startup; the CLI/import retains
the startup timeout. All operations remain on the main thread. Live application
and usage failures retain their original start and retry on subsequent ticks.
Failed final writes transfer their title and exact interval into the owned queue
in `src/tracker_writes.odin`, allowing the next foreground activity to proceed.
Rows with pending final writes are not reused by quick-return merging.

The queue holds at most 256 entries. A tick retries up to four entries, stopping
on the first failure. Space is reserved to finalize both live intervals before
the queue fills; tracking then pauses and shows a warning instead of dropping
writes or accumulating unbounded memory. It automatically resumes with new
intervals after the queue drains; the suspended period is not tracked. The status
bar and window title retain save/load warnings while the problem persists.
Normal tray Exit is cancelled when final tracker writes cannot be saved, leaving
the process available to retry. Pending writes are in memory, not a crash journal:
a forced kill during an outage can lose them. Task/tag actions retain their
existing direct error reporting rather than joining the tracker retry queue.

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
  full 24 h ruler, three lanes (Tags, Computer Usage, Applications),
  the details list, the totals panel, tooltips, filter row and status bar.
- `src/date_picker.odin` — a palette-colored native owner-drawn button showing
  the selected weekday/date and a calendar icon. It opens a non-modal native
  month calendar below the button; clicking a day or pressing Enter navigates,
  while Escape or deactivation dismisses without changing the date. The calendar
  selection is synchronized on open and after prev/next/Today navigation.

Layout constants (`TAB_H`, `TOOLBAR_H`, `LANE_*`, `LIST_*`, ...) live at the top
of `src/ui.odin`; `compute_layout()` derives every rect from the client size, so
the window resizes correctly. Repaints are on-demand: the timer invalidates
every 500 ms (which also drives the 1 Hz tracker sampling inside
`tracker_tick`). Mouse movement invalidates only when the frame would change
(`src/hover.odin`): each paint records a `Hover_Signature` (bitmask of the
hover-drawn rectangles under the cursor plus the hovered timeline row), and
`WM_MOUSEMOVE` repaints when the signature at the new position differs, or on
every move while the cursor-following timeline hint is painted or about to be.
Over empty lane space the hint is just the under-cursor time; over a block it
adds the block's usual rows beneath the time. Drags invalidate on their own paths.
Hover repaints are **partial**: while the only change is the cursor line and
hint, `hover_dirty_rect` invalidates the union of what the last frame drew
(`ui.hover_rect`, recorded by `draw_cursor_line`/`draw_tooltip_lines`) and
everything the next one can draw (the line column plus a bound from
`TOOLTIP_MAX_W` and four hint rows). `WM_PAINT` clips the back buffer to
`rcPaint`, publishes it as `ui.paint_rect`, and `draw_day` skips the tabs,
toolbar, ruler, lanes, zoom bar and list/totals panes that `paint_needs` says it
does not touch (their scrollbar/state updates only matter after a full
invalidation). Rules: any other hover-dependent drawing must either flip a
`Hover_Signature.targets` bit (which forces a full invalidate) or be inside the
dirty rect; every non-hover state change must invalidate with a nil rect; a
hint taller or wider than the bound must raise `TOOLTIP_MAX_W`/the row count in
`hover_dirty_rect` (`src/hover_dirty_test.odin` checks coverage). The day
snapshot is not cached: building it is ~16 us per paint.
`TrackMouseEvent` delivers
`WM_MOUSELEAVE`, which clears hover visuals. Theme values live in one
`Palette` struct (`src/palette.odin`) with named semantic fields and two constant
instances, `PALETTE_LIGHT` and `PALETTE_DARK`; there are no positional arrays. The
drawing code reads `C_*` variables (`C_BG`, `C_TXT`, ...) that `palette_apply`
assigns from the active palette, so `theme_set_palette` in `src/theme.odin` is a
one-liner and call sites did not change. `C_ACCENT/GREEN/ORANGE/RED` are fixed
constants shared by both themes. Fields that reuse another field's value for a
different purpose have their own names (`splitter_hot`, `tag_preview`,
`section_head` all equal `button_hover` today), and `zoom_selection` is themed.
Adding a color means one struct field, one value per palette, one `C_*` variable and
one line in `palette_apply`; `palette_is_applied` (tested) catches a forgotten
assignment. The toggle is saved beside the selected database as
`<database path>.theme`. Dark buttons and tabs use GDI rather than light UxTheme
drawing; stored activity colors are unchanged.

Two color types meet in `src/colors.odin`: `Colorref` (= `windows.COLORREF`,
`0x00BBGGRR`, what GDI draws with) and the distinct `Argb` (`0xAARRGGBB`, what
`"Group".Color` stores and rows carry; 0 = unset, so the renderer derives a color
from the group id). `argb_to_colorref` is the only crossing and keeps 0 as 0;
`colorref_r/g/b` read channels; `bar_text_color` picks dark or light text for tag
fills from named luma weights/threshold. The remaining fixed colors (live-bar
outline, paused-tracker dot) are named there too.

Geometry shared by drawing and hit-testing is computed once in
`src/geometry.odin` (`lane_rect`/`lane_at`, list and totals pane rectangles, the
totals rows area and row index, the list column edges, tooltip rectangles and the
cursor-following tooltip origin). Hit tests, wheel routing and painting call the
same helpers, and `geometry_behavior` checks they agree with the previous inline
expressions.

Odin note: native callbacks use a non-default calling convention and start with
`context = rt.default_context()`, then install a fresh `Scratch` allocator and
defer its destruction. Each arena allocates lazily, uses runtime map-cache-line
alignment, and is independent of suspended outer callbacks. Never clear a shared
temp allocator in a nested callback. Main's key routing has a separate scope.
Persistent strings/cache data use the normal allocator; scratch cannot escape.

Bootstrap checks required classes/windows/controls/fonts, initial backbuffer and
timer, and unwinds every acquired stage on failure. Shutdown is repeatable.
Backbuffer replacement acquires DC/bitmap/selection before releasing the previous
buffer; failed resize paints a direct error fallback and retries on later paints.
Final tracker teardown releases owned metadata without acknowledging lost writes.

### DPI and keyboard policy (audit #24)

The manifest declares Per-Monitor V2 (`assets/aika.manifest`). All design
metrics (`TAB_H`, `LIST_ROW`, ...) are 96-DPI pixels; `dpi_px` in
`src/dpi.odin` converts them centrally (`(base*dpi + 48)/96`, identity at 96
DPI, so existing layout tests are unchanged). Fonts are rebuilt from scaled
heights, stored pane sizes rescale across moves, `WM_DPICHANGED` adopts the
suggested rect and invalidates, and the minimum tracking size scales.

Keyboard scope is minimal native-only by design: Tab cycles the filter EDIT
(now `WS_TABSTOP`), the date-picker button and the scrollbars via
`IsDialogMessageW` on the main window; settings/tag dialogs keep their own
`IsDialogMessageW` routing. The custom canvas (tabs, toolbar buttons, zoom
bar, lanes, lists) stays mouse-only; `Escape` still cancels the active
interaction.

### Interaction state machine

One pointer interaction at a time lives in `ui.interaction` (`src/interaction.odin`),
a tagged union of `Press_State` (toolbar-style button held down), `Pane_State`
(splitter drag with pointer offset and a geometry snapshot), `Zoom_State`
(handle/overview/timeline drag with anchor and a view-range snapshot) and
`Tag_State` (new-range/edge drag with the resized block id). The window holds
mouse capture exactly while the value is non-nil. The selected tab, lane and
drag modes are enums (`Tab`, `Lane`, `Pane_Drag`, `Tag_Drag`, `Zoom_Drag`);
their declaration order is the former numeric order, and the totals-tree
expansion key still formats the lane as `int(lane)`. Hit-test results are a
`Hit` enum whose numeric values carry no meaning: use `hit_is_pressable`
(toolbar/zoom/theme/Settings/totals-mode buttons that press on down and act on
up) and the `hit_tab`/`hit_as_tab`, `hit_lane`/`hit_as_lane` helpers, never
ranges. Read the active kind through `pane_drag()`/`zoom_drag()`/`tag_drag()`/
`press_hit()` or `interaction_kind()`; there is exactly one
`interaction_active()` predicate, used by tooltips, wheel routing, pan/tag/zoom
entry points and the off-Day-tab gate.

Rules: `*_begin` stores the payload (snapshotting live geometry/view first),
then the caller takes capture. Commit (`interaction_end`) and every pointer-up
path set the value to nil BEFORE `ReleaseCapture`, because `ReleaseCapture`
sends `WM_CAPTURECHANGED` synchronously, which re-enters cancellation.
`interaction_cancel` is idempotent, never calls `ReleaseCapture` itself, rolls
pane geometry and the zoom range back to the payload snapshot, and only clears
the tag kind: the dragged range outlives the interaction in `tag_ui`
(`start_ms`/`end_ms` feed the picker, edge previews read them while active).
Timers, thresholds, window sizes, Win32 ids and shared geometry (tooltip box,
zoom bar, lane/list/totals rects in `src/geometry.odin`) are named in
`src/ui_consts.odin`, preferring `core:sys/windows` constants.

`wnd_proc` (in `src/winui.odin`) dispatches mouse input to one proc per message
(`on_mouse_move`, `on_set_cursor`, `on_mouse_wheel`, `on_mbutton_down/up`,
`on_lbutton_down/up`); the window procs stay contextless (`context =
rt.default_context()` + scratch) and the helpers are plain procs. Left-button
down/up ignore input while a `.Timeline` pan is active; down also ignores input
while any interaction is active (capture is held). Non-Day tabs expose only
shared tab/theme/Settings hit targets.

### Timeline

Closing the main window hides it to the system tray; its timer keeps tracking.
Click the tray icon or choose **Open aika** to restore it. The tray menu's
**Exit** destroys the window, removes the icon and flushes tracking through the
normal shutdown path. Explorer restart notifications re-register the icon.
If icon registration fails, the window stays accessible instead of hiding.
The icon uses a separate hidden top-level window for shell callbacks. Menu
tracking is deferred until the shell callback returns. The menu uses the visible,
enabled main window as its owner, or the Settings/tag-picker window when open;
only tray-only mode uses the hidden callback window as owner. This avoids
transferring activation to an invisible window while the app is visible. Mouse
capture is released before menu tracking. Open restores any open picker/settings
window too, and the menu stays available with the main window visible, hidden or
disabled by a picker.

`draw_day()`:

- Uses the full local day 00:00–24:00 as the fixed axis (ManicTime-style);
  `x_for_ms()` maps a timestamp to a pixel position.
- Draws Tags, Computer Usage and Applications lanes. The selected lane gets the
  orange ManicTime frame and drives the details list and totals panel.
- Draws application bars (stored/exported group colors) and computer usage bars
  (green = Active, orange = Away).
- Draws effective snapshot intervals, including live and retry-pending intervals.
- Draws a red "now" line when the selected date is today.
- Shows a tooltip for the last painted bar under the mouse, using the same
  half-open pixel bounds as rendering.

Middle-button dragging on the timeline ruler or lanes pans the visible time
range without changing its zoom level. Content follows the pointer and stays
within the selected day; the full-day view cannot pan. Capture keeps the drag
working outside the window. Release finishes; Escape restores the previous view.

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

`src/task.odin` persists the block every second and publishes its acknowledged
endpoint/metadata to the cache and shared snapshot. Stop and graceful exit flush the
final endpoint; hiding in the tray keeps the task running. A forced kill leaves
the last saved endpoint, and tasks do not automatically resume on restart.
Active task blocks cannot be resized or deleted until stopped. Existing future
tags stop the task at their boundary rather than allowing overlapping blocks.

### Details list and totals

`build_rows()` (temp-allocated) projects the selected lane from `Day_Snapshot`,
respects the filter string, and retains both full and displayed-day bounds.
`draw_list()` renders Title / Start / End / Duration columns with vertical-wheel
scrolling. `build_totals()` aggregates timeline activities by `group_id` for the
selected lane, sorted by duration; `draw_totals()` renders the totals panel with
color chips and a pinned `Total: h:mm:ss` line. It aggregates the same clipped
snapshot intervals, not independently loaded or extended activity data.

The small tree icon in the Totals header toggles a hierarchical view provided
by `src/totals_tree.odin`. Slash-separated names create nested groups; segment
whitespace and empty separators are ignored. Each group rolls up all descendant
time (plus any item named exactly like that group), with siblings sorted by
duration. Groups start folded; clicking a group row toggles it. Fold state is
retained per lane for the session, including across date changes and flat/tree
switches. Only visible rows count toward scrolling; the grand total always uses
the original flat totals so parent/child rows are never double-counted. Stored
names and activities are not modified.

`src/panes.odin` provides captured drag splitters below the timeline zoom bar
and between the list and totals. The horizontal divider changes all three lane
heights together; the vertical divider trades list width for totals width.
Sizes are retained for the current session and clamped to usable minimums on
window resize. Escape or capture loss restores the sizes from before the drag.

### Toolbar and status bar

- Date navigation (`<`, Today, `>`).
- Start/Stop task with elapsed timer.
- Day start / Day end / Duration boxes (ManicTime-style).
- Filter row with the native EDIT control.
- Status bar: local wall-clock date/time, a tracking-state dot (green while
  tracking, grey when paused, orange with a message on storage errors), and
  retained save/load warnings until the problem clears.

## Import pipeline

```
ManicTime.sdf
  -> tools/export-manictime.ps1 -SourceId database-id   (read-only SQL CE)
  -> JSON { sourceId, groups, activities }
  -> aika-cli.exe --import
  -> json.unmarshal into ImportFile
  -> db_import_group / db_import_activity
  -> ImportActivityMap (source database/id -> allocated local id)
```

The exporter converts `StartUtcTime`/`EndUtcTime` to Unix milliseconds. The
importer recomputes local date/time fields from those instants using the current
Windows timezone. This is correct when importing history on the same machine and
timezone.

`src/importer.odin` validates the entire file before beginning its
`BEGIN IMMEDIATE` transaction. Source activity/group IDs must be positive and
unique within the file; timestamps must be present and ordered, and nonzero group
references must resolve within the same source file/timeline. Empty group keys
are rejected rather than guessed from display names. Legacy JSON without
`sourceId` requires `--import-source`; a provided override must agree with the
payload. Source identities are explicit, case-sensitive labels for a database
generation, not paths or export timestamps.

`src/db_import.odin` never uses source IDs as local primary keys. Groups resolve
by `(TimelineId, Key)` without replacing existing metadata. Activities get fresh
local IDs and a persistent source mapping. Identical source payloads are no-ops,
even if a mapped row was edited locally. Changed source payloads update only if
the local row still matches its last imported fingerprint; otherwise the whole
transaction rolls back. Timeline/start changes for the same source ID are treated
as identity conflicts. Deletion sets the mapped local ID to NULL, retaining a
tombstone so reimports do not resurrect local deletions.

Parsed JSON/maps use an import-owned arena; SQL/conversion/fingerprint scratch
uses a separate arena reset after each completed row. Both are destroyed on
success or failure, including parse and commit failures. This still parses the
whole file in memory; it is not a streaming importer.

Schema version 0 upgrades additively to version 1 (`ImportActivityMap`). Existing
activities are not adopted by numeric IDs or content guesses. Old unprovenanced
imports can therefore duplicate on their first new import; no automatic repair
or deduplication of old history is attempted. See `docs/DATABASE.md`.

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
