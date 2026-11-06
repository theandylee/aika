package main

import "core:testing"

snapshot_expect_ms :: proc(t: ^testing.T, snapshot: Day_Snapshot, timeline, expected: i64) {
	rows := build_rows(snapshot, timeline)
	totals := build_totals(snapshot, timeline)
	defer free_totals_slice(totals)
	row_ms, total_ms, bar_ms: i64
	for row in rows { row_ms += row.end_ms - row.start_ms }
	for total in totals { total_ms += total.ms }
	for row in snapshot.rows {
		if row.activity.timeline_id == timeline { bar_ms += row.end_ms - row.start_ms }
	}
	testing.expect(t, row_ms == expected && total_ms == expected && bar_ms == expected,
		"List, totals and bar/overview intervals must describe exactly the same time")
}

@(test)
snapshot_persistence_boundary_and_reload_never_drop_live_time :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	app.date = date_int_from_unix_ms(input.now)
	tracker_init(&app)
	defer { free_activities(app.activities) }
	defer tracker_shutdown(&app)
	testing.expect(t, load_day(&app))
	start := input.now
	snapshot_expect_ms(t, build_day_snapshot(&app, start + 4999, start + 4999), TIMELINE_APPS, 4999)
	tracker_test_tick(&app, &input, start + 5000)
	testing.expect(t, app.tracker.current.persisted_id > 0)
	snapshot := build_day_snapshot(&app, input.now, input.now)
	testing.expect(t, len(build_rows(snapshot, TIMELINE_APPS)) == 1)
	snapshot_expect_ms(t, snapshot, TIMELINE_APPS, 5000)
	snapshot_expect_ms(t, snapshot, TIMELINE_COMPUTER, 5000)
	snapshot_expect_ms(t, build_day_snapshot(&app, start + 14_000, start + 14_000), TIMELINE_APPS, 14_000)
	tracker_test_tick(&app, &input, start + 15_000)
	testing.expect(t, load_day(&app))
	// Database results contain saved endpoints only; live extension belongs
	// exclusively to the snapshot and cannot corrupt the cached persisted row.
	for a in app.activities {
		if a.id == app.tracker.current.persisted_id { testing.expect(t, a.end_ms == start + 15_000) }
	}
	snapshot = build_day_snapshot(&app, start + 18_000, start + 18_000)
	snapshot_expect_ms(t, snapshot, TIMELINE_APPS, 18_000)
	snapshot_expect_ms(t, snapshot, TIMELINE_COMPUTER, 18_000)
	min, max := day_span(snapshot)
	testing.expect(t, min == start && max == start + 18_000)
}

@(test)
snapshot_persisted_but_missing_cache_and_cross_midnight :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	date := 20261107
	ds, _ := day_bounds_ms(date)
	app := App{date = date}
	app.tracker.current = CurrentActivity{active = true, persisted_id = 42, group_id = 77,
		app_name = "Editor", title = "日本語 😀", group_color = 0xff123456, start_ms = ds - 10_000}
	app.tracker.usage_active = true
	app.tracker.usage_id, app.tracker.usage_group = 43, 80
	app.tracker.usage_start_ms = ds - 10_000
	snapshot := build_day_snapshot(&app, ds + 2000, 0)
	snapshot_expect_ms(t, snapshot, TIMELINE_APPS, 2000)
	snapshot_expect_ms(t, snapshot, TIMELINE_COMPUTER, 2000)
	rows := build_rows(snapshot, TIMELINE_APPS, "日本語")
	testing.expect(t, len(rows) == 1 && rows[0].is_current && rows[0].start_ms == ds)
	testing.expect(t, rows[0].full_start_ms == ds - 10_000 && rows[0].end_ms == ds + 2000)
	testing.expect(t, app.activities == nil && app.tracker.current.start_ms == ds - 10_000,
		"Projection must not mutate its source")
	app.date = add_days(date, -1)
	snapshot = build_day_snapshot(&app, ds + 2000, 0)
	snapshot_expect_ms(t, snapshot, TIMELINE_APPS, 10_000)
	snapshot_expect_ms(t, snapshot, TIMELINE_COMPUTER, 10_000)
	for row in snapshot.rows { testing.expect(t, row.end_ms == ds && row.live) }
}

@(test)
snapshot_clips_full_multiday_bounds_and_excludes_empty_edges :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ds, de := day_bounds_ms(20261106)
	activities := [?]Activity{
		{id = 1, timeline_id = TIMELINE_APPS, group_id = 7, group_name = "Editor", display_name = "Document", start_ms = ds - 1000, end_ms = de + 1000},
		{id = 2, timeline_id = TIMELINE_APPS, start_ms = ds - 5000, end_ms = ds},
		{id = 3, timeline_id = TIMELINE_APPS, start_ms = de, end_ms = de + 5000},
		{id = 4, timeline_id = TIMELINE_APPS, start_ms = ds + 1000, end_ms = ds + 1000},
		{id = 5, timeline_id = TIMELINE_APPS, start_ms = ds + 2000, end_ms = ds + 1000},
	}
	app := App{date = 20261106, activities = activities[:]}
	snapshot := build_day_snapshot(&app, de + 5000, 0)
	testing.expect(t, len(snapshot.rows) == 1)
	snapshot_expect_ms(t, snapshot, TIMELINE_APPS, de - ds)
	rows := build_rows(snapshot, TIMELINE_APPS)
	testing.expect(t, rows[0].start_ms == ds && rows[0].end_ms == de)
	testing.expect(t, rows[0].full_start_ms == ds - 1000 && rows[0].full_end_ms == de + 1000)
	testing.expect(t, fmt_snapshot_clock(snapshot, rows[0].end_ms) == "24:00")
}

