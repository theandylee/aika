# Roadmap

Current state: working MVP. The core tracking loop, SQLite persistence, timeline
UI, and ManicTime import are functional.

This roadmap is ordered by value and implementation risk.

---

## Audit follow-up — correctness before new features

Added from the 2026-11-06 project audit. Complete the high-priority data-integrity
fixes before expanding the tracker. Checkboxes reflect verified follow-up work.

### High priority

- [x] **A1. Make imports collision-safe** (`src/db.odin`, `src/db_import.odin`, `src/importer.odin`).
  Replace raw external-ID `INSERT OR REPLACE` behavior with stable source-to-local
  identity mapping for groups and activities. Remap imported group references and
  preserve unrelated local history. Add schema versioning/migrations if needed.
  **Acceptance:** importing colliding group/activity IDs neither overwrites local
  activities nor relabels their applications; importing the same source twice is
  idempotent. The sample still imports 202 activities and 2745 groups into a fresh DB.
  Implemented with explicit source identities, local-ID allocation, guarded source
  updates, tombstones, and additive schema version 1. Legacy exports need
  `--import-source`; existing unprovenanced history is not automatically adopted.

- [x] **A2. Reconcile application history when backdating idle**
  (`src/tracker.odin`, `src/db.odin`). Trim or remove all application intervals
  overlapping the backdated idle period, including persisted rows from title
  changes during the grace period. Reconcile the in-memory activity as well.
  **Acceptance:** title changes during the 60-second idle grace period produce
  no negative-duration rows and no application activity within the resulting
  Away interval. Cover a current activity that starts after the transition time.
  Implemented as an atomic, retryable transaction over current-spell-owned rows,
  pending writes and Active/Away endpoints. Older/imported history is untouched.

- [x] **A3. Preserve pending activity on database write failures**
  (`src/db.odin`, `src/tracker.odin`, `src/ui.odin`). Propagate SQLite write results,
  retain failed inserts/updates for retry, retry failed usage inserts, and show
  recording errors in the UI. Advance persistence state only after successful writes.
  **Acceptance:** injected insert/update failures do not silently discard completed
  activities; recovery persists pending application and usage intervals exactly
  once. Shutdown reports any records it cannot flush.

### Medium priority

Step 6 reliability follow-up is implemented: callback-scoped scratch, repeatable
partial-startup cleanup, transactional backbuffers, typed zoom/shared interaction
cancellation, hidden Day hit-target fixes, PID-scoped native test helpers and a
resource soak. Measured synthetic-history results justified only the timeline/start
index; day reads then kept their date-index path (superseded by audit #14: day
reads now use a start-time seek plus the partial `IX_Activity_Long` index).
See `AUDIT.md` for measurements, passing checks and verification boundaries.
Prepared statement reuse, snapshot/derived-view caching and import peak-memory profiling remain deferred. The later audit #13
follow-up adds bounded foreground metadata caching, not a general executable map.
DPI/keyboard policy and new tracker features were not part of this step.

- [x] **A4. Merge short activities backward** (`src/tracker.odin`). Attribute a
  discarded activity shorter than five seconds to the preceding activity rather
  than backdating the next one. Define behavior when there is no preceding row.
  **Acceptance:** in A → B → C with B lasting two seconds, A receives those two
  seconds, C starts at its actual focus time, and no B row remains. Cover quick
  A → B → A switches and pause/away boundaries without bridging tracking gaps.
  Implemented for adjacent persisted/queued predecessors in the same Active
  spell; without a predecessor the short sample is omitted. Pause/Exit force-save.

- [x] **A5. Return failing CLI exit codes** (`src/main.odin`). Return nonzero exit
  codes for database-open and import failures, including with `--quiet`.
  **Acceptance:** missing files, malformed JSON, and an unwritable database fail
  in scripts; a successful import returns zero.

- [x] **A6. Keep live overlays working across midnight** (`src/ui.odin`,
  `src/tracker.odin`). Use interval overlap with the selected day rather than
  start-date equality for current application/usage overlays, view-range logic,
  and related day helpers. Clamp intervals to the selected day's bounds.
  **Acceptance:** an application and usage interval continuing past midnight both
  grow live when viewing the new day; the preceding day's view stays clamped.
  Implemented via shared snapshot overlap clipping, including persisted rows
  absent from the selected day's cache. Daily list/tooltip bounds are clipped too.

- [x] **A7. Reconcile live and cached summary activities** (`src/ui.odin`,
  `src/main.odin`). Merge the current activity into the summary by activity ID,
  whether persisted or not, without counting its cached interval twice.
  **Acceptance:** totals do not disappear or decrease when the activity is first
  persisted at five seconds, continue growing between ten-second reloads, and
  remain correct across reloads and day boundaries.
  Implemented with ID-based queued/live overlays and acknowledged write-through
  cache updates. All Day views share a single snapshot/time sample per paint;
  completed writes stay visible before the next reload and rollback never changes
  the cache. Running tasks use acknowledged endpoints to respect tag neighbors.

