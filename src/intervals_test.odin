package main

import "core:testing"
import "core:sys/windows"

@(test)
half_open_days_follow_explicit_dst_rules :: proc(t: ^testing.T) {
	// US Eastern rules; no process-wide or machine timezone mutation.
	zone := windows.TIME_ZONE_INFORMATION{Bias = 300, DaylightBias = -60,
		DaylightDate = WIN_TIME{month = 3, day = 2, day_of_week = 0, hour = 2},
		StandardDate = WIN_TIME{month = 11, day = 1, day_of_week = 0, hour = 2}}
	expected := [3]i64{23, 25, 24}
	for date, i in ([3]int{20260308, 20261101, 20261106}) {
		start, end := day_bounds_ms(date, &zone)
		next, _ := day_bounds_ms(add_days(date, 1), &zone)
		hours := expected[i]
		testing.expect(t, end == next && end - start == hours * 3600_000)
	}
}

@(test)
tracker_idle_reconciles_multiple_persisted_switches :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	tracker_test_tick(&app, &input, start + 5000)
	input.info.title = "Automatic switch 1"
	tracker_test_tick(&app, &input, start + 20_000)
	tracker_test_tick(&app, &input, start + 25_000)
	input.info.title = "Automatic switch 2"
	tracker_test_tick(&app, &input, start + 40_000)
	tracker_test_tick(&app, &input, start + 45_000)
	testing.expect(t, db_exec(&app.db, `CREATE TRIGGER fail_idle_delete BEFORE DELETE ON Activity
		WHEN OLD.TimelineId=3 BEGIN SELECT RAISE(ABORT, 'test idle delete failure'); END`))
	input.idle = 60_000
	tracker_test_tick(&app, &input, start + 70_000)
	testing.expect(t, app.tracker.idle_pending && app.tracker.current.active)
	testing.expect(t, db_count_activities(&app.db) == 4, "Partial trims and deletions must roll back together")
	testing.expect(t, db_exec(&app.db, "DROP TRIGGER fail_idle_delete"))
	tracker_test_tick(&app, &input, start + 71_000)
	testing.expect(t, !app.tracker.idle_pending && app.tracker.usage_kind == .Away)
	testing.expect(t, import_test_scalar(&app.db, "SELECT count(*) FROM Activity WHERE EndUtcMs<StartUtcMs") == 0)
	testing.expect(t, import_test_scalar(&app.db, "SELECT count(*) FROM Activity WHERE TimelineId=3") == 1)
	last, result := db_last_activity(&app.db, TIMELINE_APPS)
	defer delete(last.display_name)
	testing.expect(t, result == .Ok && last.start_ms == start && last.end_ms == start + 10_000)
	stmt, prepared := db_prepare(&app.db, "SELECT EndLocalTime, EndUtcTime, EndLocalDate FROM Activity WHERE ActivityId=?1")
	testing.expect(t, prepared)
	if !prepared { return }
	defer sqlite3_finalize(stmt)
	bind_i64(stmt, 1, last.id)
	testing.expect(t, sqlite3_step(stmt) == SQLITE_ROW)
	local_text, utc_text := col_text(stmt, 0), col_text(stmt, 1)
	defer delete(local_text)
	defer delete(utc_text)
	testing.expect(t, local_text == format_systemtime(unix_ms_to_local(last.end_ms)))
	testing.expect(t, utc_text == format_systemtime(unix_ms_to_utc(last.end_ms)))
	testing.expect(t, col_i64(stmt, 2) == manic_date_from_date_int(date_int_from_unix_ms(last.end_ms)))
}

@(test)
tracker_idle_never_rewrites_unowned_history :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	tracker_test_tick(&app, &input, start + 5000)
	// A legacy/imported row can share timestamps after a clock adjustment. It
	// must not become owned just because it lies inside this Active spell.
	_, result := db_insert_activity(&app.db, TIMELINE_APPS, "Existing history",
		app.tracker.current.group_id, start + 20_000, start + 50_000)
	testing.expect(t, result == .Ok)
	input.idle = 60_000
	tracker_test_tick(&app, &input, start + 70_000)
	testing.expect(t, !app.tracker.idle_pending)
	testing.expect(t, import_test_scalar(&app.db, "SELECT EndUtcMs-StartUtcMs FROM Activity WHERE DisplayName='Existing history'") == 30_000)
}

