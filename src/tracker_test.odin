package main

import "core:testing"

Tracker_Test_Input :: struct {
	now, idle: i64,
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
tracker_test_insert :: proc(data: rawptr, db: ^DB, timeline: i64, title: string, group: i64, start, end: i64) -> i64 {
	input := (^Tracker_Test_Input)(data)
	input.inserts += 1
	if input.fail_insert { return 0 }
	return db_insert_activity(db, timeline, title, group, start, end)
}
tracker_test_update :: proc(data: rawptr, db: ^DB, id, end: i64) {
	input := (^Tracker_Test_Input)(data)
	input.updates += 1
	if !input.fail_update { db_update_activity_end(db, id, end) }
}

tracker_test_app :: proc(input: ^Tracker_Test_Input) -> (App, bool) {
	db, ok := db_open(":memory:")
	app := App{db = db}
	app.tracker.io = Tracker_IO{
		data = input, now = tracker_test_now, idle = tracker_test_idle,
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
	testing.expect(t, found && last.id == id && last.end_ms == start + 5000)
	delete(last.display_name)
	tracker_test_tick(&app, &input, start + 15_000)
	last, found = db_last_activity(&app.db, TIMELINE_APPS)
	testing.expect(t, found && last.id == id && last.end_ms == start + 15_000)
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
	testing.expect(t, found && last.start_ms == start && last.end_ms == start + 2000,
		"Pause force-saves even a short activity")
	delete(last.display_name)
	input.now += 10_000
	tracker_resume(&app)
	testing.expect(t, app.tracker.enabled && app.tracker.current.start_ms == input.now)
	input.now += 2000
	tracker_shutdown(&app)
	last, found = db_last_activity(&app.db, TIMELINE_APPS)
	testing.expect(t, found && last.end_ms == input.now)
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
	testing.expect(t, found && last.end_ms == start + 10_000)
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
	// Exercise failed update injection without blessing the existing lost-ack
	// behavior. Retry/acknowledgment assertions belong to the persistence fix.
	input.fail_update = true
	tracker_test_tick(&app, &input, start + 16_000)
	testing.expect(t, input.updates > 0)
	last, found := db_last_activity(&app.db, TIMELINE_APPS)
	testing.expect(t, found && last.end_ms == start + 6000)
	delete(last.display_name)
	input.fail_update = false
}
