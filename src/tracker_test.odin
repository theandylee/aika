package main

import "core:testing"

Tracker_Test_Input :: struct {
	now, idle, mono: i64,
	info: WindowInfo,
	focus_ok: bool,
	samples, inserts, updates: int,
	fail_insert, fail_update: bool,
}

tracker_test_now :: proc(data: rawptr) -> i64 { return (^Tracker_Test_Input)(data).now }
tracker_test_idle :: proc(data: rawptr) -> i64 { return (^Tracker_Test_Input)(data).idle }
tracker_test_foreground :: proc(data: rawptr) -> (WindowInfo, bool) {
	input := (^Tracker_Test_Input)(data)
	input.samples += 1
	return input.info, input.focus_ok
}
tracker_test_insert :: proc(data: rawptr, db: ^DB, timeline: i64, title: string, group: i64, start, end: i64) -> (i64, DB_Result) {
	input := (^Tracker_Test_Input)(data)
	input.inserts += 1
	if input.fail_insert { return 0, .Busy }
	return db_insert_activity(db, timeline, title, group, start, end)
}
tracker_test_update :: proc(data: rawptr, db: ^DB, id, end: i64) -> DB_Result {
	input := (^Tracker_Test_Input)(data)
	input.updates += 1
	if input.fail_update { return .Busy }
	return db_update_activity_end(db, id, end)
}

tracker_test_app :: proc(input: ^Tracker_Test_Input) -> (App, bool) {
	db, ok := db_open(":memory:")
	app := App{db = db}
	app.tracker.io = Tracker_IO{
		data = input, now = tracker_test_now, idle = tracker_test_idle,
		monotonic = tracker_test_now,
		foreground = tracker_test_foreground, insert = tracker_test_insert,
		update_end = tracker_test_update,
	}
	// Fixed UTC instant, with no settings file or foreground desktop dependency.
	input.now = 1_793_923_200_000
	input.info = WindowInfo{file_name = "editor.exe", product = "Editor", title = "Document"}
	input.focus_ok = true
	return app, ok
}

tracker_test_tick :: proc(app: ^App, input: ^Tracker_Test_Input, now: i64) {
	input.now = now
	tracker_tick(app, now)
}

@(test)
tracker_one_minute_idle_threshold :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	 testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	testing.expect(t, app.tracker.idle_threshold_ms == 60_000,
		"Keyboard/mouse inactivity must trigger Away after one minute")
}

@(test)
tracker_sampling_and_write_thresholds :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	testing.expect(t, app.tracker.current.active && app.tracker.current.start_ms == start)
	tracker_test_tick(&app, &input, start)
	samples := input.samples
	tracker_test_tick(&app, &input, start + 999)
	testing.expect(t, input.samples == samples, "Sub-second timer calls do not sample")
	tracker_test_tick(&app, &input, start + 1000)
	testing.expect(t, input.samples == samples + 1)
	tracker_test_tick(&app, &input, start + 4000)
	testing.expect(t, app.tracker.current.persisted_id == 0)
	tracker_test_tick(&app, &input, start + 5000)
	id := app.tracker.current.persisted_id
	testing.expect(t, id > 0, "Persist once at five seconds")
	tracker_test_tick(&app, &input, start + 14_000)
	last, found := db_last_activity(&app.db, TIMELINE_APPS)
	testing.expect(t, found == .Ok && last.id == id && last.end_ms == start + 5000)
	delete(last.display_name)
	tracker_test_tick(&app, &input, start + 15_000)
	last, found = db_last_activity(&app.db, TIMELINE_APPS)
	testing.expect(t, found == .Ok && last.id == id && last.end_ms == start + 15_000)
	delete(last.display_name)
	testing.expect(t, db_count_activities(&app.db) == 2, "One usage row and one application row")
}

@(test)
tracker_focus_identity_and_unavailable_sample :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	tracker_test_tick(&app, &input, start + 5000)
	first := app.tracker.current.persisted_id
	group := app.tracker.current.group_id
	input.focus_ok = false
	tracker_test_tick(&app, &input, start + 6000)
	testing.expect(t, app.tracker.current.persisted_id == first)
	input.focus_ok = true
	input.info.title = "Other document"
	tracker_test_tick(&app, &input, start + 7000)
	testing.expect(t, app.tracker.current.group_id == group && app.tracker.current.title == "Other document")
	testing.expect(t, app.tracker.current.start_ms == start + 7000)
	tracker_test_tick(&app, &input, start + 12_000)
	input.info.file_name = "browser.exe"
	input.info.product = "Browser"
	tracker_test_tick(&app, &input, start + 13_000)
	testing.expect(t, app.tracker.current.group_id != group, "Same title in another app still switches")
	testing.expect(t, app.tracker.current.start_ms == start + 13_000)
}

