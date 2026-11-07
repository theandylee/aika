# AGENTS.md — aika

This is the entry point for any agent working on **aika**, a Windows activity
tracker and timeline viewer written in **Odin + native Win32/GDI**.

Read this file first, then the focused docs it links to.

---

## 1. What the project is

aika is a ManicTime-style tracker:

- Polls the foreground window once per second.
- Records the application, window title, and time range.
- Stores a ManicTime-shaped SQLite database.
- Shows a day timeline and per-app summary.
- Imports existing ManicTime history from its SQL Server Compact `.sdf` file.

It is a **working MVP**, not a finished product. See `docs/ROADMAP.md`.

---

## 2. Quick start

```bat
:: from the repository root
build.bat
run.bat
```

Build outputs:

| File | Purpose |
|---|---|
| `build\aika.exe` | GUI build, Windows subsystem (no console) |
| `build\aika-cli.exe` | Console build for imports/scripting |

Default database: `data\aika.db` (relative to the working directory).
Override with `--db <path>`.

Import ManicTime history:

```powershell
powershell -ExecutionPolicy Bypass -File tools\export-manictime.ps1 -Days 7 -SourceId home-manictime-1
build\aika-cli.exe --db data\aika.db --import tools\manictime-export.json --quiet
```

Run checks before committing:

```bat
odin check src -vet
build.bat
```

---

## 3. Non-negotiable invariants

These have caused bugs before. Do not break them casually.

### Platform
- Windows only. The tracker uses `core:sys/windows` and direct Win32 calls.

### Foreground tracking
- Only the **foreground top-level window** is tracked. Do not add per-window or
  per-monitor tracking without a design discussion.
- The sampler runs at **1 Hz**. The UI refresh is independent.
- DPI is Per-Monitor V2: design constants are 96-DPI pixels, scale them
  centrally with `dpi_px`, never with per-feature factors. Keyboard scope is
  native-only (Tab through filter/date/scrollbars/dialogs); the canvas stays
  mouse-only and `Escape` cancels the interaction.
- Mouse-move repaints are partial (`hover_dirty_rect`, `ui.paint_rect`,
  `paint_needs`; see `docs/ARCHITECTURE.md`). Non-hover state changes must
  `InvalidateRect(..., nil, ...)`; anything hover-dependent beyond the cursor
  line/hint must set a `Hover_Signature.targets` bit or fit the dirty rect.
- Interaction state lives in one `ui.interaction` union (`Press`/`Pane`/`Zoom`/`Tag`
  with cancel snapshots); read it via `pane_drag()`/`zoom_drag()`/`tag_drag()`/`press_hit()`
  or `interaction_active()`, never parallel fields. Set it to nil BEFORE `ReleaseCapture`;
  `interaction_cancel` is idempotent and never releases capture itself.
- Every sample still reads foreground HWND/PID/title and validates process creation
  time. The one-entry metadata/group cache is keyed by `(PID, creation FILETIME)`,
  never PID alone; it expires after 60 monotonic seconds. Failed lookups are
  retried, not cached as permanent fallback identities. No process handle is held.
- A focus sample is considered unchanged only when
  `(group_id, window title)` match. Keep the comparison in `poll_focus`.
- No `SetWinEventHook` is used. It is polling by design.

### Activity lifecycle
- A new activity shorter than **5 seconds** is merged backward; do not persist
  every transient switch.
  Without an adjacent predecessor in the same Active spell it is omitted, not
  merged forward. Pause/Exit force-save; idle reconciliation preserves any
  positive pre-cutoff portion and trims/deletes all affected spell-owned rows.
- The current activity is held in memory and merged into the effective day
  snapshot, whether persisted yet or not. Do not draw separate live overlays.
- It is inserted once it reaches 5 seconds.
- Its `EndTime` is extended every **10 seconds** while active.
- On graceful exit, `tracker_shutdown` flushes the current activity.
- A forced kill can lose the last few seconds. That is accepted.
- Scheduling uses monotonic milliseconds; stored intervals/days are half-open
  `[start, end)` in UTC. A wall/monotonic delta mismatch over 2 seconds splits
  tracker spells and stops a running task at its last acknowledged endpoint.
- Idle reconciliation is transactional and retryable; never acknowledge IDs or
  clear pending/live ownership before COMMIT. Do not reconcile unrelated history
  based on timestamp overlap alone (especially after backward clock adjustments).
