# Development

## Toolchain

| Tool | Tested version / path |
|---|---|
| Odin | `dev-2026-11-nightly:10e57eb` |
| GUI | native Win32/GDI via `core:sys/windows` (no external toolkit) |
| SQLite | 3.54.1 amalgamation, statically linked |
| C compiler for SQLite | MSVC 2022 (`cl.exe` 14.38) |
| PowerShell | Windows PowerShell 5.1 for the exporter |

Just put `odin` on `PATH`; the project does not require `ODIN_ROOT` to be set.
After updating the user PATH, restart existing terminals/apps so they inherit
the new location (the previous install used WinGet's package directory).

The November 2026 toolchain requires explicit allocators for
`os.read_entire_file` and `os.get_env`; file reads/writes return an error
(`nil` on success), not a success boolean. `mem.dynamic_arena_init` now takes
`minimum_alignment`, and Windows `BOOL` accepts boolean values rather than
integer literals. See [`ODIN-PITFALLS.md`](ODIN-PITFALLS.md) for migration details.

---

## Build

```bat
:: from the repository root
build.bat
```

`build.bat` runs (it changes to its own directory first):

```bat
odin build src -out:build\aika.exe -subsystem:windows -resource:assets/aika.rc
odin build src -out:build\aika-cli.exe -resource:assets/aika.rc
```

`aika.exe` is the GUI build (no console). `aika-cli.exe` is the console build for
imports and debugging.

Both executables embed `assets/aika.manifest` via `assets/aika.rc` to opt into
Common Controls v6 visual styles and Per-Monitor V2 DPI awareness (the window
handles `WM_DPICHANGED`; see `src/dpi.odin`). Keep the resource flag when
building manually; without it native controls revert to their classic
appearance and Windows bitmap-scales the window on high-DPI monitors.

Run:

```bat
run.bat
```

or:

```bat
build\aika.exe --db data\aika.db
```

---

## Historical note: raylib (removed)

The first UI was raylib-based, linked against `vendor:raylib`. It was replaced
by native Win32/GDI in the ManicTime-style UI rewrite (see
`docs/ARCHITECTURE.md` → "UI"). Two raylib-era notes that still teach something:

1. **Static `raylib.lib` defined `CloseWindow`**, colliding with
   `user32.lib` (`LNK2005`); the fix was `-define:RAYLIB_SHARED=true` plus
   shipping `raylib.dll`. Don't "fix" linker collisions with
   `/FORCE:MULTIPLE`.
2. The raygui post-mortem below is kept because its debugging method —
   bisecting with fresh binaries and verifying via screenshot pixel analysis,
   not impressions — applies to any UI work in this repo. The root cause was
   suspected to be an uninitialized `glyphWidth` in vendored raygui 4.0.

Transient unused imports were part of the raylib era; note that legacy
AGENTS.md guidance about the font codepoint allocator hang (`load_ui_font`,
removed with raylib) is kept in AGENTS.md for history only.

---

## The native Win32 UI

Before touching this code, read [`ODIN-PITFALLS.md`](ODIN-PITFALLS.md) — most
of the rules below (and the table of compiler traps) were learned by trial and
error during the rewrite.

The GUI is GDI drawing into a double-buffered memory DC. Points worth knowing
before touching it:

- `wnd_proc` (`src/winui.odin`) is `proc "std"` — contextless in Odin. It must
  start with `context = rt.default_context()` or calling context-ful
  procedures from it fails to compile (`'context' has not been defined within
  this scope`).
- Repaints are on-demand (`WM_TIMER` every 500 ms + input), not a render loop.
  Do not add a busy loop; the tracker samples at 1 Hz inside `tracker_tick`.
- Buttons and tabs use UxTheme drawing into the same GDI backbuffer, with a
  plain GDI fallback when visual styles are unavailable. Theme handles are
  reopened on `WM_THEMECHANGED` and released at shutdown. Toolbar buttons use
  mouse capture for pressed feedback and activate on release inside the button.
  These remain custom hit targets, not native keyboard-accessible controls.
- The top-right **moon / sun** icon button switches immediately (moon for dark,
  sun for light), with a hover tooltip describing the action. It
  saves the choice in `<database path>.theme`. Missing/invalid preferences use
  light mode. `src/theme.odin` manages the palette and native control colors;
  dark buttons/tabs use the GDI fallback rather than light UxTheme rendering.
  Activity/tag colors are preserved, with contrasting text on tag blocks.
  Native menus and tag-picker buttons retain Windows styling.
  `src/date_picker.odin` provides an owner-drawn native date button with the
  weekday/date label and a small GDI calendar icon. Its face and native calendar
  popup both follow the palette. The popup accepts a clicked date or Enter;
  Escape or clicking outside cancels. This replaces editable date segments and
  removes the duplicate weekday/date label beside the task button.
  `python tools/test-theme-ui.py build/aika.exe` checks switching, date-button and
  calendar colors, keyboard selection/cancellation, and theme persistence
  with an isolated database.
- Native callbacks install independent lazy scratch arenas and destroy them on
  return. Main key routing has a separate per-dispatch scope. Never `free_all` a
  shared allocator from nested callbacks/modal loops: suspended callers may still
  hold its data. Scratch uses runtime map-cache-line alignment; persistent data
  uses the normal allocator. Don't add default-allocator deletes of temp objects.
- Bootstrap failure unwinds acquired resources and exits nonzero. Backbuffer
  allocation is transactional: DC/bitmap/selection failure releases only the new
  partial buffer and paints an error fallback, never a stale-sized BitBlt.
- Colors live in one `Palette` struct (`src/palette.odin`) with named semantic
  fields; `palette_apply` mirrors the active palette into the `C_*`
  (`0x00BBGGRR`) variables the drawing code reads, and `theme_set_palette`
  in `src/theme.odin` only selects light vs dark. Semantic activity colors
  remain constants.
- `i32` vs `int` matters: loop counters and rectangle coordinates are `i32`,
  while `len()` and array literals produce `int`. Cast with `i32(...)` at
  call sites.
- Layout is computed by `compute_layout(w, h)`; the filter EDIT control is a
  real child window positioned in `recreate_backbuffer` on resize.
- Activity rows and totals have separate row-based scroll positions and native
  vertical SCROLLBAR children. Wheel input targets only the pane under the
  pointer; headers and the grand total stay fixed. Each scrollbar is hidden
  when its rows fit, and positions are clamped after filtering or resizing.
  `pane_scroll_update` synchronizes the native range with each rendered list.
- The Totals header's tree icon toggles slash-separated name grouping. Click
  group rows to expand/fold them; groups initially start folded. Expansion state
  is session-only and lane-specific. `src/totals_tree.odin` builds a temporary
  hierarchy without changing stored names. `odin test src -vet` checks rollups,
  normalization and nested visibility; `python tools/test-totals-tree-ui.py
  build/aika.exe` checks the native toggle, folding and scrollbar row counts.
- Drag the divider below the zoom bar to resize the timeline, or the divider
  between list and totals to change their widths. Minimum sizes keep the panes
  usable; sizes are session-only. Escape or capture loss cancels a drag.
  `python tools/test-panes-ui.py build/aika.exe` checks native splitter input,
  cancellation, and resizing using a temporary database.
- The timeline zoom overview (`src/zoom.odin`) sits below the lanes. Drag its
  orange edges to resize the visible range, drag inside to pan, or click outside
  to center the selection there. `+` / `-` zoom around the center; `Full day`
  resets the view. The mouse wheel over the timeline zooms around the pointer.
  Zoom affects the ruler, lanes, now marker, and tooltips, not the day-wide lists.
  The range stays selected when changing dates. `odin test src -vet` checks zoom
  limits, panning, layout, tick spacing, and variable-length local days.
- Before rebuilding, inspect running aika processes. Never kill a user's tracker
  to unlock its EXE; use alternate GUI/CLI output names and pass those to tests.
  Build sequentially because the resource compiler shares `assets/aika.res`.

### Invalid raygui captions (post-mortem, historical)

While scaling the old raygui-based UI, all `GuiButton` captions silently
stopped rendering (verified by screenshot pixel analysis, not by eyeballing).
Findings, usefully accurate for anyone touching UI text:

1. **Symptom was conditional and weird.** With `.DEFAULT` style writes captions
   rendered; adding **any control-level style write** made them vanish.
2. **The cause was never fully pinned down.** A real suspect: raygui 4.0's
   `GuiDrawText` leaving `glyphWidth` uninitialized in the `TEXT_WRAP_NONE`
   path, so every glyph was skipped.
3. **Bisect empirically, but beware stale binaries.** Results from *old*
   executables wasted the most time.
4. **Verify pixels, not impressions.** A screenshot crop plus a color
   histogram (`System.Drawing` in PowerShell) distinguishes "text drawn in the
   wrong color" from "text not drawn at all".

---

## SQLite

The repo includes a prebuilt static library:

```
vendor\sqlite\sqlite3.lib
```

It was built with MSVC. Rebuild only if you change SQLite version/flags.

The amalgamation source is not committed (it is in `.gitignore`), but it is
available locally in `vendor\sqlite\sqlite3.c` and `sqlite3.h`.

Rebuild with MSVC:

```bat
call "<Visual Studio install>\VC\Auxiliary\Build\vcvars64.bat"

cd /d <repo-root>\vendor\sqlite
cl /nologo /c /O2 /DSQLITE_THREADSAFE=1 /DSQLITE_OMIT_LOAD_EXTENSION /DSQLITE_DQS=0 sqlite3.c /Fosqlite3.obj
lib /nologo /out:sqlite3.lib sqlite3.obj
```

Do **not** build the static lib with the default LLVM/MinGW target. It emits
`___chkstk_ms` references that MSVC's linker cannot resolve:

```
sqlite3.lib(sqlite3.obj) : error LNK2019:
unresolved external symbol ___chkstk_ms referenced in function sqlite3_win32_write_debug
```

If you must use MinGW, build a DLL and generate an import library instead.

---

## Debugging

### Static checks

```bat
odin check src -vet
```

The project currently has zero vet warnings. Keep it that way.

### Pixel snapshots (refactor safety net)

`tools/pixel-snapshot.py` proves a refactor did not change rendered pixels. It
builds a synthetic temp database (fixed activities on *yesterday*, so no live bar
or now-marker), runs the exe with `--db` on a copy, and records the client area
(PrintWindow) for light/dark themes at 1320x860 and 900x600: every lane, the three
tabs, a list filter, totals tree mode and tooltip, zoom, and hovered controls and
tooltips. The status bar (wall clock) is masked. Each scene is captured twice
until stable, so results are deterministic.

```bat
git worktree add --detach %TEMP%\aika-head HEAD
:: build the baseline exe there (copy assets\aika.res if the worktree lacks it)
python tools\pixel-snapshot.py capture <baseline.exe> %TEMP%\snap\head
odin build src -out:build\snap.exe -subsystem:windows -resource:assets/aika.rc
python tools\pixel-snapshot.py capture build\snap.exe %TEMP%\snap\cur
python tools\pixel-snapshot.py compare %TEMP%\snap\head %TEMP%\snap\cur
```

`compare` prints each differing image with its differing-pixel count and bounding
box and exits 1 on any difference. Notes: hover scenes park the real mouse cursor
over the window (the app's `TrackMouseEvent` would otherwise clear synthetic hover),
so do not use the mouse while it runs (about 4 minutes); capture baseline and
candidate on the same calendar day (the date label is "yesterday"); delete the
alternate exes and `git worktree remove --force` the baseline when done.

### Console output

The GUI build is `-subsystem:windows`, so `fmt.println` may not appear when
launched from Explorer. To see logs:

- run `build\aika-cli.exe`, or
- launch `build\aika.exe` from an existing terminal and redirect stdout, or
- temporarily build without `-subsystem:windows`.

Do not leave debug prints in `draw_frame`; they flood.

### Database inspection

Use Python read-only:

```python
import sqlite3
from pathlib import Path
p = Path("data/aika.db").resolve()
c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
print(c.execute("select count(*) from Activity").fetchone())
for r in c.execute("select * from Activity order by ActivityId desc limit 5"):
    print(r)
```

If you need the current focused app at time T, see `docs/DATABASE.md`.

### Window not drawing / white window

Past causes:

1. The app hung inside `load_ui_font` because the font codepoint array was
   allocated with `context.temp_allocator` and `defer delete` at return.
   **Fix:** allocate with the default allocator.
2. A stale executable was running after a failed build. Rebuild and verify the
   exe timestamp.
3. The draw loop was blocked before `BeginDrawing`. Add one-shot prints at each
   stage, not per-frame prints.

### Focus tracking not recording

Check:

1. Is `tracker.enabled` true? There is no manual pause button: `enabled` is
   lifecycle state (automatic pause on write-outage queue exhaustion, resume on
   drain, cleared on shutdown). A grey/orange status-bar dot reports it.
2. Is the user idle? `idle_ms() >= configured timeout` switches to Away and stops
   app rows (default 1 minute; change it in Settings → Tracking).
3. Is the window title changing every couple of seconds? The 5 s rule discards
   short activities, so a rapidly changing title can produce no rows.
4. Is the app window itself foreground? aika records itself too.
5. Check stderr for `activity insert failed` / `group insert failed`.
6. Query `Activity` for timeline 3, not timeline 2.

### Import fails

- Use `build\aika-cli.exe`, not the GUI, to see output.
- `--quiet` suppresses the message box.
- Verify the JSON starts with `{"source":"ManicTime",...,"groups":[...`.
  A PowerShell `List[object]` serialized as `{"CliXml":...}` is invalid; the
  exporter must call `.ToArray()`.
- SQL CE read-only connections need `Temp Path=...`.
- Close ManicTime if SQL CE reports `FileWrite` / access denied.

---

## Coding conventions

- One package: all `.odin` files in `src/` are `package main`.
- No background threads. Keep DB and tracker access on the main thread.
- Use `snake_case` for Odin procedures/variables, `PascalCase` for types.
- Prefer explicit `i64` for timestamps.
- Keep Win32 bindings in `win32.odin`; do not scatter `foreign import` blocks.
- Keep SQL in `db.odin`; do not build SQL strings from user input.
- Free cloned strings when replacing `CurrentActivity` / loading activities.
  `free_activities()` is the existing pattern.
- Use `context.temp_allocator` for short-lived formatting; do not free from it
  manually (see font bug above).
- Quote `"Group"` in every SQL statement.

---

## Adding a feature

### New timeline lane

1. Add a `Timeline` seed row in `SEED_SQL`.
2. Add a `TIMELINE_*` constant in `main.odin`.
3. Extend `db_load_activities` to include the timeline id.
4. Add drawing in `ui.odin` (`draw_timeline`).
5. Add group seeding/lookup if the lane has fixed groups.
6. Update `docs/DATABASE.md`.

### New tracker event

1. Extend `UsageKind` or add a struct in `tracker.odin`.
2. Persist via `db_insert_activity` / `db_update_activity_end`.
3. Trim application activities on transition if appropriate.
4. Add UI rendering and a verification query.
5. Document the event's semantics and group key.

### New document retriever

1. Define a `DocumentInfo` equivalent in Odin.
2. Add a plugin registry ordered by priority.
3. Implement the Win32 retrieval (window hierarchy, UI Automation, etc.).
4. Insert a `DocumentActivity` on timeline 4 and a `DocumentGroup`.
5. Keep title-only tracking as the fallback.

---

## Testing checklist

Run `odin test src -vet` for zoom/tag interaction and tag persistence tests.
Tracker tests use per-instance `Tracker_IO` overrides (`src/tracker_io.odin`) for
time, idle duration, foreground samples, and activity writes, with an in-memory
database. Nil callbacks retain the production Win32/SQLite behavior. Keep the
injected clock synchronized with the timestamp passed to `tracker_tick`; see
`tracker_test_tick`. Activity writes return explicit `DB_Result` outcomes; failed
updates must not advance acknowledged timestamps. Tests cover completed-write
ownership, usage retries, queue exhaustion/recovery, and repeatable shutdown.
`src/text_test.odin` checks UTF-16 GDI measurement/rendering without a window and
tracks ownership over repeated filter conversions.
`src/resources_test.odin` checks nested scratch/map alignment, failed DB opens,
partial native startup at nine acquisition stages, transactional DC/bitmap/select
failures, repeated cleanup and owned pending/current metadata teardown. Shared UI
checks are independent @(test)s serialized by the `ui_test_mutex` in
`src/ui_test_harness.odin`, which snapshots and restores `ui`, `tag_ui`,
`global_app` and the active palette (also covering the opt-in view benchmark
when enabled). This includes placeholder hit targets and
all typed zoom cancellation modes. These are not exhaustive heap-OOM tests.
`src/db_test.odin` checks failed/ignored writes, missing versus empty results,
interrupted reads after a first row, and cache preservation on load failure.
`python tools/test-persistence-ui.py build/aika.exe` holds a real SQLite writer
lock against an isolated DB, checks UI responsiveness and error visibility,
verifies Exit cancellation while writes are pending, then releases the lock and
checks recovery and successful Exit. Native UI tests should run sequentially.
All native scripts build on `tools/native_ui.py` for process control, messaging,
waiting, and PID-scoped window/popup/menu
discovery, so another running aika instance cannot be selected by a global popup
lookup. `python tools/test-resources-ui.py build/aika.exe` seeds 900 synthetic
daily rows, cycles resize/Settings/tag popups, then measures 2,000 forced paints
inside a native tray-menu loop (private memory, GDI/USER objects, process handles).
Leave the desktop focus alone while it runs: activation changes dismiss native
menus and intentionally invalidate the soak. The script prints JSON measurements
and uses bounded-growth limits, allowing a small Windows lazy-service plateau;
it is not an overnight profiler. See `AUDIT.md` for baseline and measured results.

Repeat synthetic-history measurements with the bundled production SQLite:

```powershell
$env:AIKA_BENCHMARK = '1'
odin test src -vet -define:ODIN_TEST_THREADS=1
Remove-Item Env:AIKA_BENCHMARK
```

The opt-in test seeds 337,990 rows in memory and prints 21-execution medians for
prepare/step/finalize, before/after the timeline/start index and for the legacy vs split day query
(`AIKA_DAYLOAD_BENCHMARK=1 AIKA_DAYLOAD_ROWS=100000|500000|2000000` with
`-define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.day_load_measurement`
in `src/day_load_benchmark_test.odin` also compares result hashes with the
legacy query and times the upgrade index build). No speed thresholds are enforced in correctness tests.
`python tools/benchmark-history.py` provides a disk-backed Python-SQLite query-plan
proxy; its SQLite version differs, so do not label it an Odin runtime benchmark.
Neither benchmark reads a user's database. Statement reuse was measured and applied
to importer/tracker hot paths (below); derived-view caching was measured and
rejected (see the Day-view paint benchmark below).

Opt-in statement-reuse benchmark (temp file DBs only; compares one-off prepare
with the statement cache in one run):

```powershell
$env:AIKA_STMT_BENCHMARK = '1'
odin test src -vet -define:ODIN_TEST_NAMES=main.statement_reuse_measurement
Remove-Item Env:AIKA_STMT_BENCHMARK
```

Lines starting `STMT` report a 3,000-group / 20,000-activity import, autocommit
insert/update-end, the (unconverted) task tick and raw prepare+finalize costs.
`python tools/test-import.py build/aika-cli.exe` tests the sample and renamed
reimports, source isolation, guarded updates, failure exit codes, and version-0
schema upgrades, using only temporary databases. `src/importer_test.odin` adds
ID/key collisions, alias groups, local-edit conflicts, deletion tombstones,
malformed data, embedded NUL/Unicode text, and write/commit rollback tests.
`src/intervals_test.odin` covers multi-row idle trimming/deletion, statement and
commit rollback with pending ownership, unowned-history protection, backward/
forward clock splits, pre-timer Exit, backward transient merging, midnight
adjacency and explicit 23/25-hour Windows DST rules. All clocks are injected;
these tests do not change the desktop timezone or system time.
`src/activity_snapshot_test.odin` checks matching list/totals/bar durations before
and after persistence/reload, persisted-but-not-loaded rows, midnight and full
multi-day clipping, queue recovery, failed reads, atomic cache publication after
idle COMMIT, clock-jump/frozen endpoints, task metadata and half-open pixel hits.
The snapshot tests run without changing shared UI globals and borrow source
metadata only for the projection's scratch lifetime.
`src/db_tags_test.odin` covers repository-owned tag/task transactions and their
rollback, contention, target validation, boundary and cache-acknowledgement
contracts. Shared-memory SQLite connections exercise independent writers without
creating database files. Timestamp tests verify all persisted representations
for normal insert/end updates, tag resizing and import insert/update statements.
The tag UI smoke test also exercises retained-picker retry under a real writer
lock; database failure must not be presented as an overlap conflict.
`src/focus_cache_test.odin` injects foreground samples, process-instance probes,
metadata reads and group lookups to verify title freshness, PID reuse, bounded
refresh, failure recovery, database scoping and owned cache lifetimes. Native
identity checks use only the test process, never manipulate user processes.

Opt-in focus microbenchmark (no timing threshold in correctness tests):

```powershell
$env:AIKA_FOCUS_BENCHMARK = '1'
odin test src -vet -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.focus_polling_measurement
Remove-Item Env:AIKA_FOCUS_BENCHMARK
```

It compares the explicit old metadata/hash/XML/group-lookup path with the current
validated cache, using a fixed injected window sample and the running test EXE.
This excludes common foreground/title Win32 calls and normal activity writes;
the measured executable has no version resources. It is not a full GUI CPU
benchmark, and results include the test runner's allocator tracking overhead.

Opt-in Day-view paint benchmark (mutates shared UI globals, so run it alone):

```powershell
$env:AIKA_VIEW_BENCHMARK = '1'
odin test src -vet -o:speed -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.view_paint_measurement
Remove-Item Env:AIKA_VIEW_BENCHMARK
```

It seeds a synthetic in-memory day (900 app rows over 60 groups, 24 hierarchical
tags, 2 usage rows), paints into an offscreen 1320x860 backbuffer with the app's
fonts, and prints per-call GDI primitive costs, a per-component frame breakdown,
derived-data-only timings (snapshot/rows/totals/tree) and full-frame medians,
including a day clustered into 09:00-18:00. No database or window is involved.
`src/text_test.odin` and `src/bar_run_test.odin` are the pixel-parity regression
tests for the text fast path and bar coalescing.
`python tools/test-settings-ui.py build/aika.exe` checks Tracking settings in light
and dark modes: validation, save/cancel/close, restart persistence, invalid-file
fallback and continued activity tracking while open, using an isolated database.
`python tools/test-tags-ui.py build/aika.exe` runs a native UI smoke test with
its own temporary database (create, reverse drag, search/reuse, resize both
edges, cancel, non-overlap, context-menu delete, tag reuse, persistence).
The running app owns its EXE, so never kill it to rebuild: build to a separate
filename and pass that path to the smoke test instead.
Build GUI and CLI sequentially: the resource compiler shares `assets/aika.res`.
Use this manual checklist for
the UI and tracker:

1. `odin check src -vet`
2. `build.bat`
3. Start GUI; verify the window draws.
4. Focus different apps; verify new rows in timeline 3 after 5 s.
5. Wait 10 s; verify the last row's `EndLocalTime` advances.
6. Leave both keyboard and mouse untouched beyond the configured timeout (default
   1 minute); verify an `Away` row in timeline 2
   and a gap in timeline 3.
7. Tracking pause/resume has no manual control; outage pause and recovery are
   covered by `odin test src -vet` (queue exhaustion) and
   `test-persistence-ui.py`. Verify rows resume after the configured timeout.
8. Navigate dates; verify the timeline reloads.
9. Import the sample JSON into a fresh DB; verify 202 activities / 2745 groups.
10. Close via the window close button; verify the window hides and tracking continues.
    Click the tray icon to restore; choose **Exit** from its right-click menu and
    verify the current activity is flushed. `python tools/test-tray-ui.py build/aika.exe`
    checks this with an isolated database.

---

## Common error reference

| Symptom | Cause / fix |
|---|---|
| `LNK2005 CloseWindow already defined` | raylib era only — resolved by the native UI rewrite |
| `LNK2019 ___chkstk_ms` | SQLite built with MinGW; rebuild with MSVC |
| White window / no draw | font temp-allocator hang or stale exe |
| Raygui button captions invisible | historical (raylib era): prebuilt `raygui.lib` stops drawing text after control-level style writes; see "Invalid raygui captions" — buttons are custom now, don't reintroduce raygui |
| Blurry text | font created at the wrong DPI or a missing Per-Monitor V2 manifest entry; fonts rebuild from scaled heights via `dpi_px` |
| Uniformly too-small UI | manifest not embedded (missing `-resource:assets/aika.rc`) so Windows bitmap-scales the window, or design constants bypassing `dpi_px` |
| `Access to the database file is not allowed` | SQL CE needs `Temp Path`; close ManicTime |
| `there was an error parsing the query ... Key` | quote `[Key]` or `"Key"` / use `"Group"` |
| Dates off by decades | used `yyyyMMdd` instead of days since 2000-01-01 |
| App rows missing but usage rows present | <5 s titles, idle, or paused |
| Import JSON parse `Unsupported_Type_Error` | PowerShell serialized a `List` as `CliXml` |