@(test)
tracker_pause_resume_and_shutdown_use_injected_time :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	start := input.now
	input.now += 2000
	tracker_pause(&app)
	testing.expect(t, !app.tracker.enabled && !app.tracker.current.active)
	last, found := db_last_activity(&app.db, TIMELINE_APPS)
	testing.expect(t, found == .Ok && last.start_ms == start && last.end_ms == start + 2000,
		"Pause force-saves even a short activity")
	delete(last.display_name)
	input.now += 10_000
	tracker_resume(&app)
	testing.expect(t, app.tracker.enabled && app.tracker.current.start_ms == input.now)
	input.now += 2000
	tracker_shutdown(&app)
	last, found = db_last_activity(&app.db, TIMELINE_APPS)
	testing.expect(t, found == .Ok && last.end_ms == input.now)
	delete(last.display_name)
}

@(test)
tracker_idle_transition_with_stable_foreground :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	tracker_test_tick(&app, &input, start + 5000)
	input.idle = 60_000
	tracker_test_tick(&app, &input, start + 70_000)
	testing.expect(t, app.tracker.usage_kind == .Away && !app.tracker.current.active)
	testing.expect(t, app.tracker.usage_start_ms == start + 10_000)
	last, found := db_last_activity(&app.db, TIMELINE_APPS)
	testing.expect(t, found == .Ok && last.end_ms == start + 10_000)
	delete(last.display_name)
	input.idle = 0
	tracker_test_tick(&app, &input, start + 71_000)
	testing.expect(t, app.tracker.usage_kind == .Active && app.tracker.current.active)
	testing.expect(t, app.tracker.current.start_ms == input.now)
}

@(test)
tracker_failed_live_insert_can_be_retried :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	input.fail_insert = true
	tracker_test_tick(&app, &input, start + 5000)
	testing.expect(t, app.tracker.current.active && app.tracker.current.persisted_id == 0)
	testing.expect(t, db_count_activities(&app.db) == 1)
	input.fail_insert = false
	tracker_test_tick(&app, &input, start + 6000)
	testing.expect(t, app.tracker.current.persisted_id > 0)
	testing.expect(t, app.tracker.current.start_ms == start)
	input.fail_update = true
	tracker_test_tick(&app, &input, start + 16_000)
	testing.expect(t, input.updates > 0)
	last, found := db_last_activity(&app.db, TIMELINE_APPS)
	testing.expect(t, found == .Ok && last.end_ms == start + 6000)
	delete(last.display_name)
	testing.expect(t, app.tracker.current.last_db_update_ms == start + 6000,
		"A failed update must not advance the acknowledgment timestamp")
	testing.expect(t, tracker_write_error(&app) == .Busy && app_storage_status(&app) != "")
	input.fail_update = false
	tracker_test_tick(&app, &input, start + 17_000)
	testing.expect(t, app.tracker.current.last_db_update_ms == start + 17_000)
	testing.expect(t, tracker_write_error(&app) == .Ok && app_storage_status(&app) == "")
}

@(test)
tracker_failed_final_insert_owns_completed_interval :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	input.fail_insert = true
	input.info.title = "Next document"
	tracker_test_tick(&app, &input, start + 6000)
	testing.expect(t, app.tracker.pending_count == 1)
	testing.expect(t, app.tracker.current.title == "Next document")
	testing.expect(t, app.tracker.pending[0].title == "Document")
	testing.expect(t, app.tracker.pending[0].start_ms == start && app.tracker.pending[0].end_ms == start + 6000)
	input.fail_insert = false
	tracker_test_tick(&app, &input, start + 7000)
	testing.expect(t, app.tracker.pending_count == 0)
	last, result := db_last_activity(&app.db, TIMELINE_APPS)
	defer delete(last.display_name)
	testing.expect(t, result == .Ok && last.display_name == "Document")
	testing.expect(t, last.start_ms == start && last.end_ms == start + 6000)
	tracker_test_tick(&app, &input, start + 8000)
	testing.expect(t, db_count_activities(&app.db) == 2, "Retrying cannot duplicate completed inserts")
}