- Successful tracker/task writes update the selected-day cache only after
  acknowledgement/COMMIT. Database reads return saved endpoints, never `now`.
  Rendering uses one snapshot/time sample for bars, lists, totals and tooltips;
  keep full activity bounds separate from clipped displayed-day bounds.
- Tag/task creation and task boundary extension own their transactions in the
  repository, not UI/lifecycle code. Distinguish overlap from storage failure;
  only publish IDs, task ownership and cached endpoints after successful COMMIT.

### ManicTime database semantics
- `StartLocalDate` / `EndLocalDate` are **days since 2000-01-01**, not `yyyyMMdd`.
  This is the single easiest thing to get wrong.
- `Group.Key` is a **Base64 SHA-256 hash** of
  `lowercase(FileName + ";" + ProductName)`.
- `Group` is a reserved SQL word. Always quote it as `"Group"`.
- `Activity` stores BOTH local and UTC timestamps.
- `StartUtcMs` / `EndUtcMs` are aika extensions for fast rendering. They are not
  part of ManicTime's schema.
- Timeline IDs are fixed:
  - `1` = Tags
  - `2` = ComputerUsage
  - `3` = Applications
  - `4` = Documents

### Runtime / build
- The GUI is **native Win32 + GDI** (`src/winui.odin`, `src/ui.odin`): a
  registered window class, a double-buffered paint (memory DC -> BitBlt), a
  500 ms `WM_TIMER` that drives the tracker, and an EDIT control for the
  filter bar. No OpenGL driver is loaded; a full window costs ~6 MB private
  (the raylib/OpenGL version cost ~146 MB).
- SQLite is statically linked from `vendor/sqlite/sqlite3.lib`.
- Cached statements (`Stmt_Slot`, `db_lease`/`db_release` in `db.odin`) are only for
  measured hot paths: always `defer db_release`, rebind every parameter, and keep
  one SQL text per slot. Never `sqlite3_finalize` a leased statement; `db_close`
  finalizes the cache before closing the connection.
- The GUI build uses `-subsystem:windows`; the CLI build does not.
- Do not allocate the font codepoint array with `context.temp_allocator`; freeing
  it at function return hangs. Use the default allocator. (Legacy raylib note;
  kept for history.)
- Procedures with non-default calling conventions (WndProc) are contextless in
  Odin; start them with `context = rt.default_context()`.

---

## 4. Repository map

```
src/
  main.odin       Entry point, args, message loop, date load
  tracker.odin    Focus polling, idle/away state, activity lifecycle
  tracker_intervals.odin  Atomic idle reconciliation, short merges, clock endpoints
  tracker_io.odin Injectable time/idle/foreground/write callbacks for tests
  tracker_writes.odin  Bounded pending-write queue, outage pause, retry
  focus_cache.odin  Bounded process-instance metadata/group cache; no title caching
  activity_snapshot.odin  Effective day projection, daily clipping, write-through cache
  win32.odin      Win32 bindings, time/date helpers, version info, group identity
  db.odin         SQLite schema, repository, activity/group queries, import helpers
  db_import.odin  Import group resolution, guarded activity updates, provenance
  db_tags.odin    Transactional tag creation and task start/boundary extension
  db_time.odin    Shared local/UTC/date/millisecond timestamp binding
  sqlite.odin     SQLite C bindings
  winui.odin      Native window: WndProc, timer, GDI helpers, double buffer, hit tests
  ui.odin         ManicTime-style Day view drawn with GDI (lanes, list, totals, tooltip)
  ui_consts.odin  Named timers, thresholds, sizes, messages, control/pen IDs
  geometry.odin   Shared layout rects for drawing and hit-testing
  palette.odin    Named Palette struct, C_* mirror, fixed accents
  colors.odin     Colorref vs Argb, channel/luma helpers, fixed UI colors
  dpi.odin        Central Per-Monitor V2 scaling (dpi_px), DPI changes
  interaction.odin  One ui.interaction union (Press/Pane/Zoom/Tag), begin/end/cancel
  hover.odin      Hover signatures, on-demand mouse-move repaints
  panes.odin      Captured splitter drags for timeline/list-totals panes
  zoom.odin       Overview/timeline zoom and pan, wheel routing
  cursor.odin     Cursor shapes for hit targets
  filter_edit.odin  Native filter EDIT control behavior
  date_picker.odin  Native owner-drawn date button and calendar popup
  theme.odin      Light/dark toggle, palette/native control colors
  settings.odin   Native Tracking settings window and .settings file
  tags.odin       Time-range dragging, native searchable tag picker, tag resizing
  task.odin       Running-task lifecycle (tick/stop/flush, clock jumps)
  totals_tree.odin  Hierarchical totals from slash-separated names
  scratch.odin    Scoped reentrancy-safe scratch arenas for native callbacks
  importer.odin   JSON import command
  ui_test_harness.odin  Shared-test guard: ui/tag_ui/palette snapshot + test mutex
tools/
  export-manictime.ps1   Read ManicTime.sdf and write JSON
vendor/
  sqlite/         SQLite 3.54.1 amalgamation + MSVC-built static lib
docs/
  ARCHITECTURE.md
  DATABASE.md
  DEVELOPMENT.md
  ROADMAP.md
```

