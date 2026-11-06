# Project audit — refactoring backlog

Audit date: 2026-11-06.

This backlog records a source review of the application, tests, build
configuration, exporter, and documentation. Items are unchecked until fixed and
verified. References describe the source at audit time; line numbers may drift.

## Verification boundary

- `odin check src -vet` passed.
- Group replacement producing orphaned activities and acceptance of negative
  durations were reproduced with the current schema in an in-memory SQLite DB.
- Query plans were inspected in an in-memory SQLite DB; performance costs have
  not been benchmarked against representative history.
- Memory findings are based on allocation/ownership inspection, not a runtime
  leak profiler. Leak rates and GDI-handle stability still need measurement.
- No implementation changes were made as part of the audit.

## Recommended order

1. Protect history: import identity mapping, write-error propagation, idle
   reconciliation.
2. Fix contained defects: filter leak, UTF-16 lengths, startup/CLI failures,
   hidden hit targets.
3. Unify time and view state: monotonic scheduling, half-open intervals,
   effective live activity snapshot.
4. Bound resource usage: scoped scratch storage and import memory ownership.
5. Optimize measured hot paths: metadata caching, indexes, statement reuse,
   derived-view caching.
6. Simplify UI structure: typed interactions, focused handlers, palette/constants,
   shared test harness.

## High priority: correctness and data loss

- [x] **1. Importing can overwrite local history and orphan activities.**
  References: `src/db.odin:578`, `src/db.odin:648`.
  Both activities and groups use `INSERT OR REPLACE` with imported IDs. An
  imported activity or group ID can replace an unrelated local record. A matching
  `(TimelineId, Key)` with a different imported ID deletes the existing group,
  leaving its activities referencing a nonexistent group. The latter was
  reproduced against the current schema.
  Introduce source-to-local ID mapping, resolve group identity independently of
  source IDs, and define an explicit, idempotent import strategy.
  Fixed: groups resolve by `(TimelineId, Key)` without changing existing metadata;
  source activity IDs map to allocated local IDs under an explicit source database
  identity. Reimports are no-ops or guarded updates, with conflicts rolling back
  the whole transaction and deletions retained as tombstones. Schema version 1
  adds provenance without adopting/overwriting older unprovenanced history.

- [x] **2. Persistence failures are silently treated as success.**
  References: `src/db.odin:309–344`, `src/tracker.odin:68–88`,
  `src/tracker.odin:126–164`.
  `db_update_activity_end` ignores `sqlite3_step` and returns nothing. Callers
  advance last-saved timestamps or clear state regardless of success. Failed
  final inserts lose the activity when `finish_current` clears it; failed usage
  inserts leave `usage_id == 0` without retry until another state transition.
  GUI users generally cannot see stderr diagnostics.
  Return explicit database results, acknowledge persistence only after success,
  retain pending writes for retry, and expose a persistent tracking-error state.
  Fixed for tracker activity/usage writes: explicit results and affected-row
  checks gate acknowledgments. Failed final writes move to an owned, bounded
  queue; failed live/usage writes retry without losing their original start.
  The status bar/window title show errors, and normal Exit is cancelled until
  pending tracker writes can be saved. Unused legacy deletion and other tag/import
  repository APIs have not all been migrated to the typed result contract.

- [x] **3. Idle backdating can produce negative durations and overlapping history.**
  References: `src/tracker.odin:230–238`, `src/tracker.odin:145`.
  Away is backdated to `now - idle_threshold_ms`, checked only against usage
  start. An automatic foreground change during the idle timeout can create a
  persisted application activity whose start is later than the backdated Away
  transition. Finishing it can put its end before its start. Earlier persisted
  application rows within that interval are not reconciled and can overlap Away.
  The database accepts negative-duration rows, as reproduced during the audit.
  Make idle transitions interval-reconciliation operations and enforce
  `end >= start`, including affected persisted rows.
  Fixed: one retryable transaction replays pending writes, clips/removes all
  affected current-spell-owned application rows, finishes Active and creates Away.
  Failure preserves live/queued state and prevents Exit. Explicit ID/spell ownership
  protects unrelated/imported/previous-clock history. Repository writes reject
  reversed intervals; old malformed rows and direct SQL bypasses are not repaired.