- [x] **A8. Repository boundary cleanup (audit #20)** (`src/db_tags.odin`,
  `src/db_time.odin`). Tag/task transactions, overlap/neighbor checks and identity
  lookup now live behind repository operations rather than in UI/task code.
  Timestamp bindings are shared across tracker, tags and imports. Checked results
  distinguish storage failure from overlap, and failed writes/commits cannot
  advance task/cache state. No schema migration or interval-policy change.

- [x] **A9. Foreground metadata caching (audit #13)** (`src/focus_cache.odin`).
  Cache one validated process instance's metadata/hash/XML and resolved group.
  Continue 1 Hz HWND/PID/title sampling and creation-time validation; invalidate
  on process change, failed validation or 60-second monotonic expiry. Errors retry
  rather than poisoning the cache. Warm own-process microbenchmarks improve from
  roughly 53 to 3 microseconds, a small absolute saving; no multi-process cache,
  long-lived handles, title caching or lifecycle/key changes were introduced.

- [x] **A10. Day-view paint cost (audit #15)** (`src/winui.odin`, `src/ui.odin`).
  Measured before changing anything: derived rows/totals cost ~0.2 ms of a ~9 ms
  900-row frame, so no derived-view cache was added. GDI text was the cost. Fitting
  text now uses clipped `ExtTextOutW` (overflow keeps `DrawTextW` ellipsis),
  measurement reuses the backbuffer DC, and overpainted bars coalesce. Frames
  dropped to ~5.7 ms (spread day) and ~4.4–5.0 ms (clustered day). Pixel-parity
  tests cover bars and space-free text; text containing spaces may shift ≤1 px.
  Mouse-move repaint frequency was then addressed separately (A11).

- [x] **A11. Mouse-move repaints** (`src/hover.odin`, `src/winui.odin`).
  `WM_MOUSEMOVE` no longer invalidates the whole frame on every position
  change. Each paint records a hover signature (hover-sensitive rectangles
  plus the bar-tooltip row, sharing hit helpers with `draw_tooltip`); a move
  repaints only when the signature would change or a cursor-following tooltip
  is involved. Scripted 400-move sweeps over empty areas dropped from ~0.8–1 s
  of app CPU to ~0–16 ms. Also fixed `TrackMouseEvent` never being called, so
  `WM_MOUSELEAVE` now clears hover promptly.
- [x] **A12. Ellipsized labels (audit #15 follow-up)** (`src/winui.odin`).
  Overflowing text reproduces `DT_END_ELLIPSIS` with kerned advances from
  `GetCharacterPlacementW` and one clipped `ExtTextOutW`, falling back to
  `DrawTextW` for complex scripts/font linking/ligatures. Pixel-identical to
  `DrawTextW` over 12,131 overflowing renderings (20 strings, 8 fonts, every
  width). Tag labels ~2.5x cheaper; `Ruler_Lanes` 4.90 → 3.56 ms.

- [x] **A13. Unified interaction state (audit #18, #23)** (`src/interaction.odin`,
  `src/winui.odin`, `src/panes.odin`, `src/zoom.odin`, `src/tags.odin`).
  One `ui.interaction` union (`Press`/`Pane`/`Zoom`/`Tag` with cancel snapshots)
  replaces parallel `pane_drag`/`zoom_drag`/`tag_ui.drag`/`pressed_hit` fields;
  single `interaction_active()` predicate, idempotent `interaction_cancel`, and
  per-message `wnd_proc` handlers. Typed `Tab`/`Lane`/`Pane_Drag`/`Tag_Drag`/`Hit`
  enums, named `Palette`, `Colorref`/`Argb` discipline, shared geometry helpers,
  named Win32/EM/ODS constants and typed fixed accents. Verified by 104 tests,
  all UI scripts, and 92/92 pixel-identical snapshots against HEAD.

- [x] **A14. DPI and keyboard policy (audit #24)** (`src/dpi.odin`,
  `assets/aika.manifest`).
  Per-Monitor V2 declaration; every design constant scales centrally via
  `dpi_px` (identity at 96 DPI). Scaled fonts, rescaled stored pane sizes,
  `WM_DPICHANGED` suggested-rect adoption, scaled minimum tracking size.
  Native-only keyboard scope: Tab through filter/date/scrollbars/dialogs via
  `IsDialogMessageW`; canvas stays mouse-only. Verified by
  `dpi_scaling_behavior`, 104 tests, all UI scripts, 92/92 pixel-identical
  vs HEAD at 96 DPI.

---

## P0 — finish the tracker core

### 1. Session lock and power events

**Why:** The data model already has `SessionLocked` and `PowerOff` groups, but
nothing emits them. Today a locked screen looks like ordinary activity until the
idle threshold fires.

**Implementation notes:**

- Bind `WTSRegisterSessionNotification` / `WTSUnRegisterSessionNotification`
  from `wtsapi32.dll`.
- Register using the main window handle (`ui.hwnd`).
- Handle `WM_WTSSESSION_CHANGE`:
  - `WTS_SESSION_LOCK` → finish app activity, emit `SessionLocked`
  - `WTS_SESSION_UNLOCK` → close lock row, emit `Active`, restart app poll
- Handle `WM_POWERBROADCAST`:
  - `PBT_APMSUSPEND` → emit `PowerOff`
  - `PBT_APMRESUMEAUTOMATIC` / `PBT_APMRESUMESUSPEND` → emit `Active`
- The WndProc now lives in `src/winui.odin` — add these messages to the
  existing switch.
- Extend `UsageKind` transitions in `tracker_tick` to accept external events
  instead of only `idle_ms`.
- Trim application activities to the lock/suspend timestamp.

**Acceptance:**

- Lock the workstation for 2 minutes → a `Session locked` row appears in
  timeline 2 and timeline 3 has a gap.
- Unlock → `Active` resumes and a new app activity starts.
- Sleep/resume behaves the same.

ManicTime reference (from the former reverse-engineering notes, kept here so
the file could go): two idle strategies — `TrackAwayWithIdleTime`
(`TimeLimitedInactivity` checks `GetLastInputInfo` every 5 minutes and backdates
away to `now - threshold`, default 10 minutes) versus `ScreenSaverInactivity`
(screensaver/monitor-off/lock events). aika already implements the first
strategy with 1-second checks and a 1-minute default; this item only adds the
lock/power event sources and their `SessionLocked`/`PowerOff` rows.

### 2. Settings

Tracking settings already expose an idle timeout (default 1 minute, range 1–500)
through a native window and a database-adjacent `.settings` file. Remaining policy
constants are currently fixed:

- poll interval = 1 second
- 5 s minimum
- 10 s heartbeat
- track window titles always on
- aika tracks itself

**Add** a small `Settings` struct and persistence:

```odin
Settings :: struct {
    idle_threshold_min: int,
    poll_interval_ms: int,
    min_activity_ms: int,
    heartbeat_ms: int,
    track_titles: bool,
    exclude_self: bool,
    start_minimized: bool,
}
```

Storage options:

- a `Settings` table in SQLite (recommended; one file), or
- `aika.ini` next to the exe.

Extend the existing native settings window only under a separate feature request;
"don't track aika" and other policy options are not implemented.

**Acceptance:**

- Changing the idle threshold takes effect without a restart.
- `exclude_self = true` means aika windows are not recorded.

### 3. Graceful shutdown / single instance

- Use a named mutex (`CreateMutexW`) to prevent two trackers writing the same DB.
- If a second instance starts, focus the existing window or exit with a message.
- Close-to-tray, Open/Settings/Exit, continued hidden tracking and guarded final
  write flushing are implemented. Single-instance prevention and tray Pause remain
  future policy work.

**Acceptance:**

- Second launch does not create a second writer.
- Closing the window hides to tray, tracking continues.
- Tray Exit flushes the current activity.

---

## P1 — documents, tags, statistics

### 4. Document / URL tracking

**Why:** ManicTime's Documents timeline is a major feature. aika currently only
records window titles.

**Minimum viable implementation:**

- Add `DocumentInfo`:

```odin
DocumentInfo :: struct {
    display_name: string,
    document_name: string,
    group_name: string, // stable identity (ManicTime: DocumentGroupName)
    type: DocumentType, // ManicTime: File / WebSite / Other
}
```

- Add a retriever registry ordered by priority (ManicTime: `CallOrder`),
  caching results per window.
- Implement Chrome/Edge URL retrieval:
  - `EnumChildWindows` on the foreground window
  - find the omnibox class
  - `SendMessageW(hwnd, WM_GETTEXT, ...)`
  - extract URL
- Implement Firefox similarly (URL bar class differs).
- Fallback: parse the window title for known patterns is unreliable; prefer UI
  Automation.
- Persist a `DocumentGroup` on timeline 4 and a `DocumentActivity` for each app
  activity where a document was recognized.
- Add a Documents lane to the UI.
- Only store URLs/paths when `track_titles` is enabled.

**Acceptance:**

- Browsing two tabs switches the Documents lane at tab-switch time.
- A text editor file path appears as a document group.
- Disabling title tracking stops document rows too.

### 5. Tags

**Implemented:** range dragging in either direction, searchable tag selection,
creation, persisted tag blocks, border resizing, details and totals. See
`src/tags.odin`. Multi-tag group lists and tag management remain future work.

**Why:** Tags are how ManicTime turns raw activity into timesheets.

**Design:**

- Use timeline 1 (`ManicTime/Tags`).
- A tag is an `Activity` with a `Group` whose display name is the tag name.
- Tags can overlap app/document activities; the UI needs a separate lane.
- Add an "Add tag" action for a selected time range:
  - one row per tag
  - optional multiple tags per range (ManicTime uses `GroupList` for this)
- Start simple: one tag group per tag, no group lists.

**Acceptance:**

- Select a time range in the UI, add tag "Meeting".
- The Tags lane shows the block.
- Tag totals appear in the summary.

### 6. Statistics and search

- Day/week/month totals per application, document, tag.
- Search by app/title/date.
- Export to CSV.
- Chart view: reuse the stacked-bar drawing from `src/ui.odin`.

ManicTime reference (from the former reverse-engineering notes): the day loader
queries by local date range over the `Activity` rows (no session table), trims
bar start/end to the day, refreshes every second but re-queries a timeline only
after its `UpdateInterval` (10 s for local timelines), and catches up
incrementally via `UpdatedTimestamp`/deletion timestamps.

Keep it read-only initially; do not build an editor until tags are stable.

---

## P2 — import, packaging, polish

### 7. Import improvements

Current exporter:

- fixed SQL CE path (`%LOCALAPPDATA%\Finkit\ManicTime`)
- exports all groups (2745 in the sample) even if only a few are referenced
- recomputes local dates from UTC ms on import
- no incremental import

Improvements:

- `-Sdf <path>` parameter.
- `-From` / `-To` date range.
- Filter groups to those referenced by exported activities.
- Export `startLocalDate` / `endLocalDate` / local time strings and preserve them
  exactly instead of recomputing.
- Incremental import by `ActivityId` or `UpdatedTimestamp`.
- Optional `--replace` vs `--merge` mode.
- A progress indicator for large imports.

### 8. Packaging

- Add a Windows icon and version resource (`rsrc` or `.rc`).
- Ship `aika.exe`, `aika-cli.exe`, `README.md`.
- Add a small installer or portable ZIP.
- Add "Start with Windows" using the Run key or Task Scheduler.
- Add crash log file (`aika.log`) with rotation.

### 9. UI polish

- Group legend with toggles.
- Hover highlight for all bars, not just app bars.
- Zoom/pan is implemented, including overview resizing and middle-button panning.
- DPI scaling is implemented centrally via `dpi_px` (Per-Monitor V2, audit #24):
  design constants, fonts, stored pane sizes and minimum tracking size all scale.
- Keyboard shortcuts: `T` today, arrows for days, `Space` pause.
- Empty-state hints.

---

## P3 — deeper compatibility

### 10. Direct `.sdf` access via .NET sidecar

Not recommended for the core app, but useful if live two-way compatibility is
required (ManicTime's tracker/client split was mapped with Ghidra/ilspycmd
against `Finkit.ManicTime.*` in `C:\Program Files (x86)\ManicTime`; re-derive
from the installed assemblies if this is ever revived):

- Build a small C# helper that exposes a line-based JSON protocol over
  stdin/stdout or a named pipe.
- Operations: list timelines, query activities by range, insert activity, update
  end time, import/export.
- aika calls the helper only when the user chooses "ManicTime DB mode".
- This breaks the "pure Odin" property and requires .NET Framework + SQL CE.

Document the trade-off clearly before implementing.

### 11. Write-back / export

- Export aika data to ManicTime-compatible JSON/CSV.
- Optionally write a `.sdf` through the sidecar.
- Do not attempt to write `.sdf` natively.

---

## Technical debt

| Item | Notes |
|---|---|
| Automated reliability coverage | 119 Odin tests plus isolated native UI/import scripts; extend with each change |
| Hardcoded timing constants | Move to `Settings` |
| Hardcoded group colors | ManicTime-like palette is fine, but make it configurable |
| Additive schema migrations | Schema version 1 with import provenance; targeted indexes created idempotently |
| `Sequence` table unused | Needed only for exact ManicTime ID behavior |
| Document table unused | Implement with the Documents timeline |
| No error log | Add rotating `aika.log` |
| UI uses fixed pixel sizes | Central `dpi_px` scaling (Per-Monitor V2) since audit #24 |
| Importer recomputes local dates | Preserve exported local fields for exact history |
| `fmt.println` in GUI build | No console; use a log file for diagnostics |

---

## Suggested next step

**A1–A7** and the scoped/measured step-6 reliability work are complete. Review the
remaining unchecked `AUDIT.md` items before selecting another change. Session
lock/power events, broader settings and document/URL tracking require separate
feature approval; they are not implied by the reliability refactoring.