@(test)
snapshot_pending_and_recovered_final_writes_remain_visible :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	app.date = date_int_from_unix_ms(input.now)
	tracker_init(&app)
	defer { free_activities(app.activities) }
	defer tracker_shutdown(&app)
	testing.expect(t, load_day(&app))
	start := input.now
	input.fail_insert = true
	input.info.title = "Next"
	tracker_test_tick(&app, &input, start + 6000)
	testing.expect(t, app.tracker.pending_count == 1)
	snapshot := build_day_snapshot(&app, start + 7000, start + 7000)
	testing.expect(t, len(build_rows(snapshot, TIMELINE_APPS)) == 2)
	snapshot_expect_ms(t, snapshot, TIMELINE_APPS, 7000)
	input.fail_insert = false
	tracker_test_tick(&app, &input, start + 8000)
	testing.expect(t, app.tracker.pending_count == 0)
	snapshot = build_day_snapshot(&app, input.now, input.now)
	testing.expect(t, len(build_rows(snapshot, TIMELINE_APPS)) == 2)
	snapshot_expect_ms(t, snapshot, TIMELINE_APPS, 8000)
	// A finalized successful row survives independently of the now-cleared queue
	// and live current, without requiring another database reload.
	input.now = start + 9000
	tracker_pause(&app)
	snapshot_expect_ms(t, build_day_snapshot(&app, input.now, input.now), TIMELINE_APPS, 9000)
}

@(test)
snapshot_pending_updates_replace_ids_but_not_distinct_unsaved_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ds, _ := day_bounds_ms(20261106)
	activities := [?]Activity{{id = 10, timeline_id = TIMELINE_APPS, group_id = 5,
		display_name = "Title", group_name = "Editor", start_ms = ds, end_ms = ds + 1000}}
	app := App{date = 20261106, activities = activities[:]}
	app.tracker.pending_count = 3
	app.tracker.pending[0] = Pending_Activity{id = 10, timeline = TIMELINE_APPS,
		group = 5, title = "Title", start_ms = ds, end_ms = ds + 2000}
	app.tracker.pending[1] = Pending_Activity{timeline = TIMELINE_APPS,
		group = 5, title = "Title", start_ms = ds + 2000, end_ms = ds + 3000}
	app.tracker.pending[2] = Pending_Activity{timeline = TIMELINE_APPS,
		group = 5, title = "Title", start_ms = ds + 3000, end_ms = ds + 4000}
	snapshot := build_day_snapshot(&app, ds + 5000, 0)
	testing.expect(t, len(snapshot.rows) == 3)
	snapshot_expect_ms(t, snapshot, TIMELINE_APPS, 4000)
	testing.expect(t, snapshot.rows[1].activity.id != snapshot.rows[2].activity.id)
}

@(test)
snapshot_cache_idle_changes_only_after_commit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	app.date = date_int_from_unix_ms(input.now)
	tracker_init(&app)
	defer { free_activities(app.activities) }
	defer tracker_shutdown(&app)
	testing.expect(t, load_day(&app))
	start := input.now
	tracker_test_tick(&app, &input, start + 5000)
	input.info.title = "Automatic"
	tracker_test_tick(&app, &input, start + 20_000)
	tracker_test_tick(&app, &input, start + 25_000)
	old_end := app.activities[0].end_ms
	testing.expect(t, db_exec(&app.db, `CREATE TRIGGER deny_snapshot_away BEFORE INSERT ON Activity
		WHEN NEW.DisplayName='Away' BEGIN SELECT RAISE(ABORT, 'test rollback'); END`))
	input.idle = 60_000
	tracker_test_tick(&app, &input, start + 70_000)
	testing.expect(t, app.tracker.idle_pending && !app.tracker.cache_suspended)
	testing.expect(t, app.activities[0].end_ms == old_end, "Rolled-back writes must never change the selected-day cache")
	testing.expect(t, db_exec(&app.db, "DROP TRIGGER deny_snapshot_away"))
	tracker_test_tick(&app, &input, start + 71_000)
	snapshot := build_day_snapshot(&app, input.now, input.now)
	snapshot_expect_ms(t, snapshot, TIMELINE_APPS, 10_000)
	snapshot_expect_ms(t, snapshot, TIMELINE_COMPUTER, 71_000)
	testing.expect(t, len(build_rows(snapshot, TIMELINE_APPS)) == 1)
}