- [x] **4. Scheduling uses an adjustable wall clock.**
  References: `src/tracker.odin:217–225`, `src/winui.odin:285–295`,
  `src/task.odin:31–33`.
  Sampling, refresh intervals, and write throttling use UTC wall-clock
  differences. Backward adjustments can suspend work until the clock catches up;
  forward jumps can manufacture large intervals.
  Use a monotonic clock for scheduling, UTC for stored timestamps, and define how
  clock discontinuities affect active intervals.
  Fixed: monotonic sampling, insertion/write throttles, task saves and day reloads.
  A wall/monotonic delta mismatch over 2 seconds closes tracker intervals at the
  last observation and begins a new spell at the new UTC instant. Pause/Exit also
  check for jumps; tasks stop at their acknowledged endpoint. Backward jumps can
  overlap earlier spells in UTC; old history is deliberately not shifted/repaired.

- [x] **5. Live activity presentation has inconsistent implementations.**
  References: `src/main.odin:16–23`, `src/ui.odin:478–505`,
  `src/ui.odin:537–583`, `src/ui.odin:637–683`.
  Bars use live tracker state while lists/totals mostly use periodically loaded
  rows. Once inserted, an activity loses its unpersisted list/totals overlay even
  if its new row has not been loaded. Persisted durations are stale between
  reloads; usage bars and usage totals disagree. Live overlays require the
  activity to have started on the selected date, losing live treatment after
  midnight for a continuing activity.
  Produce one effective snapshot merging persisted rows and live state by ID,
  clipped by interval overlap. Use it for bars, lists, totals, tooltips, and the
  overview.
  Fixed: one pure day snapshot overlays queued/live application, usage and task
  rows by ID, then clips by overlap. All Day views share it and its captured time.
  Missing persisted live rows are added; acknowledged writes update the selected
  cache immediately so completed intervals stay visible before reload. Idle
  publication is deferred until COMMIT, and failed reads retain the cache.
  Tasks intentionally stop at saved endpoints rather than guessing past neighbors.

- [x] **6. Daily list durations are not clipped to the day.**
  Reference: `src/ui.odin:547–564`.
  `build_rows` calculates clipped bounds but stores the original activity bounds.
  Multi-day activity durations therefore disagree with clipped daily totals.
  Distinguish full activity bounds from displayed-day bounds explicitly.
  Fixed: snapshot/list rows retain full source bounds separately and render/sum
  clipped selected-day bounds. Tooltips use those same daily bounds; next midnight
  is displayed as `24:00`. Empty and reversed projected intervals are omitted.

- [x] **7. UTF-8 byte counts are passed to UTF-16 GDI APIs.**
  Reference: `src/winui.odin:235–266`.
  Text is converted to UTF-16, but `GetTextExtentPoint32W` and `DrawTextW` receive
  the UTF-8 byte count `len(s)`. For non-ASCII text, lengths are wrong and
  measurement can read beyond the converted buffer.
  Retain the UTF-16 slice and pass its code-unit count; use `-1` only where the
  API supports null-terminated input. Add non-ASCII text tests.
  Fixed: both helpers retain the converted UTF-16 slice and pass its code-unit
  count. Regression tests compare measurement and rendered pixels against explicit
  UTF-16 references for ASCII, accented text, Japanese, and a surrogate pair.

- [ ] **8. Startup and CLI failures have broken control flow.**
  References: `src/main.odin:58–78`, `src/main.odin:90`,
  `src/winui.odin:875–992`.
  `ui_bootstrap()` failure is ignored, potentially leaving a process waiting
  without a usable window. Database/import failures return normally from
  `main`, reporting success to scripts. Unknown flags and missing argument values
  are silently ignored.
  Add validated argument parsing, explicit startup stages with cleanup, and
  meaningful failure exit codes.
  Partial progress: database/import failures now exit nonzero, and missing option
  values/unknown arguments are rejected. GUI bootstrap failure handling and full
  staged startup cleanup remain open.

## Memory and resource ownership

- [x] **9. Filter changes leak an intermediate string.**
  Reference: `src/winui.odin:777–789`.
  `read_filter` allocates UTF-8 `s` with the default allocator, then allocates a
  lowercase copy. Only the lowercase copy is eventually freed, leaking the
  intermediate string on each nonempty change.
  Use temporary storage for the conversion or free it after lowercasing.
  Fixed: `filter_from_utf16` frees its intermediate conversion. A tracking-allocator
  test verifies no outstanding allocations after 1,000 conversion/free cycles.

