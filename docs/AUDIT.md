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

- [x] **8. Startup and CLI failures have broken control flow.**
  References: `src/main.odin:58–78`, `src/main.odin:90`,
  `src/winui.odin:875–992`.
  `ui_bootstrap()` failure is ignored, potentially leaving a process waiting
  without a usable window. Database/import failures return normally from
  `main`, reporting success to scripts. Unknown flags and missing argument values
  are silently ignored.
  Add validated argument parsing, explicit startup stages with cleanup, and
  meaningful failure exit codes.
  Fixed: database/import failures exit nonzero and malformed arguments are rejected.
  GUI startup now checks bootstrap/timer/required-control/font/buffer failures,
  unwinds before returning a failing exit code, and handles GetMessage failure.

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

- [x] **11. Temporary cleanup depends on returning from native modal loops.**
  References: `src/main.odin:108–113`, `src/winui.odin:164`,
  `src/tags.odin:64`.
  Temporary memory is cleared only after outer message dispatch. Native menus,
  message boxes, and move/resize loops can dispatch paints/timers internally,
  accumulating allocations until those loops finish.
  Introduce scoped, reentrancy-safe scratch allocation. Do not simply call
  `free_all` in every callback: that can invalidate outer callbacks' live data.
  Fixed: every native callback owns independent lazy scratch; main key routing has
  its own per-dispatch scope. Nested callbacks cannot clear suspended callbacks'
  allocations. Scratch arenas use runtime map-cache-line alignment.

- [x] **12. Failure-path resource cleanup is incomplete.**
  References: `src/db.odin:128–146`, `src/main.odin:58–64`,
  `src/winui.odin:302–331`.
  Failed DB startup can leave a SQLite handle and cloned path unclosed.
  Backbuffer allocation is unchecked before `mem_valid` becomes true. Bootstrap
  has partial initialization paths without explicit unwinding.
  Make initialization transactional and cleanup safe at every partial stage.
  These are failure-path issues, not evidence of a steady GDI leak.
  Fixed: failed DB opens return an empty, already-closed owner. GUI bootstrap is
  staged and cleanup is repeatable; required controls/fonts/timer are checked.
  Backbuffers are replaced transactionally, with cleanup on DC/bitmap/selection
  failure and a direct-painted error fallback instead of blitting stale sizes.
  Settings/tag/calendar partial control failures unwind. Final teardown releases
  tracker/task metadata without pretending unsaved writes were acknowledged.

## Performance and scalability

- [x] **13. Foreground polling repeatedly reads executable metadata.**
  References: `src/tracker.odin:167–189`, `src/win32.odin:330–424`.
  Each 1 Hz sample opens the process, queries its path, reads version resources,
  builds XML, hashes identity, and prepares/executes a group lookup, even for an
  unchanged application.
  Cache executable metadata and resolved group identity. Continue title sampling
  and preserve the required `(group_id, title)` comparison.
  Fixed: a bounded, one-process cache keyed by PID plus process creation FILETIME
  owns metadata/hash/XML and successful DB group resolution. HWND/PID/title and
  process-instance validation still run on each 1 Hz sample. Cache misses verify
  creation time again before path lookup; process changes and 60-second monotonic
  expiry refresh the entry. Failed metadata/identity lookups are not cached, and
  failed DB lookups retry without discarding valid metadata. No handles are retained.