@(test)
tracker_pending_endpoint_is_not_reused_by_quick_return :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	tracker_test_tick(&app, &input, start + 5000)
	id := app.tracker.current.persisted_id
	input.fail_update = true
	input.info.title = "Transient"
	tracker_test_tick(&app, &input, start + 6000)
	input.info.title = "Document"
	tracker_test_tick(&app, &input, start + 7000)
	testing.expect(t, app.tracker.pending_count == 1)
	testing.expect(t, app.tracker.current.persisted_id == 0,
		"Do not reuse a row with an older queued final endpoint")
	input.fail_update = false
	tracker_test_tick(&app, &input, start + 8000)
	last, result := db_last_activity(&app.db, TIMELINE_APPS)
	defer delete(last.display_name)
	testing.expect(t, result == .Ok && last.id == id && last.end_ms == start + 7000,
		"The short switch is merged backward into the queued predecessor")
}

@(test)
tracker_usage_insert_retries_without_state_transition :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	input.fail_insert = true
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	testing.expect(t, app.tracker.usage_active && app.tracker.usage_id == 0)
	testing.expect(t, app.tracker.usage_last_db_update == 0)
	input.fail_insert = false
	tracker_test_tick(&app, &input, start + 1000)
	testing.expect(t, app.tracker.usage_id > 0 && app.tracker.usage_start_ms == start)
	testing.expect(t, app.tracker.usage_last_db_update == start + 1000)
	testing.expect(t, tracker_write_error(&app) == .Ok)
}

@(test)
tracker_usage_transition_preserves_failed_writes :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	tracker_test_tick(&app, &input, start + 5000)
	input.fail_insert, input.fail_update = true, true
	input.idle = 60_000
	tracker_test_tick(&app, &input, start + 70_000)
	testing.expect(t, app.tracker.pending_count == 0 && app.tracker.idle_pending)
	testing.expect(t, app.tracker.usage_kind == .Active && app.tracker.usage_active && app.tracker.usage_id > 0,
		"A failed atomic transition keeps the original live state for retry")
	input.fail_insert, input.fail_update = false, false
	tracker_test_tick(&app, &input, start + 71_000)
	testing.expect(t, app.tracker.pending_count == 0 && app.tracker.usage_id > 0)
	testing.expect(t, app.tracker.usage_start_ms == start + 10_000)
	testing.expect(t, db_count_activities(&app.db) == 3)
	testing.expect(t, tracker_write_error(&app) == .Ok)
}

@(test)
tracker_shutdown_reports_failure_and_can_be_retried :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	input.now += 2000
	input.fail_insert, input.fail_update = true, true
	testing.expect(t, !tracker_shutdown(&app))
	testing.expect(t, app.tracker.pending_count == 2)
	testing.expect(t, !app.tracker.current.active && !app.tracker.usage_active)
	testing.expect(t, !tracker_shutdown(&app) && app.tracker.pending_count == 2,
		"Repeated shutdown attempts do not duplicate queued intervals")
	input.fail_insert, input.fail_update = false, false
	testing.expect(t, tracker_shutdown(&app))
	testing.expect(t, app.tracker.pending_count == 0 && db_count_activities(&app.db) == 2)
	last, result := db_last_activity(&app.db, TIMELINE_APPS)
	defer delete(last.display_name)
	testing.expect(t, result == .Ok && last.end_ms == input.now)
}

@(test)
tracker_outage_queue_is_bounded_and_recovers :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start := input.now
	input.fail_insert, input.fail_update = true, true
	for i in 0 ..< TRACKER_PENDING_LIMIT + 10 {
		input.info.title = "A" if i % 2 == 0 else "B"
		tracker_test_tick(&app, &input, start + i64(i + 1) * 6000)
	}
	testing.expect(t, app.tracker.retry_paused && !app.tracker.enabled)
	testing.expect(t, app.tracker.pending_count <= TRACKER_PENDING_LIMIT && app.tracker.pending_count > 0)
	testing.expect(t, !app.tracker.current.active && !app.tracker.usage_active)
	samples := input.samples
	tracker_test_tick(&app, &input, input.now + 1000)
	testing.expect(t, input.samples == samples, "A full queue pauses sampling instead of dropping writes")
	input.fail_insert, input.fail_update = false, false
	for _ in 0 ..< TRACKER_PENDING_LIMIT {
		tracker_test_tick(&app, &input, input.now + 1000)
		if app.tracker.pending_count == 0 { break }
	}
	testing.expect(t, app.tracker.pending_count == 0 && app.tracker.enabled && !app.tracker.retry_paused)
	testing.expect(t, app.tracker.current.active && app.tracker.current.start_ms == input.now)
	testing.expect(t, app_storage_status(&app) == "")
}