- [x] **10. Import allocations have no bounded ownership scope.**
  References: `src/importer.odin:31–74`, `src/db.odin:172–174`.
  The input file is freed, but the unmarshalled object graph is not. Per-row SQL,
  text, and date scratch allocations accumulate because imports never enter the
  GUI loop that resets the temporary allocator. This is chiefly a large-import
  peak-memory problem because the CLI exits afterward.
  Use an import-owned arena for parsed data and separately resettable per-batch
  scratch storage, including cleanup after parse errors.
  Fixed: parsed JSON/maps belong to an import-owned arena; a separate scratch
  arena is reset after each row's repository calls return/finalize. Both are
  destroyed on success, parse failure, rollback or failed commit. Whole-file
  parsing still has O(input size) memory cost; peak memory has not been benchmarked.

- [ ] **11. Temporary cleanup depends on returning from native modal loops.**
  References: `src/main.odin:108–113`, `src/winui.odin:164`,
  `src/tags.odin:64`.
  Temporary memory is cleared only after outer message dispatch. Native menus,
  message boxes, and move/resize loops can dispatch paints/timers internally,
  accumulating allocations until those loops finish.
  Introduce scoped, reentrancy-safe scratch allocation. Do not simply call
  `free_all` in every callback: that can invalidate outer callbacks' live data.

- [ ] **12. Failure-path resource cleanup is incomplete.**
  References: `src/db.odin:128–146`, `src/main.odin:58–64`,
  `src/winui.odin:302–331`.
  Failed DB startup can leave a SQLite handle and cloned path unclosed.
  Backbuffer allocation is unchecked before `mem_valid` becomes true. Bootstrap
  has partial initialization paths without explicit unwinding.
  Make initialization transactional and cleanup safe at every partial stage.
  These are failure-path issues, not evidence of a steady GDI leak.

## Performance and scalability

- [ ] **13. Foreground polling repeatedly reads executable metadata.**
  References: `src/tracker.odin:167–189`, `src/win32.odin:330–424`.
  Each 1 Hz sample opens the process, queries its path, reads version resources,
  builds XML, hashes identity, and prepares/executes a group lookup, even for an
  unchanged application.
  Cache executable metadata and resolved group identity. Continue title sampling
  and preserve the required `(group_id, title)` comparison.

- [ ] **14. Indexes do not match important access patterns.**
  References: `src/db.odin:60–61`, `src/db.odin:437–444`,
  `src/task.odin:35–36`.
  Query-plan inspection found a temporary sort for latest activity and no
  start-time seek for task neighbors. Day loading scans a historical start-date
  range before filtering end dates and sorting.
  Benchmark realistic history and add targeted timeline/start-time indexes.
  Review day-overlap queries separately rather than assuming one index solves
  every access pattern.

- [ ] **15. Derived view data is rebuilt on every repaint.**
  References: `src/ui.odin:537–710`, `src/totals_tree.odin:21–74`.
  Mouse-move repaints rebuild rows, aggregate/sort totals, and potentially rebuild
  the hierarchy. Filtering heap-allocates lowercase candidate names.
  Cache derived data by data revision, date, lane, filter, and tree state; update
  live durations separately. Measure before adding complex rendering machinery.

- [x] **16. SQLite busy waits block tracking and UI.**
  References: `src/db.odin:137`, `src/winui.odin:285–295`.
  The five-second busy timeout runs on the same thread as sampling and painting;
  multiple operations can compound stalls.
  Preserve the single-threaded design but use bounded busy/retry handling,
  pending writes, and visible error state.
  Fixed: the GUI connection disables SQLite busy sleeping after startup; CLI/import
  startup retains its existing timeout. Timer ticks retry at most four queued
  writes, stopping at the first failure. Tracking pauses before the 256-entry
  queue fills and automatically resumes with new intervals after it drains.
  Task/tag actions still report failure directly rather than entering this queue.

- [ ] **17. Hot-path statements are repeatedly prepared/finalized.**
  References: `src/db.odin`, `src/importer.odin:51–71`.
  This is particularly wasteful in imports and repeated endpoint updates.
  Reuse prepared statements for measured hot paths, with explicit ownership and
  complete rebinding. The bindings already expose `sqlite3_reset`.

## Structure, readability, and maintainability

- [ ] **18. UI interaction state is coupled through globals and integer modes.**
  References: `src/winui.odin:29–72`, `src/winui.odin:441–755`,
  `src/tags.odin:8–19`.
  `ui`, `tag_ui`, `settings_ui`, and `global_app` are tightly coupled. Integer
  drag states and conditions such as `drag >= 2` obscure intent. Cancellation and
  capture handling are duplicated. Escape restores middle-button panning but does
  not cancel overview zoom dragging. Settings bypasses the pressed-button range
  used by the other toolbar buttons.
  Introduce typed interaction states and shared begin/update/commit/cancel
  conventions; split the large window procedure into focused handlers.

