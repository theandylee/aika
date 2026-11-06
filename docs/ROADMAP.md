# Roadmap

Current state: working MVP. The core tracking loop, SQLite persistence, timeline
UI, and ManicTime import are functional.

This roadmap is ordered by value and implementation risk.

---

## Audit follow-up — correctness before new features

Added from the 2026-11-06 project audit. Complete the high-priority data-integrity
fixes before expanding the tracker. All tasks below are open.

### High priority

- [ ] **A1. Make imports collision-safe** (`src/db.odin`, `src/importer.odin`).
  Replace raw external-ID `INSERT OR REPLACE` behavior with stable source-to-local
  identity mapping for groups and activities. Remap imported group references and
  preserve unrelated local history. Add schema versioning/migrations if needed.
  **Acceptance:** importing colliding group/activity IDs neither overwrites local
  activities nor relabels their applications; importing the same source twice is
  idempotent. The sample still imports 202 activities and 2745 groups into a fresh DB.

- [ ] **A2. Reconcile application history when backdating idle**
  (`src/tracker.odin`, `src/db.odin`). Trim or remove all application intervals
  overlapping the backdated idle period, including persisted rows from title
  changes during the grace period. Reconcile the in-memory activity as well.
  **Acceptance:** title changes during the ten-minute idle grace period produce
  no negative-duration rows and no application activity within the resulting
  Away interval. Cover a current activity that starts after the transition time.

- [ ] **A3. Preserve pending activity on database write failures**
  (`src/db.odin`, `src/tracker.odin`, `src/ui.odin`). Propagate SQLite write results,
  retain failed inserts/updates for retry, retry failed usage inserts, and show
  recording errors in the UI. Advance persistence state only after successful writes.
  **Acceptance:** injected insert/update failures do not silently discard completed
  activities; recovery persists pending application and usage intervals exactly
  once. Shutdown reports any records it cannot flush.

### Medium priority

- [ ] **A4. Merge short activities backward** (`src/tracker.odin`). Attribute a
  discarded activity shorter than five seconds to the preceding activity rather
  than backdating the next one. Define behavior when there is no preceding row.
  **Acceptance:** in A → B → C with B lasting two seconds, A receives those two
  seconds, C starts at its actual focus time, and no B row remains. Cover quick
  A → B → A switches and pause/away boundaries without bridging tracking gaps.

- [ ] **A5. Return failing CLI exit codes** (`src/main.odin`). Return nonzero exit
  codes for database-open and import failures, including with `--quiet`.
  **Acceptance:** missing files, malformed JSON, and an unwritable database fail
  in scripts; a successful import returns zero.

- [ ] **A6. Keep live overlays working across midnight** (`src/ui.odin`,
  `src/tracker.odin`). Use interval overlap with the selected day rather than
  start-date equality for current application/usage overlays, view-range logic,
  and related day helpers. Clamp intervals to the selected day's bounds.
  **Acceptance:** an application and usage interval continuing past midnight both
  grow live when viewing the new day; the preceding day's view stays clamped.

- [ ] **A7. Reconcile live and cached summary activities** (`src/ui.odin`,
  `src/main.odin`). Merge the current activity into the summary by activity ID,
  whether persisted or not, without counting its cached interval twice.
  **Acceptance:** totals do not disappear or decrease when the activity is first
  persisted at five seconds, continue growing between ten-second reloads, and
  remain correct across reloads and day boundaries.

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

### 2. Settings

The current constants are hardcoded:

- idle threshold = 10 minutes
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

Add a settings panel in raygui. At minimum expose idle threshold and
"don't track aika".

**Acceptance:**

- Changing the idle threshold takes effect without a restart.
- `exclude_self = true` means aika windows are not recorded.

### 3. Graceful shutdown / single instance

- Use a named mutex (`CreateMutexW`) to prevent two trackers writing the same DB.
- If a second instance starts, focus the existing window or exit with a message.
- Add a tray icon with "Pause", "Open", "Exit" so closing the window can keep
  tracking.
- The current app exits when the window closes; ManicTime keeps running in the
  tray.

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
    group_name: string,
    type: DocumentType,
}
```

- Add a retriever registry ordered by priority.
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
- Zoom/pan (currently auto-fit only).
- Keyboard shortcuts: `T` today, arrows for days, `Space` pause.
- DPI scaling: GDI text sizes are fixed pixels today; `GetDpiForWindow` +
  font recreation (or `SystemParametersInfo`) is a likely future step.
- High-DPI font sizes.
- Empty-state hints.

---

## P3 — deeper compatibility

### 10. Direct `.sdf` access via .NET sidecar

Not recommended for the core app, but useful if live two-way compatibility is
required:

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
| No automated tests | Add headless DB tests and a fake clock first |
| Hardcoded timing constants | Move to `Settings` |
| Hardcoded group colors | ManicTime-like palette is fine, but make it configurable |
| No schema version | Add `PRAGMA user_version` and migrations before changing schema |
| `Sequence` table unused | Needed only for exact ManicTime ID behavior |
| Document table unused | Implement with the Documents timeline |
| No error log | Add rotating `aika.log` |
| UI uses fixed pixel sizes | Add DPI-aware scaling |
| Importer recomputes local dates | Preserve exported local fields for exact history |
| `fmt.println` in GUI build | No console; use a log file for diagnostics |

---

## Suggested next step

Resolve **A1–A3 (import safety, idle reconciliation, and write-failure recovery)**
first, with focused regression tests. Then complete **A4–A7** before adding new
tracker features.

Next, implement **session lock + power events** and **settings** together. They
share the same lifecycle code in `tracker.odin`. After that, document/URL tracking
is the highest-value user feature.