@(test)
tracker_exit_before_clock_tick_does_not_stretch_history :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	app.tracker.io.monotonic = tracker_test_mono
	tracker_init(&app)
	start := input.now
	input.mono = 5000
	tracker_test_tick(&app, &input, start + 5000)
	input.mono = 6000
	input.now = start + 3600_000
	testing.expect(t, tracker_shutdown(&app))
	testing.expect(t, import_test_scalar(&app.db, "SELECT MAX(EndUtcMs-StartUtcMs) FROM Activity") == 5000)
}

@(test)
tracker_clock_jump_survives_failed_idle_retries :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	app.tracker.io.monotonic = tracker_test_mono
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	input.mono = 5000
	tracker_test_tick(&app, &input, start + 5000)
	input.fail_update = true
	input.idle = 60_000
	input.mono = 70_000
	tracker_test_tick(&app, &input, start + 70_000)
	testing.expect(t, app.tracker.idle_pending)
	input.mono = 71_000
	tracker_test_tick(&app, &input, start + 3671_000)
	testing.expect(t, app.tracker.idle_pending)
	input.fail_update = false
	input.mono = 72_000
	tracker_test_tick(&app, &input, start + 3672_000)
	testing.expect(t, !app.tracker.idle_pending && app.tracker.usage_start_ms == input.now)
	testing.expect(t, import_test_scalar(&app.db, "SELECT MAX(EndUtcMs-StartUtcMs) FROM Activity") <= 60_000,
		"Failed retries must not swallow a clock jump and stretch Away across it")
}

@(test)
tracker_idle_rollback_keeps_pending_ownership :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	input.fail_insert = true
	input.info.title = "Automatic"
	tracker_test_tick(&app, &input, start + 20_000)
	testing.expect(t, app.tracker.pending_count == 1)
	input.info.title = "Another automatic switch"
	tracker_test_tick(&app, &input, start + 40_000)
	testing.expect(t, app.tracker.pending_count == 2)
	input.fail_insert = false
	// Defer failure until COMMIT, after pending inserts, clipping, Active end,
	// and Away insertion have all executed successfully inside the transaction.
	testing.expect(t, db_exec(&app.db, `CREATE TABLE IdleCommitGuard (ref INTEGER REFERENCES Timeline(TimelineId) DEFERRABLE INITIALLY DEFERRED);
		CREATE TRIGGER fail_idle AFTER INSERT ON Activity WHEN NEW.DisplayName='Away'
		BEGIN INSERT INTO IdleCommitGuard VALUES(999); END`))
	input.idle = 60_000
	// Call the transition directly so the normal pre-tick retry cannot consume
	// the queue outside the reconciliation transaction.
	app.tracker.idle_pending = true
	app.tracker.idle_cutoff, app.tracker.idle_observed = start + 10_000, start + 70_000
	input.now = start + 70_000
	testing.expect(t, !tracker_reconcile_idle(&app))
	testing.expect(t, app.tracker.pending_count == 2 && app.tracker.pending[0].id == 0 && app.tracker.pending[1].id == 0)
	testing.expect(t, app.tracker.current.active && app.tracker.usage_kind == .Active)
	testing.expect(t, db_count_activities(&app.db) == 1)
	testing.expect(t, !tracker_shutdown(&app), "Exit cannot bypass a failed idle transaction")
	testing.expect(t, db_exec(&app.db, "DROP TRIGGER fail_idle"))
	testing.expect(t, tracker_reconcile_idle(&app))
	testing.expect(t, app.tracker.pending_count == 0 && !app.tracker.current.active)
	testing.expect(t, db_count_activities(&app.db) == 3)
	last, result := db_last_activity(&app.db, TIMELINE_APPS)
	defer delete(last.display_name)
	testing.expect(t, result == .Ok && last.end_ms == start + 10_000)
	testing.expect(t, tracker_write_error(&app) == .Ok)
}

@(test)
tracker_first_transient_and_pause_do_not_bridge_gaps :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	start := input.now
	input.info.title = "Next"
	tracker_test_tick(&app, &input, start + 2000)
	testing.expect(t, app.tracker.current.start_ms == start + 2000)
	testing.expect(t, import_test_scalar(&app.db, "SELECT count(*) FROM Activity WHERE TimelineId=3") == 0)
	tracker_test_tick(&app, &input, start + 7000)
	input.now = start + 8000
	tracker_pause(&app)
	input.now = start + 8500
	tracker_resume(&app)
	testing.expect(t, app.tracker.current.persisted_id == 0 && app.tracker.current.start_ms == input.now,
		"Even a sub-second pause must start a new owned interval")
	input.now = start + 9000
	testing.expect(t, tracker_shutdown(&app))
	last, result := db_last_activity(&app.db, TIMELINE_APPS)
	defer delete(last.display_name)
	testing.expect(t, result == .Ok && last.start_ms == start + 8500 && last.end_ms == start + 9000)
}