- [ ] **19. Hidden Day-view controls remain clickable on placeholder tabs.**
  Reference: `src/ui.odin:783–815`.
  Only some hit targets are gated on `ui.tab == 0`. Date navigation, task
  controls, and lane hit-testing remain active where they are not drawn.
  Derive hit targets from the active view using rendering's visibility rules.

- [ ] **20. Persistence logic leaks into UI and task code.**
  References: `src/tags.odin:317–335`, `src/task.odin:9–48`.
  The picker manages transactions and task code contains raw SQL. Timestamp
  binding is duplicated across insertion, import, resizing, and endpoint updates.
  Add repository operations such as `create_tag_block`, `start_task`, and
  `extend_task_until_boundary`, backed by shared timestamp-binding helpers.

- [x] **21. Database reads conflate empty, not found, and failed.**
  References: `src/db.odin:360–369`, `src/db.odin:437–459`,
  `src/db.odin:474–510`, `src/main.odin:16–23`.
  Read loops stop on any result other than `SQLITE_ROW`, without distinguishing
  completion from failure. `load_day` frees the old cache before confirming a
  successful replacement, so errors can present as empty/partial days.
  Return data plus explicit results; replace the cache only after a complete,
  successful read.
  Fixed for day/tag lists, latest activity, and tracker group lookups: empty,
  missing, contention, and failed outcomes are distinct. Failed/partial list
  reads free their allocations. Day loading keeps the previous cache and date
  on failure, and the tag picker reports load errors instead of showing an
  apparently empty successful list. The test-only count convenience query and
  some boolean repository helpers retain their older contracts.

- [x] **22. Time interval conventions are inconsistent.**
  References: `src/win32.odin:274–280`, `src/db.odin:390–400`.
  Tags use half-open intervals, but day bounds end one millisecond before next
  midnight. Rendering compensates with `day_end + 1` expressions.
  Adopt `[start, end)` consistently, including day bounds, to simplify durations,
  adjacency, midnight clipping, and DST behavior.
  Fixed: exclusive next-midnight day bounds, UTC day-overlap predicates, and
  removal of the overview's `day_end + 1` compensation. Explicit Windows timezone
  rules test 23/25-hour days without changing the machine's timezone. Daily list
  clipping and live overlays remain separate step-5 work.

- [ ] **23. Constants, names, and palette representation invite mistakes.**
  References: `src/theme.odin:42–54`, `src/ui.odin:601–607`,
  `src/ui.odin:83`, `src/ui.odin:462`.
  Palette selection relies on three positionally synchronized arrays.
  `col_start` identifies Duration while `col_dur` identifies Start; `btn_track`
  now means the task button. Active usage is partly identified by assumed group
  ID `1`. Raw Win32 messages/styles/control IDs are scattered through the UI.
  Use a named `Palette`, semantic names, typed state/constants, and centralized
  usage identity.
  Partial progress: ComputerUsage rendering no longer assumes Active has group ID
  1; snapshot usage identity comes from tracker state/resolved group metadata.

- [ ] **24. DPI and keyboard behavior need a coherent UI policy.**
  References: `assets/aika.manifest`, `src/winui.odin:853–870`,
  `src/ui.odin:41–56`.
  The manifest has no DPI-awareness declaration; layout/font sizes are fixed
  pixels. Custom-painted controls largely lack keyboard focus/activation.
  Define scaling and focus/navigation centrally rather than adding per-feature
  scale factors and keyboard exceptions.

- [ ] **25. Tests under-cover tracker lifecycle and duplicate native UI harnesses.**
  References: `src/tracker_test.odin`, `src/totals_tree_test.odin:5`,
  `tools/test-*.py`.
  The tracker test checks only the default idle threshold and invokes real
  foreground inspection. Some UI tests are serialized through another test
  because of global view state. Native scripts duplicate process/window helpers;
  global `FindWindowW` popup lookup can target another running instance.
  Add injectable time/idle/foreground inputs; cover failed writes, transient
  switches, idle backdating, clock changes, midnight, import collisions, and
  reimports. Share PID-scoped native helpers and add allocation/GDI soak checks.
  Partial progress: per-tracker time/idle/foreground/write callbacks now support
  deterministic tests without real foreground inspection. Tests cover sampling,
  insertion/update thresholds, group/title identity, pause/resume/shutdown, stable
  foreground idle transitions, and failed live inserts. Failure acknowledgment,
  reconciliation, clock discontinuities and imports were added in steps 2–4;
  shared PID-scoped UI helpers and soak checks remain.
  Step 1 verification: `odin check src -vet`, all 16 tests in `odin test src -vet`,
  both builds, and isolated Settings/task UI smoke tests passed. The task script's
  stale toolbar click coordinate was corrected. This does not establish a GDI soak
  result or fix the remaining lifecycle defects.