- [x] **14. Indexes do not match important access patterns.**
  References: `src/db.odin:60–61`, `src/db.odin:437–444`,
  `src/task.odin:35–36`.
  Query-plan inspection found a temporary sort for latest activity and no
  start-time seek for task neighbors. Day loading scans a historical start-date
  range before filtering end dates and sorting.
  Benchmark realistic history and add targeted timeline/start-time indexes.
  Review day-overlap queries separately rather than assuming one index solves
  every access pattern.
  Step 6: added `(TimelineId, StartUtcMs, ActivityId)` after synthetic-history
  measurements on bundled SQLite. Latest-row and task-neighbor reads now seek
  without the old scan/sort. Day reads explicitly retain the local-date index:
  allowing the new index doubled their cost.
  Resolved (day-overlap follow-up): the day query is now a `UNION ALL` of
  ordinary rows (duration <= `LONG_ACTIVITY_MS`, 24 h; bounded seek on
  `IX_Activity_Timeline_Start` over `[dayStart - LONG, dayEnd)`) and long rows
  (partial index `IX_Activity_Long (TimelineId, StartUtcMs) WHERE EndUtcMs -
  StartUtcMs > 86400000`), ordered by `StartUtcMs, ActivityId`. Local-date terms
  stay as row filters, so results are identical (id hashes compared with the
  legacy query for six target days at each size, plus equivalence tests). Median
  load, synthetic 8-year history, bundled SQLite 3.54.1, disk file, cold open,
  21 runs/target:

  | Rows | Target | Legacy median | Split median | Rows loaded |
  |---:|---|---:|---:|---:|
  | 100k | today / 3y ago / oldest | 6,745 / 2,918 / 59 us | 176 / 111 / 91 us | ~34 |
  | 500k | today / 3y ago / oldest | 33,727 / 18,745 / 197 us | 431 / 316 / 243 us | ~171 |
  | 2M | today / 3y ago / oldest | 127,513 / 73,550 / 981 us | 1,426 / 1,166 / 1,820 us | ~685 |

  The legacy cost depended on history age; the new cost is flat across ages and
  proportional to the day's row count (the old query was only fast for the oldest
  day, which the new one gives up by ~0.1-0.8 ms of fixed/row cost).
  Write cost (tracker autocommit insert / update-end medians): 48/34 us before,
  49-51/35-36 us after at every size, i.e. within noise (partial index holds only
  rows > 24 h). Index build on an existing database happens once at open
  (`CREATE INDEX IF NOT EXISTS`; `user_version` unchanged at 1): 64 ms for 0.5M
  rows, 305 ms for 2M rows. Limitations: the long-row branch scans every long row
  older than the day (~0.1 % of synthetic rows; at 2M the "inside a multi-day
  row" day took 2.7 ms); a database with very many > 24 h rows would degrade
  toward the old behavior for that branch. The oldest day got slower (59 -> 91 us
  at 100k, 981 -> 1,820 us at 2M) because the legacy query could stop at once.
  Index size was not measured. Not done: a `max duration` bound for long rows, and `IX_Activity_Timeline_Date`
  is now unused by the app (kept for schema compatibility and as test oracle).

- [x] **15. Derived view data is rebuilt on every repaint.**
  References: `src/ui.odin:537–710`, `src/totals_tree.odin:21–74`.
  Mouse-move repaints rebuild rows, aggregate/sort totals, and potentially rebuild
  the hierarchy. Filtering heap-allocates lowercase candidate names.
  Cache derived data by data revision, date, lane, filter, and tree state; update
  live durations separately. Measure before adding complex rendering machinery.
  Resolved by measurement: on a 900-row day the whole derivation costs ~0.2 ms
  (~0.6 ms with a filter) of a ~9 ms frame, so caching was not added. The frame
  cost was GDI: `DrawTextW` and per-measurement `GetDC`. Text that fits now uses
  clipped `ExtTextOutW`, measurements use the backbuffer DC, and fully
  overpainted/contiguous same-colour bars coalesce with pixel parity. Filter
  lowering uses paint scratch instead of the heap. See the follow-up below.

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

- [x] **17. Hot-path statements are repeatedly prepared/finalized.**
  References: `src/db.odin`, `src/importer.odin:51–71`.
  This is particularly wasteful in imports and repeated endpoint updates.
  Reuse prepared statements for measured hot paths, with explicit ownership and
  complete rebinding. The bindings already expose `sqlite3_reset`.
  Resolved for the measured paths (importer rows/groups, tracker insert and
  end-time update); deliberately not applied elsewhere. Prepare+finalize costs
  2.6-4.3 us per statement (bundled SQLite 3.54.1, temp file DB, WAL). Median
  times, opt-in `statement_reuse_measurement` (synthetic 3,000 groups / 20,000
  activities; 5 runs; 1,001 calls for the writes), one-off prepare -> cache:

  | Path | Before | After |
  |---|---:|---:|
  | Fresh import (~86k prepares) | 1,160 ms | 812 ms (-30 %) |
  | Unchanged re-import (20k lookups) | 261 ms | 198 ms (-24 %) |
  | `db_insert_activity` (autocommit) | 45.9 us | 38.3 us |
  | `db_update_activity_end` (autocommit) | 32.6 us | 25.0 us |
  | `db_extend_task_until_boundary` (not converted) | 66.2 us | 65.6 us (noise) |

  Not converted, by number: the 1 Hz task tick spends ~15 us of 66 us in four
  prepares, i.e. ~0.0015 % of one core; the tracker's 10 s end update saves
  ~7 us per 10 s (converted only because the slot is shared with idle
  reconciliation and the change is mechanical); `db_reconcile_idle_apps` DELETE,
  tag range/resize/color/bounds lookups, day load, `db_ensure_group`, schema and
  one-shot statements are rare or user-driven and keep `db_prepare` + finalize.
  Design: `DB.cache` points to a heap `Stmt_Cache` (explicit `heap_allocator`,
  so allocator-tracking tests and arena contexts cannot misattribute it) with
  fixed `Stmt_Slot`-indexed statements, one SQL text per slot, never keyed by
  string. `db_lease` returns the statement reset with cleared bindings (callers
  rebind every parameter) and `defer db_release` resets/clears on every exit path,
  so no cached statement is left mid-step holding a read lock; the reset return
  code (previous step's error) is ignored, and result codes still come from
  `sqlite3_step`, so Busy/Locked/Failed map exactly as before. A slot already
  leased (reentrancy), a nil/disabled cache, or a cache whose `handle` differs from
  `db.handle` falls back to a one-off prepare/finalize. Copies of a `DB` value
  (`App{db = db}`) are moves: they share the cache pointer, so in-use flags agree;
  only one copy is closed, as before. `db_close` finalizes all slots before
  `sqlite3_close_v2` and clears both pointers (idempotent); `db_init_schema` flushes
  idle slots first, and statements are prepared lazily afterwards.
  Tests: `src/statement_cache_test.odin` (rebinding incl. NULL vs value, early
  returns, constraint error, BUSY from a second connection, reentrancy, rollback
  and failed-import recovery, close/reopen/double close, no leaked statements,
  copy and mismatched-connection safety, byte-identical import dumps cached vs
  uncached across fresh/unchanged/updated imports).

## Structure, readability, and maintainability

- [x] **18. UI interaction state is coupled through globals and integer modes.**
  References: `src/winui.odin:29–72`, `src/winui.odin:441–755`,
  `src/tags.odin:8–19`.
  `ui`, `tag_ui`, `settings_ui`, and `global_app` are tightly coupled. Integer
  drag states and conditions such as `drag >= 2` obscure intent. Cancellation and
  capture handling are duplicated. Escape restores middle-button panning but does
  not cancel overview zoom dragging. Settings bypasses the pressed-button range
  used by the other toolbar buttons.
  Introduce typed interaction states and shared begin/update/commit/cancel
  conventions; split the large window procedure into focused handlers.
  Step 6 partial: typed zoom states and one idempotent cancellation helper now
  cover Escape, capture loss and native modal transitions. Overview drags restore
  their original range too; Settings uses normal press/release feedback. Tag and
  pane modes remain integers, and a broader handler/state rewrite is deferred.
  Partial: batch A (constants + typed Tab/Lane/Pane_Drag/Tag_Drag/Hit). Tab, lane,
  pane and tag drag modes and hit targets are enums; pressable targets use
  `hit_is_pressable` instead of a numeric range. Interaction-state unification
  and the window-procedure split remain open.
  Fixed (batch C): one `Interaction` union in `ui.interaction`
  (`src/interaction.odin`: `Press`/`Pane`/`Zoom`/`Tag` payloads with cancel
  snapshots) replaces `ui.pane_drag`/`ui.zoom_drag`+anchors/snapshots,
  `tag_ui.drag` and `ui.pressed_hit`. Single `interaction_active()` predicate,
  idempotent `interaction_cancel` (restores pane geometry and zoom range, keeps
  the tag range for the picker), state-nil-before-`ReleaseCapture` ordering, and
  per-message `wnd_proc` handlers (`on_mouse_move`, `on_set_cursor`,
  `on_mouse_wheel`, `on_mbutton_down/up`, `on_lbutton_down/up`).
  Verified by 104 tests, all tools/test-*-ui.py scripts, and 92/92 pixel-identical
  snapshots against HEAD (`tools/pixel-snapshot.py`). `ui`/`tag_ui` remain the
  state roots by design.

- [x] **19. Hidden Day-view controls remain clickable on placeholder tabs.**
  Reference: `src/ui.odin:783–815`.
  Only some hit targets are gated on `ui.tab == 0`. Date navigation, task
  controls, and lane hit-testing remain active where they are not drawn.
  Derive hit targets from the active view using rendering's visibility rules.
  Fixed: after shared tab/theme/Settings targets, non-Day views return no hit.
  Exhaustive sampled hit tests and native hidden-task checks cover placeholders.

- [x] **20. Persistence logic leaks into UI and task code.**
  References: `src/tags.odin:317–335`, `src/task.odin:9–48`.
  The picker manages transactions and task code contains raw SQL. Timestamp
  binding is duplicated across insertion, import, resizing, and endpoint updates.
  Add repository operations such as `create_tag_block`, `start_task`, and
  `extend_task_until_boundary`, backed by shared timestamp-binding helpers.
  Fixed: `src/db_tags.odin` owns tag creation/task start/extension transactions,
  typed overlap/storage outcomes, tag identity/color lookup and neighbor queries.
  `src/tags.odin` and `src/task.odin` no longer contain SQL or transaction control.
  `src/db_time.odin` binds all timestamp representations for insertion, end-only
  updates, tag resizing and import writes. Acknowledgements/cache publication
  remain gated on COMMIT. Storage failures retain the picker for retry rather
  than being mislabeled as overlaps.

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

- [x] **23. Constants, names, and palette representation invite mistakes.**
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
  Partial: batch A (constants + typed Tab/Lane/Pane_Drag/Tag_Drag/Hit). Timers,
  thresholds, window sizes, Win32 messages/styles/cursor ids, control ids,
  tooltip and zoom-bar geometry are named (`src/ui_consts.odin`, preferring
  `windows.*`). The palette arrays and the `col_start`/`col_dur` names remain.
  Partial: batches A+B. One named `Palette` (`PALETTE_LIGHT`/`PALETTE_DARK`) replaces
  the three synchronized arrays and the duplicated light literals; `C_*` are
  assigned from it. Semantic fields replace reuse of `C_BTN_HOVER`; `Colorref` and
  a distinct `Argb` separate GDI and stored colors; magic colors/luma thresholds are
  named; list columns are `List_Columns{start,end,duration}` and toolbar names are
  unit-explicit. Remaining: usage identity centralization is done: rendering reads it from tracker
  state/resolved group metadata, never from an assumed group ID. Fixed accents
  are typed `windows.COLORREF` constants; `WS_EX_TOOLWINDOW`,
  `MONITOR_DEFAULTTONEAREST`, `ODS_SELECTED`/`ODS_FOCUS`,
  `EM_GETSEL`/`EM_SETSEL`/`EM_REPLACESEL` and `CHAR_DELETE` are named in
  `src/ui_consts.odin` (no `core:sys/windows` equivalent exists) and used in
  `date_picker.odin`/`filter_edit.odin`. A shared `mouse_point` helper replaces
  the repeated signed-word `lparam` decoding in `wnd_proc` handlers. The
  remaining raw `& 0xFFFF`/`>> 16` message plumbing is standard Win32 word
  extraction.

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
  Step 6: all native scripts now share PID-scoped window/popup/menu discovery;
  no desktop-global popup lookups remain. Added deterministic nested scratch,
  startup-stage unwinding, failed DB open, backbuffer failure and owned-metadata
  teardown tests, plus a measured native resource soak (below).
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

## Follow-up verification — step 6

- `odin check src -vet`, all 64 Odin tests and normal `build.bat` GUI/CLI builds
  passed. The opt-in benchmark also ran single-threaded with production SQLite.
  The original GUI was left untouched while running; alternate names were built
  initially. Normal builds ran only after no aika process remained.
- All isolated native task, persistence, tags, totals-tree, theme/date, panes,
  Settings and tray scripts passed sequentially, as did CLI import integration.
- Resource baseline: a copy of the existing step-5 GUI with 900 synthetic daily
  app rows grew from 7,446,528 to 104,431,616 private bytes during 300 forced paints
  inside one suspended tray-menu callback (3.37 s), returning to 7,675,904 after
  closing the menu. This intentionally failed the new bounded-growth assertion.
- Final build: 2,000 modal paints over 21.97 s, after 30 resize/Settings/tag-popup
  cycles, passed. Private bytes went from 7,565,312 to a maximum modal sample of 7,831,552;
  process handles stayed 169. GDI/USER counts stayed bounded (menu 23/23, after
  dismissal 22/20). This is a short deterministic stress run, not an overnight
  leak proof. Other desktop-activation-interrupted attempts are not counted as
  passing soaks; Windows lazy services can also cause one-time handle plateaus.
- Measured optimization: 337,990 synthetic rows (365 days × 900 app switches,
  24 tags, 2 usage rows), 21 executions/query, median prepare+step+finalize time,
  bundled SQLite 3.54.1, in-memory, single test thread:

  | Query | Before index | After index |
  |---|---:|---:|
  | Latest app | 92.962 ms | 0.006 ms |
  | Next task boundary | 2.319 ms | 0.005 ms |
  | Recent day, unrestricted planner | 21.091 ms | 30.008 ms |
  | Recent day, retained date index | 18.773 ms | 18.248 ms |

  (Superseded by item 14's day-overlap follow-up: the date query no longer uses
  `IX_Activity_Timeline_Date`.) At this step the date query deliberately used
  `INDEXED BY IX_Activity_Timeline_Date` to avoid the measured regression. A separate
  Python SQLite 3.50.4 disk-backed proxy reproduced the same plan tradeoff. Added
  query-plan regression tests and repeatable opt-in Odin/Python benchmarks.
- Deferred: executable metadata/resolved identity caching, prepared-statement
  reuse, snapshot/derived-view caching, write-through array capacity changes,
  generalized day-overlap indexing and import peak-memory profiling. None was
  justified by the measurements made here. Index creation is additive on startup
  and has an upfront disk/time cost on large existing histories; all measurements
  used synthetic isolated databases, never the user's live history.
- Failure testing covers each acquired bootstrap stage and DC/bitmap/selection
  failures, not every possible system/heap OOM or all native API failure codes.
  No broader DPI/keyboard policy or new tracker/product features were added.

## Follow-up verification — audit item 20

- `odin check src -vet` and all 71 tests pass on
  `dev-2026-11-nightly:10e57eb`. New repository tests cover creation/name reuse,
  overlap/invalid/missing targets, ignored/aborted writes, deferred-constraint
  COMMIT failures, real writer contention via independent shared-memory SQLite
  connections, task/cache acknowledgement, midnight neighbors and timestamp
  consistency across every SQL layout, including binding failures.
- GUI/CLI alternate builds (`build/aika-audit20.exe`,
  `build/aika-audit20-cli.exe`) succeeded. The user's running normal GUI was not
  stopped or overwritten. CLI import integration and isolated tag/task/persistence
  UI smoke tests passed. Tag smoke coverage now holds a real independent writer lock,
  verifies the save-error message and retained picker, then retries successfully.
- No live database, schema migration, interval-policy change or performance
  optimization was part of this follow-up. Some older boolean convenience
  repository wrappers remain for existing callers/tests; new transactions use
  checked result APIs.

## Follow-up verification — audit item 13

- The opt-in own-process benchmark isolates metadata/group resolution: foreground
  HWND/PID/title are a fixed injected sample, and the DB is in-memory. The process
  is the versionless test executable, not representative of every application.
  With the testing allocator enabled, a same-build 101-sample comparison measured
  medians of 53.2 microseconds uncached versus 2.9 microseconds with identity
  validation/cache reuse (p95 107.7 versus 3.4 microseconds). An earlier uncached
  baseline was 74.5 microseconds. These are small absolute costs, not end-to-end
  CPU savings or a justification for an unbounded/multi-process cache.
- Deterministic tests cover fresh titles/windows, same-app process switches,
  reused PIDs, unavailable foreground/identity/path/metadata, legitimate versionless
  fallback, failed DB lookup/recovery, TTL refresh, database scoping, scratch
  lifetime and repeatable cleanup. Native tests validate the current process and
  reject a mismatched creation stamp and missing-resource-file I/O failure.
- `odin check src -vet` and all 81 tests passed on the updated compiler.
  Alternate GUI/CLI builds (`build/aika-audit13.exe`,
  `build/aika-audit13-cli.exe`) passed, leaving the running normal GUI untouched.
  Isolated CLI import, native task and persistence tests passed. A 2,000-modal-paint
  resource soak also passed: sampled handles stayed at 177; private bytes ranged
  from 7,671,808 warm to a maximum of 7,942,144 over 22.6 seconds. This is bounded
  short-soak evidence, not an overnight leak proof or forced OS PID-reuse test.
- Metadata refresh may lag external resource/group edits by up to 60 seconds.
  Statement/derived-view caching and broader polling/performance work remain
  separate audit items; this change preserves group keys and lifecycle policy.

## Follow-up verification — audit item 15

- Opt-in `view_paint_measurement` (`AIKA_VIEW_BENCHMARK=1`, `-o:speed`, one test
  thread, testing allocator on): synthetic day with 900 app rows/60 groups, 24
  hierarchical tags and 2 usage rows, painted offscreen at 1320x860. Baseline was
  measured in a temporary HEAD worktree with the same benchmark, alternating
  three rounds with the new build in one session:

  | Median per repaint | HEAD `2dec7cc` | After |
  |---|---:|---:|
  | Derived data only (snapshot, rows, totals, bar hit) | ~0.19 ms | ~0.19 ms |
  | Full frame, rows spread over 24 h | 8.6–9.6 ms | 5.7 ms |
  | Full frame, rows clustered 09:00–18:00 | 8.5–8.8 ms | 4.4–5.0 ms |
  | Details list / totals panel | 1.77 / 0.99 ms | 0.58 / 0.29 ms |

  GDI primitives on the backbuffer: `DrawTextW` 15–56 µs per call, clipped
  `ExtTextOutW` 3–7 µs, `GetDC`-based measurement 8.9 µs vs 0.7 µs on the
  backbuffer DC, `FillRect` ~1.4 µs. With the spread synthetic data, bars rarely
  share pixels, so coalescing gives no gain there. With the clustered data it took
  the frame from 5.6 to 4.4 ms (same-session toggle).
- Rendering contract: text that fits is drawn by `ExtTextOutW` at the same origin
  and clip rectangle; overflow still uses `DrawTextW` end ellipsis. Tests show the
  result is pixel-identical to `DrawTextW` for space-free text (times, durations)
  and identical to an independent clipped `ExtTextOutW` reference for all fitting
  text. Strings containing spaces can differ from `DrawTextW` by up to 1 px in
  glyph placement after a space. That placement now matches
  `GetTextExtentPoint32W`, which layout already used for alignment. Bar
  coalescing is pixel-identical to one `FillRect` per bar over 200 randomized
  dense/sparse sequences.
- `odin check src -vet` and all 83 tests passed. Alternate builds
  (`build/aika-perf.exe`, `build/aika-perf-cli.exe`) passed; the running normal GUI
  was not touched. Isolated tags, task, totals-tree, theme/date, panes,
  persistence, import and 2,000-modal-paint resource soak scripts passed (handles
  stayed at 177, GDI 22, USER 20).
- Not done: DIB-based bar rendering. This is a measured opportunity, not a defect.
  Repaint frequency (every mouse move repainted the full frame) is addressed by
  the mouse-move follow-up below; the `DrawTextW` cost for overflowing
  tag/title labels is addressed by the ellipsized-text follow-up (most
  ellipsized text now skips `DrawTextW`; complex scripts still use it).
  Correction: the ≤1 px placement difference above comes from `DrawTextW`'s pair
  kerning ("Wo", "Te", "AV", ...), not from spaces.

## Follow-up - mouse-move repaints

- `WM_MOUSEMOVE` used to invalidate the full frame on every position change.
  Now `draw_frame` records a `Hover_Signature` for the position it painted:
  a bit for each rectangle whose drawing reads `ui.mouse` (3 tabs, theme and
  settings switches and their tooltips, prev/next/Today/task, zoom -/+/Full
  day, totals-mode button and its tooltip, both pane splitters), plus the bar
  tooltip's snapshot row. A move repaints when the signature at the new
  position differs, or whenever a bar tooltip is painted or would be. That box
  follows the cursor. `draw_tooltip` and the signature share
  `tooltip_lane`/`tooltip_bar_hit`, including the drag/popup/menu suppression
  and the filter check. The snapshot is built on a move only when the cursor is
  over a lane's bar rectangle. Pane, tag and zoom drags still invalidate on
  their own paths. The 500 ms timer repaint is unchanged.
- Existing gap, fixed: `WM_MOUSELEAVE` was handled, but `TrackMouseEvent` was
  never called, so it never arrived. Hover/tooltips lingered after the cursor
  left, until the next timer paint (up to 500 ms). Leave tracking is now armed
  on mouse move, and leave repaints if the last frame drew hover state. This is
  the only intended visible difference: the hover clears sooner.
- `hover_repaint_behavior` (serialized in `zoom_behavior`) covers these cases:
  empty-area moves, entering/leaving/moving within a button, a distinct bit per
  hover rectangle, placeholder tabs, moves inside one tooltip bar, moves
  between bars and lanes, suppression during drags or the menu, filter-hidden
  bars, the lazy window-side variant matching the pure one, and `draw_tooltip`
  painting a box exactly when the signature reports a bar.
  `odin check src -vet` and all 83 tests passed. Alternate builds
  (`build/aika-mouse.exe`, `build/aika-mouse-cli.exe`) passed. Isolated theme,
  tags, task, totals-tree, panes, persistence, resources, settings and tray
  scripts passed.
- Scripted sweep: 400 synthetic `WM_MOUSEMOVE`s, each followed by
  `UpdateWindow`, isolated DB. Target-process CPU, two runs each:

  | Sweep | Before | After |
  |---|---:|---:|
  | Details list (empty area) | 766-969 ms | 0-16 ms |
  | Empty Tags lane | 875-1031 ms | 0 ms |

  Synthetic moves over the tab strip still repaint often (500-625 ms). Paint
  reads the real cursor via `GetCursorPos`, which sat outside the window, so
  every paint recorded "no hover". With real input this only happens on tab
  crossings. A cross-process `GetUpdateRect` count was not reliable on the
  baseline and is not quoted.

## Follow-up — ellipsized text

- `draw_string` overflow no longer calls `DrawTextW` for simple text.
  `end_ellipsis_layout` (`src/winui.odin`) reproduces `DT_END_ELLIPSIS` with
  `GetCharacterPlacementW(GCP_USEKERNING)`, then draws one clipped `ExtTextOutW`
  with those advances. Rule, derived from per-width `DT_MODIFYSTRING` tables:
  if the kerned line fits, draw it whole. Otherwise keep the longest prefix
  whose own kerned width (the line's kerned advances before the last kept unit,
  plus that unit's `GetCharWidth32W` advance) plus the width of `"..."` fits.
  Keep at least one unit, clipped when even that is too wide, as `DrawTextW`
  does at 1 px. Then draw prefix + `"..."` kerned together. The ellipsis is
  three periods. Skipping labels at tiny widths was rejected because `DrawTextW`
  still draws a clipped first glyph there.
- Falls back to `DrawTextW` unless every UTF-16 unit is in a simple BMP
  whitelist, the font maps each one to its own glyph (`GetGlyphIndicesW`, so no
  font linking), and placement is one glyph per unit (no ligatures). Probes showed
  `GetCharacterPlacementW` failing or mis-measuring otherwise: CJK in Segoe UI,
  surrogate pairs, combining marks, Yu Gothic's "fi" ligature. Fallback covers
  surrogates/emoji, combining marks, RTL, joiners and invalid UTF-16, so a
  surrogate pair is never split by this code. `GCP_MAXEXTENT` was tried and
  rejected (inconsistent fit and advances).
- Parity (`gdi_ellipsis_matches_drawtext`): every width from 1 px to past the
  extent, 20 strings, 8 fonts (stock, Segoe UI 12/12 bold/11/20 bold,
  Segoe UI Symbol, Yu Gothic UI, Malgun Gothic). 12,131 overflow renderings are
  pixel-identical to `DrawTextW(DT_END_ELLIPSIS)`. The 6,760 that took the new
  path also kept exactly the prefix `DT_MODIFYSTRING` reports. The other 5,371
  are `DrawTextW` itself. 628 fitting renderings still match the clipped
  `ExtTextOutW` contract. Exact parity, no accepted differences, for
  overflowing text on this machine's fonts.
- Measured with `view_paint_measurement`, 3 alternating rounds against an
  exported `HEAD` copy with the same benchmark, medians. Absolute numbers run
  ~1.7x the item-15 session's because of concurrent machine load, so compare
  within a column pair only.

  | Median | Before | After |
  |---|---:|---:|
  | Tag label, bold, 60 px (`Draw_String_Tag_Label`) | 66.1 µs | 26.7 µs |
  | 47-char title, 120 px (`Draw_String_Clipped`) | 85.6 µs | 32.8 µs |
  | Tag label, 5 px (`Draw_String_Tag_Tiny`) | 32.8 µs | 21.8 µs |
  | `DrawTextW` end ellipsis (reference) | 61.9 µs | 62.7 µs |
  | `Ruler_Lanes` component | 4.90 ms | 3.56 ms |
  | List / Totals components | 1.23 / 0.54 ms | 1.13 / 0.48 ms |

  Whole-frame medians stayed within this session's noise (for example `Frame`
  9.5 vs 10.2 ms, `Frame_Clustered` 8.4 vs 7.8 ms, overlapping ranges).
  Remaining cost per ellipsized draw: two `GetCharacterPlacementW` calls
  (~2.6 µs + ~0.25 µs per unit each), `GetGlyphIndicesW`, and `ExtTextOutW`.
- `odin check src -vet` and all 84 tests passed. Alternate builds
  `build/aika-tags.exe` and `build/aika-tags-cli.exe` passed. Isolated tags,
  task, totals-tree, theme, panes and resource-soak UI scripts passed against
  the GUI build.

## Guardrails for follow-up work

- Keep Windows-only foreground top-level polling at 1 Hz; do not replace it with
  hooks or expand tracking scope as an incidental refactor.
- Preserve ManicTime date/key semantics, quoted `"Group"`, fixed timeline IDs,
  and local/UTC timestamp consistency.
- Keep DB/tracker operations single-threaded unless separately designed.
- Add regression tests before changing lifecycle and interval behavior.
- Run `odin check src -vet`, `odin test src -vet`, both builds, and applicable
  isolated native UI tests after implementation changes.