@(test)
snapshot_clock_jump_and_frozen_idle_do_not_invent_live_time :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ds, _ := day_bounds_ms(20261106)
	app := App{date = 20261106}
	app.tracker.current = CurrentActivity{active = true, start_ms = ds, title = "Document"}
	app.tracker.clock_ready = true
	app.tracker.last_wall_ms, app.tracker.last_wall_mono = ds + 5000, 5000
	snapshot_expect_ms(t, build_day_snapshot(&app, ds + 3600_000, 6000), TIMELINE_APPS, 5000)
	app.tracker.idle_pending, app.tracker.idle_observed = true, ds + 5000
	snapshot_expect_ms(t, build_day_snapshot(&app, ds + 8000, 8000), TIMELINE_APPS, 5000)
}

@(test)
snapshot_hits_follow_half_open_painted_order_and_one_pixel_bars :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ds, _ := day_bounds_ms(20261106)
	activities := [?]Activity{
		{id = 1, timeline_id = TIMELINE_APPS, start_ms = ds, end_ms = ds + 10},
		{id = 2, timeline_id = TIMELINE_APPS, start_ms = ds + 10, end_ms = ds + 20},
		{id = 3, timeline_id = TIMELINE_APPS, start_ms = ds + 30, end_ms = ds + 31},
	}
	app := App{date = 20261106, activities = activities[:]}
	snapshot := build_day_snapshot(&app, ds + 1000, 0)
	i := snapshot_bar_hit(snapshot, TIMELINE_APPS, 10, 0, 1000, ds, ds + 1000)
	testing.expect(t, i >= 0 && snapshot.rows[i].activity.id == 2)
	testing.expect(t, snapshot_bar_hit(snapshot, TIMELINE_APPS, 20, 0, 1000, ds, ds + 1000) == -1)
	i = snapshot_bar_hit(snapshot, TIMELINE_APPS, 3, 0, 100, ds, ds + 1000)
	testing.expect(t, i >= 0 && snapshot.rows[i].activity.id == 3, "A sub-pixel activity has the same one-pixel hit target as its painted bar")
}

@(test)
snapshot_task_uses_saved_endpoint_and_survives_missing_cache :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ds, _ := day_bounds_ms(20261107)
	app := App{date = 20261107}
	app.task = RunningTask{id = 1, group_id = 5, name = "Work/Code", color = 0xff123456,
		start_ms = ds - 1000, end_ms = ds + 2000}
	snapshot := build_day_snapshot(&app, ds + 2500, 0)
	snapshot_expect_ms(t, snapshot, TIMELINE_TAGS, 2000)
	rows := build_rows(snapshot, TIMELINE_TAGS)
	testing.expect(t, len(rows) == 1 && rows[0].name == "Work/Code" && rows[0].is_current)
}

@(test)
snapshot_completed_writes_survive_failed_reads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	app.date = date_int_from_unix_ms(input.now)
	tracker_init(&app)
	defer { free_activities(app.activities) }
	defer tracker_shutdown(&app)
	testing.expect(t, load_day(&app))
	start := input.now
	input.info.title = "Next"
	tracker_test_tick(&app, &input, start + 6000)
	progress := DB_Test_Progress{fail_after = 1}
	sqlite3_progress_handler(app.db.handle, 1, db_test_progress, &progress)
	testing.expect(t, !load_day(&app))
	sqlite3_progress_handler(app.db.handle, 0, nil, nil)
	snapshot := build_day_snapshot(&app, start + 7000, start + 7000)
	snapshot_expect_ms(t, snapshot, TIMELINE_APPS, 7000)
	testing.expect(t, len(build_rows(snapshot, TIMELINE_APPS)) == 2 && app.load_result == .Failed)
}

@(test)
snapshot_task_midnight_write_through_and_unresolved_usage_color :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	defer { free_activities(app.activities) }
	defer task_clear(&app.task)
	ds, _ := day_bounds_ms(20261107)
	app.date = 20261106
	input.now = ds - 1000
	testing.expect(t, load_day(&app))
	testing.expect(t, task_start(&app, 0, "Work", input.now))
	app.date = 20261107
	testing.expect(t, load_day(&app) && len(app.activities) == 0)
	input.now = ds + 2000
	testing.expect(t, task_tick(&app, input.now))
	snapshot := build_day_snapshot(&app, input.now, input.now)
	snapshot_expect_ms(t, snapshot, TIMELINE_TAGS, 2000)
	testing.expect(t, len(app.activities) == 1)
	app.tracker.usage_active = true
	app.tracker.usage_start_ms = ds
	app.tracker.usage_kind = .Away
	snapshot = build_day_snapshot(&app, input.now, input.now)
	snapshot_expect_ms(t, snapshot, TIMELINE_COMPUTER, 2000)
	for row in snapshot.rows {
		if row.activity.timeline_id == TIMELINE_COMPUTER {
			testing.expect(t, row.activity.id < 0 && row.activity.group_id < 0)
			_ = activity_colorref(row.activity) // unresolved identity must never index a palette negatively
		}
	}
}