@(test)
tracker_short_switch_merges_backward_not_forward :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	tracker_test_tick(&app, &input, start + 5000)
	input.info.title = "Transient"
	tracker_test_tick(&app, &input, start + 6000)
	input.info.title = "Next"
	tracker_test_tick(&app, &input, start + 8000)
	testing.expect(t, app.tracker.current.start_ms == start + 8000)
	last, result := db_last_activity(&app.db, TIMELINE_APPS)
	defer delete(last.display_name)
	testing.expect(t, result == .Ok && last.display_name == "Document" && last.end_ms == start + 8000)
}

tracker_test_mono :: proc(data: rawptr) -> i64 { return (^Tracker_Test_Input)(data).mono }

@(test)
tracker_clock_jumps_split_without_stalling_or_stretching :: proc(t: ^testing.T) {
	for delta in ([2]i64{-3600_000, 3600_000}) {
		input: Tracker_Test_Input
		app, ok := tracker_test_app(&input)
		testing.expect(t, ok)
		if !ok { return }
		app.tracker.io.monotonic = tracker_test_mono
		tracker_init(&app)
		start := input.now
		input.mono = 5000
		tracker_test_tick(&app, &input, start + 5000)
		old := app.tracker.current.persisted_id
		input.mono = 6000
		tracker_test_tick(&app, &input, start + 6000 + delta)
		testing.expect(t, app.tracker.current.start_ms == input.now && app.tracker.current.persisted_id == 0)
		testing.expect(t, import_test_scalar(&app.db, "SELECT MAX(EndUtcMs-StartUtcMs) FROM Activity") <= 5000)
		stmt, prepared := db_prepare(&app.db, "SELECT EndUtcMs FROM Activity WHERE ActivityId=?1")
		testing.expect(t, prepared)
		if prepared {
			bind_i64(stmt, 1, old)
			testing.expect(t, sqlite3_step(stmt) == SQLITE_ROW && col_i64(stmt, 0) == start + 5000)
			sqlite3_finalize(stmt)
		}
		input.mono = 11_000
		tracker_test_tick(&app, &input, input.now + 5000)
		testing.expect(t, app.tracker.current.persisted_id > 0, "Backward jumps do not suspend sampling")
		testing.expect(t, tracker_shutdown(&app))
		db_close(&app.db)
	}
}

@(test)
half_open_days_and_repository_reject_reversed_intervals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	for date in ([4]int{20260329, 20261025, 20260308, 20261101}) {
		start, end := day_bounds_ms(date)
		next, _ := day_bounds_ms(add_days(date, 1))
		testing.expect(t, end == next && end > start, "Adjacent local days share exactly one boundary, including DST dates")
		id, result := db_insert_activity(&db, TIMELINE_COMPUTER, "Active", 1, end - 1000, end)
		testing.expect(t, result == .Ok)
		_, bad := db_insert_activity(&db, TIMELINE_COMPUTER, "Invalid", 1, end, start)
		testing.expect(t, bad != .Ok && db_update_activity_end(&db, id, end - 1001) != .Ok)
		rows, loaded := db_load_activities(&db, add_days(date, 1))
		testing.expect(t, loaded == .Ok && len(rows) == 0, "An interval ending at midnight does not overlap the next day")
		free_activities(rows)
	}
}

@(test)
task_clock_jump_stops_at_acknowledged_endpoint :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	app.tracker.io.monotonic = tracker_test_mono
	start := input.now
	testing.expect(t, task_start(&app, 0, "Task", start))
	input.mono = 1000
	testing.expect(t, task_tick(&app, start + 1000))
	input.mono = 2000
	testing.expect(t, task_tick(&app, start + 3600_000))
	testing.expect(t, app.task.id == 0)
	last, result := db_last_activity(&app.db, TIMELINE_TAGS)
	defer delete(last.display_name)
	testing.expect(t, result == .Ok && last.end_ms == start + 1000)
}