- [ ] **26. Documentation has drifted from implementation.**
  References: `AGENTS.md`, `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT.md`.
  Examples include raylib references, four-lane descriptions despite three
  rendered lanes, outdated status-bar descriptions, and “merged backward”
  guidance versus code that backdates the next activity.
  Resolve behavioral contracts first, especially short-activity merge direction,
  then update documentation. Preserve deliberate platform/tracking invariants.

## Follow-up verification — step 2

- `odin check src -vet` and all 26 tests in `odin test src -vet` passed.
- Both GUI and CLI builds succeeded.
- The isolated sample CLI import succeeded with 202 activities and 2,745 groups.
- Isolated native persistence, task, Settings, tray, theme/date, and tag tests
  passed. The persistence test held a real SQLite write lock, verified responsive
  timer calls and persistent error state, exercised cancelled Exit, then verified
  automatic retry recovery and clean Exit after releasing the lock.
- Pending writes remain memory-only; forced termination during an outage can
  lose them. Import identity, idle reconciliation, wall-clock scheduling and
  effective live-view consistency remain separate unchecked work.

## Follow-up verification — step 3

- `odin check src -vet` and all 36 tests in `odin test src -vet` passed, including
  import collisions, reimports, local-edit conflicts, deletion tombstones, Unicode/
  embedded NUL text, malformed inputs, and write/commit rollback.
- The normal build was blocked by the user's running `build/aika.exe`. Both
  alternate builds (`build/aika-step3.exe`, `build/aika-step3-cli.exe`) succeeded;
  the existing process was not stopped or replaced.
- The isolated CLI integration test passed: 202 sample activities / 2,745 groups,
  renamed reimports, source isolation, timestamp consistency, local-edit conflict
  handling, version-0 migration, and nonzero failure exit codes.
- Exporter PowerShell syntax and rejection of missing `SourceId` were checked.
  The installed SQL CE exporter was not run against the user's live history.
- Isolated PID-scoped task and persistence UI tests passed against the alternate
  GUI build. Tests with global popup lookup were avoided while another aika
  instance was running.

## Follow-up verification — step 4

- Monotonic scheduling, clock-spell splitting, backward short-switch attribution,
  half-open day bounds and atomic idle reconciliation are implemented. Retryable
  idle transitions retain pending/live ownership until commit; reconciliation
  touches only application IDs owned by the current Active spell.
- Verification uses injected clocks/inputs and explicit Windows DST rules; it
  does not adjust system time, timezone or the user's live tracking database.
- `odin check src -vet` and all 47 tests passed, including clock jumps during
  failed idle retries. GUI/CLI alternate builds succeeded (`build/aika-step4.exe`,
  `build/aika-step4-cli.exe`); the user's running normal GUI was not stopped or
  replaced. Isolated CLI import integration and PID-scoped task/persistence UI
  tests passed. Tests with global popup lookup were not run alongside that GUI.
- Unified live snapshots, cross-midnight overlays, daily list-duration clipping,
  general resource ownership and measured optimizations remain later steps.

## Follow-up verification — step 5

- `odin check src -vet` and all 58 tests passed. Snapshot tests cover pre/post
  persistence and reloads, absent cached rows, midnight/full-day clipping,
  pending-write identity/recovery, failed reads, rollback-safe cache publication,
  frozen clock/idle endpoints, tasks and half-open pixel hit targets.
- The normal `build.bat` succeeded after confirming no existing aika process was
  running. CLI import integration and isolated native task, persistence, tags,
  totals-tree, theme/date, panes, Settings and tray smoke tests passed against
  `build/aika.exe` / `build/aika-cli.exe`.
- Resource-scope safety during nested native message loops, derived-view caching
  and measured performance/resource work remain step 6, not implied by these tests.

## Guardrails for follow-up work

- Keep Windows-only foreground top-level polling at 1 Hz; do not replace it with
  hooks or expand tracking scope as an incidental refactor.
- Preserve ManicTime date/key semantics, quoted `"Group"`, fixed timeline IDs,
  and local/UTC timestamp consistency.
- Keep DB/tracker operations single-threaded unless separately designed.
- Add regression tests before changing lifecycle and interval behavior.
- Run `odin check src -vet`, `odin test src -vet`, both builds, and applicable
  isolated native UI tests after implementation changes.