---

## 5. Data flow (one screen)

```
GetForegroundWindow (1 Hz)
  -> GetWindowThreadProcessId
  -> QueryFullProcessImageNameW
  -> FileVersionInfo: ProductName / CompanyName / FileDescription
  -> GetWindowTextW
  -> key = lowercase(fileName + ";" + product)
  -> group hash = Base64(SHA256(key))
  -> compare (group_id, title)
  -> CurrentActivity in memory
       -> after 5 s: INSERT Activity
       -> every 10 s: UPDATE EndTime
  -> UI reads activities for selected day
  -> DayView bars + summary
```

The detailed version is in `docs/ARCHITECTURE.md`.

---

## 6. Where to change what

| Task | Files |
|---|---|
| Change poll rate, 5 s rule, idle threshold | `src/tracker.odin` |
| Change Win32 calls / add process info | `src/win32.odin` |
| Change schema, queries, date encoding | `src/db.odin` |
| Change tag/task persistence | `src/db_tags.odin` (repository), `src/task.odin` (lifecycle) |
| Change SQLite binding | `src/sqlite.odin` |
| Change timeline rendering / layout | `src/ui.odin` (drawing), `src/winui.odin` (window, input, GDI helpers) |
| Change live/day interval presentation | `src/activity_snapshot.odin` |
| Change importer format | `src/importer.odin`, `tools/export-manictime.ps1` |
| Change startup / args / build behavior | `src/main.odin`, `build.bat` |

---

## 7. Verification checklist

After changes:

1. `odin check src -vet` passes.
2. `build.bat` succeeds and produces both EXEs.
3. Start `build\aika.exe`; the window opens and draws.
4. Wait at least 6 seconds; the current app appears in the summary and the
   database.
5. Query the DB read-only:

```powershell
@'
import sqlite3
from pathlib import Path
p = Path("data/aika.db").resolve()
c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
print("activities", c.execute("select count(*) from Activity").fetchone()[0])
for r in c.execute("select ActivityId,TimelineId,DisplayName,GroupId,StartLocalDate,StartLocalTime,EndLocalTime from Activity order by ActivityId desc limit 5"):
    print(r)
'@ | python -
```

6. Import test:

```bat
build\aika-cli.exe --db data\import-test.db --import tools\manictime-today.json --import-source manictime-sample --quiet
```

Expected: exit code 0, 202 activities for the sample file, 2745 groups.
New exports carry `sourceId`; legacy exports require `--import-source`. Reuse the
same ID for one source database generation, never an export filename or date.

7. Close the window to hide it in the system tray; verify tracking continues.
   Restore via the tray icon, then choose its right-click **Exit** option and
   verify the current activity is flushed.

---

## 8. Known limitations

- Session lock and power-off events are not implemented; only idle `Away`.
- Documents/URLs are not tracked.
- Folders, statistics, general activity editing, and autostart are missing.
- Tags support range creation, border resizing and right-click block deletion;
  tag-name deletion/renaming is not implemented.
- The UI draws Tags, ComputerUsage and Applications; Documents are not tracked.
- Import history assumes the same Windows timezone.
- The exporter depends on the installed ManicTime SQL CE assemblies.
- `aika` is not binary-compatible with `.sdf`; it is schema/semantics-compatible
  and uses a one-way importer.

---

## 9. Documentation index

- `docs/ARCHITECTURE.md` — how tracking, persistence, and UI work in detail.
- `docs/ODIN-PITFALLS.md` — compiler traps hit during the native-UI rewrite; read before touching `src/winui.odin` / `src/ui.odin`.
- `docs/DATABASE.md` — schema, ManicTime date/key semantics, example queries.
- `docs/DEVELOPMENT.md` — toolchain, build, debugging, common failures.
- `docs/ROADMAP.md` — next features with implementation notes.
- `README.md` — user-facing overview.
